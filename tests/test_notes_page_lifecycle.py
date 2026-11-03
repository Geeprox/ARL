"""A late old SwiftUI view cannot revoke the new Notes page's action lease."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]


@unittest.skipUnless(sys.platform=='darwin' and shutil.which('xcrun'),'macOS Swift required')
class NotesPageLifecycleTests(unittest.TestCase):
    def test_late_disappearance_keeps_only_the_current_appearance(self):
        with tempfile.TemporaryDirectory(prefix='arl-notes-page-') as temp:
            output=Path(temp).resolve()
            build=subprocess.run(['xcrun','swiftc','-swift-version','6','-j','1','-parse-as-library',
                '-module-cache-path',str(output/'cache'),str(ROOT/'macOS/ARLControl/Models/NotesDirectModels.swift'),
                str(ROOT/'tests/NotesPageLifecycleTests.swift'),'-o',str(output/'checks')],
                capture_output=True,text=True,timeout=60)
            self.assertEqual(build.returncode,0,build.stderr[-6000:])
            result=subprocess.run([str(output/'checks')],capture_output=True,text=True,timeout=10)
            self.assertEqual(result.returncode,0,result.stderr[-6000:])
            self.assertIn('PASS 6 Notes appearance-lease checks',result.stdout)


if __name__=='__main__':unittest.main()
