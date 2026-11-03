"""Actual Swift settings persistence and Python consumer compatibility, all synthetic."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from arl.codex_packages import PackageRegistry, validate_packages
ROOT=Path(__file__).resolve().parents[1]
@unittest.skipUnless(sys.platform=='darwin' and shutil.which('xcrun'),'macOS Swift required')
class CodexPackageSettingsTests(unittest.TestCase):
    def test_native_editor_round_trip_and_revision_guards(self):
        with tempfile.TemporaryDirectory(prefix='arl-package-settings-') as directory:
            output=Path(directory).resolve();binary=output/'checks';home=output/'settings'
            sources=['macOS/ARLControl/Models/CodexExecutionOptions.swift','macOS/ARLControl/Models/CodexPackageConfiguration.swift','macOS/ARLControl/Services/RemindersNativeSocket.swift','macOS/ARLControl/Services/CodexPackageSettingsStore.swift','tests/CodexPackageSettingsTests.swift']
            built=subprocess.run(['xcrun','swiftc','-swift-version','6','-j','1','-parse-as-library','-module-cache-path',str(output/'cache'),*[str(ROOT/s) for s in sources],'-o',str(binary)],capture_output=True,text=True,timeout=90)
            self.assertEqual(built.returncode,0,built.stdout+built.stderr)
            result=subprocess.run([str(binary),str(home)],capture_output=True,text=True,timeout=15)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            self.assertIn('PASS package settings',result.stdout)
            config=PackageRegistry(home).load();catalog=json.loads((home/'catalog-v2.json').read_text())
            validate_packages(config['packages'],catalog['models'])
            self.assertEqual(config['packages']['medium']['model'],'synthetic-b')
            self.assertEqual(config['packages']['medium']['reasoning_effort'],'low')
            self.assertEqual(config['packages']['high']['display_name'],'第一处修改')
if __name__=='__main__':unittest.main()
