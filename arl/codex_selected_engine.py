"""Explicit-review engines using the existing Store, worker, native events and RPCs."""
from __future__ import annotations
import copy
import json
import time
from .contracts import Fault, encode
from .research import sha
from .codex_contract import _same
from .codex_research import CodexResearchEngine, NativeContext
from .codex_sourced_research import CodexSourcedResearchEngine
from . import codex_sourced_contract as sourced
from . import codex_selected_contract as rank
from . import codex_selected_transport as wire


def normalized(args):
    return dict(args, **{key: {k: v for k, v in args[key].items() if k != 'payload_id'}
                        for key in ('request', 'descriptor')})


class ExistingV2Authorization:
    """Reuse the exact existing producer without expanding its tool or consent."""
    tool_name = sourced.NAME

    def __init__(self, admission):
        from .research_product import ResearchAdmission
        if type(admission) is not ResearchAdmission:
            raise Fault('selected_authorization_missing')
        self.admission = admission

    def current(self):
        return self.admission.current()

    def __call__(self, owner, tool, args):
        return self.admission(owner, tool, args)


class SelectedReviewProducer:
    """Host-owned exact reviews, not an RPC, a grant issuer or a configuration flag.

    A trusted product review UI/controller must call approve_exact only after
    reviewing full bytes. The caller also supplies a current source/scope check.
    Nothing calls approve_exact on import, startup, capability lookup or submit.
    """
    def __init__(self, authorization, subject, selection_current, *, clock=time.monotonic):
        if (getattr(authorization, 'tool_name', None) not in {sourced.NAME, rank.NAME} or
                not callable(authorization) or not callable(getattr(authorization, 'current', None)) or
                not callable(subject) or not callable(selection_current)):
            raise Fault('selected_authorization_missing')
        self.authorization, self.subject, self.selection_current = authorization, subject, selection_current
        self.clock = clock
        self.engine = self.runtime = None
        self._records = {}

    def current(self, owner, tool):
        if (owner != 'tisra' or tool != self.authorization.tool_name or
                self.authorization.current() is not True or self.runtime.admission is not self):
            raise Fault('selected_authorization_missing')
        return self.subject(owner)

    def approve_exact(self, owner, args, raw, descriptor_raw, *, ttl_seconds=120):
        if type(ttl_seconds) is not int or not 1 <= ttl_seconds <= 120:
            raise Fault('selected_review_not_admitted')
        engine = self.engine
        if engine is None or engine.store is None:
            raise Fault('selected_review_not_admitted')
        with engine.store.transaction():
            engine.submit_args(args)
            subject = self.current(owner, engine.name)
            self.authorization(owner, engine.name, args)
            grant, _ = engine.grant(owner, args)
            if (sha(raw) != args['request']['sha256'] or len(raw) != args['request']['byte_count'] or
                    sha(descriptor_raw) != args['descriptor']['sha256'] or len(descriptor_raw) != args['descriptor']['byte_count']):
                raise Fault('selected_review_not_admitted')
            engine.validate_pair(raw, descriptor_raw, args)
            request = engine.validate_request(raw, args)
            scope = request.get('scope')
            review = {'operation': engine.operation, 'contract_sha256': engine.contract_sha256,
                      'request_sha256': sha(raw), 'scope': scope}
            evidence = engine.contract.reviewed_bindings(request)
            if self.selection_current(copy.deepcopy(review), copy.deepcopy(evidence)) is not True:
                raise Fault('selected_review_not_admitted')
            key = (owner, args['run_id'], args['epoch'])
            if key in self._records or len(self._records) >= 256:
                raise Fault('selected_review_already_issued')
            self._records[key] = {'args': encode(normalized(args)), 'review': encode(review),
                'evidence': encode(evidence), 'subject': subject, 'auth_epoch': grant.auth_epoch,
                'runtime_epoch': self.runtime.review_epoch, 'expires': self.clock() + ttl_seconds,
                'revoked': False}
            return sha(encode({'args': normalized(args), 'review': review, 'evidence': evidence}))

    def require(self, owner, args):
        engine = self.engine
        subject = self.current(owner, engine.name)
        self.authorization(owner, engine.name, args)
        record = self._records.get((owner, args['run_id'], args['epoch']))
        grant, _ = CodexResearchEngine.grant(engine, owner, args)
        if (record is None or record['revoked'] or self.clock() >= record['expires'] or
                record['args'] != encode(normalized(args)) or record['subject'] != subject or
                record['auth_epoch'] != grant.auth_epoch or record['runtime_epoch'] != self.runtime.review_epoch or
                self.selection_current(json.loads(record['review']), json.loads(record['evidence'])) is not True):
            raise Fault('selected_review_not_admitted')
        return record

    def revoke(self, owner, run_id, epoch):
        with self.engine.store.transaction():
            record = self._records.get((owner, run_id, epoch))
            if record is not None:
                record['revoked'] = True
            run = self.engine.store.db.execute('SELECT * FROM research_runs WHERE owner=? AND run_id=? AND epoch=?',
                                               (owner, run_id, epoch)).fetchone()
            if run is not None:
                self.engine.invalidate(run)

    def __call__(self, owner, tool, args):
        if tool != self.engine.name:
            raise Fault('selected_review_not_admitted')
        with self.engine.store.lock:
            if type(args) is dict and set(args) == {'run_id'}:
                run = self.engine.store.db.execute('SELECT * FROM research_runs WHERE owner=? AND run_id=?',
                                                   (owner, args['run_id'])).fetchone()
                if run is None:
                    raise Fault('selected_review_not_admitted')
                self.engine.require_review(run)
            else:
                self.require(owner, args)


class SelectedNativeContext(NativeContext):
    def native_snapshot(self):
        # Before thread/start acknowledgement there is no persisted model row;
        # use only the already admitted exact model evidence until it arrives.
        with self.engine.store.lock:
            row = self.engine.native_row(self.run['job'])
            evidence = json.loads(row['model_evidence']) if row['model_evidence'] else self.admitted_model_evidence
            return json.loads(row['binding']), self.engine.native_projection(row), copy.deepcopy(evidence)

    def selected_review_current(self, review, binding, phase):
        if phase not in {'submit', 'execute', 'publish'}:
            return False
        with self.engine.store.lock:
            current = self.engine.run(self.run['job'])
            record = self.engine.require_review(current)
            return (_same(binding, self.engine.original_binding(current)) and
                    record['review'] == encode(review))


class ReviewEngine:
    def __init__(self, grants, adapters, producer, *, clock=time.time):
        if type(producer) is not SelectedReviewProducer or producer.engine is not None:
            raise Fault('selected_review_not_admitted')
        self.review = producer
        super().__init__(grants, adapters, clock=clock)
        producer.engine = self

    def grant(self, owner, args=None):
        result = super().grant(owner, args)
        self.review.current(owner, self.name)
        return result

    def submit_args(self, args):
        super().submit_args(args)
        if args['priority'] != 'explicit':
            raise Fault('selected_explicit_submit_required')

    def attach(self, store):
        super().attach(store)
        with store.transaction():
            store.db.execute('CREATE TABLE IF NOT EXISTS selected_research_reviews(job TEXT PRIMARY KEY, binding TEXT NOT NULL)')

    def review_binding(self, run):
        return sha(encode({'run': self.original_binding(run), 'args': normalized(json.loads(run['args']))}))

    def require_review(self, run):
        pin = self.store.db.execute('SELECT binding FROM selected_research_reviews WHERE job=?', (run['job'],)).fetchone()
        if pin is None or pin['binding'] != self.review_binding(run):
            raise Fault('selected_review_not_admitted')
        return self.review.require(run['owner'], json.loads(run['args']))

    def invalid(self, run):
        try:
            self.require_review(run)
        except Fault:
            return True
        return super().invalid(run)

    def dispatch(self, owner, method, params, policy):
        if method != 'codex.research.submit.v1':
            return super().dispatch(owner, method, params, policy)
        self.submit_args(params)
        with self.store.transaction():
            self.review.require(owner, params)
            old = self.store.db.execute('SELECT * FROM research_runs WHERE owner=? AND run_id=?',
                                       (owner, params['run_id'])).fetchone()
            super().dispatch(owner, method, params, policy, in_transaction=True)
            run = self.store.db.execute('SELECT * FROM research_runs WHERE owner=? AND run_id=?',
                                       (owner, params['run_id'])).fetchone()
            if old is None:
                self.store.db.execute('INSERT INTO selected_research_reviews VALUES(?,?)',
                                      (run['job'], self.review_binding(run)))
            self.require_review(run)
            return self.receipt(run)

    def external_admission(self, run):
        self.require_review(run)
        super().external_admission(run)

    def provider_context(self, context, run):
        return SelectedNativeContext(self, context, run)


class SelectedExplanationEngine(ReviewEngine, CodexSourcedResearchEngine):
    operation = 'explain'

    def validate_request(self, raw, args):
        request = super().validate_request(raw, args)
        if not request['evidence']:
            raise Fault('selected_sources_required')
        return request


class SelectedRerankEngine(ReviewEngine, CodexResearchEngine):
    operation = 'rerank'
    name = rank.NAME
    contract = wire
    renderer = wire.RENDERER
    contract_sha256 = rank.CONTRACT_SHA256
    structured_generated_citations = True
    formats = rank.FORMATS
    limits = wire.LIMITS
    request_purpose, descriptor_purpose, response_purpose = wire.REQUEST, wire.DESCRIPTOR, wire.RESPONSE

    def validate_pair(self, raw, meta, args):
        request = rank.request_body(raw, args)
        value = wire.descriptor(meta, args)
        if value['evidence'] != wire.snapshot_bindings(request):
            raise Fault('descriptor_mismatch')

    def validate_response(self, raw, args, run):
        row = self.native_row(run['job'])
        request = self.object_bytes(run['owner'], args['request'], self.request_purpose, run['run_id'], run['epoch'])
        return rank.result_body(raw, args, request=request, binding=json.loads(row['binding']),
            native=self.native_projection(row),
            model_evidence=json.loads(row['model_evidence']) if row['model_evidence'] else None)
