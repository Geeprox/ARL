"""Actual neutral host/client/Store contract plus real-process offline acceptance."""
from dataclasses import replace
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest
import uuid

from arl.application_models import METHODS as MODEL_METHODS
from arl.codex_application import EXECUTE, RECOVER, EXECUTION_METHODS, compose_codex_application
from arl.codex_application_client import CodexApplicationClient
from arl.codex_server import CodexService, CodexTextAdapter
from arl.contracts import AppPolicy, Fault
from arl.identity import RegisteredPeerVerifier, process_identity
from arl.storage import Store

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(sys.platform == 'darwin', 'Kernel process identity is macOS-specific')
class CodexProductionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='arlcp-', dir=Path('/tmp').resolve())
        self.home = Path(self.tmp.name)
        self.caller = 'neutral-acceptance'
        self.authorized = True
        self.peer = RegisteredPeerVerifier({self.caller})
        self.peer.register(self.caller, os.getpid(), process_identity(os.getpid())['executable'])
        self.lease = self.peer.capture_registration(self.caller, os.getpid())
        self.service = CodexService(CodexTextAdapter(enabled=True,
            test_command=[sys.executable, '-B', '-I', str(ROOT/'tests/fixtures/CodexProductionServer.py')]),
            caller=self.caller, model='synthetic-model', max_calls=3, reasoning_effort='medium',
            authorization_current=lambda: self.authorized, peer_current=self.lease.is_current,
            allow_model_selection=True, allow_test_command=True)
        self.policy = AppPolicy(frozenset({self.service.name}), providers=frozenset(), max_pending=1,
            max_calls=3, methods=MODEL_METHODS | EXECUTION_METHODS |
            {'health', 'ready', 'capabilities', 'get', 'cancel', 'heartbeat'},
            priority_bands=frozenset({'background', 'explicit', 'interactive'}), max_deadline_ms=30000)
        self.runtime = compose_codex_application(self.home, service=self.service, peer_verifier=self.peer,
            policy=self.policy, isolated=True)
        self.runtime.store = Store(self.home/'state.sqlite')
        self.runtime.ready.set()
        self.service.preflight()
        self.binding = ('kernel-acceptance-registration', self.lease.is_current)
        self.open()

    def tearDown(self):
        self.runtime.store.close()
        self.runtime.control.close()
        self.runtime.service_portal.close()
        self.tmp.cleanup()

    def fault(self, code, callback):
        with self.assertRaises(Fault) as result:
            callback()
        self.assertEqual(result.exception.code, code)

    def rpc(self, method, params=None, verified=True):
        return self.runtime.dispatch({'protocol': 'arl/1', 'app': self.caller,
            'method': method, 'params': params or {}}, verified_app=self.caller if verified else None,
            peer_binding=self.binding if verified else None)

    def open(self):
        value = self.rpc('connection.open', {'client_nonce': 'a'*64, 'name': 'Neutral consumer',
            'icon_ref': 'sf:cpu', 'version': '1', 'capabilities': [self.service.name]})
        self.rpc('connection.confirm', {k: value[k] for k in ('session_id', 'challenge')})
        self.sid = value['session_id']

    def resolution(self, text='synthetic input', **changes):
        catalog = self.rpc('application.models.discover.v1', {'session_id': self.sid})
        args = {'schema_version': 1, 'session_id': self.sid, 'catalog_version': catalog['catalog_version'],
            'request_id': str(uuid.uuid4()), 'request_sha256': hashlib.sha256(text.encode()).hexdigest(),
            'task_kind': 'explain', 'package_id': 'high', 'thinking_effort': 'low',
            'service_tier': 'default', 'priority': 'interactive', 'deadline_ms': 25000,
            'allow_degradation': False}
        return self.rpc('application.models.request.v1', dict(args, **changes))

    def params(self, resolved, text='synthetic input', **changes):
        p = {k: resolved[k] for k in ('schema_version', 'session_id', 'request_id', 'request_sha256', 'resolution_id')}
        return dict(p, input=text, max_output_bytes=128, **changes)

    def budget(self):
        row = self.runtime.store.db.execute('SELECT calls FROM budget WHERE owner=?', (self.caller,)).fetchone()
        return row[0] if row else 0

    def test_server_frozen_selection_drives_actual_job_and_duplicate_has_one_budget(self):
        r = self.resolution()
        self.assertTrue(r['accepted'])
        result = self.rpc(EXECUTE, self.params(r))
        self.assertEqual({k: result['execution'][k] for k in r['resolved']}, r['resolved'])
        row = self.runtime.store.row(self.caller, result['job']['id'])
        self.assertEqual(json.loads(row['args'])['reasoning_effort'], 'low')
        self.assertEqual(row['priority'], 'interactive')
        self.assertEqual(row['deadline_span'], 25000)
        for _ in range(3):
            self.assertEqual(self.rpc(EXECUTE, self.params(r))['job']['id'], result['job']['id'])
        self.assertEqual(self.budget(), 1)

    def test_resolution_identity_body_and_host_grant_fail_before_budget(self):
        r = self.resolution()
        self.fault('app_identity_unverified', lambda: self.rpc(EXECUTE, self.params(r), verified=False))
        p = self.params(r); p['resolution_id'] = '0'*64
        self.fault('application_models_request_changed', lambda: self.rpc(EXECUTE, p))
        p = self.params(r); p['input'] = 'changed text'
        self.fault('application_models_request_changed', lambda: self.rpc(EXECUTE, p))
        self.authorized = False
        self.fault('codex_scope_unavailable', lambda: self.rpc(EXECUTE, self.params(r)))
        self.assertEqual(self.budget(), 0)

    def test_replaced_host_admission_is_enforced_before_queue(self):
        r = self.resolution()
        def reject(*_):
            raise Fault('review_withdrawn')
        self.runtime.admission = reject
        self.fault('review_withdrawn', lambda: self.rpc(EXECUTE, self.params(r)))
        self.assertEqual(self.budget(), 0)

    def test_resolution_expiry_cannot_be_used_to_start_inference(self):
        r = self.resolution()
        self.runtime.application_models.requests[self.caller, r['request_id']]['at'] -= 31
        self.fault('application_models_request_changed', lambda: self.rpc(EXECUTE, self.params(r)))
        self.assertEqual(self.budget(), 0)

    def test_changed_catalog_cannot_silently_change_resolved_job(self):
        r = self.resolution()
        self.service.catalog[0]['fast_available'] = True
        self.fault('application_models_catalog_changed', lambda: self.rpc(EXECUTE, self.params(r)))
        self.assertEqual(self.budget(), 0)

    def test_new_session_and_store_reopen_recover_original_job_without_replay(self):
        r = self.resolution()
        before = self.rpc(EXECUTE, self.params(r))
        self.runtime.store.claim(scope=self.runtime.work_scope)
        self.runtime.store.close()
        self.runtime.store = Store(self.home/'state.sqlite')
        self.runtime.store.recover(self.runtime.tools, scope=self.runtime.work_scope)
        self.rpc('connection.close', {'session_id': self.sid})
        self.runtime.application_models.requests.clear()
        self.open()
        after = self.rpc(RECOVER, {'schema_version': 1, 'session_id': self.sid,
            'request_id': r['request_id'], 'request_sha256': r['request_sha256']})
        self.assertEqual(before['job']['id'], after['job']['id'])
        self.assertEqual(after['job']['state'], 'needs_review')
        self.assertEqual(after['execution'], before['execution'])
        self.assertEqual(self.budget(), 1)
        self.assertIsNone(self.runtime.store.claim(scope=self.runtime.work_scope))
        self.fault('application_models_request_changed', lambda: self.rpc(RECOVER,
            {'schema_version': 1, 'session_id': self.sid, 'request_id': r['request_id'], 'request_sha256': '0'*64}))

    def test_policy_scope_and_production_signature_cannot_be_implicitly_expanded(self):
        # Test a fresh unattached service, so invalid policy rejection cannot be
        # accidentally satisfied by the separate single-owner invariant.
        fresh = CodexService(CodexTextAdapter(enabled=True, test_command=['not-executed']),
            caller=self.caller, model='synthetic-model', max_calls=3,
            authorization_current=lambda: True, peer_current=self.lease.is_current,
            allow_model_selection=True, allow_test_command=True)
        for bad in (replace(self.policy, max_calls=None), replace(self.policy, max_pending=True),
                replace(self.policy, methods=self.policy.methods-{EXECUTE}),
                replace(self.policy, tools=self.policy.tools | {'other.tool'})):
            self.fault('codex_service_not_admitted', lambda: compose_codex_application(self.home/'other',
                service=fresh, peer_verifier=self.peer, policy=bad, isolated=True))
        self.fault('codex_service_not_admitted', lambda: compose_codex_application(self.home/'other',
            service=fresh, peer_verifier=self.peer, policy=self.policy, isolated=False))

    def test_host_policy_helper_preserves_existing_quota_and_explicit_default(self):
        from arl.codex_application import scoped_application_policy
        p = scoped_application_policy(self.service, legacy_submit=True)
        self.assertEqual(p.max_calls, 3)
        self.assertEqual(p.priority_bands, frozenset({'explicit'}))
        self.assertIn('submit', p.methods)
        self.service.max_calls = None
        self.assertIsNone(scoped_application_policy(self.service).max_calls)

    def test_default_runtime_does_not_gain_execution_from_a_method_declaration(self):
        from arl.service import Runtime
        plain = Runtime(self.home/'plain', policies={self.caller: self.policy}, providers={},
            identity_verifier=self.peer)
        plain.application_execution_methods = EXECUTION_METHODS
        try:
            self.fault('unknown_method', lambda: plain.dispatch({'protocol': 'arl/1', 'app': self.caller,
                'method': EXECUTE, 'params': {}}, verified_app=self.caller, peer_binding=self.binding))
        finally:
            plain.control.close(); plain.service_portal.close()

    def test_existing_production_factory_branch_preserves_legacy_and_metadata_only_peer(self):
        from arl.codex_application import scoped_application_policy, CodexApplicationRuntime
        from arl.compat_host import compose_codex_service, make_runtime
        from arl.formal_peer import FormalTisraPeer
        from unittest.mock import patch
        fresh = CodexService(CodexTextAdapter(enabled=True,
            test_command=[sys.executable, '-B', '-I', str(ROOT/'tests/fixtures/CodexProductionServer.py')]),
            caller=self.caller, model='synthetic-model', max_calls=3, reasoning_effort='medium',
            authorization_current=lambda: True, peer_current=self.lease.is_current,
            allow_model_selection=True, allow_test_command=True)
        policy = scoped_application_policy(fresh, legacy_submit=True)
        self.fault('codex_service_not_admitted', lambda: make_runtime(self.home/'missing',
            codex_application_policy=policy))
        helper = self.home/'inert-signed-helper'; helper.write_bytes(b'not executed')
        formal = FormalTisraPeer(helper)
        runtime = compose_codex_service(self.home/'branch', service=fresh, peer_verifier=self.peer,
            isolated=True, application_policy=policy, formal_tisra_peer=formal)
        try:
            self.assertIsInstance(runtime, CodexApplicationRuntime)
            self.assertEqual(runtime.policies[self.caller].max_calls, 3)
            self.assertEqual(runtime.policies['tisra'].tools, frozenset())
            self.assertEqual(runtime.policies['tisra'].max_calls, 0)
            self.assertFalse(EXECUTION_METHODS & runtime.policies['tisra'].methods)
            runtime.store = Store(self.home/'branch.sqlite'); runtime.ready.set(); fresh.preflight()
            job = runtime.dispatch({'protocol': 'arl/1', 'app': self.caller, 'method': 'submit',
                'params': {'tool': fresh.name, 'key': 'legacy-existing-caller',
                    'args': {'model': fresh.model, 'input': 'synthetic input', 'max_output_bytes': 128}}},
                verified_app=self.caller)
            self.assertEqual(job['state'], 'queued')
            with patch.object(FormalTisraPeer, '__call__', return_value='tisra'):
                self.assertEqual(runtime.identity_verifier(None, 'tisra'), 'tisra')
            self.fault('method_not_authorized', lambda: runtime.dispatch({'protocol': 'arl/1', 'app': 'tisra',
                'method': EXECUTE, 'params': {}}, verified_app='tisra', peer_binding=('metadata-peer', lambda: True)))
        finally:
            if runtime.store is not None: runtime.store.close()
            runtime.control.close(); runtime.service_portal.close()


@unittest.skipUnless(sys.platform == 'darwin', 'Actual macOS kernel peer test')
class CodexProductionProcessTests(unittest.TestCase):
    def test_actual_process_socket_resolution_execution_cancel_and_reconnect(self):
        from script.check_codex_production import run
        proof = run()
        self.assertTrue(proof['ok'], proof)
        self.assertTrue(proof['simulated'])
        self.assertEqual(proof['persistent_call_count'], 2)
        self.assertEqual([p['job_state'] for p in proof['results']], ['succeeded', 'cancelled'])
        self.assertEqual([p['execution']['priority'] for p in proof['results']], ['background', 'interactive'])
        self.assertTrue(proof['owned_consumers_closed'])
        self.assertTrue(proof['isolated_runtime_closed'])
        self.assertFalse(proof['production_signed_caller_verified'])


if __name__ == '__main__':
    unittest.main()
