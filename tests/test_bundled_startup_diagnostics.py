"""Fixed startup diagnostics only; no actual account home or core launch."""
import errno,importlib.util,json,tempfile,unittest
from pathlib import Path
from unittest.mock import patch
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('bundled_entry',ROOT/'script/bundled_runtime_entry.py');entry=importlib.util.module_from_spec(spec);spec.loader.exec_module(entry)
class StartupDiagnosticsTests(unittest.TestCase):
    def test_private_failure_receipt_has_no_exception_text(self):
        with tempfile.TemporaryDirectory() as folder:
            home=Path(folder).resolve();home.chmod(0o700)
            with patch.object(entry.sys,'argv',['entry','--isolated-test','--home',str(home)]):entry.startup_failure(OSError(errno.EACCES,'private token path'),'import_runtime')
            path=home/'runtime-startup-failure.json';data=json.loads(path.read_text())
            self.assertEqual(data['phase'],'import_runtime');self.assertEqual(data['errno'],errno.EACCES)
            self.assertEqual(path.stat().st_mode&0o777,0o600);self.assertNotIn('private token',path.read_text())
            self.assertEqual(set(data),{'schema_version','phase','code','type','pid','parent_pid','at','errno'})
    def test_unsafe_test_home_cannot_receive_failure_receipt(self):
        with tempfile.TemporaryDirectory() as folder:
            home=Path(folder).resolve();home.chmod(0o755)
            with patch.object(entry.sys,'argv',['entry','--isolated-test','--home',str(home)]):entry.startup_failure(ValueError('private token'),'verify_package')
            self.assertFalse((home/'runtime-startup-failure.json').exists())
