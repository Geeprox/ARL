"""Model execution stays with local/LAN clients; Mio service policy is separate."""
import unittest
from unittest.mock import patch

from arl.extension_contracts import CODEX_METHODS, RESPONSES_METHODS, default_policies, metadata_policies


class ModelTransportBoundaryTests(unittest.TestCase):
    def test_mio_has_no_model_completion_or_typed_research_execution(self):
        for local_enabled in (False, True):
            policy = default_policies(local_enabled)["mio"]
            self.assertNotIn("model.complete", policy.tools)
            self.assertFalse(any(name.startswith(("codex.", "model.", "research.", "tisra.codex."))
                                 for name in policy.tools))
            self.assertFalse(policy.methods & (CODEX_METHODS | RESPONSES_METHODS))
            self.assertIn("runtime.ping", policy.tools)
            self.assertTrue(any(name.startswith("mio_maps_") for name in policy.tools))

    def test_existing_local_consumers_keep_explicit_model_routes(self):
        for client in ("tisra", "friday"):
            self.assertIn("model.complete", default_policies(False)[client].tools)
            self.assertNotIn("ollama", default_policies(False)[client].providers)
            self.assertIn("ollama", default_policies(True)[client].providers)

    def test_metadata_profile_does_not_create_mio_execution_grants(self):
        policies=metadata_policies()
        self.assertNotIn("mio",policies)
        self.assertEqual(set(policies),{"settings"})
        self.assertFalse(policies["settings"].tools)

    def test_settings_method_sets_follow_the_host_profile(self):
        development = default_policies()["settings"]
        local = metadata_policies()["settings"]
        with patch('arl.extension_contracts.compatibility', None):
            public = metadata_policies()["settings"]
        self.assertEqual(public.methods, development.methods | {"settings.task_attention.v1"})
        self.assertEqual(local.methods, public.methods | {
            "settings.scheduler.v1", "codex.service.status.v1", "settings.app_icon.v1",
        })
        for policy in (development, local, public):
            self.assertTrue(policy.public_metadata)
            self.assertFalse(policy.tools)
            self.assertFalse(policy.providers)
            self.assertEqual((policy.max_pending, policy.max_calls), (0, 0))



if __name__ == "__main__":
    unittest.main()
