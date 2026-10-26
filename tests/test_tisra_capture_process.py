"""Real macOS kernel peers around a deliberately synthetic channel fixture.

These focused tests exercise process registration, strict framing, bounded
transport and callback topology. They do not claim Ledger/Core validation;
the separate Swift process integration owns that evidence.
"""
from __future__ import annotations

import base64
import hashlib
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import uuid
from dataclasses import replace
from pathlib import Path
from unittest.mock import patch

from arl.contracts import Fault, encode
from arl.identity import RegisteredPeerVerifier, process_identity
from arl.tisra_capture_contract import CaptureBinding, CaptureCodec, CommitConfirmation, MAX_REQUEST_BYTES, MAX_RESULT_BYTES
from arl.tisra_capture_process import (
    CHANNEL_PROTOCOL, MAX_FRAME_BYTES, CaptureProcessRegistrations,
    NativeCaptureProcess, _Connection, _frame, _image_hash,
)
from arl.tisra_capture_runtime import (
    CODEC, SCHEMA_SHA256, CaptureAuthority, CaptureCommit, CaptureConsumerPin,
    RegisteredCaptureParticipant,
)

FIXTURES = Path(__file__).resolve().parents[1] / 'integrations/tisra/capture-inner-v1'


def uid(): return str(uuid.uuid4())
def sha(raw): return hashlib.sha256(raw).hexdigest()


class Guard:
    def __init__(self, consumer, binding, authority):
        self.consumer, self.binding, self.authority = consumer, binding, authority
        self.effects = self.checks = 0
        self.cancelled = False
        self.lock = threading.RLock()
        self.before_check = None

    def check(self):
        if self.before_check is not None:
            self.before_check()
        with self.lock:
            self.checks += 1
            if self.cancelled:
                raise Fault('cancelled')
            if self.consumer.metadata() != self.consumer.pin:
                raise Fault('capture_consumer_pin_mismatch')

    def perform(self, callback):
        with self.lock:
            self.check()
            self.effects += 1
            return callback()


def fixture(root, metadata, mode):
    """Test-only server: real separate PID/socket; synthetic validator/journal."""
    raw_request = (FIXTURES/'metadata-request.json').read_bytes()
    raw_result = (FIXTURES/'metadata-created.receipt.json').read_bytes()
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(str(root/'native.sock')); listener.listen(16)
    journal = {}
    journal_lock = threading.Lock()
    if mode == 'wrong_library':
        metadata['library_id'] = uid()
    if mode == 'wrong_inode':
        metadata['ledger_inode'] += 1
    print('ready', flush=True)

    def handle(connection):
        uploads = {}
        stream = connection.makefile('rb')
        def send(value):
            connection.sendall(encode(value)+b'\n')
        def authorize(binding, stage='completion', index=None):
            event_id = uid()
            context = {'capture_request_id': binding['capture_request_id'],
                'request_sha256': binding['request_sha256'], 'request_bytes': binding['request_bytes'],
                'stage': stage, 'index': index}
            if mode == 'wrong_event':
                context['request_sha256'] = '0'*64
            send({'protocol': CHANNEL_PROTOCOL, 'id': event_id, 'event': 'authorize', 'context': context})
            response = _frame(stream.readline(MAX_FRAME_BYTES+1))
            return response == {'protocol': CHANNEL_PROTOCOL, 'id': event_id,
                                'event': 'authorization', 'allowed': True}
        def result_meta(entry):
            return {'binding': entry['binding'], 'instance_id': metadata['instance_id'], 'state': entry['state'],
                'transaction_id': entry['transaction_id'] if entry['state'] == 'created' else None,
                'committed_at_ms': entry['committed_at_ms'] if entry['state'] == 'created' else None,
                'result_ref': {'payload_id': entry['transaction_id'], 'sha256': sha(raw_result),
                               'byte_count': len(raw_result)} if entry['state'] == 'created' else None}
        try:
            while True:
                raw = stream.readline(MAX_FRAME_BYTES+1)
                if not raw:
                    break
                request = _frame(raw)
                method, params = request['method'], request['params']
                result = None
                if method == 'metadata':
                    result = metadata
                elif method == 'upload.begin':
                    assert params['upload_id'] not in uploads
                    assert params['kind'] in {'request', 'result'}
                    uploads[params['upload_id']] = dict(params, data=bytearray(), sealed=False)
                elif method == 'upload.append':
                    entry = uploads[params['upload_id']]
                    assert not entry['sealed'] and params['offset'] == len(entry['data'])
                    chunk = base64.b64decode(params['data_base64'], validate=True)
                    assert 1 <= len(chunk) <= 8192
                    entry['data'].extend(chunk)
                elif method == 'upload.seal':
                    entry = uploads[params['upload_id']]
                    assert len(entry['data']) == entry['byte_count'] and sha(entry['data']) == entry['sha256']
                    entry['sealed'] = True
                    result = {key: entry[key] for key in ('upload_id', 'sha256', 'byte_count')}
                elif method == 'validate.request':
                    uploaded = bytes(uploads[params['request_upload_id']]['data'])
                    assert uploaded.rstrip() == raw_request.rstrip()
                elif method == 'validate.result':
                    assert bytes(uploads[params['request_upload_id']]['data']).rstrip() == raw_request.rstrip()
                    assert bytes(uploads[params['result_upload_id']]['data']).rstrip() == raw_result.rstrip()
                    assert params['state'] == 'created'
                elif method in {'execute', 'cached'}:
                    binding = params['binding']
                    assert bytes(uploads[params['request_upload_id']]['data']) == raw_request
                    if method == 'cached':
                        with journal_lock:
                            entry = journal.get(binding['capture_request_id'])
                            result = result_meta(entry) if entry is not None and entry.get('acked') else None
                    else:
                        allowed = authorize(binding, 'admission') and authorize(binding, 'record', -1) and authorize(binding)
                        entry = {'binding': binding, 'state': 'created' if allowed else 'needs_review',
                                 'transaction_id': uid(), 'committed_at_ms': 123456789, 'acked': False}
                        with journal_lock:
                            journal[binding['capture_request_id']] = entry
                        result = result_meta(entry)
                        if mode == 'wrong_binding':
                            result['binding'] = dict(binding, auth_epoch='rebound')
                        if mode == 'wrong_payload_id' and allowed:
                            result['result_ref']['payload_id'] = uid()
                elif method == 'result.read':
                    binding = params['binding']
                    assert authorize(binding)
                    with journal_lock:
                        entry = journal[binding['capture_request_id']]
                        assert entry['state'] == 'created' and params['payload_id'] == entry['transaction_id']
                    start = params['offset']; chunk = raw_result[start:start+params['limit']]
                    result = {'offset': start, 'data_base64': base64.b64encode(chunk).decode(),
                              'eof': start+len(chunk) == len(raw_result)}
                    if mode == 'wrong_eof':
                        result['eof'] = not result['eof']
                elif method in {'confirm', 'ack'}:
                    binding = params['binding']; assert authorize(binding)
                    outer_raw = base64.b64decode(params['outer_receipt_base64'], validate=True)
                    with journal_lock:
                        entry = journal[binding['capture_request_id']]
                        if entry['state'] != 'created':
                            send({'protocol': CHANNEL_PROTOCOL, 'id': request['id'], 'ok': False,
                                  'error': {'code': 'held'}})
                            continue
                        expected = dict(binding, schema_version=1, state='created',
                            commit={'transaction_id': entry['transaction_id'], 'committed_at_ms': entry['committed_at_ms']},
                            result_ref={'payload_id': entry['transaction_id'], 'sha256': sha(raw_result), 'byte_count': len(raw_result)})
                        assert outer_raw == encode(expected)
                        if method == 'confirm':
                            result = {'library_id': binding['library_id'], 'capture_request_id': binding['capture_request_id'],
                                      'transaction_id': entry['transaction_id'], 'receipt_sha256': sha(outer_raw)}
                            if mode == 'wrong_confirmation':
                                result['receipt_sha256'] = '0'*64
                        else:
                            entry['acked'] = True
                elif method == 'hold':
                    with journal_lock:
                        journal[params['binding']['capture_request_id']]['state'] = 'needs_review'
                else:
                    raise AssertionError('unknown synthetic method')
                send({'protocol': CHANNEL_PROTOCOL, 'id': request['id'], 'ok': True, 'result': result})
        except (AssertionError, Fault, OSError, ValueError, KeyError):
            pass
        finally:
            stream.close(); connection.close()
    while True:
        connection, _ = listener.accept()
        threading.Thread(target=handle, args=(connection,), daemon=True).start()


class FrameTests(unittest.TestCase):
    def assert_bad(self, raw):
        with self.assertRaises(Fault): _frame(raw)

    def test_exact_unicode_and_integer_frames(self):
        opaque = 'Peer-e\u0301-É'
        self.assertEqual(_frame(encode({'opaque': opaque, 'number': 1})+b'\n')['opaque'], opaque)
        self.assert_bad(b'{"a":1,"a":2}\n')
        self.assert_bad(b'{"a":1,"\\u0061":2}\n')
        self.assert_bad(b'{"a":"\\ud800"}\n')
        self.assert_bad(b'{"a":1.0}\n')
        self.assert_bad(b'{"a":1e0}\n')
        self.assert_bad(b'{"a":NaN}\n')
        self.assert_bad(b'{"a":"\xff"}\n')
        self.assert_bad(b'{}\n{}\n')
        self.assert_bad(b'{}')
        self.assert_bad(b' '+b'x'*(MAX_FRAME_BYTES-1)+b'\n')
        self.assert_bad(b'['*66+b'0'+b']'*66+b'\n')

    def test_complete_frame_limit_includes_newline(self):
        raw = b'{"p":"'+b'x'*(MAX_FRAME_BYTES-9)+b'"}\n'
        self.assertEqual(len(raw), MAX_FRAME_BYTES)
        self.assertEqual(len(_frame(raw)['p']), MAX_FRAME_BYTES-9)
        self.assert_bad(raw[:-2]+b'x"}\n')

    def test_fragmented_frames_and_oversize(self):
        left, right = socket.socketpair()
        connection = object.__new__(_Connection)
        connection.socket, connection.buffer = left, bytearray()
        try:
            right.sendall(b'{"a":')
            right.sendall(b'1}\n')
            self.assertEqual(connection.receive(time.monotonic()+1), {'a': 1})
            sender = threading.Thread(target=lambda: right.sendall(b'x'*MAX_FRAME_BYTES))
            sender.start()
            with self.assertRaises(Fault): connection.receive(time.monotonic()+1)
            sender.join(1)
            self.assertFalse(sender.is_alive())
        finally:
            left.close(); right.close()

    def test_eof_and_expired_deadline_fail_closed(self):
        left, right = socket.socketpair()
        connection = object.__new__(_Connection)
        connection.socket, connection.buffer = left, bytearray()
        try:
            with self.assertRaises(Fault) as expired:
                connection.receive(time.monotonic()-1)
            self.assertEqual(expired.exception.code, 'capture_channel_unavailable')
            right.shutdown(socket.SHUT_WR)
            with self.assertRaises(Fault) as eof:
                connection.receive(time.monotonic()+1)
            self.assertEqual(eof.exception.code, 'capture_channel_unavailable')
        finally:
            left.close(); right.close()


@unittest.skipUnless(sys.platform == 'darwin', 'actual macOS kernel identity required')
class ProcessTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='arl-process-unit-')
        self.root = Path(self.temp.name)
        self.ledger = self.root/'ledger.sqlite'; self.ledger.write_bytes(b'synthetic-ledger-test')
        self.verifier = RegisteredPeerVerifier({'native-test', 'source-test'})
        self.registrations = CaptureProcessRegistrations(self.verifier)
        self.participant = RegisteredCaptureParticipant('opaque-source-é', 'agent', 'opaque-epoch-e\u0301')
        self.executable = process_identity(os.getpid())['executable']
        self.image_hash = _image_hash(self.executable)
        self.source = self.registrations.register('source-test', os.getpid(), self.executable, self.image_hash, self.participant)
        self.pin = CaptureConsumerPin(uid(), uid(), self.image_hash)
        self.consumer = self.native = None
        self.raw = (FIXTURES/'metadata-request.json').read_bytes()
        self.result = (FIXTURES/'metadata-created.receipt.json').read_bytes()
        self.binding = CaptureBinding(uid(), sha(self.raw), len(self.raw), self.pin.library_id,
            CODEC, SCHEMA_SHA256, 'd'*64, 'source-test', self.participant.participant_id,
            self.participant.actor_kind, self.participant.auth_epoch)
        self.authority = CaptureAuthority('source-test', self.participant.participant_id, 'agent',
            self.pin.library_id, self.pin.instance_id, self.participant.auth_epoch, 'd'*64)
        self.allowed = True

    def tearDown(self):
        if self.consumer is not None: self.consumer.close()
        if self.native is not None:
            self.native.terminate()
            try: self.native.wait(5)
            except subprocess.TimeoutExpired:
                self.native.kill(); self.native.wait(5)
            for stream in (self.native.stdin, self.native.stdout, self.native.stderr):
                if stream is not None: stream.close()
        self.temp.cleanup()

    def start_native(self, mode='normal', **changes):
        info = self.ledger.stat()
        metadata = dict(self.pin.__dict__, ledger_device=info.st_dev, ledger_inode=info.st_ino)
        environment = dict(os.environ, PYTHONDONTWRITEBYTECODE='1')
        self.native = subprocess.Popen([sys.executable, '-m', 'tests.test_tisra_capture_process',
            '--fixture', str(self.root), json.dumps(metadata), mode], stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=environment)
        ready = self.native.stdout.readline().strip()
        if ready != 'ready':
            self.native.wait(5)
            self.fail(self.native.stderr.read())
        actual = process_identity(self.native.pid)
        self.assertEqual(actual['executable'], self.executable)
        self.verifier.register('native-test', self.native.pid, self.executable)
        config = dict(socket_path=self.root/'native.sock', verifier=self.verifier, native_app='native-test',
            native_pid=self.native.pid, expected_executable=self.executable, expected_sha256=self.image_hash,
            selected_ledger=self.ledger, pin=self.pin, registrations=self.registrations,
            authorize=lambda authority, method: self.allowed and authority == self.authority,
            timeout=5)
        config.update(changes)
        self.consumer = NativeCaptureProcess(**config)
        return self.consumer

    def assert_fault(self, code, callback):
        with self.assertRaises(Fault) as raised: callback()
        self.assertEqual(raised.exception.code, code)

    def outer(self, commit):
        return encode(dict(self.binding.wire(), schema_version=1, state=commit.state,
            commit={'transaction_id': commit.transaction_id, 'committed_at_ms': commit.committed_at_ms},
            result_ref={'payload_id': commit.result_payload_id, 'sha256': sha(commit.raw_result), 'byte_count': len(commit.raw_result)}))

    def capture(self):
        guard = Guard(self.consumer, self.binding, self.authority)
        return self.consumer.capture(self.binding, self.raw, self.authority, guard), guard

    def test_real_registered_source_mapping_identity_hash_epoch_and_generation(self):
        self.assertTrue(self.registrations('source-test', self.participant))
        native = self.source.to_native()
        self.assertEqual(native['pid'], os.getpid())
        self.assertEqual(native['birth'], list(process_identity(os.getpid())['birth']))
        self.assertNotIn('registration_generation', native)
        self.assertFalse(self.registrations('source-test', replace(self.participant, auth_epoch='rotated')))
        self.verifier.register('source-test', os.getpid(), self.executable)
        self.assertFalse(self.registrations('source-test', self.participant))
        self.registrations.register('source-test', os.getpid(), self.executable, self.image_hash, self.participant)
        self.registrations.revoke('source-test')
        self.assertFalse(self.registrations('source-test', self.participant))

    def test_failed_hash_never_enrolls_process(self):
        fresh = CaptureProcessRegistrations(RegisteredPeerVerifier({'source-test'}))
        self.assert_fault('capture_process_identity_changed', lambda: fresh.register(
            'source-test', os.getpid(), self.executable, '0'*64, self.participant))
        self.assertEqual(fresh.verifier.registry, {})

    def test_metadata_is_genuine_kernel_peer_and_independent_image_ledger_pin(self):
        self.start_native()
        self.assertEqual(self.consumer.metadata(), self.pin)
        self.assertIs(type(self.consumer.codec), CaptureCodec)
        self.verifier.register('native-test', self.native.pid, self.executable)
        self.assert_fault('capture_process_identity_changed', self.consumer.metadata)

    def test_wrong_actual_peer_pid_rejected_before_metadata(self):
        self.start_native()
        # The helper can pin another real registered PID, but kernel observation
        # of the connected server must independently agree with that selection.
        self.verifier.register('native-test', os.getpid(), self.executable)
        self.consumer.identity = replace(self.consumer.identity, pid=os.getpid(),
            birth=process_identity(os.getpid())['birth'],
            registration_generation=self.verifier.registry[os.getpid()][2])
        self.assert_fault('capture_process_identity_changed', self.consumer.metadata)

    def test_metadata_self_report_wrong_library_or_selected_inode_rejected(self):
        for mode in ('wrong_library', 'wrong_inode'):
            with self.subTest(mode=mode):
                self.start_native(mode)
                self.assert_fault('capture_consumer_pin_mismatch', self.consumer.metadata)
                self.consumer.close(); self.consumer = None
                self.native.terminate(); self.native.wait(5)
                for stream in (self.native.stdin, self.native.stdout, self.native.stderr): stream.close()
                self.native = None; (self.root/'native.sock').unlink()

    def test_replaced_host_selected_ledger_is_rejected(self):
        self.start_native()
        replacement = self.root/'replacement'; replacement.write_bytes(self.ledger.read_bytes())
        replacement.replace(self.ledger)
        self.assert_fault('capture_consumer_pin_mismatch', self.consumer.metadata)

    def test_exact_codec_raw_signatures_and_complete_bounded_uploads(self):
        self.start_native()
        self.assertIsNone(self.consumer.codec.validate_request(self.raw))
        self.assertIsNone(self.consumer.codec.validate_result(self.result, self.raw, 'created'))
        exact_limit = self.raw + b' '*(MAX_REQUEST_BYTES-len(self.raw))
        self.assertIsNone(self.consumer.codec.validate_request(exact_limit))
        result_limit = self.result + b' '*(MAX_RESULT_BYTES-len(self.result))
        self.assertIsNone(self.consumer.codec.validate_result(result_limit, self.raw, 'created'))
        self.assert_fault('capture_payload_mismatch', lambda: self.consumer.validate_request(exact_limit+b' '))
        self.assert_fault('capture_payload_mismatch', lambda: self.consumer.validate_result(
            b'x'*(MAX_RESULT_BYTES+1), self.raw, 'created'))

    def test_live_bidirectional_guard_confirm_ack_cache_exact_receipt(self):
        self.start_native()
        self.assertIsNone(self.consumer.cached(self.binding, self.raw, self.authority))
        commit, guard = self.capture()
        self.assertIs(type(commit), CaptureCommit)
        self.assertEqual(commit.raw_result, self.result)
        self.assertEqual(commit.result_payload_id, commit.transaction_id)
        self.assertGreaterEqual(guard.effects, 1)
        self.assertGreaterEqual(guard.checks, 3)
        outer = self.outer(commit)
        confirmation = self.consumer.confirm(commit, outer, self.raw, self.authority)
        self.assertEqual(confirmation, CommitConfirmation(self.pin.library_id, self.binding.capture_request_id,
                                                         commit.transaction_id, sha(outer)))
        self.assertIsNone(self.consumer.acknowledge(commit, outer, self.authority, guard))
        self.assertEqual(self.consumer.cached(self.binding, self.raw, self.authority), commit)

    def test_unobserved_forged_commit_and_altered_outer_never_mint_confirmation(self):
        self.start_native()
        fake = CaptureCommit(self.binding, self.authority, 'created', self.result, uid(), uid(), 42)
        self.assert_fault('capture_commit_unconfirmed', lambda: self.consumer.confirm(fake, self.outer(fake), self.raw, self.authority))
        commit, _ = self.capture()
        self.assert_fault('capture_commit_unconfirmed', lambda: self.consumer.confirm(
            replace(commit, transaction_id=uid()), self.outer(commit), self.raw, self.authority))
        self.assert_fault('capture_commit_unconfirmed', lambda: self.consumer.confirm(
            commit, self.outer(commit)+b' ', self.raw, self.authority))
        altered = json.loads(self.outer(commit)); altered['writing_participant']['actor_kind'] = 'human'
        self.assert_fault('capture_commit_unconfirmed', lambda: self.consumer.confirm(commit, encode(altered), self.raw, self.authority))

    def test_native_confirmation_digest_is_compared_before_minting(self):
        self.start_native('wrong_confirmation')
        commit, _ = self.capture()
        self.assert_fault('capture_commit_unconfirmed', lambda: self.consumer.confirm(commit, self.outer(commit), self.raw, self.authority))

    def test_native_binding_result_id_eof_and_authorization_context_rebinding_fail_closed(self):
        for mode, code in (('wrong_binding', 'capture_commit_unconfirmed'),
                           ('wrong_payload_id', 'capture_commit_unconfirmed'),
                           ('wrong_eof', 'capture_channel_invalid'),
                           ('wrong_event', 'capture_channel_invalid')):
            with self.subTest(mode=mode):
                self.start_native(mode)
                self.assert_fault(code, self.capture)
                self.consumer.close(); self.consumer = None
                self.native.terminate(); self.native.wait(5)
                for stream in (self.native.stdin, self.native.stdout, self.native.stderr): stream.close()
                self.native = None; (self.root/'native.sock').unlink()

    def test_source_revoke_cancel_or_live_authorizer_denial_is_sent_on_actual_channel(self):
        self.start_native()
        guard = Guard(self.consumer, self.binding, self.authority)
        guard.cancelled = True
        self.assert_fault('capture_needs_review', lambda: self.consumer.capture(self.binding, self.raw, self.authority, guard))
        self.binding = replace(self.binding, capture_request_id=uid())
        self.allowed = False
        self.assert_fault('capture_needs_review', self.capture)
        self.allowed = True
        self.registrations.revoke('source-test')
        self.assert_fault('capture_participant_unregistered', self.capture)

    def test_callback_rechecks_actual_source_hash_and_registry_generation(self):
        self.start_native()
        self.verifier.register('source-test', os.getpid(), self.executable)
        self.assert_fault('capture_participant_unregistered', self.capture)
        self.registrations.register('source-test', os.getpid(), self.executable, self.image_hash, self.participant)
        original = _image_hash
        with patch('arl.tisra_capture_process._image_hash', side_effect=lambda path:
                   '0'*64 if threading.current_thread().name == 'source-hash-change' else original(path)):
            outcomes = []
            def changed():
                try: self.capture()
                except Fault as error: outcomes.append(error.code)
            worker = threading.Thread(target=changed, name='source-hash-change'); worker.start(); worker.join(5)
            self.assertEqual(outcomes, ['capture_participant_unregistered'])

    def test_actual_registration_changes_during_record_authorization_are_denied(self):
        self.start_native()
        guard = Guard(self.consumer, self.binding, self.authority)
        calls = [0]
        def before_check():
            calls[0] += 1
            if calls[0] == 2:
                self.verifier.register('source-test', os.getpid(), self.executable)
        guard.before_check = before_check
        self.assert_fault('capture_needs_review', lambda: self.consumer.capture(
            self.binding, self.raw, self.authority, guard))
        self.assertEqual(guard.effects, 0)

    def test_actual_source_process_exit_invalidates_registration(self):
        environment = dict(os.environ, PYTHONDONTWRITEBYTECODE='1')
        source = subprocess.Popen([sys.executable, '-c',
            'import sys; print("ready", flush=True); sys.stdin.buffer.read()'],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, env=environment)
        try:
            self.assertEqual(source.stdout.readline().strip(), 'ready')
            observed = process_identity(source.pid)
            self.registrations.register('source-test', source.pid, observed['executable'],
                                        _image_hash(observed['executable']), self.participant)
            self.assertTrue(self.registrations('source-test', self.participant))
            source.terminate(); source.wait(5)
            self.assertFalse(self.registrations('source-test', self.participant))
        finally:
            if source.poll() is None:
                source.terminate(); source.wait(5)
            for stream in (source.stdin, source.stdout, source.stderr): stream.close()

    def test_parallel_metadata_during_bound_callback_avoids_configuration_lock_deadlock(self):
        self.start_native()
        guard = Guard(self.consumer, self.binding, self.authority)
        pending, release = threading.Event(), threading.Event()
        def before_check():
            pending.set()
            if not release.wait(3): raise AssertionError('concurrent metadata did not finish')
        guard.before_check = before_check
        outcomes = []
        def execute():
            try: outcomes.append(self.consumer.capture(self.binding, self.raw, self.authority, guard))
            except Exception as error: outcomes.append(error)
        worker = threading.Thread(target=execute); worker.start()
        self.assertTrue(pending.wait(3))
        # A separate host thread already holding its configuration lock can
        # request metadata while the native bound operation awaits guard.check.
        with guard.lock:
            self.assertEqual(self.consumer.metadata(), self.pin)
            guard.cancelled = True
        release.set(); worker.join(5)
        self.assertFalse(worker.is_alive())
        self.assertEqual(len(outcomes), 1)
        self.assertIsInstance(outcomes[0], Fault)
        self.assertEqual(outcomes[0].code, 'capture_needs_review')

    def test_safety_hold_after_source_revocation_only_holds_original_journal(self):
        self.start_native()
        commit, _ = self.capture()
        self.registrations.revoke('source-test')
        self.assertIsNone(self.consumer.report_uncertain(self.binding, self.authority))
        self.registrations.register('source-test', os.getpid(), self.executable, self.image_hash, self.participant)
        self.assert_fault('capture_native_rejected', lambda: self.consumer.confirm(commit, self.outer(commit), self.raw, self.authority))


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '--fixture':
        fixture(Path(sys.argv[2]), json.loads(sys.argv[3]), sys.argv[4])
    else:
        unittest.main()
