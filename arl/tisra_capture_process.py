"""Explicit host adapter for the finite, private native capture channel.

There is no default consumer, enrollment RPC, subprocess runner, signing
credential or caller-selected socket/library. The supervisor selects every pin
and registers both real processes through RegisteredPeerVerifier. Native Core
independently checks its own source registrations, grants and selected Ledger.
"""
from __future__ import annotations

import base64
import hashlib
import json
import math
import os
import socket
import stat
import struct
import threading
import time
import uuid
from collections import OrderedDict
from dataclasses import dataclass
from pathlib import Path

from .contracts import Fault, encode
from .identity import RegisteredPeerVerifier, process_identity
from .tisra_capture_contract import (
    CaptureBinding, CaptureCodec, CommitConfirmation, MAX_OUTER_BYTES,
    MAX_REQUEST_BYTES, MAX_RESULT_BYTES, RECEIPT_KEYS, parse_outer,
    _digest, _integer, _participant, _string, _uuid,
)
from .tisra_capture_runtime import (
    CODEC, SCHEMA_SHA256, CaptureAuthority, CaptureCommit, CaptureConsumerPin,
    RegisteredCaptureParticipant,
)

CHANNEL_PROTOCOL = 'tisra.capture.channel.v2'
MAX_FRAME_BYTES = 16384
CHUNK_BYTES = 8192
MAX_EVENTS = 64
MAX_OBSERVED_COMMITS = 64
MAX_OBSERVED_REQUEST_BYTES = 8 * 1024 * 1024
_METADATA_KEYS = {'library_id', 'instance_id', 'codec', 'consumer_schema_sha256',
                  'code_sha256', 'ledger_device', 'ledger_inode'}


def _sha(raw):
    return hashlib.sha256(raw).hexdigest()


def _exact(value, keys):
    if type(value) is not dict or set(value) != set(keys):
        raise Fault('capture_channel_invalid')


def _same(value, expected):
    if type(value) is not type(expected):
        return False
    if type(value) is dict:
        return set(value) == set(expected) and all(_same(value[k], v) for k, v in expected.items())
    if type(value) is list:
        return len(value) == len(expected) and all(_same(a, b) for a, b in zip(value, expected))
    return value == expected


def _frame(raw):
    """Decode one complete bounded frame, preserving opaque UTF-8 exactly."""
    if type(raw) is not bytes or not 2 <= len(raw) <= MAX_FRAME_BYTES or not raw.endswith(b'\n'):
        raise Fault('capture_channel_invalid')
    if b'\n' in raw[:-1]:
        raise Fault('capture_channel_invalid')
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError('duplicate field')
            result[key] = value
        return result
    def constant(_):
        raise ValueError('nonfinite constant')
    def tree(value, depth=0):
        if depth > 64:
            raise ValueError('excess depth')
        if type(value) is str:
            value.encode('utf-8', errors='strict')
        elif type(value) is dict:
            for key, item in value.items():
                tree(key, depth + 1); tree(item, depth + 1)
        elif type(value) is list:
            for item in value:
                tree(item, depth + 1)
        elif type(value) is float:
            raise ValueError('channel numbers must be integers')
    try:
        value = json.loads(raw[:-1].decode('utf-8', errors='strict'),
                           object_pairs_hook=pairs, parse_constant=constant)
        tree(value)
    except (ValueError, UnicodeError, RecursionError):
        raise Fault('capture_channel_invalid') from None
    if type(value) is not dict:
        raise Fault('capture_channel_invalid')
    return value


def _image_hash(executable):
    # Hash only a host-observed canonical executable, never an RPC pathname.
    try:
        flags = os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0)
        descriptor = os.open(executable, flags)
        with os.fdopen(descriptor, 'rb') as stream:
            before = os.fstat(stream.fileno())
            if not stat.S_ISREG(before.st_mode):
                raise Fault('capture_process_identity_changed')
            digest = hashlib.sha256()
            while True:
                chunk = stream.read(131072)
                if not chunk:
                    break
                digest.update(chunk)
            after = os.fstat(stream.fileno())
            current = os.stat(executable, follow_symlinks=False)
            fields = lambda info: (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)
            if fields(before) != fields(after) or fields(after) != fields(current):
                raise Fault('capture_process_identity_changed')
            return digest.hexdigest()
    except OSError:
        raise Fault('capture_process_identity_changed') from None


@dataclass(frozen=True)
class CaptureProcessIdentity:
    pid: int
    uid: int
    birth: tuple
    executable: str
    sha256: str
    registration_generation: int

    def to_native(self):
        """Actual process pin for separate synthetic trusted native host setup."""
        return {'pid': self.pid, 'uid': self.uid, 'birth': list(self.birth),
                'executable': self.executable, 'sha256': self.sha256}


def _observe_registration(verifier, app, pid, executable, expected_sha256):
    if type(verifier) is not RegisteredPeerVerifier:
        raise Fault('capture_host_unconfigured')
    _string(app); _integer(pid, 1, 2147483647); _digest(expected_sha256)
    try:
        expected = str(Path(executable).resolve(strict=True))
        with verifier.lock:
            entry = verifier.registry.get(pid)
        current = process_identity(pid)
        if (entry is None or entry[0] != app or current != entry[1] or
                current['uid'] != os.geteuid() or current['executable'] != expected or
                _image_hash(expected) != expected_sha256 or process_identity(pid) != current):
            raise Fault('capture_process_identity_changed')
        with verifier.lock:
            if verifier.registry.get(pid) is not entry:
                raise Fault('capture_process_identity_changed')
        return CaptureProcessIdentity(pid, current['uid'], current['birth'], expected,
                                      expected_sha256, entry[2])
    except (OSError, KeyError, ValueError):
        raise Fault('capture_process_identity_changed') from None


class CaptureProcessRegistrations:
    """Volatile host source PID -> opaque participant mapping, never IPC input.

    Exactly one current registered source process per app is selected here.
    Re-registering in the verifier invalidates this mapping even if PID/image
    remain identical. A host must explicitly replace the mapping/epoch.
    """
    def __init__(self, verifier):
        if type(verifier) is not RegisteredPeerVerifier:
            raise Fault('capture_host_unconfigured')
        self.verifier = verifier
        self._sources = {}
        self._lock = threading.RLock()

    def register(self, app, actual_source_pid, expected_executable, expected_sha256, participant):
        if type(participant) is not RegisteredCaptureParticipant:
            raise Fault('capture_participant_unregistered')
        _string(app); _participant(participant.participant_id); _string(participant.auth_epoch)
        if type(participant.actor_kind) is not str or participant.actor_kind not in {'human', 'agent'}:
            raise Fault('capture_participant_unregistered')
        _integer(actual_source_pid, 1, 2147483647); _digest(expected_sha256)
        try:
            expected = str(Path(expected_executable).resolve(strict=True))
            before = process_identity(actual_source_pid)
            if before['executable'] != expected or _image_hash(expected) != expected_sha256:
                raise Fault('capture_process_identity_changed')
            with self._lock:
                self.verifier.register(app, actual_source_pid, expected)
                identity = _observe_registration(self.verifier, app, actual_source_pid, expected, expected_sha256)
                if before != process_identity(actual_source_pid):
                    self.verifier.revoke(actual_source_pid)
                    raise Fault('capture_process_identity_changed')
                previous = self._sources.get(app)
                self._sources[app] = (participant, identity)
                if previous is not None and previous[1].pid != actual_source_pid:
                    self.verifier.revoke(previous[1].pid)
                return identity
        except OSError:
            raise Fault('capture_process_identity_changed') from None

    def revoke(self, app):
        with self._lock:
            previous = self._sources.pop(app, None)
            if previous is not None:
                self.verifier.revoke(previous[1].pid)

    def identity(self, app, participant):
        with self._lock:
            entry = self._sources.get(app)
            if entry is None or entry[0] != participant or type(participant) is not RegisteredCaptureParticipant:
                raise Fault('capture_participant_unregistered')
            expected = entry[1]
            current = _observe_registration(self.verifier, app, expected.pid,
                                            expected.executable, expected.sha256)
            if current != expected or self._sources.get(app) is not entry:
                raise Fault('capture_participant_unregistered')
            return current

    def __call__(self, app, participant):
        try:
            self.identity(app, participant)
            return True
        except (Fault, OSError):
            return False


class _Connection:
    def __init__(self, consumer):
        self.consumer = consumer
        self.socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.buffer = bytearray()
        self.deadline = time.monotonic() + consumer.timeout

    def __enter__(self):
        try:
            self.socket.settimeout(max(0.001, self.deadline - time.monotonic()))
            self.socket.connect(self.consumer.socket_path)
            self.consumer._check_peer(self.socket)
            return self
        except Exception:
            self.socket.close()
            raise

    def __exit__(self, *_):
        self.socket.close()

    def send(self, value, deadline):
        raw = encode(value) + b'\n'
        if not 2 <= len(raw) <= MAX_FRAME_BYTES:
            raise Fault('capture_channel_invalid')
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise Fault('capture_channel_unavailable')
        self.socket.settimeout(remaining)
        self.socket.sendall(raw)

    def receive(self, deadline):
        while True:
            end = self.buffer.find(b'\n')
            if end >= 0:
                raw = bytes(self.buffer[:end + 1])
                del self.buffer[:end + 1]
                return _frame(raw)
            if len(self.buffer) >= MAX_FRAME_BYTES:
                raise Fault('capture_channel_invalid')
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise Fault('capture_channel_unavailable')
            self.socket.settimeout(remaining)
            raw = self.socket.recv(min(4096, MAX_FRAME_BYTES - len(self.buffer)))
            if not raw:
                raise Fault('capture_channel_unavailable')
            self.buffer.extend(raw)

    def rpc(self, method, params, *, binding=None, authority=None, guard=None, host_method='capture.submit.v1'):
        deadline = self.deadline
        request_id = str(uuid.uuid4())
        self.consumer._check_peer(self.socket)
        self.send({'protocol': CHANNEL_PROTOCOL, 'id': request_id, 'method': method, 'params': params}, deadline)
        seen = set()
        while True:
            reply = self.receive(deadline)
            if 'event' in reply:
                if len(seen) >= MAX_EVENTS:
                    raise Fault('capture_channel_invalid')
                _exact(reply, {'protocol', 'id', 'event', 'context'})
                _uuid(reply['id'])
                if reply['protocol'] != CHANNEL_PROTOCOL or reply['event'] != 'authorize' or reply['id'] in seen:
                    raise Fault('capture_channel_invalid')
                seen.add(reply['id'])
                self.consumer._authorization(self, reply, deadline, binding, authority, guard, host_method)
                continue
            _exact(reply, {'protocol', 'id', 'ok', 'result'} if reply.get('ok') is True
                   else {'protocol', 'id', 'ok', 'error'})
            if reply['protocol'] != CHANNEL_PROTOCOL or reply['id'] != request_id or type(reply['ok']) is not bool:
                raise Fault('capture_channel_invalid')
            self.consumer._check_peer(self.socket)
            if not reply['ok']:
                _exact(reply['error'], {'code'}); _string(reply['error']['code'], 128)
                raise Fault('capture_native_rejected')
            return reply['result']

    def upload(self, raw, kind):
        maximum = MAX_REQUEST_BYTES if kind == 'request' else MAX_RESULT_BYTES
        if type(raw) is not bytes or not 1 <= len(raw) <= maximum:
            raise Fault('capture_payload_mismatch')
        upload_id = str(uuid.uuid4())
        info = {'upload_id': upload_id, 'kind': kind, 'sha256': _sha(raw), 'byte_count': len(raw)}
        if self.rpc('upload.begin', info) is not None:
            raise Fault('capture_channel_invalid')
        for offset in range(0, len(raw), CHUNK_BYTES):
            if self.rpc('upload.append', {'upload_id': upload_id, 'offset': offset,
                    'data_base64': base64.b64encode(raw[offset:offset + CHUNK_BYTES]).decode('ascii')}) is not None:
                raise Fault('capture_channel_invalid')
        sealed = self.rpc('upload.seal', {'upload_id': upload_id})
        expected = {key: info[key] for key in ('upload_id', 'sha256', 'byte_count')}
        if not _same(sealed, expected):
            raise Fault('capture_payload_mismatch')
        return upload_id


class NativeCaptureProcess:
    """Frozen-v1 CaptureConsumer and actual selected-Ledger CaptureCodec.

    authorize is a trusted live host policy/grant callback. It must check the
    exact authority and method against current host configuration, rather than
    accepting request-declared identity. Source registration is rechecked here
    independently; a capture/ACK additionally uses the exact frozen guard.
    """
    def __init__(self, *, socket_path, verifier, native_app, native_pid,
                 expected_executable, expected_sha256, selected_ledger,
                 pin, registrations, authorize, timeout=15.0):
        if (type(pin) is not CaptureConsumerPin or type(registrations) is not CaptureProcessRegistrations or
                registrations.verifier is not verifier or not callable(authorize)):
            raise Fault('capture_host_unconfigured')
        _uuid(pin.library_id); _uuid(pin.instance_id); _digest(pin.code_sha256)
        if (pin.codec, pin.consumer_schema_sha256) != (CODEC, SCHEMA_SHA256) or pin.code_sha256 != expected_sha256:
            raise Fault('capture_consumer_pin_mismatch')
        if type(timeout) not in {int, float} or not math.isfinite(timeout) or not 0 < timeout <= 60:
            raise Fault('capture_host_unconfigured')
        endpoint = Path(socket_path)
        if not endpoint.is_absolute():
            raise Fault('capture_host_unconfigured')
        self.socket_path = str(endpoint)
        self.verifier, self.native_app = verifier, native_app
        self.identity = _observe_registration(verifier, native_app, native_pid, expected_executable, expected_sha256)
        self.pin, self.registrations, self.authorize, self.timeout = pin, registrations, authorize, timeout
        self._local = threading.local()
        self._observed = OrderedDict()
        self._observed_lock = threading.RLock()
        self._ledger_fd = None
        try:
            self.selected_ledger = str(Path(selected_ledger).resolve(strict=True))
            self._ledger_fd = os.open(self.selected_ledger, os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0))
            info = os.fstat(self._ledger_fd)
            if not stat.S_ISREG(info.st_mode):
                raise Fault('capture_consumer_pin_mismatch')
            self._ledger_identity = (info.st_dev, info.st_ino)
            self._check_ledger()
        except Exception:
            self.close()
            raise
        self.codec = CaptureCodec(CODEC, SCHEMA_SHA256, self.validate_request, self.validate_result)

    def close(self):
        descriptor, self._ledger_fd = self._ledger_fd, None
        if descriptor is not None:
            os.close(descriptor)

    def _check_ledger(self):
        try:
            if self._ledger_fd is None:
                raise Fault('capture_consumer_pin_mismatch')
            current, retained = os.stat(self.selected_ledger, follow_symlinks=False), os.fstat(self._ledger_fd)
            if (not stat.S_ISREG(current.st_mode) or (current.st_dev, current.st_ino) != self._ledger_identity or
                    (retained.st_dev, retained.st_ino) != self._ledger_identity):
                raise Fault('capture_consumer_pin_mismatch')
        except OSError:
            raise Fault('capture_consumer_pin_mismatch') from None

    def _check_identity(self):
        actual = _observe_registration(self.verifier, self.native_app, self.identity.pid,
                                       self.identity.executable, self.identity.sha256)
        if actual != self.identity:
            raise Fault('capture_process_identity_changed')
        self._check_ledger()

    def _check_peer(self, connection):
        self._check_identity()
        try:
            pid = struct.unpack('i', connection.getsockopt(0, 2, 4))[0]
        except (OSError, struct.error):
            raise Fault('capture_process_identity_changed') from None
        if pid != self.identity.pid or self.verifier(connection, self.native_app) != self.native_app:
            raise Fault('capture_process_identity_changed')
        self._check_identity()

    def _metadata(self, connection):
        value = connection.rpc('metadata', {})
        _exact(value, _METADATA_KEYS)
        expected = dict(self.pin.__dict__, ledger_device=self._ledger_identity[0], ledger_inode=self._ledger_identity[1])
        if not _same(value, expected):
            raise Fault('capture_consumer_pin_mismatch')
        return self.pin

    def metadata(self):
        # Frozen guard.check reenters metadata during an event on this socket.
        # Only that callback's already observed exact native metadata is reused;
        # the real process/image/registration/Ledger are still checked afresh.
        active = getattr(self._local, 'callback_connection', None)
        if active is not None:
            self._check_peer(active.socket)
            return self.pin
        try:
            with _Connection(self) as connection:
                return self._metadata(connection)
        except (OSError, TimeoutError):
            raise Fault('capture_channel_unavailable') from None

    def _bound(self, binding, authority):
        if type(binding) is not CaptureBinding or type(authority) is not CaptureAuthority:
            raise Fault('capture_authority_changed')
        expected = CaptureAuthority(binding.writer_app, binding.participant_id, binding.actor_kind,
                                    binding.library_id, self.pin.instance_id, binding.auth_epoch, binding.admission_sha256)
        if authority != expected or binding.library_id != self.pin.library_id or (binding.codec, binding.consumer_schema_sha256) != (CODEC, SCHEMA_SHA256):
            raise Fault('capture_authority_changed')
        _uuid(binding.capture_request_id); _digest(binding.request_sha256); _digest(binding.admission_sha256)
        _integer(binding.request_bytes, 1, MAX_REQUEST_BYTES)
        _string(binding.writer_app); _participant(binding.participant_id); _string(binding.auth_epoch)
        if type(binding.actor_kind) is not str or binding.actor_kind not in {'human', 'agent'}:
            raise Fault('capture_authority_changed')
        participant = RegisteredCaptureParticipant(binding.participant_id, binding.actor_kind, binding.auth_epoch)
        if not self.registrations(binding.writer_app, participant):
            raise Fault('capture_participant_unregistered')
        return participant

    def _live_authority(self, connection, binding, authority, guard, host_method):
        self._check_peer(connection.socket)
        self._bound(binding, authority)
        if guard is not None:
            if guard.binding != binding or guard.authority != authority:
                raise Fault('capture_guard_invalid')
            guard.check()
        if self.authorize(authority, host_method) is not True:
            raise Fault('capture_not_authorized')
        self._bound(binding, authority)
        self._check_peer(connection.socket)

    def _authorization(self, connection, event, deadline, binding, authority, guard, host_method):
        context = event['context']
        _exact(context, {'capture_request_id', 'request_sha256', 'request_bytes', 'stage', 'index'})
        if binding is None or authority is None:
            raise Fault('capture_channel_invalid')
        expected = {'capture_request_id': binding.capture_request_id,
                    'request_sha256': binding.request_sha256, 'request_bytes': binding.request_bytes}
        if any(not _same(context[key], value) for key, value in expected.items()):
            raise Fault('capture_channel_invalid')
        stage = context['stage']
        if type(stage) is not str or stage not in {'admission', 'record', 'completion'}:
            raise Fault('capture_channel_invalid')
        if stage == 'record':
            _integer(context['index'], -1, 7)
        elif context['index'] is not None:
            raise Fault('capture_channel_invalid')
        prior = getattr(self._local, 'callback_connection', None)
        self._local.callback_connection = connection
        allowed = False
        try:
            self._live_authority(connection, binding, authority, guard, host_method)
            allowed = True
        except Exception:
            allowed = False
        finally:
            self._local.callback_connection = prior
        response = {'protocol': CHANNEL_PROTOCOL, 'id': event['id'], 'event': 'authorization', 'allowed': allowed}
        if allowed and stage == 'record' and guard is not None:
            # Native's own corresponding per-record guard is required on its
            # Ledger queue. This records the actual effect authorization gate.
            self._local.callback_connection = connection
            try:
                guard.perform(lambda: connection.send(response, deadline))
            finally:
                self._local.callback_connection = prior
        else:
            connection.send(response, deadline)

    @staticmethod
    def _request(binding, raw):
        if type(raw) is not bytes or len(raw) != binding.request_bytes or _sha(raw) != binding.request_sha256:
            raise Fault('capture_payload_mismatch')

    def validate_request(self, raw_request):
        try:
            with _Connection(self) as connection:
                self._metadata(connection)
                request_id = connection.upload(raw_request, 'request')
                if connection.rpc('validate.request', {'request_upload_id': request_id}) is not None:
                    raise Fault('capture_channel_invalid')
        except (OSError, TimeoutError):
            raise Fault('capture_channel_unavailable') from None

    def validate_result(self, raw_result, raw_request, state):
        if type(state) is not str or state not in {'created', 'deduplicated', 'partial'}:
            raise Fault('capture_channel_invalid')
        try:
            with _Connection(self) as connection:
                self._metadata(connection)
                request_id = connection.upload(raw_request, 'request')
                result_id = connection.upload(raw_result, 'result')
                if connection.rpc('validate.result', {'request_upload_id': request_id,
                        'result_upload_id': result_id, 'state': state}) is not None:
                    raise Fault('capture_channel_invalid')
        except (OSError, TimeoutError):
            raise Fault('capture_channel_unavailable') from None

    def _read_commit(self, connection, value, binding, raw_request, authority, request_id, guard):
        _exact(value, {'binding', 'instance_id', 'state', 'transaction_id', 'committed_at_ms', 'result_ref'})
        if not _same(value['binding'], binding.wire()) or value['instance_id'] != self.pin.instance_id:
            raise Fault('capture_commit_unconfirmed')
        state = value['state']
        if type(state) is not str or state not in {'created', 'deduplicated', 'partial', 'needs_review', 'rejected'}:
            raise Fault('capture_channel_invalid')
        if state in {'needs_review', 'rejected'}:
            if any(value[key] is not None for key in ('transaction_id', 'committed_at_ms', 'result_ref')):
                raise Fault('capture_channel_invalid')
            raise Fault('capture_needs_review')
        _uuid(value['transaction_id']); _integer(value['committed_at_ms'], 1, 9007199254740991)
        ref = value['result_ref']
        _exact(ref, {'payload_id', 'sha256', 'byte_count'})
        _uuid(ref['payload_id']); _digest(ref['sha256']); _integer(ref['byte_count'], 1, MAX_RESULT_BYTES)
        if ref['payload_id'] != value['transaction_id']:
            raise Fault('capture_commit_unconfirmed')
        result = bytearray()
        while len(result) < ref['byte_count']:
            offset = len(result)
            limit = min(CHUNK_BYTES, ref['byte_count'] - offset)
            read = connection.rpc('result.read', {'binding': binding.wire(), 'request_upload_id': request_id,
                'payload_id': ref['payload_id'], 'offset': offset, 'limit': limit},
                binding=binding, authority=authority, guard=guard)
            _exact(read, {'offset', 'data_base64', 'eof'})
            if type(read['offset']) is not int or read['offset'] != offset or type(read['eof']) is not bool or type(read['data_base64']) is not str:
                raise Fault('capture_channel_invalid')
            try:
                chunk = base64.b64decode(read['data_base64'], validate=True)
            except (ValueError, UnicodeError):
                raise Fault('capture_channel_invalid') from None
            if (not 1 <= len(chunk) <= limit or
                    base64.b64encode(chunk).decode('ascii') != read['data_base64'] or
                    read['eof'] != (offset + len(chunk) == ref['byte_count'])):
                raise Fault('capture_channel_invalid')
            result.extend(chunk)
        raw_result = bytes(result)
        if _sha(raw_result) != ref['sha256']:
            raise Fault('capture_payload_mismatch')
        result_id = connection.upload(raw_result, 'result')
        if connection.rpc('validate.result', {'request_upload_id': request_id,
                'result_upload_id': result_id, 'state': state}) is not None:
            raise Fault('capture_channel_invalid')
        commit = CaptureCommit(binding, authority, state, raw_result, ref['payload_id'],
                               value['transaction_id'], value['committed_at_ms'])
        with self._observed_lock:
            self._observed[binding.capture_request_id] = (commit, raw_request)
            self._observed.move_to_end(binding.capture_request_id)
            while (len(self._observed) > MAX_OBSERVED_COMMITS or
                   sum(len(pair[1]) for pair in self._observed.values()) > MAX_OBSERVED_REQUEST_BYTES):
                self._observed.popitem(last=False)
        return commit

    def _deliver(self, method, binding, raw_request, authority, guard=None):
        self._bound(binding, authority); self._request(binding, raw_request)
        try:
            with _Connection(self) as connection:
                self._metadata(connection)
                request_id = connection.upload(raw_request, 'request')
                value = connection.rpc(method, {'binding': binding.wire(), 'request_upload_id': request_id},
                                       binding=binding, authority=authority, guard=guard)
                if value is None:
                    if method != 'cached':
                        raise Fault('capture_channel_invalid')
                    return None
                return self._read_commit(connection, value, binding, raw_request, authority, request_id, guard)
        except (OSError, TimeoutError):
            raise Fault('capture_channel_unavailable') from None

    def cached(self, binding, raw_request, authority):
        return self._deliver('cached', binding, raw_request, authority)

    def capture(self, binding, raw_request, authority, guard):
        if guard is None or guard.binding != binding or guard.authority != authority:
            raise Fault('capture_guard_invalid')
        return self._deliver('execute', binding, raw_request, authority, guard)

    def _observed_commit(self, commit, authority, raw_request=None):
        if type(commit) is not CaptureCommit or commit.authority != authority:
            raise Fault('capture_commit_unconfirmed')
        if (type(commit.raw_result) is not bytes or not 1 <= len(commit.raw_result) <= MAX_RESULT_BYTES or
                type(commit.state) is not str or commit.state not in {'created', 'deduplicated', 'partial'}):
            raise Fault('capture_commit_unconfirmed')
        _uuid(commit.transaction_id); _uuid(commit.result_payload_id)
        _integer(commit.committed_at_ms, 1, 9007199254740991)
        self._bound(commit.binding, authority)
        with self._observed_lock:
            observed = self._observed.get(commit.binding.capture_request_id)
        if observed is None or not _same(commit.__dict__, observed[0].__dict__) or raw_request is not None and observed[1] != raw_request:
            raise Fault('capture_commit_unconfirmed')
        self._request(commit.binding, observed[1])
        return observed[1]

    @staticmethod
    def _outer(commit, raw_outer):
        value = parse_outer(raw_outer)
        _exact(value, RECEIPT_KEYS)
        expected = dict(commit.binding.wire(), schema_version=1, state=commit.state,
            commit={'transaction_id': commit.transaction_id, 'committed_at_ms': commit.committed_at_ms},
            result_ref={'payload_id': commit.result_payload_id, 'sha256': _sha(commit.raw_result),
                        'byte_count': len(commit.raw_result)})
        if not _same(value, expected) or raw_outer != encode(expected) or len(raw_outer) > MAX_OUTER_BYTES:
            raise Fault('capture_commit_unconfirmed')

    def confirm(self, commit, raw_outer_receipt, raw_request, authority):
        self._observed_commit(commit, authority, raw_request)
        self._outer(commit, raw_outer_receipt)
        try:
            with _Connection(self) as connection:
                self._metadata(connection)
                request_id = connection.upload(raw_request, 'request')
                value = connection.rpc('confirm', {'binding': commit.binding.wire(), 'request_upload_id': request_id,
                    'outer_receipt_base64': base64.b64encode(raw_outer_receipt).decode('ascii')},
                    binding=commit.binding, authority=authority)
                expected = {'library_id': commit.binding.library_id, 'capture_request_id': commit.binding.capture_request_id,
                    'transaction_id': commit.transaction_id, 'receipt_sha256': _sha(raw_outer_receipt)}
                if not _same(value, expected):
                    raise Fault('capture_commit_unconfirmed')
                # This constructor is reached only after exact observed native
                # Core confirmation, never from a local parser or claimed proof.
                return CommitConfirmation(**value)
        except (OSError, TimeoutError):
            raise Fault('capture_channel_unavailable') from None

    def acknowledge(self, commit, raw_outer_receipt, authority, guard):
        raw_request = self._observed_commit(commit, authority)
        self._outer(commit, raw_outer_receipt)
        if guard is None or guard.binding != commit.binding or guard.authority != authority:
            raise Fault('capture_guard_invalid')
        try:
            with _Connection(self) as connection:
                self._metadata(connection)
                request_id = connection.upload(raw_request, 'request')
                if connection.rpc('ack', {'binding': commit.binding.wire(), 'request_upload_id': request_id,
                        'outer_receipt_base64': base64.b64encode(raw_outer_receipt).decode('ascii')},
                        binding=commit.binding, authority=authority, guard=guard) is not None:
                    raise Fault('capture_commit_unconfirmed')
        except (OSError, TimeoutError):
            raise Fault('capture_channel_unavailable') from None

    def report_uncertain(self, binding, authority):
        # Safety-only holds remain possible after source revocation. The pinned
        # native process independently restricts this to its exact bound journal.
        if type(binding) is not CaptureBinding or type(authority) is not CaptureAuthority:
            raise Fault('capture_authority_changed')
        expected = CaptureAuthority(binding.writer_app, binding.participant_id, binding.actor_kind,
                                    binding.library_id, self.pin.instance_id, binding.auth_epoch, binding.admission_sha256)
        if authority != expected:
            raise Fault('capture_authority_changed')
        if binding.library_id != self.pin.library_id or (binding.codec, binding.consumer_schema_sha256) != (CODEC, SCHEMA_SHA256):
            raise Fault('capture_authority_changed')
        _uuid(binding.capture_request_id); _digest(binding.request_sha256); _digest(binding.admission_sha256)
        _integer(binding.request_bytes, 1, MAX_REQUEST_BYTES)
        try:
            with _Connection(self) as connection:
                self._metadata(connection)
                if connection.rpc('hold', {'binding': binding.wire()}) is not None:
                    raise Fault('capture_channel_invalid')
        except (OSError, TimeoutError):
            raise Fault('capture_channel_unavailable') from None
