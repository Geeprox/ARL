"""Actual native process, kernel-registered source, Store and synthetic Ledger."""
import base64
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import select
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import uuid

from arl.contracts import AppPolicy, Fault, encode
from arl.identity import RegisteredPeerVerifier, process_identity
from arl.tisra_capture_composition import CaptureProcessComposition
from arl.tisra_capture_process import CaptureProcessRegistrations, NativeCaptureProcess
from arl.tisra_capture_runtime import CODEC, NAME, SCHEMA_SHA256, CaptureConsumerPin, RegisteredCaptureParticipant
from arl.tisra_capture_uploads import METHODS

ROOT = Path(__file__).resolve().parents[1]
NATIVE = ROOT.parent / 'TisraCaptureProcessV2/.build-process/out/Products/Debug/CaptureProcessFixture'
SOURCE_APP = 'capture-source-test'
NATIVE_APP = 'native-capture-test'
PARTICIPANT = RegisteredCaptureParticipant('fixture-agent', 'agent', 'synthetic-epoch-v2')
FIRST_WRITER = {'participant_id': 'fixture-agent', 'display_name': 'Synthetic Agent', 'actor_kind': 'agent'}


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def emit_evidence(name, data, files=None):
    target = os.environ.get('CAPTURE_PROCESS_EVIDENCE_DIR')
    if not target:
        return
    directory = Path(target)
    directory.mkdir(parents=True, exist_ok=True)
    (directory / (name + '.json')).write_bytes(encode(data) + b'\n')
    for filename, raw in (files or {}).items():
        (directory / filename).write_bytes(raw)


def process_pin(pid):
    info = process_identity(pid)
    return dict(pid=pid, uid=info['uid'], birth=list(info['birth']),
                executable=info['executable'], sha256=sha(Path(info['executable']).read_bytes()))


def read_line(process, timeout=20):
    if not select.select([process.stdout], [], [], timeout)[0]:
        raise AssertionError('Synthetic process response timeout')
    raw = process.stdout.readline()
    if not raw:
        raise AssertionError('Synthetic process stopped before responding')
    if len(raw) > 131072:
        raise AssertionError('Synthetic process exceeded evidence frame')
    return json.loads(raw)


class ProcessFixture:
    def __init__(self, directory):
        self.root = Path(directory)
        self.home = self.root / 'arl'
        self.native_root = self.root / 'native'
        self.library_id, self.instance_id = str(uuid.uuid4()), str(uuid.uuid4())
        self.verifier = RegisteredPeerVerifier({SOURCE_APP, NATIVE_APP})
        self.registrations = CaptureProcessRegistrations(self.verifier)
        self.children = []
        self.runtime = self.thread = None
        self.runtime_errors = []
        self.start_source()
        source_info = process_identity(self.source.pid)
        self.source_identity = self.registrations.register(
            SOURCE_APP, self.source.pid, source_info['executable'],
            sha(Path(source_info['executable']).read_bytes()), PARTICIPANT)
        self.start_native('create')
        methods = frozenset(METHODS)
        self.policies = {SOURCE_APP: AppPolicy(frozenset({NAME}), methods=methods,
                                             max_pending=8, max_calls=64)}
        self.start_runtime()

    def start_runtime(self):
        methods = frozenset(METHODS)
        self.composition = CaptureProcessComposition(
            verifier=self.verifier, registrations=self.registrations,
            native_app=NATIVE_APP, native_pid=self.native.pid,
            expected_executable=str(NATIVE.resolve()), expected_sha256=sha(NATIVE.read_bytes()),
            socket_path=self.native_root / 'capture.sock',
            selected_ledger=self.native_root / 'library/ledger.sqlite', pin=self.pin,
            participants={SOURCE_APP: PARTICIPANT},
            library_grants={(SOURCE_APP, PARTICIPANT.participant_id): frozenset({self.library_id})},
            method_grants={(SOURCE_APP, PARTICIPANT.participant_id, self.library_id): methods},
            active=True,
        )
        self.runtime = self.composition.make_runtime(self.home, policies=self.policies)
        def run():
            try:
                self.runtime.run()
            except Exception as error:
                self.runtime_errors.append(error)
        self.thread = threading.Thread(target=run, daemon=True)
        self.thread.start()
        if not self.runtime.ready.wait(10):
            raise AssertionError('Isolated runtime did not become ready')

    def restart_runtime(self):
        self.runtime.shutdown()
        self.thread.join(10)
        if self.thread.is_alive():
            raise AssertionError('Isolated ARL did not stop for restart')
        self.composition.close()
        self.start_runtime()

    def start_source(self):
        source = subprocess.Popen([sys.executable, '-B', '-m',
            'tests.capture_source_process_fixture', '--isolated-test', str(self.home), SOURCE_APP],
            cwd=ROOT, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, bufsize=1, env=dict(os.environ, PYTHONDONTWRITEBYTECODE='1'))
        self.children.append(source)
        if read_line(source) != {'pid': source.pid}:
            raise AssertionError('Wrong synthetic source PID')
        self.source = source
        return source

    def start_native(self, mode):
        native = subprocess.Popen([str(NATIVE), '--isolated-test', str(self.native_root)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, bufsize=1)
        self.children.append(native)
        descriptor = dict(mode=mode, library_id=self.library_id, instance_id=self.instance_id,
            host=process_pin(os.getpid()), registrations=[dict(
                process=self.source_identity.to_native(), writer_app=SOURCE_APP,
                participant_id=PARTICIPANT.participant_id, actor_kind=PARTICIPANT.actor_kind,
                auth_epoch=PARTICIPANT.auth_epoch, active=True, write_granted=True,
                library_id=self.library_id)])
        native.stdin.write(json.dumps(descriptor) + '\n'); native.stdin.flush()
        metadata = read_line(native)
        expected = {'library_id', 'instance_id', 'codec', 'consumer_schema_sha256',
                    'code_sha256', 'ledger_device', 'ledger_inode'}
        if set(metadata) != expected or metadata['library_id'] != self.library_id or metadata['instance_id'] != self.instance_id:
            raise AssertionError('Native fixture metadata mismatch')
        self.verifier.register(NATIVE_APP, native.pid, str(NATIVE.resolve()))
        self.pin = CaptureConsumerPin(self.library_id, self.instance_id, sha(NATIVE.read_bytes()))
        if metadata['code_sha256'] != self.pin.code_sha256 or metadata['codec'] != CODEC or metadata['consumer_schema_sha256'] != SCHEMA_SHA256:
            raise AssertionError('Native executable or schema mismatch')
        observed = os.stat(self.native_root / 'library/ledger.sqlite')
        if (metadata['ledger_device'], metadata['ledger_inode']) != (observed.st_dev, observed.st_ino):
            raise AssertionError('Native selected Ledger mismatch')
        self.native = native

    def rpc_reply(self, method, params, source=None):
        source = source or self.source
        source.stdin.write(json.dumps({'method': method, 'params': params}, ensure_ascii=False) + '\n')
        source.stdin.flush()
        return read_line(source)

    def rpc(self, method, params):
        reply = self.rpc_reply(method, params)
        if reply.get('ok') is not True:
            raise AssertionError('Registered source RPC failed: ' + str(reply.get('error')))
        return reply['result']

    def upload(self, capture_id, raw):
        begin = self.rpc('capture.upload.begin.v2', dict(capture_request_id=capture_id,
            library_id=self.library_id, sha256=sha(raw), byte_count=len(raw)))
        for offset in range(0, len(raw), 8192):
            result = self.rpc('capture.upload.append.v2', dict(payload_id=begin['payload_id'],
                offset=offset, data_base64=base64.b64encode(raw[offset:offset+8192]).decode()))
            if result['offset'] != min(offset + 8192, len(raw)):
                raise AssertionError('Upload changed exact offset')
        return self.rpc('capture.upload.seal.v2', {'payload_id': begin['payload_id']})

    def submit(self, capture_id, raw, reference=None):
        reference = reference or self.upload(capture_id, raw)
        request = dict(schema_version=1, capture_request_id=capture_id, library_id=self.library_id,
            codec=CODEC, consumer_schema_sha256=SCHEMA_SHA256,
            payload=reference, declared_attribution=None)
        return self.rpc('capture.submit.v1', {'key': capture_id, 'request': request})

    def wait(self, capture_id, admission):
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            status = self.rpc('capture.status.v1', dict(capture_request_id=capture_id, admission_sha256=admission))
            if status['state'] in {'succeeded', 'failed', 'cancelled', 'needs_review', 'needs_unlock'}:
                return status
            threading.Event().wait(0.02)
        raise AssertionError('Finite synthetic capture did not reach a terminal outcome')

    def result(self, capture_id, status):
        admission = status['binding']['admission_sha256']
        expected = status['receipt']['result_ref']
        raw = b''
        while len(raw) < expected['byte_count']:
            part = self.rpc('capture.result.read.v1', dict(capture_request_id=capture_id,
                admission_sha256=admission, offset=len(raw), limit=8192))
            chunk = base64.b64decode(part['data_base64'], validate=True)
            if not chunk or part['offset'] != len(raw):
                raise AssertionError('Result lost exact bytes/offset')
            raw += chunk
            if part['eof'] != (len(raw) == expected['byte_count']):
                raise AssertionError('Result EOF mismatch')
        if len(raw) != expected['byte_count'] or sha(raw) != expected['sha256']:
            raise AssertionError('Native receipt digest mismatch')
        return raw

    def record_count(self):
        with sqlite3.connect(f'file:{self.native_root}/library/ledger.sqlite?mode=ro', uri=True) as db:
            return db.execute('SELECT COUNT(*) FROM records').fetchone()[0]

    def journal(self, capture_id):
        with sqlite3.connect(f'file:{self.native_root}/journal/capture-receipts.sqlite?mode=ro', uri=True) as db:
            db.row_factory = sqlite3.Row
            row = db.execute('SELECT * FROM captures WHERE capture_id=?', (capture_id.upper(),)).fetchone()
            return dict(row) if row else None

    def wait_journal_phase(self, capture_id, phase):
        # ARL commits its hold before notifying the independent native journal.
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            row = self.journal(capture_id)
            if row and row['phase'] == phase:
                return row
            threading.Event().wait(0.02)
        raise AssertionError('Native journal did not receive the durable hold')

    def restart_native(self):
        previous = self.native
        previous.stdin.write(json.dumps({'command': 'stop'}) + '\n'); previous.stdin.flush()
        previous.wait(10)
        self.verifier.revoke(previous.pid)
        self.start_native('reopen')
        self.composition.replace_native_consumer(self.native.pid)

    def close(self):
        if self.runtime:
            self.runtime.shutdown()
        if self.thread:
            self.thread.join(10)
            if self.thread.is_alive():
                raise AssertionError('Isolated ARL did not stop')
        if hasattr(self, 'composition'):
            self.composition.close()
        for process in reversed(self.children):
            if process.poll() is None:
                try:
                    process.stdin.write(json.dumps({'command': 'stop'}) + '\n'); process.stdin.flush()
                    process.wait(3)
                except (BrokenPipeError, subprocess.TimeoutExpired):
                    process.terminate(); process.wait(3)
            for stream in (process.stdin, process.stdout, process.stderr):
                stream.close()
        if self.runtime_errors:
            raise AssertionError('Isolated ARL thread failed') from self.runtime_errors[0]


@contextmanager
def fixture():
    with tempfile.TemporaryDirectory(prefix='cap-p2-', dir='/tmp') as directory:
        item = ProcessFixture.__new__(ProcessFixture)
        try:
            item.__init__(directory)
            yield item
        finally:
            if hasattr(item, 'children'):
                item.close()


def request(url='https://example.invalid/synthetic-capture-v2', writer=None):
    return encode(dict(schema_version=1, source={'original_url': url, 'title': 'Synthetic source'},
        writer=writer or FIRST_WRITER, body={'content_kind': 'original', 'text': 'Original synthetic body, exact UTF-8: café.'},
        contributions=[{'writer': FIRST_WRITER, 'content_kind': 'summary', 'text': 'A separate synthetic summary.'}]))


class CaptureProcessEndToEndTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if sys.platform != 'darwin' or not NATIVE.is_file():
            raise AssertionError('Build the isolated macOS CaptureProcessFixture before acceptance; this suite must not skip')

    def test_real_registered_capture_first_writer_and_acknowledged_restart_bytes(self):
        with fixture() as f:
            capture_id, raw = str(uuid.uuid4()), request()
            submitted = f.submit(capture_id, raw)
            status = f.wait(capture_id, submitted['binding']['admission_sha256'])
            self.assertEqual(status['state'], 'succeeded')
            receipt_bytes = f.result(capture_id, status)
            receipt = json.loads(receipt_bytes)
            self.assertEqual(receipt['source']['writer'], FIRST_WRITER)
            self.assertEqual(receipt['source']['writer_trust'], 'declared')
            self.assertEqual(len(receipt['contributions']), 1)
            self.assertEqual(f.record_count(), 2)
            self.assertEqual(f.journal(capture_id)['acknowledged'], 1)
            self.assertEqual(f.journal(capture_id)['outer_receipt_hash'], sha(encode(status['receipt'])))
            peer = {'participant_id': 'fixture-human', 'display_name': 'Synthetic Human', 'actor_kind': 'human'}
            changed = json.loads(raw); changed['writer'] = peer; changed['contributions'] = []
            peer_id = str(uuid.uuid4())
            peer_submission = f.submit(peer_id, encode(changed))
            peer_status = f.wait(peer_id, peer_submission['binding']['admission_sha256'])
            peer_receipt = json.loads(f.result(peer_id, peer_status))
            self.assertEqual(peer_status['receipt']['state'], 'deduplicated')
            self.assertEqual(peer_receipt['source']['record_id'], receipt['source']['record_id'])
            self.assertEqual(peer_receipt['source']['writer'], FIRST_WRITER)
            self.assertEqual(f.record_count(), 2)
            f.restart_native()
            cached = f.submit(capture_id, raw)
            self.assertEqual(cached['receipt'], status['receipt'])
            self.assertEqual(f.result(capture_id, cached), receipt_bytes)
            self.assertEqual(f.record_count(), 2)
            emit_evidence('registered-process', dict(
                kernel_source_identity=f.source_identity.to_native(),
                kernel_native_identity=process_pin(f.native.pid),
                host_identity=process_pin(os.getpid()),
                binding=status['binding'], outer_receipt=status['receipt'],
                ledger_records=2, native_acknowledged=1,
                peer_source_record_id=peer_receipt['source']['record_id'],
                peer_stored_writer=peer_receipt['source']['writer'],
                acknowledged_restart_bytes_equal=True,
                result_sha256=sha(receipt_bytes), result_bytes=len(receipt_bytes)),
                {'registered-request.json': raw,
                 'registered.receipt.json': receipt_bytes,
                 'registered.outer-receipt.json': encode(status['receipt']),
                 'peer-deduplicated.receipt.json': encode(peer_receipt)})

    def test_real_unregistered_source_excess_rebinding_and_revocation(self):
        with fixture() as f:
            registered = f.source
            unregistered = f.start_source()
            f.source = registered
            wrong = f.rpc_reply('capture.upload.begin.v2', dict(capture_request_id=str(uuid.uuid4()),
                library_id=f.library_id, sha256='0'*64, byte_count=1), unregistered)
            self.assertEqual(wrong, {'ok': False, 'error': 'app_identity_unverified'})
            excess = f.rpc_reply('capture.upload.begin.v2', dict(capture_request_id=str(uuid.uuid4()),
                library_id=f.library_id, sha256='0'*64, byte_count=524289))
            self.assertFalse(excess['ok'])
            capture_id, raw = str(uuid.uuid4()), request()
            reference = f.upload(capture_id, raw)
            wrong_request = dict(schema_version=1, capture_request_id=str(uuid.uuid4()), library_id=f.library_id,
                codec=CODEC, consumer_schema_sha256=SCHEMA_SHA256, payload=reference, declared_attribution=None)
            changed = f.rpc_reply('capture.submit.v1', {'key': wrong_request['capture_request_id'], 'request': wrong_request})
            self.assertEqual(changed, {'ok': False, 'error': 'capture_payload_unavailable'})
            f.registrations.revoke(SOURCE_APP)
            revoked = f.rpc_reply('capture.capabilities.v1', {'library_id': f.library_id})
            self.assertEqual(revoked, {'ok': False, 'error': 'app_identity_unverified'})
            self.assertEqual(f.record_count(), 0)
            emit_evidence('rejected-process', dict(unregistered=wrong,
                oversized=excess, rebound=changed, revoked=revoked, ledger_records=0))

    def test_native_own_revocation_and_real_lost_ack_hold_never_replay(self):
        with fixture() as f:
            f.native.stdin.write(json.dumps({'command': 'revoke', 'writer_app': SOURCE_APP}) + '\n'); f.native.stdin.flush()
            self.assertEqual(read_line(f.native), {'command': 'revoked', 'writer_app': SOURCE_APP})
            capture_id = str(uuid.uuid4())
            submitted = f.submit(capture_id, request())
            denied = f.wait(capture_id, submitted['binding']['admission_sha256'])
            self.assertEqual(denied['state'], 'needs_review')
            self.assertEqual(f.record_count(), 0)
        with fixture() as f:
            acknowledge = f.composition.consumer.acknowledge
            def lost_after_actual_ack(*args, **kwargs):
                acknowledge(*args, **kwargs)
                raise OSError('Synthetic lost acknowledgement after actual native journal commit')
            f.composition.consumer.acknowledge = lost_after_actual_ack
            capture_id, raw = str(uuid.uuid4()), request()
            submitted = f.submit(capture_id, raw)
            held = f.wait(capture_id, submitted['binding']['admission_sha256'])
            self.assertEqual(held['state'], 'needs_review')
            self.assertEqual(f.record_count(), 2)
            self.assertEqual(f.wait_journal_phase(capture_id, 'needs_review')['phase'], 'needs_review')
            f.restart_native()
            f.restart_runtime()
            retry_upload = f.rpc_reply('capture.upload.begin.v2', dict(capture_request_id=capture_id,
                library_id=f.library_id, sha256=sha(raw), byte_count=len(raw)))
            self.assertEqual(retry_upload, {'ok': False, 'error': 'capture_upload_cancelled'})
            retried = f.rpc('capture.status.v1', dict(capture_request_id=capture_id,
                admission_sha256=submitted['binding']['admission_sha256']))
            self.assertEqual(retried['state'], 'needs_review')
            self.assertEqual(f.record_count(), 2)
            self.assertEqual(f.journal(capture_id)['phase'], 'needs_review')
            emit_evidence('lost-ack-process', dict(capture_request_id=capture_id,
                arl_state=held['state'], native_phase='needs_review',
                restart_state=retried['state'], restart_upload=retry_upload,
                native_and_arl_restarted=True, ledger_records=2, replayed=False))


if __name__ == '__main__':
    unittest.main()
