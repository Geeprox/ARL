"""Opt-in Codex-native research over the existing typed store and worker.

Nothing here installs a grant, starts a provider, or changes installed discovery.
The Responses research namespace and its hard-token contract stay independent.
"""
from __future__ import annotations

import json
import time
from dataclasses import dataclass, replace
from pathlib import Path

from .contracts import Fault, encode
from .codex_server import CodexTextAdapter, CONFIG, SCHEMA, DEFAULT_BINARY, THREAD_CONTROLS, TURN_CONTROLS
from .research import ResearchEngine, METHODS as RESEARCH_METHODS, exact, uid, digest, integer, text, sha
from . import codex_contract as contract

NAME = contract.NAME
METHODS = frozenset('codex.' + name for name in RESEARCH_METHODS)
RENDERER = 'tisra.codex.raw-json.v1'
CONTROL_CONTRACT = {
    'protocol_version': '0.159.0', 'controls': CONFIG, 'text_schema': SCHEMA,
    'thread_controls': THREAD_CONTROLS, 'turn_controls': TURN_CONTROLS,
    'renderer_version': RENDERER, 'whole_call_ms': 30000, 'turns': 1,
    'actions': 'reject', 'retries': 0, 'fallback': False,
    'upstream_request_frame_bytes': 32768, 'upstream_response_line_bytes': 65536,
}
# Independent consumer agreement pin, distinct from the requested model pin.
CONTRACT_SHA256 = sha(encode({'formats': contract.FORMATS, 'renderer': RENDERER,
    'limits': contract.LIMITS, 'control_contract': CONTROL_CONTRACT,
    'native_descriptor': 'tisra.codex.v1.maximumOutputTokens=null.maximumTextBytes',
    'request_schema_sha256': '9cdc14e57d1528f4d257c8a1cd79c9c96097b39652ba7272f0a47f650dddeed1'}))


@dataclass(frozen=True)
class CodexResearchGrant:
    provider: str
    models: frozenset
    auth_epoch: str
    contract_sha256: str


class NativeCodexAdapter:
    """Composition of the pinned existing text transport, never another runtime."""
    name = 'codex_app_server'
    formats = contract.FORMATS
    token_hard_cap = False
    contract_sha256 = CONTRACT_SHA256
    contract = contract
    control_contract = CONTROL_CONTRACT

    def __init__(self, models, *, text_adapter=None):
        self.text_adapter = text_adapter or CodexTextAdapter(DEFAULT_BINARY, enabled=False)
        self.evidence = 'test_double' if self.text_adapter.test_command is not None else 'implementation_only'
        if self.text_adapter.test_command is None:
            self.binary_sha256 = self.text_adapter.pin
            control = self.control_contract
            self.fixture_pin = None
        else:
            # Synthetic transport has an actual interpreter binary pin and an
            # explicitly simulated control/fixture pin. It is not live evidence.
            command = self.text_adapter.test_command
            self.binary_sha256 = sha(Path(command[0]).resolve(strict=True).read_bytes())
            self.fixture_pin = sha(Path(command[2]).resolve(strict=True).read_bytes()) if len(command) > 2 and command[1] == '-I' else sha(encode(command))
            control = dict(self.control_contract, test_double_sha256=self.fixture_pin)
        self.control_sha256 = sha(encode(control))
        self.model_fingerprints = {model: contract.model_fingerprint(self.model_evidence(model)) for model in models}

    def model_evidence(self, model):
        return {'source': 'thread_start_confirmed_identifier', 'confirmed_identifier': model,
            'adapter_binary_sha256': self.binary_sha256, 'protocol_version': '0.159.0',
            'control_contract_sha256': self.control_sha256, 'backend_weights_revision': None}

    def preflight(self, args):
        if not self.text_adapter.enabled: raise Fault('paid_provider_disabled')
        self.text_adapter.verify()
        current_control = self.control_contract if self.fixture_pin is None else dict(
            self.control_contract, test_double_sha256=self.fixture_pin)
        if sha(encode(current_control)) != self.control_sha256:
            raise Fault('provider_controls_changed')
        if args['model_fingerprint'] != self.model_fingerprints.get(args['model']):
            raise Fault('research_not_authorized')
        if self.text_adapter.test_command is not None:
            command = self.text_adapter.test_command
            if sha(Path(command[0]).resolve(strict=True).read_bytes()) != self.binary_sha256:
                raise Fault('provider_binary_changed')
            current = sha(Path(command[2]).resolve(strict=True).read_bytes()) if len(command) > 2 and command[1] == '-I' else sha(encode(command))
            if current != self.fixture_pin: raise Fault('provider_binary_changed')

    def complete(self, raw, args, context):
        contract.request_body(raw, args)  # Never transform reviewed bytes.
        self.preflight(args)
        result = self.text_adapter.run({'model': args['model'], 'input': raw.decode('utf-8'),
            'max_output_bytes': args['max_output_bytes']}, context)
        binding, native, evidence = context.native_snapshot()
        envelope = dict(binding, schema_version=1, provider_input_sha256=sha(raw),
            model_evidence=evidence, native=native, text=result['text'],
            output_sha256=sha(result['text'].encode('utf-8')),
            reviewed_evidence_bindings=contract.reviewed_bindings(contract.request_body(raw)),
            usage={'tokens': None, 'cost': None}, token_hard_cap_supported=False)
        reply = encode(envelope)
        contract.result_body(reply, args, binding=binding, native=native,
                             model_evidence=evidence,
                             reviewed_evidence=envelope['reviewed_evidence_bindings'])
        return reply


class NativeContext:
    def __init__(self, engine, context, run):
        self.engine, self.context, self.run = engine, context, run
        self.owner, self.row = context.owner, context.row
        args = json.loads(run['args'])
        self.admitted_model_evidence = engine.adapters[args['provider']].model_evidence(args['model'])
        self.deadline = time.monotonic() + context.remaining(30)

    def check_cancelled(self):
        self.context.check_cancelled()
        if time.monotonic() >= self.deadline: raise Fault('provider_deadline_exceeded')
        with self.engine.store.lock:
            current = self.engine.run(self.run['job'])
            if self.engine.invalid(current): raise Fault('research_invalidated')

    def remaining(self, maximum=30):
        self.check_cancelled()
        return min(maximum, self.context.remaining(maximum), self.deadline - time.monotonic())

    def native_observer(self, event, **fields):
        if event == 'native_thread_ack':
            fields = dict(fields, model_evidence=self.admitted_model_evidence)
        self.engine.record_native(self.run['job'], event, fields)

    def native_snapshot(self):
        with self.engine.store.lock:
            row = self.engine.native_row(self.run['job'])
            return json.loads(row['binding']), self.engine.native_projection(row), json.loads(row['model_evidence'])


class CodexResearchEngine(ResearchEngine):
    contract = contract
    renderer = RENDERER
    contract_sha256 = CONTRACT_SHA256
    structured_generated_citations = False
    name = NAME
    formats = contract.FORMATS
    limits = contract.LIMITS
    request_purpose, descriptor_purpose, response_purpose = contract.REQUEST, contract.DESCRIPTOR, contract.RESPONSE

    def __init__(self, grants, adapters, *, clock=time.time):
        super().__init__(grants, adapters, clock=clock)
        self.tool = replace(self.tool, availability='adapter', description=
            'Host-enabled native Codex. Byte/time/one-turn bounds; no token or cost hard cap or upstream resume.')

    def attach(self, store):
        super().attach(store)
        with store.transaction():
            store.db.execute('''CREATE TABLE IF NOT EXISTS research_native(
                job TEXT PRIMARY KEY, binding TEXT NOT NULL, thread_id TEXT, turn_id TEXT,
                terminal TEXT NOT NULL, interrupt TEXT NOT NULL, model_evidence TEXT)''')

    def grant(self, owner, args=None):
        g = self.grants.get(owner)
        if not isinstance(g, CodexResearchGrant): raise Fault('research_not_authorized')
        a = self.adapters.get(g.provider)
        if (g.provider != 'codex_app_server' or not isinstance(a, NativeCodexAdapter) or
            a.formats != self.formats or g.contract_sha256 != a.contract_sha256):
            raise Fault('unsupported_research_provider')
        if args is not None and (args['provider'] != g.provider or args['model'] not in g.models or
                args['model_fingerprint'] != a.model_fingerprints.get(args['model'])):
            raise Fault('research_not_authorized')
        return g, a

    def submit_args(self, p):
        from .priority import validate_request
        if 'scheduling' in p:validate_request(p['scheduling'])
        exact(p, {'schema_version', 'run_id', 'epoch', 'request', 'descriptor', 'provider', 'model',
            'model_fingerprint', 'request_format', 'output_format', 'history_version',
            'max_output_tokens', 'max_output_bytes', 'priority', 'deadline_ms'} | ({'scheduling'} if 'scheduling' in p else set()))
        integer(p['schema_version'], 1, 1); uid(p['run_id']); integer(p['epoch'], 0, 2147483647)
        if type(p['request']) is dict and type(p['request'].get('byte_count')) is int and p['request']['byte_count'] > 8192:
            raise Fault('codex_input_too_large')
        self.payload_ref(p['request'], self.request_purpose); self.payload_ref(p['descriptor'], self.descriptor_purpose)
        text(p['provider']); text(p['model'], 150); digest(p['model_fingerprint'])
        if tuple(p[k] for k in ('request_format', 'output_format', 'history_version')) != self.formats:
            raise Fault('unsupported_research_format')
        if p['max_output_tokens'] is not None: raise Fault('unsupported_research_budget')
        integer(p['max_output_bytes'], 128, 32768); text(p['priority'], 20)
        integer(p['deadline_ms'], 1, 30000)

    def capability_result(self, owner):
        g, a = self.grant(owner)
        return {'schema_version': 1, 'tool': self.name, 'formats': dict(zip(('request', 'output', 'history'), self.formats)),
            'renderer_version': self.renderer, 'contract_sha256': self.contract_sha256,
            'provider': g.provider, 'provider_evidence': a.evidence,
            'models': {m: a.model_fingerprints[m] for m in sorted(g.models) if m in a.model_fingerprints},
            'model_evidence_basis': 'pinned_adapter_binary_protocol_controls_confirmed_identifier',
            'backend_weights_revision': None, 'max_request_bytes': 8192, 'max_descriptor_bytes': 32768,
            'max_response_bytes': 262144, 'max_output_bytes': 32768, 'max_output_tokens': None,
            'token_hard_cap_supported': False, 'cost_hard_cap_supported': False, 'max_deadline_ms': 30000,
            'max_provider_turns': 1, 'automatic_retries': 0, 'structured_generated_citations': self.structured_generated_citations,
            'request_frame_bytes': 16384, 'response_frame_bytes': 65536}

    def validate_descriptor(self, raw, args): return self.contract.descriptor(raw, args)
    def validate_request(self, raw, args): return self.contract.request_body(raw, args)

    def validate_pair(self, raw, meta, args):
        request, d = self.contract.request_body(raw, args), self.contract.descriptor(meta, args)
        snapshots = self.contract.snapshot_bindings(request) if hasattr(self.contract, 'snapshot_bindings') else [
            {'evidenceID': e['evidence_id'], 'snapshotDigest': e['snapshot_digest']} for e in request['evidence']]
        if d['evidence'] != snapshots:
            raise Fault('descriptor_mismatch')
        migration = request['migration']
        if migration is not None and (not d['startsAlternatePath'] or d['parentRunID'] != migration['parent_run_id'] or
                d['parentFingerprint'] != migration['parent_fingerprint']): raise Fault('descriptor_mismatch')

    def validate_response(self, raw, args, run):
        n = self.native_row(run['job'])
        request = self.object_bytes(run['owner'], args['request'], self.request_purpose, run['run_id'], run['epoch'])
        kwargs = {'request': self.contract.request_body(request)} if self.structured_generated_citations else {}
        return self.contract.result_body(raw, args, binding=json.loads(n['binding']), native=self.native_projection(n),
            model_evidence=json.loads(n['model_evidence']) if n['model_evidence'] else None,
            reviewed_evidence=self.contract.reviewed_bindings(self.contract.request_body(request)), **kwargs)

    def run(self, job):
        r = self.store.db.execute('SELECT * FROM research_runs WHERE job=?', (job,)).fetchone()
        if r is None: raise Fault('research_binding_missing')
        return r

    def original_binding(self, run):
        p = json.loads(run['args'])
        return {'owner': run['owner'], 'job_id': run['job'], 'run_id': run['run_id'],
            'request_sha256': p['request']['sha256'], 'epoch': run['epoch'], 'auth_epoch': run['auth_epoch'],
            **{k: p[k] for k in ('provider', 'model', 'model_fingerprint', 'request_format', 'output_format', 'history_version')}}

    def native_row(self, job):
        row = self.store.db.execute('SELECT * FROM research_native WHERE job=?', (job,)).fetchone()
        if row is None or json.loads(row['binding']) != self.original_binding(self.run(job)):
            raise Fault('research_receipt_mismatch')
        return row

    @staticmethod
    def native_projection(row):
        return {'thread_id': row['thread_id'], 'turn_id': row['turn_id'],
                'terminal': row['terminal'], 'interrupt': row['interrupt']}

    def external_admission(self, run):
        if run['external_started']: raise Fault('research_no_replay')
        p = json.loads(run['args']); _, a = self.grant(run['owner'], p)
        # All rejection and binary verification happens before external admission.
        a.preflight(p)
        raw = self.object_bytes(run['owner'], p['request'], self.request_purpose, run['run_id'], run['epoch'])
        meta = self.object_bytes(run['owner'], p['descriptor'], self.descriptor_purpose, run['run_id'], run['epoch'])
        self.validate_pair(raw, meta, p)
        if self.store.db.execute('SELECT 1 FROM research_native WHERE job=?', (run['job'],)).fetchone():
            raise Fault('research_no_replay')
        self.store.db.execute('INSERT INTO research_native VALUES(?,?,NULL,NULL,?,?,NULL)',
            (run['job'], encode(self.original_binding(run)).decode(), 'unknown', 'not_requested'))

    def provider_context(self, context, run): return NativeContext(self, context, run)

    def record_native(self, job, event, fields):
        relevant = {'native_thread_ack', 'native_turn_ack', 'native_terminal', 'interrupt_sent',
                    'interrupt_ack', 'interrupt_rejected', 'cancel_terminal', 'interrupt_drain_ended'}
        if event not in relevant: return
        with self.store.transaction():
            r, n = self.run(job), self.native_row(job)
            thread_id, turn_id = n['thread_id'], n['turn_id']
            terminal, interrupt, evidence = n['terminal'], n['interrupt'], n['model_evidence']
            if event == 'native_thread_ack':
                value = fields['thread_id']; text(value, 100)
                if thread_id is not None and thread_id != value: raise Fault('provider_contract_mismatch')
                p = json.loads(r['args']); observed = fields['model_evidence']
                if (fields['confirmed_identifier'] != p['model'] or observed['confirmed_identifier'] != fields['confirmed_identifier'] or
                        contract.model_fingerprint(observed) != p['model_fingerprint']): raise Fault('provider_contract_mismatch')
                thread_id = value; evidence = encode(observed).decode()
            elif event == 'native_turn_ack':
                value = fields['turn_id']; text(value, 100)
                if thread_id is None or (turn_id is not None and turn_id != value): raise Fault('provider_contract_mismatch')
                turn_id = value
            elif event in {'native_terminal', 'cancel_terminal'}:
                value = fields['terminal'] if event == 'native_terminal' else fields['status']
                if value not in {'completed', 'interrupted', 'failed'} or not thread_id or not turn_id:
                    raise Fault('provider_contract_mismatch')
                if terminal != 'unknown' and terminal != value: raise Fault('provider_contract_mismatch')
                terminal = value
            elif event == 'interrupt_sent':
                if interrupt == 'not_requested': interrupt = 'sent' if fields.get('request_sent') is True else 'unknown'
            elif event == 'interrupt_ack': interrupt = 'acknowledged'
            elif event == 'interrupt_rejected': interrupt = 'rejected'
            elif event == 'interrupt_drain_ended' and interrupt == 'sent': interrupt = 'unknown'
            self.store.db.execute('UPDATE research_native SET thread_id=?,turn_id=?,terminal=?,interrupt=?,model_evidence=? WHERE job=?',
                (thread_id, turn_id, terminal, interrupt, evidence, job))

    def receipt(self, run):
        result = super().receipt(run)
        row = self.store.db.execute('SELECT * FROM research_native WHERE job=?', (run['job'],)).fetchone()
        native = self.native_projection(self.native_row(run['job'])) if row else {
            'thread_id': None, 'turn_id': None, 'terminal': 'unknown' if run['external_started'] else 'not_started', 'interrupt': 'not_requested'}
        result['native'] = native
        result['external_stop'] = native['terminal']
        return result

    def dispatch(self, owner, method, p, policy, *, in_transaction=False):
        if method not in METHODS: raise Fault('unknown_method')
        mapped = method.removeprefix('codex.')
        # Binding status/cancel/cleanup must remain possible after grant loss.
        # Runtime still enforces current kernel identity and narrow method policy.
        if mapped in {'research.status.v1', 'research.cancel.v1'}:
            with self.store.transaction():
                run = self.binding(owner, p)
                if json.loads(run['args'])['request_format'] != self.formats[0]: raise Fault('research_receipt_mismatch')
                if mapped == 'research.cancel.v1' or self.invalid(run): self.invalidate(run)
                return self.receipt(self.run(run['job']))
        if mapped == 'payload.revoke.v1':
            # No grant required for owner-bound destruction of this exact handle.
            with self.store.lock:
                row = self.payload(owner, p.get('payload_id'), usable=False)
                if row['purpose'] not in self.limits: raise Fault('payload_binding_mismatch')
            return self.payload_rpc(owner, mapped, p)
        if mapped.startswith('payload.'):
            if mapped == 'payload.begin.v1' and p.get('purpose') == self.request_purpose and type(p.get('byte_count')) is int and p['byte_count'] > 8192:
                raise Fault('codex_input_too_large')
            if mapped != 'payload.begin.v1':
                with self.store.lock:
                    row = self.payload(owner, p.get('payload_id'), usable=False)
                    if row['purpose'] not in self.limits: raise Fault('payload_binding_mismatch')
        return super().dispatch(owner, mapped, p, policy,submit_method=method,
                                in_transaction=in_transaction)

    def recover(self):
        """Correlation survives restart; ephemeral upstream turns never resume."""
        with self.store.transaction():
            for r in self.store.db.execute('SELECT * FROM research_runs WHERE external_started=1').fetchall():
                if json.loads(r['args'])['request_format'] != self.formats[0]: continue
                job = self.store.row(r['owner'], r['job'])
                if job['state'] in {'queued', 'running', 'needs_unlock'}:
                    self.store.set_state(job['id'], 'needs_review', error='interrupted')
