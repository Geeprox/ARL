import json
import os
import subprocess
import unittest
from pathlib import Path

from arl.apple import EventKitTransport
from arl.identity import RegisteredPeerVerifier, process_identity
from tests.test_runtime import running

ROOT = Path(__file__).resolve().parents[1]


class NativeTests(unittest.TestCase):
    @unittest.skipUnless((ROOT/"build/EventKitHelper").exists(), "Run build_and_run.sh to compile native helper")
    def test_authorization_query_does_not_prompt_or_read_private_data(self):
        reply = EventKitTransport(ROOT/"build/EventKitHelper")("apple.authorization", {})
        self.assertEqual(reply["status"], "ok")
        self.assertFalse(reply["result"]["prompts_requested"])
        self.assertEqual(set(reply["result"]), {"calendar", "reminders", "prompts_requested"})

    @unittest.skipUnless((ROOT/"build/SwiftSmoke").exists(), "Run build_and_run.sh to compile Swift client")
    def test_swift6_client_real_rpc(self):
        import tempfile
        with tempfile.TemporaryDirectory(prefix="arl-swift-") as home:
            with running(home):
                result = subprocess.run([str(ROOT/"build/SwiftSmoke"), home], capture_output=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr.decode())
                self.assertIn("passed", result.stdout.decode())

    @unittest.skipUnless((ROOT/"build/SwiftSmoke").exists(), "Run build_and_run.sh to compile Swift client")
    def test_supervisor_registers_real_swift_client_without_credentials(self):
        import tempfile
        with tempfile.TemporaryDirectory(prefix="arl-peer-swift-") as home:
            verifier = RegisteredPeerVerifier({"tisra", "friday", "mio"})
            verifier.register("tisra", os.getpid(), process_identity(os.getpid())["executable"])
            with running(home, identity_verifier=verifier):
                binary = ROOT/"build/SwiftSmoke"
                process = subprocess.Popen([str(binary), home, "--await-host"], stdin=subprocess.PIPE,
                                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                try:
                    self.assertEqual(process.stdout.readline().strip(), "prepared")
                    verifier.register("tisra", process.pid, binary)
                    stdout, stderr = process.communicate("go\n", timeout=10)
                    self.assertEqual(process.returncode, 0, stderr)
                    self.assertIn("passed", stdout)
                finally:
                    verifier.revoke(process.pid)
                    if process.poll() is None:
                        process.kill(); process.wait()
