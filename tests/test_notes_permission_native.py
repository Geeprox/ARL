"""Recovered Notes permission state-machine fixture; injected surfaces only.

Compile current main sources directly. Never run the retired candidate builder,
query TCC, send Notes events, create grants, or alter the existing identity pins.
"""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(sys.platform == "darwin", "macOS Swift/ApplicationServices fixture")
class NotesPermissionNativeTests(unittest.TestCase):
    def test_permission_states_one_attempt_and_expiry_without_native_effects(self):
        source = ROOT / "integrations/notes_permission_v2/source"
        sources = [ROOT / "integrations/apple_review/Proposal.swift"]
        sources += [source / "native" / name for name in ("NotesEvents.swift", "NotesFirstUse.swift")]
        sources += [source / "host" / name for name in ("NotesPermissionLease.swift", "NotesPermissionRequest.swift")]
        sources += [ROOT / "tests/NotesPermissionNativeFixture.swift"]
        with tempfile.TemporaryDirectory(prefix="arl-notes-permission-fixture-") as temporary:
            output = Path(temporary)
            args = ["xcrun", "swiftc", "-swift-version", "6", "-j", "1", "-parse-as-library",
                    "-module-cache-path", str(output / "ModuleCache"), *map(str, sources),
                    "-framework", "ApplicationServices", "-framework", "Security", "-o", str(output / "fixture")]
            compiled = subprocess.run(args, capture_output=True, text=True, timeout=120)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            result = subprocess.run([str(output / "fixture")], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(),
                "notes_permission_native_checks=15; real_permission_queries=0; real_notes_events=0; "
                "grants_created=0; synthetic_surfaces_only=true")


if __name__ == "__main__":
    unittest.main()
