"""Native Button focus intent/notification/timeout, with no actual activation."""
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("xcrun"), "macOS Swift/AppKit required")
class NotesFocusTests(unittest.TestCase):
    def test_explicit_button_waits_for_current_focus_and_keeps_original_gates(self):
        with tempfile.TemporaryDirectory(prefix="arl-notes-focus-") as temporary:
            output = Path(temporary).resolve()
            sources = ["macOS/ARLControl/Models/NotesDirectModels.swift", "macOS/ARLControl/Services/NotesDirectFocus.swift", "tests/NotesFocusTests.swift"]
            build = subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-target", f"{platform.machine()}-apple-macos14.0", "-j", "1", "-parse-as-library", "-module-cache-path", str(output / "cache"), *[str(ROOT / source) for source in sources], "-o", str(output / "checks")], capture_output=True, text=True, timeout=90)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            result = subprocess.run([str(output / "checks")], capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("Notes focus/admission checks", result.stdout)
            self.assertIn("real app activation=0 Notes reads=0", result.stdout)


if __name__ == "__main__": unittest.main()
