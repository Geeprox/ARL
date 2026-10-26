import hashlib
import json
import os
import re
import subprocess
import struct
import sys
import tempfile
import threading
import unittest
from pathlib import Path

from arl.client import Client
from arl.contracts import Fault
from arl.identity import RegisteredPeerVerifier, process_identity
from arl.service import Runtime
from arl.supervisor import ControlledSupervisor, LaunchSpec, SignedPeerVerifier, pin_sources

ROOT = Path(__file__).resolve().parents[1]
FRIDAY = Path(os.environ.get("ARL_FRIDAY_SOURCE", str(ROOT/"build/optional-friday-source")))


class IntegrationTests(unittest.TestCase):
    def run_apps(self, home, specs, signed=None):
        registry = RegisteredPeerVerifier({"tisra", "friday", "mio"})
        registry.register("tisra", os.getpid(), process_identity(os.getpid())["executable"])
        supervisor = ControlledSupervisor(specs, registry)
        def verify(connection, app):
            # Parent only controls this isolated test; real deployment does not
            # register an arbitrary pre-existing Python caller.
            if struct.unpack("i", connection.getsockopt(0, 2, 4))[0] == os.getpid():
                return registry(connection, app)
            return (signed(connection, app) if signed else None) or supervisor.peer_verifier(connection, app)
        runtime = Runtime(home, identity_verifier=verify)
        errors = []
        def run():
            try: runtime.run()
            except Exception as exc: errors.append(exc)
        thread = threading.Thread(target=run); thread.start()
        self.assertTrue(runtime.ready.wait(5))
        try:
            results = []
            for spec in specs:
                child = supervisor.launch(spec.app)
                output, _ = child.communicate(timeout=10)
                self.assertEqual(child.returncode, 0, output)
                results.append(json.loads(output.strip()))
            return results
        finally:
            supervisor.close(); runtime.shutdown(); thread.join(5)
            self.assertFalse(thread.is_alive())
            self.assertEqual(errors, [])

    @unittest.skipUnless((ROOT/"build/TisraIntegrationSmoke").exists(), "Build Swift integration first")
    def test_tisra_opt_in_native_action_module(self):
        with tempfile.TemporaryDirectory(prefix="arl-tisra-app-") as home:
            binary = ROOT/"build/TisraIntegrationSmoke"
            spec = LaunchSpec("tisra", binary, (home,), ROOT, pin_sources([
                binary, ROOT/"examples/ARLClient.swift", ROOT/"integrations/tisra/TisraRuntime.swift"]))
            result = self.run_apps(home, [spec])[0]
            self.assertTrue(result["native_swift6"])
            self.assertTrue(result["opt_in_default_disabled"])
            self.assertTrue(result["deduplicated"])

    @unittest.skipUnless((FRIDAY/"homeplane/arl.py").exists(), "Actual Friday adapter is unavailable")
    def test_current_friday_adapter_uses_shared_sdk_under_supervisor(self):
        with tempfile.TemporaryDirectory(prefix="arl-friday-app-") as home:
            script = ROOT/"integrations/friday/smoke.py"
            interpreter = FRIDAY/".venv/bin/python"
            spec = LaunchSpec("friday", interpreter, (str(script), home), ROOT,
                pin_sources([script, FRIDAY/"homeplane/arl.py", FRIDAY/"homeplane/__init__.py"]),
                python_paths=(ROOT, FRIDAY))
            result = self.run_apps(home, [spec])[0]
            self.assertTrue(result["existing_adapter"])
            self.assertTrue(result["deduplicated"])
            self.assertFalse(result["device_actions"])

    def test_fixed_launch_manifest_rejects_source_drift(self):
        with tempfile.TemporaryDirectory(prefix="arl-launch-pin-") as directory:
            source = Path(directory)/"entry.py"; source.write_text("print('prepared',flush=True)")
            spec = LaunchSpec("friday", Path(sys.executable), (str(source),), Path(directory), pin_sources([source]))
            host = ControlledSupervisor([spec], RegisteredPeerVerifier({"friday"}))
            source.write_text("print('unreviewed code')")
            with self.assertRaises(Fault) as fault:
                host.launch("friday")
            self.assertEqual(fault.exception.code, "launch_source_changed")
            self.assertEqual(host.children, {})

    @unittest.skipUnless((ROOT/"build/PeerSignatureHelper").exists(), "Build Security helper first")
    def test_native_audit_token_signature_check_accepts_only_pinned_cdhash(self):
        binary = ROOT/"build/TisraIntegrationSmoke"
        metadata = subprocess.run(["/usr/bin/codesign", "-d", "--verbose=4", str(binary)], capture_output=True)
        match = re.search(r"^CDHash=([0-9a-f]+)$", metadata.stderr.decode(), re.MULTILINE)
        self.assertIsNotNone(match)
        signed = SignedPeerVerifier(ROOT/"build/PeerSignatureHelper", {"tisra": 'cdhash H"'+match[1]+'"'})
        with tempfile.TemporaryDirectory(prefix="arl-signed-peer-") as home:
            # Deliberately don't register Swift PID: real Security guest identity
            # from LOCAL_PEERTOKEN must authorize it, while Python cannot spoof it.
            registry = RegisteredPeerVerifier({"tisra"})
            registry.register("tisra", os.getpid(), process_identity(os.getpid())["executable"])
            def verify(connection, app): return registry(connection, app) or signed(connection, app)
            runtime = Runtime(home, identity_verifier=verify)
            thread = threading.Thread(target=runtime.run); thread.start(); self.assertTrue(runtime.ready.wait(5))
            process = subprocess.Popen([str(binary), home], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE, text=True)
            try:
                self.assertEqual(process.stdout.readline().strip(), "prepared")
                output, stderr = process.communicate("go\n", timeout=10)
                self.assertEqual(process.returncode, 0, stderr)
                self.assertTrue(json.loads(output)["deduplicated"])
                # A separately running Python interpreter declares the same app but fails signing.
                program = "from arl.client import Client; from arl.contracts import Fault; import sys;\ntry: Client(sys.argv[1],'tisra').rpc('health')\nexcept Fault as e: print(e.code)"
                spoof = subprocess.run([sys.executable, "-c", program, home], capture_output=True, timeout=5)
                self.assertEqual(spoof.stdout.decode().strip(), "app_identity_unverified")
            finally:
                if process.poll() is None: process.kill(); process.wait()
                runtime.shutdown(); thread.join(5)
                self.assertFalse(thread.is_alive())

    @unittest.skipUnless((ROOT/"build/PeerSignatureHelper").exists(), "Build Security helper first")
    def test_identifier_only_native_policy_is_rejected(self):
        with self.assertRaises(Fault) as fault:
            SignedPeerVerifier(ROOT/"build/PeerSignatureHelper", {"tisra": 'identifier "app.tisra.dev"'})
        self.assertEqual(fault.exception.code, "signature_policy_unpinned")
