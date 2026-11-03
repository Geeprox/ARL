"""Compile the real helper handler against a synthetic repository, without TCC."""
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class RemindersCatalogJournalTests(unittest.TestCase):
    @unittest.skipUnless(sys.platform == "darwin" and shutil.which("xcrun"), "macOS Swift toolchain required")
    def test_catalog_keeps_independent_metadata_without_repairing_journal(self):
        spec = importlib.util.spec_from_file_location("reminders_static", ROOT / "integrations/reminders_v3/build_static.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory(prefix="arl-remcat-") as temp:
            output = Path(temp).resolve()
            common = ["xcrun", "swiftc", "-swift-version", "6", "-target", "arm64-apple-macos14.0", "-j", "1", "-parse-as-library", "-module-cache-path", str(output / "cache")]
            core = [str(ROOT / p) for p in module.CORE]
            subprocess.run(common + ["-whole-module-optimization", "-emit-module", "-emit-object", "-module-name", "ARLRemindersCore", "-emit-module-path", str(output / "ARLRemindersCore.swiftmodule"), *core, "-o", str(output / "ARLRemindersCore.o")], check=True, capture_output=True, timeout=120)
            sources = ["macOS/ARLControl/Services/RemindersNativeSocket.swift", "macOS/ARLControl/Models/RemindersFirstSlice.swift", "macOS/ARLControl/Models/RemindersTask.swift", "macOS/ARLControl/Models/RemindersProductModels.swift", "integrations/reminders_v3/RemindersProductRequest.swift", "integrations/reminders_v3/RemindersProductHandler.swift", "integrations/reminders_v3/adapter_source/Fixtures/FixtureRepository.swift", "tests/RemindersCatalogJournalTests.swift"]
            subprocess.run(common + ["-I", str(output), *[str(ROOT / p) for p in sources], str(output / "ARLRemindersCore.o"), "-o", str(output / "checks")], check=True, capture_output=True, timeout=120)
            result = subprocess.run([str(output / "checks"), str(output / "fixture")], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("PASS 12 catalog/journal checks", result.stdout)

    def test_read_only_diagnostic_reports_binding_without_printing_anchor(self):
        spec = importlib.util.spec_from_file_location("diagnose_product_journal", ROOT / "integrations/reminders_v3/diagnose_product_journal.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory(prefix="arl-remdiag-") as temp:
            home = Path(temp).resolve()
            root = home / "product-v1"
            tasks = root / "tasks"
            tasks.mkdir(parents=True, mode=0o700)
            root.chmod(0o700)
            r, t = root.stat(), tasks.stat()
            anchor = home / "product-v1.anchor"
            raw = "v1\n%d\n%d\n%d\n%d\n" % (r.st_dev, r.st_ino, t.st_dev, t.st_ino)
            anchor.write_text(raw)
            anchor.chmod(0o600)
            before = anchor.read_bytes()
            report = module.inspect(str(home))
            self.assertEqual(report["binding"], "matches")
            self.assertEqual(report["records_read"], 0)
            self.assertNotIn("anchor_contents", report)
            tasks.rename(home / "preserved")
            tasks.mkdir(mode=0o700)
            self.assertEqual(module.inspect(str(home))["binding"], "identity_mismatch")
            self.assertEqual(anchor.read_bytes(), before)
            self.assertTrue((home / "preserved").is_dir())


if __name__ == "__main__":
    unittest.main()
