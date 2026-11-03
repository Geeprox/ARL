"""Compile actual once-only journals; no application launch or system permission."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]


@unittest.skipUnless(sys.platform=='darwin' and shutil.which('xcrun'),'macOS Swift required')
class JournalVolumeIdentityTests(unittest.TestCase):
    def test_persistent_volume_and_legacy_migration_fences(self):
        with tempfile.TemporaryDirectory(prefix='arl-volume-') as temp:
            output=Path(temp).resolve()
            sources=['macOS/ARLControl/Services/RemindersNativeSocket.swift',
                     'macOS/ARLControl/Services/AppleDirectJournal.swift',
                     'macOS/ARLControl/Services/MessagesDirectJournal.swift',
                     'tests/JournalVolumeIdentityTests.swift']
            build=subprocess.run(['xcrun','swiftc','-swift-version','6','-j','1','-parse-as-library',
                '-module-cache-path',str(output/'cache'),*[str(ROOT/p) for p in sources],'-o',str(output/'checks')],
                capture_output=True,text=True,timeout=120)
            self.assertEqual(build.returncode,0,build.stderr[-6000:])
            result=subprocess.run([str(output/'checks'),str(output/'fixture')],capture_output=True,text=True,timeout=30)
            self.assertEqual(result.returncode,0,result.stderr[-6000:])
            self.assertIn('persistent-volume journal checks',result.stdout)


if __name__=='__main__':
    unittest.main()
