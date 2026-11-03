"""Run the real native receive owner against private synthetic SQLite fixtures."""
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("xcrun"), "macOS Swift/SQLite required")
class MessagesReceiveTests(unittest.TestCase):
    def test_native_scope_delivery_ack_and_cross_process_recovery(self):
        with tempfile.TemporaryDirectory(prefix="arl-msgreceive-") as temporary:
            output = Path(temporary).resolve()
            command = ["xcrun", "swiftc", "-swift-version", "6", "-target", "arm64-apple-macos14.0", "-j", "1", "-parse-as-library", "-module-cache-path", str(output / "cache"), str(ROOT / "macOS/ARLControl/Services/MessagesReceiveCore.swift"), str(ROOT / "tests/MessagesReceiveTests.swift"), "-lsqlite3", "-o", str(output / "checks")]
            compile_result = subprocess.run(command, capture_output=True, text=True, timeout=120)
            self.assertEqual(compile_result.returncode, 0, compile_result.stdout + compile_result.stderr)
            run = subprocess.run([str(output / "checks"), str(output / "fixture")], capture_output=True, text=True, timeout=45)
            metadata = []
            if run.returncode:
                for entry in sorted((output / "fixture").rglob("*")):
                    info = entry.lstat()
                    metadata.append((str(entry.relative_to(output)), oct(stat.S_IMODE(info.st_mode)), info.st_uid, info.st_nlink, info.st_size))
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr + repr(metadata))
            self.assertIn("three real child processes", run.stdout)
            self.assertIn("real Messages reads=0 sends=0", run.stdout)


if __name__ == "__main__":
    unittest.main()
