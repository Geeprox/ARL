import json
import sys
import tempfile
import unittest
import subprocess
import threading
import time
from pathlib import Path
from arl.client import Client
from arl.contracts import AppPolicy
from arl.identity import RegisteredPeerVerifier
from arl.research import ResearchEngine, ResearchGrant, NAME, METHODS, sha
from arl.service import Runtime
from tests.test_research import Adapter, MODEL, FINGERPRINT, response
from tests.test_runtime import RuntimeCase

@unittest.skipUnless(sys.platform == 'darwin', 'real macOS peer identity required')
class SwiftResearchTests(RuntimeCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix='arl-research-swift-')
        cls.addClassCleanup(cls.temporary.cleanup)
        home = Path(cls.temporary.name)
        root = Path(__file__).resolve().parents[1]
        cls.executable = home/'research-swift-smoke'
        built = subprocess.run(['xcrun','swiftc','-swift-version','6','-module-cache-path',str(home/'cache'),
            str(root/'examples/ARLClient.swift'),str(root/'integrations/tisra/ARLResearchClient.swift'),
            str(root/'integrations/tisra/ResearchSmoke.swift'),'-o',str(cls.executable)],capture_output=True,timeout=120)
        if built.returncode: raise RuntimeError(built.stderr.decode())

    def test_actual_swift_typed_consumer_registered_native_process(self):
        root=Path(__file__).resolve().parents[1]
        executable=self.executable
        verifier=RegisteredPeerVerifier({'tisra'})
        adapter=Adapter(lambda *_:response(1048576))
        engine=ResearchEngine({'tisra':ResearchGrant('responses_fixture',frozenset({MODEL}),'swift-test-epoch')},{'responses_fixture':adapter})
        policy=AppPolicy(frozenset({NAME}),methods=METHODS|{'health','ready'},max_pending=4)
        runtime=Runtime(self.home,policies={'tisra':policy},research=engine,identity_verifier=verifier)
        errors=[]
        def serve():
            try:runtime.run()
            except Exception as exc:errors.append(exc)
        thread=threading.Thread(target=serve);thread.start();process=None
        try:
            end=time.monotonic()+5
            while not runtime.ready.is_set() and not errors and time.monotonic()<end:time.sleep(.01)
            if errors:raise errors[0]
            self.assertTrue(runtime.ready.is_set())
            process=subprocess.Popen([str(executable)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
            self.assertEqual(process.stdout.readline(),b'prepared\n')
            verifier.register('tisra',process.pid,str(executable))
            out,err=process.communicate((str(self.home)+'\n').encode(),timeout=10)
            self.assertEqual(process.returncode,0,err.decode())
            summary=json.loads(out)
            self.assertEqual(summary,{'state':'succeeded','request_bytes':524288,'response_bytes':1048576,'response_sha256':sha(response(1048576))})
            self.assertEqual(len(adapter.calls),1)
            self.assertEqual(len(adapter.calls[0]),524288)
        finally:
            if process and process.poll() is None:process.kill();process.wait(timeout=2)
            runtime.shutdown();thread.join(10)
            if errors:raise errors[0]
