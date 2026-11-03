"""Real signed socket frames with slow verification; no installed app or data."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('xcrun'), 'macOS Swift required')
class OwnerReadHandshakeTests(unittest.TestCase):
    def test_cold_verification_and_short_frame_budgets_share_one_deadline(self):
        sources = [
            'integrations/credential_read_owner/OwnerReadWire.swift',
            'integrations/credential_read_owner/OwnerReadAuthority.swift',
            'integrations/credential_read_owner/OwnerReadTransport.swift',
            'integrations/runtime_logging/ConnectionLog.swift',
            'tests/fixtures/OwnerReadHandshakeCatalogSupport.swift',
            'tests/OwnerReadHandshakeTests.swift',
        ]
        with tempfile.TemporaryDirectory(prefix='arl-owner-admission-') as temporary:
            output = Path(temporary).resolve()
            executable = output/'checks'
            build = subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-j', '1',
                '-parse-as-library', '-module-cache-path', str(output/'cache'),
                *[str(ROOT/p) for p in sources], '-o', str(executable)],
                capture_output=True, text=True, timeout=120)
            self.assertEqual(build.returncode, 0, build.stderr[-6000:])
            signed = subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', '--options', 'runtime', str(executable)],
                capture_output=True, text=True, timeout=20)
            self.assertEqual(signed.returncode, 0, signed.stderr[-2000:])
            result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr[-6000:])
            self.assertIn('PASS 8 real socket/signature owner admission checks', result.stdout)


if __name__ == '__main__':
    unittest.main()
