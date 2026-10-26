"""Bounded local-socket rehearsal; signature and model adapter are inert."""
import hashlib
import os
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import patch

from arl.client import Client
from arl.codex_server import CodexTextAdapter
from arl.contracts import Fault
from arl.formal_peer import FormalTisraPeer, exact_file
from arl.formal_research_host import FormalResearchActivation
from arl.host import make_runtime
from arl.identity import RegisteredPeerVerifier, process_identity
from arl.priority import AppProfilePolicy, ResourcePolicy, TaskPolicy
from arl.priority_host import PriorityHostConfig
from arl.research_product import ResearchAdmission, grant, read_consent


class ProductResearchSocketTests(unittest.TestCase):
    def test_signed_first_connection_observes_real_kernel_pid_without_model(self):
        with tempfile.TemporaryDirectory(prefix='arl-product-socket-') as root:
            base = Path(root)
            grant(base, 'inert-model', confirmed=True)
            consent, state = read_consent(base)
            self.assertEqual(state, 'approved')
            binary = base / 'inert-codex'; binary.write_bytes(b'never executed')
            helper = base / 'inert-helper'; helper.write_bytes(b'never executed')
            # The signature result is synthetic. The socket PID, UID, birth,
            # executable and registry checks remain the real macOS path.
            executable = Path(process_identity(os.getpid())['executable'])
            verifier = RegisteredPeerVerifier({'tisra'})
            priority = PriorityHostConfig(
                (ResourcePolicy('model', slots=1, realtime_reserved=0,
                                background_start_limit_ms=30000),),
                (TaskPolicy('tisra.codex.research.v2', 'model.inference', 'model',
                            owners=frozenset({'tisra'}), maximum_class='interactive',
                            execution_budget_ms=25000),),
                {'tisra': AppProfilePolicy(frozenset({'background', 'interactive'}),
                                           max_deadline_ms=30000)}, 60000)
            activation = FormalResearchActivation(FormalTisraPeer(helper), verifier,
                CodexTextAdapter(binary, enabled=True), 'inert-model',
                consent.consent_id, priority, ResearchAdmission(base, consent),
                consent.consent_id)
            with patch('arl.formal_research_host.DEFAULT_BINARY', binary), \
                 patch('arl.formal_research_host.TISRA_EXECUTABLE', executable), \
                 patch('arl.formal_research_host.TISRA_EXECUTABLE_SHA256', hashlib.sha256(executable.read_bytes()).hexdigest()), \
                 patch('arl.formal_research_host.HELPER_SHA256', hashlib.sha256(helper.read_bytes()).hexdigest()), \
                 patch('arl.formal_research_host.exact_file', side_effect=lambda path, digest:
                       True if Path(path) == executable else exact_file(path, digest)), \
                 patch.object(FormalTisraPeer, '__call__', return_value='tisra'):
                runtime = make_runtime(base / 'runtime', research_activation=activation)
                errors = []
                def serve():
                    try:
                        runtime.run()
                    except Exception as error:
                        errors.append(error)
                worker = threading.Thread(target=serve)
                worker.start()
                try:
                    client = Client(base / 'runtime', 'tisra')
                    client.connect(timeout=5)
                    self.assertTrue(client.rpc('health')['ready'])
                    self.assertEqual(verifier.registration_generation('tisra', os.getpid()), 1)
                    with self.assertRaises(Fault) as blocked:
                        client.rpc('codex.research.capabilities.v1')
                    self.assertEqual(blocked.exception.code, 'research_model_not_ready')
                    self.assertFalse(hasattr(runtime, 'research_preflight_at'))
                    proof = {'model': 'inert-model', 'ephemeral': True,
                             'read_only': True, 'synthetic': False}
                    with patch.object(activation.text_adapter, 'preflight_model', return_value=proof) as spy:
                        runtime.priority_producer.probe_native('tisra', 'inert-model')
                    self.assertEqual(spy.call_count, 1)
                    with self.assertRaises(Fault) as still_blocked:
                        client.rpc('codex.research.capabilities.v1')
                    self.assertEqual(still_blocked.exception.code, 'research_model_not_ready')
                    runtime.research_preflight_at = time.monotonic()
                    self.assertEqual(client.rpc('codex.research.capabilities.v1')['tool'],
                                     'tisra.codex.research.v2')
                finally:
                    runtime.shutdown()
                    worker.join(10)
                self.assertFalse(worker.is_alive())
                self.assertEqual(errors, [])


if __name__ == '__main__':
    unittest.main()
