import json
import os
import subprocess
import sys
import threading
import unittest

from arl.capabilities import AppleAdapter
from arl.client import Client
from arl.identity import RegisteredPeerVerifier, process_identity
from tests.test_runtime import RuntimeCase, running


@unittest.skipUnless(sys.platform == "darwin", "Real macOS peer identity test")
class IdentityTests(RuntimeCase):
    def test_registered_kernel_pid_can_read_mock_private_tool_spoof_rejected(self):
        verifier = RegisteredPeerVerifier({"tisra", "friday", "mio"})
        current = process_identity(os.getpid())
        verifier.register("tisra", os.getpid(), current["executable"])
        apple = AppleAdapter(lambda tool, args: {"status": "ok", "result": {"test_double": True}})
        with running(self.home, identity_verifier=verifier, apple=apple) as (_, client):
            job = client.submit("apple.reminders.list", {}, "verified")
            self.assertTrue(client.wait(job["id"])["result"]["test_double"])
            self.assert_fault("app_identity_unverified", lambda: Client(self.home, "friday").rpc("health"))
            # Another real process, same UID and same interpreter, cannot claim Tisra.
            program = "from arl.client import Client; from arl.contracts import Fault; import sys;\ntry: Client(sys.argv[1], 'tisra').rpc('health')\nexcept Fault as e: print(e.code)"
            result = subprocess.run([sys.executable, "-c", program, str(self.home)], capture_output=True, timeout=5)
            self.assertEqual(result.stdout.decode().strip(), "app_identity_unverified")
            verifier.revoke(os.getpid())
            self.assert_fault("app_identity_unverified", lambda: client.rpc("health"))

    def test_registry_rejects_wrong_executable_and_changed_birth(self):
        verifier = RegisteredPeerVerifier({"tisra"})
        current = process_identity(os.getpid())
        self.assert_fault("registration_identity_mismatch", lambda: verifier.register("tisra", os.getpid(), "/bin/sh"))
        verifier.register("tisra", os.getpid(), current["executable"])
        # Real kernel peer PID is still the same, but a reused/changed lifetime rejects.
        with running(self.home, identity_verifier=verifier) as (_, client):
            with verifier.lock:
                forged = dict(current); forged["birth"] = (0, 0)
                verifier.registry[os.getpid()] = ("tisra", forged)
            self.assert_fault("app_identity_unverified", lambda: client.rpc("health"))
            self.assertNotIn(os.getpid(), verifier.registry)
