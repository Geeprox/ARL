"""Explicit, reviewed Tisra sourced-research host composition candidate.

The installed entry point does not construct this object. A product host must
first register the current Tisra process, select a model, establish the existing
Codex account/model preflight, and supply a current human-reviewed admission.
"""
from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
import struct
import threading
import time
import uuid

from .codex_research import CodexResearchGrant, METHODS as CODEX_METHODS
from .codex_server import CodexTextAdapter, DEFAULT_BINARY
from .codex_sourced_research import CONTRACT_SHA256, NAME
from .codex_sourced_execution import CodexExecutionAdapter as CodexSourcedAdapter, CodexExecutionEngine as CodexSourcedResearchEngine
from .contracts import AppPolicy, Fault, encode
from .formal_peer import FormalTisraPeer, exact_file, HELPER_SHA256, TISRA_EXECUTABLE, TISRA_EXECUTABLE_SHA256
from .identity import RegisteredPeerVerifier
from .priority_host import PriorityHostConfig, RegisteredRouteProducer
from .service import Runtime


@dataclass(frozen=True)
class FormalResearchActivation:
    signed_peer: FormalTisraPeer
    registered_peer: RegisteredPeerVerifier
    text_adapter: CodexTextAdapter
    model: str
    auth_epoch: str
    priority: PriorityHostConfig
    admission: object
    review_revision: str


class BothPeers:
    """A signed binary and the current registered kernel process must agree."""
    def __init__(self, signed, registered):
        self.signed, self.registered = signed, registered
        self.lock = threading.Lock()

    def __call__(self, connection, app):
        if app != 'tisra':
            return None
        if self.signed(connection, app) != app:
            return None
        # The exact signed, pinned application may establish its own observed
        # kernel PID. This is host-side identity observation, not an RPC method
        # or acceptance of a caller-supplied PID. An active second PID denies.
        try:
            with self.lock:
                pid = struct.unpack('i', connection.getsockopt(0, 2, 4))[0]
                with self.registered.lock:
                    others = [(old_pid, entry[2]) for old_pid, entry in self.registered.registry.items()
                              if entry[0] == app and old_pid != pid]
                for old_pid, generation in others:
                    if self.registered.is_registered(app, old_pid):
                        return None
                    self.registered.revoke(old_pid, expected_generation=generation)
                # Revalidate even the fast path: a reused PID, changed process
                # birth or second current subject must never inherit admission.
                if self.registered(connection, app) == app:
                    self.registered.registration_subject(app)
                    return app
                generation = self.registered.register(app, pid, TISRA_EXECUTABLE)
                try:
                    self.registered.registration_subject(app)
                    if self.registered(connection, app) == app:
                        return app
                except Fault:
                    pass
                self.registered.revoke(pid, expected_generation=generation)
                return None
        except (OSError, ValueError, struct.error, Fault):
            return None

    def session_binding(self, connection, app):
        if self(connection, app) != app:
            raise Fault('app_identity_unverified')
        signed = self.signed.session_binding(connection, app)
        registered = self.registered.session_binding(connection, app)
        return signed[0]+registered[0], lambda: signed[1]() and registered[1]()


class FormalAdmission:
    def __init__(self, activation):
        self.activation = activation
        self.revision = activation.review_revision
        self.engine = None

    def evaluate(self, owner, tool, args):
        a = self.activation
        if (owner != 'tisra' or tool != NAME or
                not exact_file(a.signed_peer.helper, HELPER_SHA256) or
                not exact_file(TISRA_EXECUTABLE, TISRA_EXECUTABLE_SHA256)):
            raise Fault('research_host_identity_changed')
        a.registered_peer.registration_subject('tisra')
        a.text_adapter.verify()
        a.admission(owner, tool, args)

    def __call__(self, owner, tool, args):
        # Runtime's worker sees {run_id}; all review decisions use the same
        # persisted, canonical full submit arguments.
        if type(args) is dict and set(args) == {'run_id'}:
            if self.engine is None or self.engine.store is None:
                raise Fault('research_review_not_authorized')
            with self.engine.store.lock:
                run = self.engine.store.db.execute(
                    'SELECT * FROM research_runs WHERE owner=? AND run_id=?',
                    (owner, args['run_id'])).fetchone()
                if run is None:raise Fault('research_review_not_authorized')
                self.engine.require_review(run)
            return
        if self.engine is None:raise Fault('research_review_not_authorized')
        self.engine.submit_args(args)
        self.evaluate(owner, tool, args)


class FormalResearchRuntime(Runtime):
    """Change the formal review epoch under the Store publication lock."""
    @property
    def admission(self):return self._admission

    @admission.setter
    def admission(self, value):
        store=getattr(self,'store',None)
        if store is None:
            self._admission=value
            self.review_epoch=uuid.uuid4().hex
        else:
            with store.lock:
                self._admission=value
                self.review_epoch=uuid.uuid4().hex


def compose_formal_research(home, activation: FormalResearchActivation, *, service_portal=None):
    """Wire the current v2 SDK route with no caller-selected RPC configuration.

    The review admission is checked at both publication and external execution.
    Its issuer and lifecycle are a product decision; no default is manufactured.
    """
    if type(activation) is not FormalResearchActivation:
        raise Fault('research_host_not_admitted')
    a = activation
    if (type(a.signed_peer) is not FormalTisraPeer or
            type(a.registered_peer) is not RegisteredPeerVerifier or
            type(a.text_adapter) is not CodexTextAdapter or
            type(a.priority) is not PriorityHostConfig or a.priority.allow_synthetic or
            not callable(a.admission) or
            type(a.review_revision) is not str or not 1 <= len(a.review_revision) <= 128 or
            any(ord(c) < 33 or ord(c) > 126 for c in a.review_revision) or
            type(a.model) is not str or not 1 <= len(a.model) <= 150 or
            type(a.auth_epoch) is not str or not 1 <= len(a.auth_epoch) <= 128):
        raise Fault('research_host_not_admitted')
    if (not exact_file(a.signed_peer.helper, HELPER_SHA256) or
            not exact_file(TISRA_EXECUTABLE, TISRA_EXECUTABLE_SHA256) or
            a.text_adapter.test_command is not None or not a.text_adapter.enabled or
            a.text_adapter.binary != DEFAULT_BINARY.resolve(strict=True)):
        raise Fault('research_host_identity_changed')
    a.text_adapter.verify()
    # No process is enrolled by source composition. The first exact signed
    # connection establishes its current kernel PID before private RPC dispatch.
    tasks = [t for t in a.priority.tasks if t.tool == NAME and t.owners == frozenset({'tisra'})]
    if (len(tasks) != 1 or tasks[0].task_kind != 'model.inference' or
            tasks[0].resource_kind != a.priority.resources[0].kind):
        raise Fault('research_host_not_admitted')
    a.text_adapter.capture_execution_catalog = True
    native = CodexSourcedAdapter([a.model], text_adapter=a.text_adapter)
    grant = CodexResearchGrant('codex_app_server', frozenset({a.model}),
                               a.auth_epoch, CONTRACT_SHA256)
    review = FormalAdmission(a)

    class AdmittedEngine(CodexSourcedResearchEngine):
        def require_product_active(self):
            current = getattr(a.admission, 'current', None)
            if current is None:
                return  # Other explicit compositions retain their own admission contract.
            if (not callable(current) or not current() or not self.runtime.ready.is_set() or
                    self.runtime.stopping.is_set()):
                raise Fault('research_model_not_ready')
            a.registered_peer.registration_subject('tisra')
            if (not exact_file(a.signed_peer.helper, HELPER_SHA256) or
                    not exact_file(TISRA_EXECUTABLE, TISRA_EXECUTABLE_SHA256)):
                raise Fault('research_host_identity_changed')
            a.text_adapter.verify()

        def require_product_preflight(self):
            self.require_product_active()
            if getattr(a.admission, 'current', None) is None:
                return
            observed = getattr(self.runtime, 'research_preflight_at', None)
            if (type(observed) is not float or
                    not 0 <= time.monotonic() - observed < a.priority.ready_ttl_ms / 1000):
                raise Fault('research_model_not_ready')

        def capability_result(self, owner):
            self.require_product_active()
            return super().capability_result(owner)

        def attach(self, store):
            super().attach(store)
            with store.transaction():
                store.db.execute('''CREATE TABLE IF NOT EXISTS formal_research_reviews(
                    job TEXT PRIMARY KEY, revision TEXT NOT NULL, review_epoch TEXT NOT NULL,
                    binding TEXT NOT NULL)''')

        def review_binding(self, run):
            return hashlib.sha256(encode({'run':self.original_binding(run),
                                          'args':json.loads(run['args'])})).hexdigest()

        def require_review(self, run):
            if self.runtime.admission is not review:
                raise Fault('research_review_not_authorized')
            pin=self.store.db.execute(
                'SELECT * FROM formal_research_reviews WHERE job=?',(run['job'],)).fetchone()
            if pin is None or (pin['revision'],pin['review_epoch'],pin['binding']) != (
                    review.revision,self.runtime.review_epoch,self.review_binding(run)):
                raise Fault('research_review_not_authorized')
            review.evaluate(run['owner'],NAME,json.loads(run['args']))

        def invalid(self, run):
            try:self.require_review(run)
            except Fault:return True
            return super().invalid(run)

        def dispatch(self, owner, method, p, policy):
            if method in {'codex.research.capabilities.v1', 'codex.payload.begin.v1', 'codex.payload.write.v1',
                          'codex.payload.seal.v1', 'codex.research.submit.v1'}:
                if method == 'codex.research.capabilities.v1' and p.get('execution_contract') == 'tisra.codex.execution.v1':
                    self.require_product_active()
                else:
                    self.require_product_preflight()
            if method!='codex.research.submit.v1':
                return super().dispatch(owner,method,p,policy)
            self.submit_args(p)
            with self.store.transaction():
                if self.runtime.admission is not review:
                    raise Fault('research_review_not_authorized')
                review.evaluate(owner,NAME,p)
                old=self.store.db.execute(
                    'SELECT * FROM research_runs WHERE owner=? AND run_id=?',
                    (owner,p['run_id'])).fetchone()
                # The base submit calls receipt before the first review pin is
                # inserted. Its temporary invalid projection has no side effect.
                super().dispatch(owner,method,p,policy,in_transaction=True)
                run=self.store.db.execute(
                    'SELECT * FROM research_runs WHERE owner=? AND run_id=?',
                    (owner,p['run_id'])).fetchone()
                if old is None:
                    self.store.db.execute(
                        'INSERT INTO formal_research_reviews VALUES(?,?,?,?)',
                        (run['job'],review.revision,self.runtime.review_epoch,
                         self.review_binding(run)))
                self.require_review(run)
                return self.receipt(run)

        def external_admission(self, run):
            self.require_review(run)
            super().external_admission(run)

    engine = AdmittedEngine({'tisra': grant}, {'codex_app_server': native})
    from .host import metadata_policies
    policies = metadata_policies()
    policies['tisra'] = AppPolicy(
        frozenset({NAME}), frozenset(), 0, 16, 100,
        methods=frozenset({'health', 'ready', 'capabilities',
                           'priority.negotiate.v2'}) | CODEX_METHODS,
        max_deadline_ms=30000, priority_bands=frozenset({'background','explicit','interactive'}))
    runtime = FormalResearchRuntime(home, policies=policies, local_enabled=False, providers={},
                      identity_verifier=BothPeers(a.signed_peer, a.registered_peer),
                      execute_jobs=True, codex_research=engine,
                      admission=review, service_portal=service_portal)
    engine.runtime=runtime
    review.engine=engine
    producer = RegisteredRouteProducer(runtime, a.registered_peer, a.priority)
    producer.register_native(engine, task_kind=tasks[0].task_kind,
                             resource_kind=tasks[0].resource_kind,
                             backend='codex_app_server')
    return runtime
