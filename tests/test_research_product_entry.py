"""Offline production-entry and consent boundary tests; no real app or model."""
import hashlib
import json
import os
import signal
import struct
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import patch

from arl.contracts import Fault
from arl.formal_peer import FormalTisraPeer
from arl.formal_research_host import BothPeers, FormalResearchActivation
from arl.host import main, make_runtime, run
from arl.identity import RegisteredPeerVerifier
from arl.research_product import (FILENAME, ResearchAdmission, build_activation,
                                  grant, read_consent, revoke, status)
from arl.storage import Store


class ProductResearchEntryTests(unittest.TestCase):
    def test_missing_grant_is_actionable_and_does_not_construct_activation(self):
        with tempfile.TemporaryDirectory() as root:
            home = Path(root)
            with patch('arl.research_product.available_formal_tisra_peer', side_effect=AssertionError('peer discovery')):
                activation, state = build_activation(home)
            self.assertIsNone(activation)
            self.assertEqual(state, 'needs_user_authorization')
            self.assertEqual(status(home)['state'], state)

    def test_exact_hour_grant_and_revocation_fence_admission(self):
        with tempfile.TemporaryDirectory() as root:
            home = Path(root)
            with self.assertRaises(Fault):
                grant(home, 'reviewed-model')
            expires = grant(home, 'reviewed-model', confirmed=True, now_ms=100000)
            self.assertEqual(expires, 3700000)
            path = home / FILENAME
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            consent, state = read_consent(home, now_ms=100000)
            self.assertEqual(state, 'approved')
            with patch('arl.research_product.time.time', return_value=100):
                admission = ResearchAdmission(home, consent)
                args = {'provider': 'codex_app_server', 'model': 'reviewed-model',
                        'priority': 'explicit', 'max_output_tokens': None,
                        'max_output_bytes': 32768, 'deadline_ms': 30000,
                        'request': {'byte_count': 8192},
                        'descriptor': {'byte_count': 32768}}
                admission('tisra', 'tisra.codex.research.v2', args)
                with self.assertRaises(Fault):
                    admission('friday', 'tisra.codex.research.v2', args)
                with self.assertRaises(Fault):
                    admission('tisra', 'tisra.codex.research.v2', dict(args, model='other'))
                revoke(home)
                with self.assertRaises(Fault):
                    admission('tisra', 'tisra.codex.research.v2', args)
            self.assertEqual(read_consent(home)[1], 'needs_user_authorization')

    def test_unsafe_and_expired_consent_never_enable(self):
        with tempfile.TemporaryDirectory() as root:
            home = Path(root)
            grant(home, 'reviewed-model', confirmed=True, now_ms=100000)
            path = home / FILENAME
            self.assertEqual(read_consent(home, now_ms=3700000)[1], 'consent_expired')
            os.chmod(path, 0o644)
            self.assertEqual(read_consent(home, now_ms=100000)[1], 'consent_unsafe')
            os.chmod(path, 0o600)
            value = json.loads(path.read_text())
            path.write_text(json.dumps(value)[:-1] + ',"model":"other"}')
            self.assertEqual(read_consent(home, now_ms=100000)[1], 'consent_invalid')
            path.unlink()
            path.symlink_to(home / 'elsewhere')
            self.assertEqual(read_consent(home, now_ms=100000)[1], 'consent_unreadable')

    def test_approved_builder_is_consumed_by_real_main_seam(self):
        with tempfile.TemporaryDirectory() as root:
            home = Path(root)
            grant(home, 'reviewed-model', confirmed=True, now_ms=100000)
            binary = home / 'codex'; binary.write_bytes(b'inert binary')
            peer = object()
            with patch('arl.research_product.time.time', return_value=100), \
                 patch('arl.research_product.available_formal_tisra_peer', return_value=peer), \
                 patch('arl.research_product.DEFAULT_BINARY', binary):
                activation, state = build_activation(home)
            self.assertIs(type(activation), FormalResearchActivation)
            self.assertIs(activation.signed_peer, peer)
            self.assertEqual(activation.model, 'reviewed-model')
            self.assertEqual(activation.priority.tasks[0].task_kind, 'model.inference')
            self.assertEqual(state, 'awaiting_tisra_connection')
            with patch('sys.argv', ['arl-host', '--isolated-test', '--home', str(home)]), \
                 patch('arl.research_product.build_activation', return_value=(activation, state)), \
                 patch('arl.formal_peer.available_formal_tisra_peer', side_effect=AssertionError('duplicate peer')), \
                 patch('arl.compat_host.run', return_value=7) as run:
                self.assertEqual(main(), 7)
            self.assertIs(run.call_args.kwargs['research_activation'], activation)
            self.assertIsNone(run.call_args.kwargs['formal_tisra_peer'])

    def test_product_approval_composes_real_runtime_without_model_or_process(self):
        with tempfile.TemporaryDirectory() as root:
            home = Path(root)
            grant(home, 'reviewed-model', confirmed=True, now_ms=100000)
            binary = home / 'codex'; binary.write_bytes(b'inert binary')
            helper = home / 'peer'; helper.write_bytes(b'inert helper')
            app = home / 'Tisra'; app.write_bytes(b'inert app')
            with patch('arl.research_product.time.time', return_value=100), \
                 patch('arl.research_product.DEFAULT_BINARY', binary), \
                 patch('arl.research_product.available_formal_tisra_peer', return_value=FormalTisraPeer(helper)), \
                 patch('arl.formal_research_host.DEFAULT_BINARY', binary), \
                 patch('arl.formal_research_host.TISRA_EXECUTABLE', app), \
                 patch('arl.formal_research_host.HELPER_SHA256', hashlib.sha256(helper.read_bytes()).hexdigest()), \
                 patch('arl.formal_research_host.TISRA_EXECUTABLE_SHA256', hashlib.sha256(app.read_bytes()).hexdigest()):
                activation, _ = build_activation(home)
                runtime = make_runtime(home / 'runtime', research_activation=activation)
            self.assertTrue(runtime.execute_jobs)
            self.assertEqual(runtime.policies['tisra'].tools, frozenset({'tisra.codex.research.v2'}))
            self.assertEqual(runtime.policies['friday'].tools, frozenset())
            self.assertEqual(runtime.priority_producer.config.tasks[0].task_kind, 'model.inference')
            self.assertFalse(activation.registered_peer.registry)
            self.assertFalse(runtime.ready.is_set())
            engine = runtime.research_engines['tisra.codex.research.v2']
            with self.assertRaises(Fault) as missing:
                engine.capability_result('tisra')
            self.assertEqual(missing.exception.code, 'research_model_not_ready')
            with self.assertRaises(Fault) as blocked:
                engine.dispatch('tisra', 'codex.payload.begin.v1', {}, runtime.policies['tisra'])
            self.assertEqual(blocked.exception.code, 'research_model_not_ready')
            with patch('arl.research_product.time.time', return_value=100), \
                 patch.object(activation.registered_peer, 'registration_subject', return_value='current'), \
                 patch('arl.formal_research_host.TISRA_EXECUTABLE', app), \
                 patch('arl.formal_research_host.HELPER_SHA256', hashlib.sha256(helper.read_bytes()).hexdigest()), \
                 patch('arl.formal_research_host.TISRA_EXECUTABLE_SHA256', hashlib.sha256(app.read_bytes()).hexdigest()):
                runtime.ready.set()
                self.assertFalse(hasattr(runtime, 'research_preflight_at'))
                self.assertEqual(engine.capability_result('tisra')['tool'], 'tisra.codex.research.v2')

    def test_first_signed_connection_registers_only_kernel_verified_pid(self):
        with tempfile.TemporaryDirectory() as root:
            app = Path(root) / 'Tisra'; app.write_bytes(b'inert app')
            registry = RegisteredPeerVerifier({'tisra'})
            class Connection:
                def getsockopt(self, level, name, length):
                    self_call = 417
                    return self_call.to_bytes(4, 'little', signed=True)
            connection = Connection()
            identity = {'uid': os.geteuid(), 'birth': (1, 2),
                        'executable': str(app.resolve())}
            with patch('arl.formal_research_host.TISRA_EXECUTABLE', app), \
                 patch('arl.identity.process_identity', return_value=identity):
                denied = BothPeers(lambda *_: None, registry)
                self.assertIsNone(denied(connection, 'tisra'))
                self.assertEqual(registry.registry, {})
                accepted = BothPeers(lambda *_: 'tisra', registry)
                self.assertEqual(accepted(connection, 'tisra'), 'tisra')
                self.assertEqual(accepted(connection, 'tisra'), 'tisra')
                self.assertEqual(len(registry.registry), 1)
                registry.revoke(417)
                self.assertFalse(registry.registry)

    def test_first_production_probe_requires_real_proof_before_public_rpc(self):
        with tempfile.TemporaryDirectory() as root:
            home = Path(root)
            binary = home / 'codex'; binary.write_bytes(b'inert transport')
            helper = home / 'peer'; helper.write_bytes(b'inert helper')
            app = home / 'Tisra'; app.write_bytes(b'inert app')
            now = time.time()
            grant(home, 'synthetic-model', confirmed=True, now_ms=int(now * 1000))
            identity = {'uid': os.geteuid(), 'birth': (1, 2),
                        'executable': str(app.resolve())}
            with patch('arl.research_product.time.time', return_value=now), \
                 patch('arl.research_product.DEFAULT_BINARY', binary), \
                 patch('arl.research_product.available_formal_tisra_peer', return_value=FormalTisraPeer(helper)), \
                 patch('arl.formal_research_host.DEFAULT_BINARY', binary), \
                 patch('arl.formal_research_host.TISRA_EXECUTABLE', app), \
                 patch('arl.formal_research_host.HELPER_SHA256', hashlib.sha256(helper.read_bytes()).hexdigest()), \
                 patch('arl.formal_research_host.TISRA_EXECUTABLE_SHA256', hashlib.sha256(app.read_bytes()).hexdigest()), \
                 patch('arl.identity.process_identity', return_value=identity):
                activation, _ = build_activation(home)
                runtime = make_runtime(home / 'runtime', research_activation=activation)
                engine = runtime.research_engines['tisra.codex.research.v2']
                store = Store(home / 'state.sqlite')
                try:
                    runtime.store = store
                    engine.attach(store)
                    runtime.bind_priority()
                    activation.registered_peer.register('tisra', 417, app)
                    runtime.ready.set()
                    self.assertFalse(hasattr(runtime, 'research_preflight_at'))
                    policy = runtime.policies['tisra']
                    def blocked(*codes):
                        for method in ('codex.research.capabilities.v1', 'codex.payload.begin.v1'):
                            with self.assertRaises(Fault) as error:
                                engine.dispatch('tisra', method, {}, policy)
                            self.assertIn(error.exception.code, codes or ('research_model_not_ready',))
                    blocked()
                    proof = {'model': 'synthetic-model', 'ephemeral': True,
                             'read_only': True, 'synthetic': False}
                    with patch.object(activation.text_adapter, 'preflight_model', return_value={}):
                        with self.assertRaises(Fault):
                            runtime.priority_producer.probe_native('tisra', 'synthetic-model')
                    self.assertFalse(runtime.priority_producer.preflights)
                    blocked()
                    def drift(_model):
                        binary.write_bytes(b'changed inert transport')
                        return proof
                    with patch.object(activation.text_adapter, 'preflight_model', side_effect=drift):
                        with self.assertRaises(Fault):
                            runtime.priority_producer.probe_native('tisra', 'synthetic-model')
                    self.assertFalse(runtime.priority_producer.preflights)
                    blocked('provider_binary_changed')
                    binary.write_bytes(b'inert transport')
                    during_proof = []
                    def read_only_proof(_model):
                        during_proof.append(not hasattr(runtime, 'research_preflight_at'))
                        try:
                            engine.dispatch('tisra', 'codex.research.capabilities.v1', {}, policy)
                        except Fault as error:
                            during_proof.append(error.code)
                        return proof
                    def run_until_ready():
                        deadline = time.monotonic() + 3
                        while not hasattr(runtime, 'research_preflight_at') and time.monotonic() < deadline:
                            time.sleep(.01)
                        if not hasattr(runtime, 'research_preflight_at'):
                            raise AssertionError('production monitor did not record proof')
                    old_term, old_int = signal.getsignal(signal.SIGTERM), signal.getsignal(signal.SIGINT)
                    try:
                        with patch('arl.compat_host.make_runtime', return_value=runtime), \
                             patch.object(runtime, 'run', side_effect=run_until_ready), \
                             patch.object(activation.text_adapter, 'preflight_model', side_effect=read_only_proof) as spy:
                            self.assertEqual(run(home / 'runtime', research_activation=activation), 0)
                    finally:
                        signal.signal(signal.SIGTERM, old_term)
                        signal.signal(signal.SIGINT, old_int)
                    self.assertEqual(spy.call_count, 1)
                    self.assertEqual(len(runtime.priority_producer.preflights), 1)
                    self.assertEqual(during_proof, [True, 'research_model_not_ready'])
                    self.assertEqual(engine.dispatch('tisra', 'codex.research.capabilities.v1', {}, policy)['tool'],
                                     'tisra.codex.research.v2')
                    # Both producer views and the public RPC require current consent.
                    revoke(home)
                    with self.assertRaises(Fault):
                        runtime.priority_producer.probe_native('tisra', 'synthetic-model')
                    with self.assertRaises(Fault):
                        engine.dispatch('tisra', 'codex.research.capabilities.v1', {}, policy)
                    with self.assertRaises(Fault):
                        engine.dispatch('tisra', 'codex.payload.begin.v1', {}, policy)
                finally:
                    store.close()

    def test_signed_first_enrollment_serializes_two_live_pids_and_replaces_stale(self):
        with tempfile.TemporaryDirectory() as root:
            app = Path(root) / 'Tisra'; app.write_bytes(b'inert app')
            registry = RegisteredPeerVerifier({'tisra'})
            accepted = BothPeers(lambda _connection, app_id: app_id, registry)
            class Connection:
                def __init__(self, pid): self.pid = pid
                def getsockopt(self, level, name, length):
                    self.assert_socket = (level, name, length)
                    return struct.pack('i', self.pid)
            identity = lambda pid: {'uid': os.geteuid(), 'birth': (pid, 2),
                                    'executable': str(app.resolve())}
            barrier = threading.Barrier(3)
            results = {}
            def enroll(pid):
                barrier.wait(3)
                results[pid] = accepted(Connection(pid), 'tisra')
            with patch('arl.formal_research_host.TISRA_EXECUTABLE', app), \
                 patch('arl.identity.process_identity', side_effect=identity):
                workers = [threading.Thread(target=enroll, args=(pid,)) for pid in (417, 418)]
                for worker in workers: worker.start()
                barrier.wait(3)
                for worker in workers: worker.join(3)
                self.assertFalse(any(worker.is_alive() for worker in workers))
                self.assertEqual(sorted(results.values(), key=str), [None, 'tisra'])
                self.assertEqual(len(registry.registry), 1)
                winner = next(iter(registry.registry))
                loser = 418 if winner == 417 else 417
                self.assertEqual(accepted(Connection(winner), 'tisra'), 'tisra')
                self.assertIsNone(accepted(Connection(loser), 'tisra'))
                # A stale process is removed only at its observed generation.
                with patch('arl.identity.process_identity', side_effect=lambda pid:
                           dict(identity(pid), birth=(9, 9)) if pid == winner else identity(pid)):
                    self.assertEqual(accepted(Connection(loser), 'tisra'), 'tisra')
                self.assertEqual(list(registry.registry), [loser])

                # A failed admission may race with an independent newer
                # generation. Cleanup must only target the generation it made.
                registry.revoke(loser)
                original_subject = registry.registration_subject
                def replaced_subject(app_id):
                    registry.register(app_id, loser, app)
                    raise Fault('priority_identity_binding_unavailable')
                with patch.object(registry, 'registration_subject', side_effect=replaced_subject):
                    self.assertIsNone(accepted(Connection(loser), 'tisra'))
                self.assertEqual(len(registry.registry), 1)
                self.assertEqual(registry.registration_generation('tisra', loser), registry.generation)
                self.assertTrue(original_subject('tisra'))

                # Same-generation failure removes only the entry just written.
                registry.revoke(loser)
                with patch.object(registry, 'registration_subject',
                                  side_effect=Fault('priority_identity_binding_unavailable')):
                    self.assertIsNone(accepted(Connection(loser), 'tisra'))
                self.assertEqual(registry.registration_generation('tisra', loser), -1)

                # B3: an independent trusted register replaces the entry
                # before the old call returns its token. Cleanup owns the old
                # write, never the replacement now visible in the registry.
                raw_register = registry.register
                writes = []
                def replace_before_token(app_id, pid, expected):
                    writes.append(raw_register(app_id, pid, expected))
                    writes.append(raw_register(app_id, pid, expected))
                    newer_subject.append(original_subject(app_id))
                    return writes[0]
                newer_subject = []
                with patch.object(registry, 'register', side_effect=replace_before_token), \
                     patch.object(registry, 'registration_subject',
                                  side_effect=Fault('priority_identity_binding_unavailable')):
                    self.assertIsNone(accepted(Connection(loser), 'tisra'))
                self.assertEqual(len(writes), 2)
                self.assertLess(writes[0], writes[1])
                self.assertEqual(registry.registration_generation('tisra', loser), writes[1])
                self.assertEqual(registry.registration_subject('tisra'), newer_subject[0])


if __name__ == '__main__':
    unittest.main()
