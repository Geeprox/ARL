"""Finite actual-host acceptance; no installed services or personal libraries."""
from contextlib import contextmanager
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import uuid

from arl.contracts import Fault, encode
from arl.host import make_runtime
from arl.tisra_capture_host import CaptureHostAttachment
from tests.test_capture_process_end_to_end import (ROOT, ProcessFixture, NATIVE, request,
    FIRST_WRITER, read_line, sha, emit_evidence)


class HostFixture(ProcessFixture):
    def __init__(self, directory, mode):
        self.root = Path(directory)
        self.native_root = self.root / 'native'
        env = {key: os.environ[key] for key in ('PATH', 'TMPDIR') if key in os.environ}
        env['PYTHONDONTWRITEBYTECODE'] = '1'
        self.host = subprocess.Popen([sys.executable, '-B', '-m', 'tests.capture_host_fixture',
            '--isolated-test', str(self.root), str(NATIVE), mode], cwd=ROOT, env=env,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
        self.first = read_line(self.host)
        self.summary = self.first if self.first['event'] == 'stopped' else None
        if self.summary is None:
            self.library_id = self.first['library_id']
        elif mode not in {'bad_hash', 'select_failure'}:
            raise AssertionError('actual host failed startup: ' + (self.root / 'arl/host.log').read_text())
        self.source = None

    def command(self, command):
        self.host.stdin.write(json.dumps(command) + '\n'); self.host.stdin.flush()
        return read_line(self.host)

    def rpc_reply(self, method, params, source=None):
        return self.command(dict(method=method, params=params))

    def close(self):
        if getattr(self, '_cleaned', False):
            return
        if self.host.poll() is None and self.summary is None:
            self.summary = self.command({'command': 'stop'})
        try:
            self.host.wait(5)
        except subprocess.TimeoutExpired:
            self.host.terminate(); self.host.wait(5)
            raise AssertionError('actual host did not close')
        errors = self.host.stderr.read()
        for pipe in (self.host.stdin, self.host.stdout, self.host.stderr):
            pipe.close()
        self._cleaned = True
        if errors:
            raise AssertionError('actual host stderr: ' + errors)


@contextmanager
def host_fixture(mode='granted'):
    with tempfile.TemporaryDirectory(prefix='cap-host-', dir='/tmp') as directory:
        fixture = HostFixture.__new__(HostFixture)
        try:
            fixture.__init__(directory, mode)
            yield fixture
        finally:
            if hasattr(fixture, 'host'):
                fixture.close()


class CaptureHostAttachmentTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if sys.platform != 'darwin' or not NATIVE.is_file():
            raise AssertionError('supply reviewed pinned native fixture; acceptance must not skip')

    def assert_closed(self, summary, result=0):
        self.assertEqual(summary['event'], 'stopped')
        self.assertEqual(summary['result'], result)
        for field in ('closed', 'runtime_closed', 'source_exited', 'fd_closed', 'worker_stopped'):
            self.assertIs(summary[field], True, field)
        self.assertFalse(summary['source_registered'])
        self.assertEqual(summary['controller_errors'], [])
        self.assertEqual(summary['provider_calls'], 0)
        if summary['gate_proof'] is not None:
            self.assertTrue(summary['gate_child_reaped'])

    def test_default_metadata_factory_and_disabled_attachment_observe_no_consumer(self):
        default = make_runtime('/tmp/unused-synthetic-host')
        self.assertIsNone(default.host_attachment)
        self.assertIsNone(default.capture)
        self.assertFalse(default.execute_jobs)
        disabled = CaptureHostAttachment(object())
        runtime = make_runtime('/tmp/unused-synthetic-host', capture_attachment=disabled)
        self.assertIsNone(runtime.capture)
        self.assertFalse(runtime.execute_jobs)
        self.assertTrue(all(not p.providers and not p.tools for p in runtime.policies.values()))
        with host_fixture('disabled') as f:
            self.assertFalse(f.first['capture'])
            self.assertFalse(f.first['worker'])
            self.assertFalse(f.first['gate_released'])
            self.assertFalse(f.native_root.exists())
            self.assertEqual(f.first['pending_state'], 'queued')
            self.assertEqual(f.first['pending_attempts'], 0)
            f.close()
            self.assert_closed(f.summary)
            self.assertEqual(f.summary['selector_calls'], 0)

    def test_enabled_attachment_default_grants_deny_source_and_provider(self):
        with host_fixture('denied') as f:
            self.assertTrue(f.first['capture'])
            self.assertTrue(f.first['gate_released'])
            self.assertFalse(f.first['worker'])
            self.assertEqual(f.first['providers'], [])
            self.assertEqual(f.first['methods'], [])
            denied = f.rpc_reply('capture.capabilities.v1', {'library_id': f.library_id})
            self.assertFalse(denied['ok'])
            self.assertFalse(f.rpc_reply('submit', {'key': 'synthetic', 'tool': 'model.complete', 'arguments': {
                'provider': 'mock', 'model': 'deterministic-v1', 'prompt': 'synthetic', 'max_tokens': 8}})['ok'])
            self.assertEqual(f.record_count(), 0)
            f.close(); self.assert_closed(f.summary)

    def test_actual_host_controlled_gate_store_worker_native_commit_and_ack(self):
        with host_fixture() as f:
            self.assertTrue(f.first['gate_released'])
            self.assertTrue(f.first['capture'])
            self.assertTrue(f.first['worker'])
            self.assertEqual(f.first['providers'], [])
            self.assertEqual(f.command({'command': 'close_while_running'}), {'error': 'capture_host_still_running'})
            capture_id, raw = str(uuid.uuid4()), request()
            submitted = f.submit(capture_id, raw)
            status = f.wait(capture_id, submitted['binding']['admission_sha256'])
            self.assertEqual(status['state'], 'succeeded')
            receipt_bytes = f.result(capture_id, status)
            receipt = json.loads(receipt_bytes)
            self.assertEqual(receipt['source']['writer'], FIRST_WRITER)
            self.assertEqual(len(receipt['contributions']), 1)
            self.assertEqual(f.record_count(), 2)
            self.assertEqual(f.journal(capture_id)['acknowledged'], 1)
            self.assertEqual(f.journal(capture_id)['outer_receipt_hash'], sha(encode(status['receipt'])))
            f.close(); self.assert_closed(f.summary)
            emit_evidence('actual-host-attachment', dict(ready=f.first, stopped=f.summary,
                binding=status['binding'], outer_receipt=status['receipt'], ledger_records=2,
                result_sha256=sha(receipt_bytes), native_acknowledged=1),
                {'actual-host.request.json': raw, 'actual-host.receipt.json': receipt_bytes})

    def test_source_code_drift_and_registration_revocation_fail_closed(self):
        for command in ('source_drift', 'revoke_source'):
            with self.subTest(command=command), host_fixture() as f:
                self.assertTrue(f.rpc_reply('capture.capabilities.v1', {'library_id': f.library_id})['ok'])
                f.command({'command': command})
                self.assertEqual(f.rpc_reply('capture.capabilities.v1', {'library_id': f.library_id}),
                    {'ok': False, 'error': 'app_identity_unverified'})
                self.assertEqual(f.record_count(), 0)
                f.close(); self.assert_closed(f.summary)

    def test_independent_native_grant_revocation_has_no_ledger_effect(self):
        with host_fixture() as f:
            self.assertEqual(f.command({'command': 'revoke_native'}), {'command': 'revoked', 'writer_app': 'tisra'})
            capture_id = str(uuid.uuid4())
            submitted = f.submit(capture_id, request())
            status = f.wait(capture_id, submitted['binding']['admission_sha256'])
            self.assertEqual(status['state'], 'needs_review')
            self.assertEqual(f.record_count(), 0)
            f.close(); self.assert_closed(f.summary)

    def test_image_mismatch_and_selection_failure_abort_before_launch_gate(self):
        for mode, selector_calls in (('bad_hash', 0), ('select_failure', 1)):
            with self.subTest(mode=mode), host_fixture(mode) as f:
                self.assert_closed(f.first, result=1)
                self.assertEqual(f.first['selector_calls'], selector_calls)
                self.assertFalse(f.first['gate_proof']['released'])
                self.assertFalse(f.native_root.exists())


if __name__ == '__main__':
    unittest.main()
