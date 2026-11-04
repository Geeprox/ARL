"""Real signed socket frames with slow verification; no installed app or data."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import os
import signal
import socket
import time
from script.local_build_area import build_area

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
        with build_area('owner-admission',toolchain='swift6-macos',reproduce=['python3','-B','-m','unittest','tests.test_owner_read_handshake']) as temporary:
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

    def test_killed_listener_recovers_while_live_owners_and_foreign_files_are_preserved(self):
        with build_area('owner-socket-recovery',toolchain='swift6-macos',reproduce=['python3','-B','-m','unittest','tests.test_owner_read_handshake']) as output:
            binary=output/'checks'
            sources=['integrations/credential_read_owner/OwnerReadWire.swift',
                'integrations/credential_read_owner/OwnerReadAuthority.swift',
                'integrations/credential_read_owner/OwnerReadTransport.swift',
                'integrations/runtime_logging/ConnectionLog.swift',
                'tests/fixtures/OwnerReadHandshakeCatalogSupport.swift',
                'macOS/ARLControl/Services/OwnerReadLifecycle.swift','tests/OwnerSocketRecoveryTests.swift']
            built=subprocess.run(['xcrun','swiftc','-swift-version','6','-j','1','-D','ARL_OWNER_FIXTURE',
                '-parse-as-library','-module-cache-path',str(output/'cache'),*[str(ROOT/p) for p in sources],'-o',str(binary)],capture_output=True,text=True,timeout=120)
            self.assertEqual(built.returncode,0,built.stdout+built.stderr)
            # Only short socket endpoints use /tmp: Darwin sockaddr_un is bounded.
            with tempfile.TemporaryDirectory(prefix='arl-r5-',dir='/private/tmp') as directory:
                root=Path(directory);endpoint=root/'read.sock'
                def run(mode):
                    result=subprocess.run([str(binary),mode,str(root)],capture_output=True,text=True,timeout=10)
                    self.assertEqual(result.returncode,0,result.stdout+result.stderr)
                child=subprocess.Popen([str(binary),'hold',str(root)],stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
                try:
                    deadline=time.monotonic()+10
                    while not (root/'ready').exists() and child.poll() is None and time.monotonic()<deadline:time.sleep(.02)
                    self.assertTrue((root/'ready').exists())
                    inode=endpoint.stat().st_ino;run('expect-busy');self.assertEqual(endpoint.stat().st_ino,inode)
                    child.send_signal(signal.SIGKILL);child.wait(timeout=5)
                    run('recover');self.assertFalse(endpoint.exists())
                finally:
                    if child.poll() is None:child.terminate();child.wait(timeout=5)
                    child.stderr.close()
                listener=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM)
                try:
                    listener.bind(str(endpoint));os.chmod(endpoint,0o600);listener.listen(1)
                    inode=endpoint.stat().st_ino;run('expect-busy');self.assertEqual(endpoint.stat().st_ino,inode)
                finally:listener.close();endpoint.unlink()
                endpoint.write_text('unrelated fixture');run('expect-busy')
                self.assertEqual(endpoint.read_text(),'unrelated fixture')


if __name__ == '__main__':
    unittest.main()
