"""Model execution stays with local/LAN clients; Mio service policy is separate."""
import unittest

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
        policy = metadata_policies()["mio"]
        self.assertFalse(policy.tools)
        self.assertFalse(policy.providers)
        self.assertFalse(policy.methods)
        self.assertEqual((policy.max_tokens, policy.max_calls, policy.max_pending), (0, 0, 0))


if __name__ == "__main__":
    unittest.main()
