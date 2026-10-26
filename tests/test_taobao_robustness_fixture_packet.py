"""Four offline fixture-integrity checks. They do not execute Swift policies."""
import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "tests/fixtures"


class TaobaoRobustnessFixturePacket(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.packet = json.loads((FIXTURES / "taobao-robustness-scenarios.json").read_bytes())
        cls.catalog = json.loads((FIXTURES / "taobao-300-official-tools.json").read_bytes())
        cls.product = json.loads((FIXTURES / "taobao-public-product-title.json").read_bytes())

    def test_R04_consumed_contract_vector_is_based_on_actual_schema(self):
        tool = next(row for row in self.catalog if row["name"] == "read_page_content")
        self.assertEqual(tool["inputSchema"]["properties"]["maxLength"]["type"], "number")
        vector = self.packet["R04"]
        self.assertNotIn(vector["unrelated_addition"], {row["name"] for row in self.catalog})
        self.assertLess(vector["search_price_length"], vector["selected_read_minimum"])
        self.assertGreaterEqual(vector["product_title_length"], vector["selected_read_minimum"])

    def test_R05_upgrade_vector_is_hypothetical_not_a_live_claim(self):
        vector = self.packet["R05"]
        self.assertEqual((vector["known_bundle"], vector["known_team"]), ("com.taobao.desktop", "VJGTV94XY8"))
        self.assertFalse(vector["actual_new_build_observed"])
        self.assertEqual(vector["negative_probe_states"], ["identityUnknown", "noListener"])
        self.assertTrue(self.packet["fixture_only"])

    def test_R06_same_pid_restart_vector_changes_both_generation_fields(self):
        vector = self.packet["R06"]
        self.assertNotEqual(vector["old_birth"], vector["new_birth"])
        self.assertNotEqual(vector["old_listener"], vector["new_listener"])
        self.assertEqual(vector["endpoint"], "http://127.0.0.1:3654/mcp")
        self.assertEqual(vector["next_action"], "EXPLICIT_NEW_READ_INITIALIZE_DISCOVER")

    def test_R07_render_and_completeness_vector_keeps_actual_identity(self):
        vector = self.packet["R07"]
        self.assertTrue(self.product["raw_title_scope_text"].startswith("[商品id] " + self.product["product_id"] + "\n"))
        self.assertGreater(vector["pending_tab_reads"], 8)
        self.assertEqual(vector["complete_markers"], {"offset": 0, "remainingLength": 0, "truncated": False})
        self.assertEqual(vector["length_profile"], "utf16_only")
        self.assertEqual(self.packet["production_regressions"], "PREPARED_NOT_RUN_NO_NATIVE_SLOT")


if __name__ == "__main__":
    unittest.main()
