"""Optional capture host composition. No transport, enrollment or default grant.

Only host objects implement the consumer, immutable upload resolver, registered
peer lookup and live authorization callbacks. None is accepted through IPC.
SQLite contains delivery metadata; Tisra owns source records and receipt bytes.
"""
from __future__ import annotations

import base64
import hashlib
import json
import threading
import time
from dataclasses import dataclass
from typing import Callable, Protocol

from .contracts import Fault, Tool, encode, object_schema, string
from .tisra_capture_contract import (
    NAME, REQUEST_PURPOSE, MAX_REQUEST_BYTES, MAX_RESULT_BYTES, MAX_OUTER_BYTES,
    CaptureBinding, CaptureCodec, CaptureContext, CommitConfirmation,
    _codec_matches, _digest, _integer, _participant, _string, _uuid,
    _validate_inner, receipt_body, submission_body, validate_request, validated_result,
)

CODEC = 'tisra.link-capture.inner.v1'
SCHEMA_SHA256 = 'f6a6618c280e78389cce1846f24613689ba4c166604597f93aafe9904cef3ce8'
METHODS = frozenset({'capture.capabilities.v1', 'capture.submit.v1',
                     'capture.status.v1', 'capture.cancel.v1', 'capture.result.read.v1'})
READ_CHUNK = 8192


def _exact(value, keys):
    if type(value) is not dict or set(value) != set(keys):
        raise Fault('capture_invalid_arguments')


def _sha(raw):
    return hashlib.sha256(raw).hexdigest()


@dataclass(frozen=True)
class RegisteredCaptureParticipant:
    participant_id: str
    actor_kind: str
    auth_epoch: str


@dataclass(frozen=True)
class CaptureConsumerPin:
    library_id: str
    instance_id: str
    code_sha256: str
    codec: str = CODEC
    consumer_schema_sha256: str = SCHEMA_SHA256


@dataclass(frozen=True)
class CaptureAuthority:
    """Actual authority mapped by the host, never a request attribution."""
    writer_app: str
    participant_id: str
    actor_kind: str
    library_id: str
    instance_id: str
    auth_epoch: str
    admission_sha256: str


@dataclass(frozen=True)
class CapturePayloadRequest:
    owner: str
    capture_request_id: str
    auth_epoch: str
    payload_id: str
    sha256: str
    byte_count: int
    purpose: str = REQUEST_PURPOSE


@dataclass(frozen=True)
class UploadedCapturePayload:
    """Capability returned by an authenticated host upload registration adapter.

    Existing research payload purposes do not include capture. The resolver must
    establish ownership, purpose, request ID, epoch and sealed immutable bytes.
    This object is deliberately not decoded from JSON and offers no path/URL.
    """
    request: CapturePayloadRequest
    raw: bytes
    sealed: bool
    expires_at: float


class CapturePayloadResolver(Protocol):
    def resolve(self, request: CapturePayloadRequest) -> UploadedCapturePayload: ...


@dataclass(frozen=True)
class CaptureCommit:
    """Consumer-owned journal output, including a stable result capability ID.

    An implementation returns this only after its durable journal commit. The
    independent confirm() call must verify that exact outer digest against the
    original journal, including authority, binding, transaction and result bytes.
    Merely constructing this Python object supplies no live transaction evidence.
    """
    binding: CaptureBinding
    authority: CaptureAuthority
    state: str
    raw_result: bytes
    result_payload_id: str
    transaction_id: str
    committed_at_ms: int


class CaptureConsumer(Protocol):
    def metadata(self) -> CaptureConsumerPin: ...
    def cached(self, binding: CaptureBinding, raw_request: bytes,
               authority: CaptureAuthority) -> CaptureCommit | None: ...
    def capture(self, binding: CaptureBinding, raw_request: bytes,
                authority: CaptureAuthority, guard: CaptureExecutionGuard) -> CaptureCommit: ...
    def confirm(self, commit: CaptureCommit, raw_outer_receipt: bytes, raw_request: bytes,
                authority: CaptureAuthority) -> CommitConfirmation: ...
    def acknowledge(self, commit: CaptureCommit, raw_outer_receipt: bytes,
                    authority: CaptureAuthority, guard: CaptureExecutionGuard) -> None: ...
    def report_uncertain(self, binding: CaptureBinding, authority: CaptureAuthority) -> None: ...


class CaptureExecutionGuard:
    """Host-only per-effect gate supplied to the separately trusted consumer.

    perform() holds host configuration stable while rechecking registration,
    dynamic authorization, native consumer pins, current AppPolicy and cancel.
    A native transport adapter must additionally run the corresponding native
    guard atomically at each Ledger/journal effect; a preflight alone is unsafe.
    """
    def __init__(self, engine, binding, authority, context):
        self.engine, self.binding, self.authority, self.context = engine, binding, authority, context
        self.effects = 0

    def check(self):
        self.context.check_cancelled()
        self.engine._recheck(self.binding, self.authority, 'capture.submit.v1')

    def perform(self, effect: Callable):
        if not callable(effect):
            raise Fault('capture_guard_invalid')
        with self.engine._configuration_lock:
            self.check()
            self.effects += 1
            return effect()


class _CompletionContext:
    def __init__(self, engine, row):
        self.engine, self.row = engine, row

    def check_cancelled(self):
        with self.engine.store.lock:
            current = self.engine.store.row(self.row['owner'], self.row['job'])
            if (self.engine.runtime.stopping.is_set() or current['cancel'] or
                    current['state'] != 'running' or current['deadline_at'] is not None and
                    current['deadline_at'] <= self.engine.clock()):
                raise Fault('capture_needs_review')


class CaptureRuntime:
    """Default-disabled, typed non-replayable delivery through an explicit host.

    Each mapping is independently supplied: actual app -> opaque participant;
    (app, participant) -> libraries; (app, participant, library) -> methods; and
    library -> code/schema/instance pin + separately authenticated consumer.
    registered_peer must query the current host registration (PID/birth/image
    mapping), not compare declared app strings or a job's historical boolean.
    authorizer is a live native authority check at admission and every effect.
    """
    name = NAME

    def __init__(self, *, active=False, participants=None, library_grants=None,
                 method_grants=None, pins=None, consumers=None, codec=None,
                 payload_resolver=None, registered_peer=None, authorizer=None,
                 clock=time.time):
        self.active = active
        self.participants = dict(participants or {})
        self.library_grants = dict(library_grants or {})
        self.method_grants = dict(method_grants or {})
        self.pins, self.consumers = dict(pins or {}), dict(consumers or {})
        self.codec, self.payload_resolver = codec, payload_resolver
        self.registered_peer, self.authorizer, self.clock = registered_peer, authorizer, clock
        self._configuration_lock = threading.RLock()
        self.runtime = self.store = None
        self.tool = Tool(NAME, object_schema({'capture_request_id': string(36)}, ['capture_request_id']),
                         self.execute, idempotent=False, permissions=('typed_capture', 'knowledge_write'),
                         availability='host_configuration_required',
                         description='Optional host-pinned Tisra capture; requires typed methods and live authority.')

    def bind_runtime(self, runtime):
        if self.runtime is not None and self.runtime is not runtime:
            raise Fault('capture_runtime_already_bound')
        self.runtime = runtime

    def attach(self, store):
        self.store = store
        with store.transaction():
            store.db.execute('''CREATE TABLE IF NOT EXISTS capture_delivery_v1(
                capture_request_id TEXT PRIMARY KEY, owner TEXT NOT NULL, job TEXT UNIQUE NOT NULL,
                binding TEXT NOT NULL, authority TEXT NOT NULL, payload_ref TEXT NOT NULL,
                external_started INTEGER NOT NULL DEFAULT 0,
                receipt_sha256 TEXT, result_sha256 TEXT)''')

    def configure(self, *, active=None, participants=None, library_grants=None,
                  method_grants=None, pins=None, consumers=None):
        """Host-only replacement/revocation. No IPC configuration method exists."""
        with self._configuration_lock:
            if active is not None: self.active = active
            for name, value in (('participants', participants), ('library_grants', library_grants),
                                ('method_grants', method_grants), ('pins', pins), ('consumers', consumers)):
                if value is not None: setattr(self, name, dict(value))

    def _authorize(self, owner, method, library_id, admission_sha256='0'*64):
        with self._configuration_lock:
            if self.active is not True:
                raise Fault('capture_disabled')
            if (self.runtime is None or self.runtime.identity_verifier is None or
                    not callable(self.registered_peer) or not callable(self.authorizer)):
                raise Fault('capture_host_unconfigured')
            policy = self.runtime.policies.get(owner)
            if policy is None or NAME not in policy.tools or method not in policy.methods:
                raise Fault('capture_not_authorized')
            participant = self.participants.get(owner)
            if type(participant) is not RegisteredCaptureParticipant:
                raise Fault('capture_participant_unregistered')
            _string(owner); _participant(participant.participant_id); _string(participant.auth_epoch)
            if participant.actor_kind not in {'human', 'agent'}:
                raise Fault('capture_participant_unregistered')
            _uuid(library_id); _digest(admission_sha256)
            if library_id not in self.library_grants.get((owner, participant.participant_id), frozenset()):
                raise Fault('capture_library_not_authorized')
            if method not in self.method_grants.get((owner, participant.participant_id, library_id), frozenset()):
                raise Fault('capture_method_not_authorized')
            pin, consumer = self.pins.get(library_id), self.consumers.get(library_id)
            if (type(pin) is not CaptureConsumerPin or consumer is None or
                    any(not callable(getattr(consumer, name, None)) for name in
                        ('metadata', 'cached', 'capture', 'confirm', 'acknowledge', 'report_uncertain'))):
                raise Fault('capture_consumer_unavailable')
            _uuid(pin.library_id); _uuid(pin.instance_id); _digest(pin.code_sha256)
            if pin.library_id != library_id or (pin.codec, pin.consumer_schema_sha256) != (CODEC, SCHEMA_SHA256):
                raise Fault('capture_consumer_pin_mismatch')
            _codec_matches(self.codec, CODEC, SCHEMA_SHA256)
            try:
                registered = self.registered_peer(owner, participant)
                metadata = consumer.metadata()
            except Exception:
                raise Fault('capture_authority_unavailable') from None
            if registered is not True:
                raise Fault('capture_participant_unregistered')
            if type(metadata) is not CaptureConsumerPin or metadata != pin:
                raise Fault('capture_consumer_pin_mismatch')
            authority = CaptureAuthority(owner, participant.participant_id, participant.actor_kind,
                                         library_id, pin.instance_id, participant.auth_epoch, admission_sha256)
            try:
                authorized = self.authorizer(authority, method)
            except Exception:
                raise Fault('capture_authority_unavailable') from None
            if authorized is not True:
                raise Fault('capture_not_authorized')
            return authority, consumer

    def _recheck(self, binding, expected, method):
        current, consumer = self._authorize(binding.writer_app, method, binding.library_id, binding.admission_sha256)
        if current != expected:
            raise Fault('capture_authority_changed')
        return consumer

    def _payload(self, binding, ref):
        if self.payload_resolver is None or not callable(getattr(self.payload_resolver, 'resolve', None)):
            raise Fault('capture_payload_resolver_unavailable')
        request = CapturePayloadRequest(binding.writer_app, binding.capture_request_id, binding.auth_epoch,
                                        ref['payload_id'], ref['sha256'], ref['byte_count'])
        try:
            uploaded = self.payload_resolver.resolve(request)
        except Exception:
            raise Fault('capture_payload_unavailable') from None
        if (type(uploaded) is not UploadedCapturePayload or uploaded.request != request or
                uploaded.sealed is not True or type(uploaded.expires_at) not in {int, float} or
                not self.clock() < uploaded.expires_at < float('inf')):
            raise Fault('capture_payload_capability_mismatch')
        raw = uploaded.raw
        if type(raw) is not bytes or not 1 <= len(raw) <= MAX_REQUEST_BYTES:
            raise Fault('capture_request_too_large')
        if len(raw) != binding.request_bytes or _sha(raw) != binding.request_sha256:
            raise Fault('capture_payload_mismatch')
        return raw

    def _delivery(self, owner, capture_request_id):
        _uuid(capture_request_id)
        row = self.store.db.execute('SELECT * FROM capture_delivery_v1 WHERE owner=? AND capture_request_id=?',
                                    (owner, capture_request_id)).fetchone()
        if row is None: raise Fault('capture_not_found')
        return row

    @staticmethod
    def _objects(row):
        return CaptureBinding(**json.loads(row['binding'])), CaptureAuthority(**json.loads(row['authority']))

    def _hold(self, row, error='capture_needs_review'):
        with self.store.transaction():
            self.store.db.execute('UPDATE jobs SET cancel=1 WHERE id=?', (row['job'],))
            self.store.set_state(row['job'], 'needs_review', error=error)
            self.store.audit(row['owner'], row['job'], 'capture_needs_review')
        # Safety notification only: its native implementation may only hold the
        # original journal entry, and must never write/replay source content.
        binding, authority = self._objects(row)
        consumer, pin = self.consumers.get(binding.library_id), self.pins.get(binding.library_id)
        try:
            if (type(pin) is CaptureConsumerPin and pin.instance_id == authority.instance_id and
                    consumer is not None and consumer.metadata() == pin):
                consumer.report_uncertain(binding, authority)
        except Exception:
            pass  # The durable ARL hold remains even when the native notice is lost.

    def _confirmed(self, row, commit, raw_request, method):
        binding, authority = self._objects(row)
        consumer = self._recheck(binding, authority, method)
        if type(commit) is not CaptureCommit or commit.binding != binding or commit.authority != authority:
            raise Fault('capture_commit_unconfirmed')
        if commit.state not in {'created', 'deduplicated', 'partial'}:
            raise Fault('capture_commit_unconfirmed')
        _uuid(commit.result_payload_id); _uuid(commit.transaction_id)
        _integer(commit.committed_at_ms, 1, 9007199254740991)
        if type(commit.raw_result) is not bytes or not 1 <= len(commit.raw_result) <= MAX_RESULT_BYTES:
            raise Fault('capture_result_too_large')
        receipt = dict(binding.wire(), schema_version=1, state=commit.state,
                       commit={'transaction_id': commit.transaction_id, 'committed_at_ms': commit.committed_at_ms},
                       result_ref={'payload_id': commit.result_payload_id, 'sha256': _sha(commit.raw_result),
                                   'byte_count': len(commit.raw_result)})
        raw_outer = encode(receipt)
        if len(raw_outer) > MAX_OUTER_BYTES: raise Fault('capture_outer_too_large')
        try:
            confirmation = consumer.confirm(commit, raw_outer, raw_request, authority)
        except Exception:
            raise Fault('capture_commit_unconfirmed') from None
        validated_result(raw_outer, binding, commit.raw_result, raw_request,
                         codec=self.codec, confirmation=confirmation)
        self._recheck(binding, authority, method)
        if row['receipt_sha256'] is not None and (row['receipt_sha256'] != _sha(raw_outer) or
                                                 row['result_sha256'] != _sha(commit.raw_result)):
            raise Fault('capture_cached_receipt_changed')
        return receipt, raw_outer

    def _projection(self, row, receipt=None):
        binding, _ = self._objects(row)
        job = self.store.row(row['owner'], row['job'])
        if job['state'] == 'needs_review':
            receipt = dict(binding.wire(), schema_version=1, state='needs_review', commit=None, result_ref=None)
            receipt_body(receipt, binding)
        return {'schema_version': 1, 'job_id': row['job'], 'binding': binding.wire(),
                'state': job['state'], 'receipt': receipt, 'error_code': job['error'],
                'external_stop': 'unknown' if row['external_started'] else 'not_started'}

    def dispatch(self, owner, method, params, policy, *, verified_app=None):
        if verified_app != owner: raise Fault('app_identity_unverified')
        if method == 'capture.capabilities.v1':
            _exact(params, {'library_id'})
            authority, _ = self._authorize(owner, method, params['library_id'])
            return {'schema_version': 1, 'tool': NAME, 'codec': CODEC, 'consumer_schema_sha256': SCHEMA_SHA256,
                    'library_id': authority.library_id, 'instance_id': authority.instance_id,
                    'consumer_code_sha256': self.pins[authority.library_id].code_sha256,
                    'writer_app': authority.writer_app,
                    'writing_participant': {'participant_id': authority.participant_id, 'actor_kind': authority.actor_kind},
                    'auth_epoch': authority.auth_epoch,
                    'max_request_bytes': MAX_REQUEST_BYTES, 'max_result_bytes': MAX_RESULT_BYTES,
                    'max_outer_bytes': MAX_OUTER_BYTES, 'frame_bytes': 16384,
                    'payload_upload': 'host_registered_immutable_capability_required', 'automatic_replay': False}
        if method == 'capture.submit.v1':
            from .priority import validate_request as validate_scheduling
            _exact(params, {'key', 'request'} | ({'scheduling'} if 'scheduling' in params else set()))
            if 'scheduling' in params:validate_scheduling(params['scheduling'])
            request = submission_body(params['request'])
            if params['key'] != request['capture_request_id']: raise Fault('capture_key_mismatch')
            authority, _ = self._authorize(owner, method, request['library_id'])
            context = CaptureContext(owner, authority.participant_id, authority.actor_kind, authority.library_id,
                                     authority.auth_epoch, CODEC, SCHEMA_SHA256, active=True, write_granted=True)
            # Resolve only after current host authority; never a caller path or URL.
            provisional = CaptureBinding(request['capture_request_id'], request['payload']['sha256'],
                request['payload']['byte_count'], request['library_id'], CODEC, SCHEMA_SHA256,
                '0'*64, owner, authority.participant_id, authority.actor_kind, authority.auth_epoch)
            raw = self._payload(provisional, request['payload'])
            binding = validate_request(request, raw, context, codec=self.codec)
            authority, _ = self._authorize(owner, method, binding.library_id, binding.admission_sha256)
            with self._configuration_lock, self.store.transaction():
                self._recheck(binding, authority, method)
                old = self.store.db.execute('SELECT * FROM capture_delivery_v1 WHERE capture_request_id=?',
                                            (binding.capture_request_id,)).fetchone()
                if old is not None:
                    if self._objects(old) != (binding, authority): raise Fault('capture_idempotency_conflict')
                    self.store.submit(owner,binding.capture_request_id,self.tool,
                        {'capture_request_id':binding.capture_request_id},policy,verified=True,
                        in_transaction=True,priority_request=params.get('scheduling'))
                    # Immutable logical bytes may have a new upload capability.
                    self.store.db.execute('UPDATE capture_delivery_v1 SET payload_ref=? WHERE job=?',
                                          (encode(request['payload']).decode(), old['job']))
                    row = self._delivery(owner, binding.capture_request_id)
                else:
                    if self.store.db.execute('SELECT COUNT(*) FROM capture_delivery_v1').fetchone()[0] >= 4096:
                        raise Fault('capture_budget_exceeded')
                    job = self.store.submit(owner, binding.capture_request_id, self.tool,
                        {'capture_request_id': binding.capture_request_id}, policy, verified=True, in_transaction=True,
                        priority_request=params.get('scheduling'))
                    self.store.db.execute('INSERT INTO capture_delivery_v1(capture_request_id,owner,job,binding,authority,payload_ref) VALUES(?,?,?,?,?,?)',
                        (binding.capture_request_id, owner, job['id'], encode(binding.__dict__).decode(),
                         encode(authority.__dict__).decode(), encode(request['payload']).decode()))
                    row = self._delivery(owner, binding.capture_request_id)
            return self._status(row, method, raw_request=raw)
        if method in {'capture.status.v1', 'capture.cancel.v1', 'capture.result.read.v1'}:
            keys = {'capture_request_id', 'admission_sha256'}
            if method == 'capture.result.read.v1': keys |= {'offset', 'limit'}
            _exact(params, keys); _digest(params['admission_sha256'])
            with self.store.lock:
                row = self._delivery(owner, params['capture_request_id'])
            binding, authority = self._objects(row)
            if params['admission_sha256'] != binding.admission_sha256: raise Fault('capture_receipt_mismatch')
            try:
                self._recheck(binding, authority, method)
            except Fault:
                self._hold(row, 'capture_authority_changed')
                raise
            if method == 'capture.cancel.v1':
                if row['external_started']:
                    self._hold(row, 'capture_cancelled_after_admission')
                else:
                    self.store.cancel(owner, row['job'])
                return self._projection(row)
            if method == 'capture.status.v1': return self._status(row, method)
            _integer(params['offset'], 0, MAX_RESULT_BYTES); _integer(params['limit'], 1, READ_CHUNK)
            if self.store.row(owner, row['job'])['state'] != 'succeeded': raise Fault('capture_not_committed')
            commit, receipt, _ = self._cached(row, method)
            if params['offset'] > len(commit.raw_result): raise Fault('capture_invalid_arguments')
            raw = commit.raw_result[params['offset']:params['offset']+params['limit']]
            with self._configuration_lock:
                self._recheck(binding, authority, method)
                if self.store.row(owner, row['job'])['state'] != 'succeeded': raise Fault('capture_not_committed')
                return dict(schema_version=1, result_ref=receipt['result_ref'], offset=params['offset'],
                            data_base64=base64.b64encode(raw).decode(),
                            eof=params['offset']+len(raw) == len(commit.raw_result))
        raise Fault('unknown_method')

    def _cached(self, row, method, raw_request=None):
        binding, authority = self._objects(row)
        try:
            consumer = self._recheck(binding, authority, method)
            raw = raw_request if raw_request is not None else self._payload(binding, json.loads(row['payload_ref']))
            commit = consumer.cached(binding, raw, authority)
            receipt, raw_outer = self._confirmed(row, commit, raw, method)
            return commit, receipt, raw_outer
        except Exception:
            self._hold(row, 'capture_cached_receipt_unavailable')
            raise Fault('capture_needs_review') from None

    def _status(self, row, method, raw_request=None):
        receipt = None
        if self.store.row(row['owner'], row['job'])['state'] == 'succeeded':
            _, receipt, _ = self._cached(row, method, raw_request)
        with self._configuration_lock:
            binding, authority = self._objects(row)
            self._recheck(binding, authority, method)
            result=self._projection(row, receipt)
            job=self.store.row(row['owner'],row['job'])
            if job['schedule_v1']:
                scheduling=self.store.project(job).get('scheduling')
                if scheduling is not None:result['scheduling']=scheduling
            return result

    def execute(self, args, context):
        with self.store.lock:
            row = self._delivery(context.owner, args['capture_request_id'])
            if row['job'] != context.row['id']: raise Fault('capture_receipt_mismatch')
        binding, authority = self._objects(row)
        guard = CaptureExecutionGuard(self, binding, authority, context)
        guard.check()
        raw = self._payload(binding, json.loads(row['payload_ref']))
        _validate_inner(self.codec.validate_request, raw)
        # An uncertain attempt is durable before contacting the consumer. It
        # never becomes queued again, including callback exceptions or lost ack.
        with self._configuration_lock, self.store.transaction():
            guard.check()
            fresh = self._delivery(context.owner, args['capture_request_id'])
            if fresh['external_started']: raise Fault('capture_needs_review')
            self.store.db.execute('UPDATE capture_delivery_v1 SET external_started=1 WHERE job=?', (row['job'],))
        consumer = self._recheck(binding, authority, 'capture.submit.v1')
        cached = consumer.cached(binding, raw, authority)
        if cached is not None:
            return cached
        result = consumer.capture(binding, raw, authority, guard)
        if guard.effects < 1: raise Fault('capture_guard_not_used')
        guard.check()
        return result

    def complete(self, job, result=None, error=None):
        with self.store.lock:
            row = self._delivery(job['owner'], json.loads(job['args'])['capture_request_id'])
        if error is not None:
            self._hold(row)
            return
        try:
            binding, authority = self._objects(row)
            self._recheck(binding, authority, 'capture.submit.v1')
            raw = self._payload(binding, json.loads(row['payload_ref']))
            _, raw_outer = self._confirmed(row, result, raw, 'capture.submit.v1')
            guard = CaptureExecutionGuard(self, binding, authority, _CompletionContext(self, row))
            with self._configuration_lock, self.store.transaction():
                guard.check()
                self.store.db.execute('UPDATE capture_delivery_v1 SET receipt_sha256=?,result_sha256=? WHERE job=?',
                                      (_sha(raw_outer), _sha(result.raw_result), row['job']))
            # Native ACK follows durable ARL metadata, with fresh native and host
            # authorization. Any lost ACK keeps this attempt held on both sides.
            consumer = self._recheck(binding, authority, 'capture.submit.v1')
            if consumer.acknowledge(result, raw_outer, authority, guard) is not None:
                raise Fault('capture_commit_unconfirmed')
            with self._configuration_lock, self.store.transaction():
                guard.check()
                self.store.set_state(row['job'], 'succeeded')
                self.store.audit(row['owner'], row['job'], 'capture_confirmed')
        except Exception:
            self._hold(row)

    def recover(self):
        """Restored deliveries are held. Recovery never calls capture/cached."""
        with self.store.lock:
            rows = self.store.db.execute("SELECT c.* FROM capture_delivery_v1 c JOIN jobs j ON j.id=c.job WHERE j.state IN ('queued','running','needs_unlock','needs_review')").fetchall()
        for row in rows: self._hold(row, 'capture_restart_requires_review')
