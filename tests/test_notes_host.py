"""Real Swift controller/modal timer + injected presentation/store/transport."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class NotesHostTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="arl-notes-host-")
        cls.bin = Path(cls.temp.name) / "fixture"
        review = ROOT / "integrations/apple_review"
        notes = ROOT / "integrations/apple_notes"
        host = ROOT / "integrations/apple_notes_host"
        sources = [review / s for s in ("Proposal.swift", "PeerAuthentication.swift", "ConsumptionJournal.swift")]
        sources += [notes / s for s in ("NotesProposal.swift", "NotesApprovalEngine.swift", "NotesAutomation.swift")]
        sources += [host / s for s in ("NativeNotesReviewer.swift", "NotesWire.swift", "NotesHost.swift", "NotesClient.swift", "NotesSocket.swift", "Fixture.swift")]
        subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-D", "APPLE_REVIEW_FIXTURE", "-module-cache-path", cls.temp.name + "/cache", *map(str, sources), "-framework", "AppKit", "-framework", "ApplicationServices", "-framework", "CoreGraphics", "-framework", "Security", "-o", str(cls.bin)], check=True, capture_output=True, timeout=90)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def call(self, scenario):
        with tempfile.TemporaryDirectory(prefix="arl-notes-host-state-") as home:
            result = subprocess.run([str(self.bin), scenario, str(Path(home).resolve())], check=True, capture_output=True, text=True, timeout=5)
            value = json.loads(result.stdout)
            self.assertEqual(value["notes_calls"], 0)
            return value

    def test_request_review_effect_receipt(self):
        r = self.call("success")
        self.assertEqual((r["status"], r["creates"], r["modal_runs"], r["exchanges"]), ("ok", 1, 1, 1))
        self.assertIn("Synthetic Folder\n完整标题 <&>\nPlain <script>\n\t下一行", r["display"])
        self.assertEqual((r["persistence"], r["cloud_sync"]), ("created_local", "not_checked"))
        self.assertLessEqual(r["wire_bytes"], 32768)

    def test_modal_timer_expiry_and_bound_cancel(self):
        for name, status in [("timer_expiry", "approval_expired"), ("cancel", "cancelled_before_effect"), ("disconnect", "cancelled_before_effect")]:
            with self.subTest(name=name):
                r = self.call(name)
                self.assertEqual((r["status"], r["creates"], r["modal_runs"], r["dismissed"]), (status, 0, 1, True))

    def test_preparation_metadata_expiry_no_modal(self):
        for name in ("prepare_expiry", "metadata_expiry"):
            r = self.call(name)
            self.assertEqual((r["status"], r["creates"], r["modal_runs"]), ("approval_expired", 0, 0))

    def test_decline_revocation_and_spoof(self):
        for name, status in [("decline", "user_cancelled"), ("revoke", "caller_unverified"), ("caller_spoof", "caller_unverified"), ("target_spoof", "capability_not_granted"), ("bad_hash", "invalid_transport_request")]:
            with self.subTest(name=name):
                r = self.call(name)
                self.assertEqual((r["status"], r["creates"]), (status, 0))

    def test_restart_no_replay_and_budget(self):
        for name, status in [("duplicate_restart", "operation_consumed"), ("budget", "effect_budget_exceeded")]:
            r = self.call(name)
            self.assertEqual((r["status"], r["creates"], r["modal_runs"]), (status, 1, 1))

    def test_unregistered_kernel_peer_and_wrong_cancel(self):
        r = self.call("invalid_fd")
        self.assertEqual((r["status"], r["creates"], r["modal_runs"]), ("caller_unverified", 0, 0))
        r = self.call("wrong_cancel")
        self.assertEqual((r["status"], r["creates"], r["dismissed"]), ("ok", 1, False))

    def test_lost_receipt_no_retry_and_mismatch(self):
        for name, status in [("lost_receipt", "outcome_unknown"), ("wrong_receipt", "receipt_mismatch")]:
            r = self.call(name)
            self.assertEqual((r["status"], r["creates"], r["exchanges"]), (status, 1, 1))


if __name__ == "__main__":
    unittest.main()
