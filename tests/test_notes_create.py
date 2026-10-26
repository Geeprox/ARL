"""Native compile and injected effects only; no Notes/TCC/AppleEvent send."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]


class NotesCreateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="arl-notes-fixtures-")
        cls.bin = Path(cls.temp.name) / "fixture"
        review = ROOT / "integrations/apple_review"
        notes = ROOT / "integrations/apple_notes"
        sources = [review / s for s in ("Proposal.swift", "PeerAuthentication.swift", "ConsumptionJournal.swift")]
        sources += [notes / s for s in ("NotesProposal.swift", "NotesApprovalEngine.swift", "NotesAutomation.swift", "Fixture.swift")]
        subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-D", "APPLE_REVIEW_FIXTURE", "-module-cache-path", cls.temp.name + "/cache",
                        *map(str, sources), "-framework", "ApplicationServices", "-framework", "CoreGraphics", "-framework", "Security", "-o", str(cls.bin)],
                       check=True, capture_output=True, timeout=90)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def call(self, scenario):
        with tempfile.TemporaryDirectory(prefix="arl-notes-journal-") as home:
            # /var is a macOS symlink; the journal deliberately rejects any
            # symlink ancestor. Supply the actual owned temp directory.
            p = subprocess.run([str(self.bin), scenario, str(Path(home).resolve())], check=True, capture_output=True, text=True, timeout=5)
            return json.loads(p.stdout)

    def rejected(self, scenarios, creates=0):
        for scenario, code in scenarios.items():
            with self.subTest(scenario=scenario):
                r = self.call(scenario)
                self.assertEqual(r["status"], code)
                self.assertEqual(r["create_calls"], creates)

    def test_default_off_and_identity(self):
        self.rejected({"default_disabled": "capability_not_granted", "forged_caller": "caller_unverified", "invalid_peer": "caller_unverified", "arbitrary_target": "capability_not_granted"})

    def test_strict_schema_and_size(self):
        self.rejected({**{n: "invalid_arguments" for n in ("raw_html", "approved_flag", "attachment", "control", "oversize")}, "duplicate_key": "duplicate_key"})

    def test_permission_lock_and_expiry(self):
        self.rejected({"permission_denied": "needs_permission", "permission_unknown": "needs_permission", "locked": "needs_unlock", "unknown_lock": "lock_state_unknown", "expired": "approval_expired", "monotonic_expired": "approval_expired"})

    def test_target_metadata(self):
        self.rejected({n: "target_changed" for n in ("shared_target", "renamed_target", "moved_target", "deleted_target")})

    def test_signature_and_exact_hash(self):
        self.rejected({"bad_signature": "permit_unverified", "tamper": "permit_binding_mismatch", "wrong_binding": "permit_binding_mismatch"})

    def test_cancellation_and_revocation(self):
        self.rejected({"cancel_before": "cancelled_before_effect", "cancel_during_metadata": "cancelled_before_effect", "revoke_during_metadata": "caller_unverified"})

    def test_final_readiness_admission(self):
        self.rejected({"cancel_during_readiness": "cancelled_before_effect", "revoke_during_readiness": "caller_unverified", "expire_during_readiness": "approval_expired",
                       "policy_during_readiness": "capability_not_granted", "budget_during_readiness": "capability_not_granted", "target_policy_during_readiness": "target_changed", "issuer_during_readiness": "permit_unverified"})

    def test_native_review_exact_fields_and_deadline(self):
        self.rejected({"native_cancel": "user_cancelled", "native_expiry": "approval_expired"})
        r = self.call("native_review")
        self.assertEqual((r["status"], r["create_calls"], r["native_confirmations"]), ("ok", 1, 1))
        self.assertIn("Synthetic Folder", r["review_text"])
        self.assertIn("Plain <script>", r["review_text"])

    def test_native_review_slow_and_cancel_signals(self):
        for scenario, code, polls in [("native_slow_review", "approval_expired", 20), ("native_cancel_review", "cancelled_before_effect", 2)]:
            with self.subTest(scenario=scenario):
                r = self.call(scenario)
                self.assertEqual((r["status"], r["create_calls"], r["native_confirmations"]), (code, 0, 1))
                self.assertEqual(r["review_deadline"], 20)
                self.assertEqual(r["review_remaining_seconds"], 20)
                self.assertEqual(r["review_polls"], polls)
                self.assertTrue(r["review_dismissed"])

    def test_native_review_not_shown_after_metadata_cancel_or_expiry(self):
        for scenario, code in [("native_cancel_before_review", "cancelled_before_effect"), ("native_expire_before_review", "approval_expired")]:
            r = self.call(scenario)
            self.assertEqual((r["status"], r["create_calls"], r["native_confirmations"]), (code, 0, 0))

    def test_native_review_gets_remaining_time_without_reset(self):
        r = self.call("native_remaining_review")
        self.assertEqual((r["status"], r["create_calls"]), ("ok", 1))
        self.assertEqual((r["review_deadline"], r["review_remaining_seconds"]), (20, 13))

    def test_durable_restart_no_replay(self):
        self.rejected({"replay_restart": "operation_consumed", "uncertain_restart": "operation_consumed", "budget": "effect_budget_exceeded"}, creates=1)
        self.rejected({"uncertain": "outcome_unknown"}, creates=1)

    def test_success_and_post_admission_cancel(self):
        for name in ("success", "late_cancel"):
            r = self.call(name)
            self.assertEqual((r["status"], r["create_calls"], r["persistence"], r["cloud_sync"]), ("ok", 1, "created_local", "not_checked"))
            self.assertNotIn("note_id", r)

    def test_native_event_descriptors_and_escaping(self):
        r = self.call("descriptors")
        self.assertEqual((r["status"], r["create_calls"], r["metadata_calls"]), ("ok", 0, 0))
        self.assertTrue(r["typed_descriptors"])
        self.assertIn("&lt;script&gt;&quot;&#39;&amp;<br>end tell<br>&#9;下一行", r["escaped_html"])
        self.assertNotIn("<script>", r["escaped_html"])
        self.rejected({"reply_error": "needs_permission"})

    def test_local_dictionary_matches_adapter(self):
        d = ET.parse("/System/Applications/Notes.app/Contents/Resources/Notes.sdef")
        for name, code in {"account": "acct", "folder": "cfol", "note": "note"}.items():
            self.assertEqual(d.find(f".//class[@name='{name}']").get("code"), code)
        self.assertEqual(d.find(".//class[@name='note']/property[@name='body']").get("code"), "body")
        self.assertEqual(d.find(".//class[@name='note']/property[@name='plaintext']").get("access"), "r")
        standard = ET.parse("/System/Library/ScriptingDefinitions/CocoaStandard.sdef")
        self.assertEqual(standard.find(".//command[@name='make']").get("code"), "corecrel")
        source = (ROOT / "integrations/apple_notes/NotesAutomation.swift").read_text()
        self.assertIn("kAEDoNotPromptForUserConsent", source)
        self.assertNotIn("NSAppleScript", source)
        self.assertNotIn("osascript", source)


if __name__ == "__main__":
    unittest.main()
