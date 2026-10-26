import json
import os
import plistlib
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

from arl.client import Client
from arl.contracts import Fault, Tool, AppPolicy, object_schema
from arl.host import MetadataLog, PeerComposition, make_runtime
from arl.storage import Store
from deployment.manage import Manager, DeploymentError, verify
from deployment.package import package

ROOT = Path(__file__).resolve().parents[1]

FAKE = '''#!/usr/bin/python3
import json,sys
from pathlib import Path
root=Path(__file__).parent
with (root/'calls.jsonl').open('a') as log: log.write(json.dumps(sys.argv[1:])+'\\n')
loaded=root/'loaded'
command=sys.argv[1]
if command=='print': sys.exit(0 if loaded.exists() else 3)
if command=='bootout': loaded.unlink(missing_ok=True); sys.exit(0)
if command=='bootstrap':
    marker=root/'fail-next-bootstrap'
    if marker.exists(): marker.unlink(); sys.exit(1)
    loaded.write_text('yes'); sys.exit(0)
sys.exit(2)
'''


class DeploymentTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='arl-d-', dir='/tmp')
        self.root = Path(self.temp.name)
        (self.root/'.arl-deployment-test').write_text('isolated')
        self.fake = self.root/'fake-launchctl'; self.fake.write_text(FAKE); self.fake.chmod(0o700)
        self.manager = Manager(test_root=self.root, fake_launchctl=self.fake)
        self.ui = self.root/'fixture.app'; (self.ui/'Contents/MacOS').mkdir(parents=True)
        (self.ui/'Contents/MacOS/ARLControl').write_bytes(b'fixture-ui-not-executed')
        (self.ui/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'local.arl.control','CFBundleExecutable':'ARLControl'}))
        self.one = self.root/'one'; self.m1 = package(self.one, self.ui)
    def tearDown(self): self.temp.cleanup()
    def second(self):
        (self.ui/'Contents/MacOS/ARLControl').write_bytes(b'fixture-ui-v2-not-executed')
        target=self.root/'two'; return target,package(target,self.ui)
    def install(self): return self.manager.deploy(self.one, self.m1['release'])
    def calls(self):
        p=self.root/'calls.jsonl'
        return [json.loads(v) for v in p.read_text().splitlines()] if p.exists() else []
    def test_plan_does_not_create_installation_or_call_launchctl(self):
        plan = self.manager.plan('install',self.m1['release'])
        self.assertEqual(plan['profile'],'metadata-only')
        self.assertFalse(self.manager.home.exists()); self.assertEqual(self.calls(),[])
        result=subprocess.run([sys.executable,'deployment/manage.py','install','--package',str(self.one),
            '--test-root',str(self.root),'--fake-launchctl',str(self.fake)],cwd=ROOT,capture_output=True)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertFalse(self.manager.home.exists()); self.assertEqual(self.calls(),[])
    def test_install_update_rollback_preserve_state_and_exact_launch_scope(self):
        self.install()
        state=self.manager.home/'state.sqlite'; store=Store(state); store.close()
        before=state.read_bytes()
        second,m2=self.second(); self.manager.deploy(second,m2['release'],update=True)
        self.assertEqual(self.manager.installation()['previous'],self.m1['release'])
        self.manager.rollback(self.m1['release'])
        self.assertEqual(state.read_bytes(),before)
        self.assertEqual((self.manager.ui/'Contents/MacOS/ARLControl').read_bytes(),b'fixture-ui-not-executed')
        plist=plistlib.loads(self.manager.plist.read_bytes())
        self.assertEqual(plist['KeepAlive'],{'SuccessfulExit':False}); self.assertEqual(plist['ThrottleInterval'],30)
        self.assertEqual(plist['StandardErrorPath'],'/dev/null')
        self.assertEqual(plist['ProgramArguments'],['/usr/bin/python3','-I',str(self.manager.runtime/'run_host.py'),'--isolated-test'])
        for call in self.calls():
            self.assertIn(call[0],{'print','bootout','bootstrap'})
            self.assertEqual(call[1],self.manager.domain if call[0]=='bootstrap' else self.manager.target)
    def test_failed_update_bootstrap_restores_previous_release_and_ui(self):
        self.install(); old=self.manager.installation()
        second,m2=self.second(); (self.root/'fail-next-bootstrap').write_text('fail')
        with self.assertRaises(DeploymentError): self.manager.deploy(second,m2['release'],update=True)
        self.assertEqual(self.manager.installation(),old)
        self.assertEqual(json.loads((self.manager.runtime/'active.json').read_text()),{'release':self.m1['release']})
        self.assertEqual((self.manager.ui/'Contents/MacOS/ARLControl').read_bytes(),b'fixture-ui-not-executed')
        self.assertTrue((self.root/'loaded').exists())
    def test_disable_update_rollback_never_silently_enable(self):
        self.install(); self.manager.disable()
        count=sum(c[0]=='bootstrap' for c in self.calls())
        second,m2=self.second(); self.manager.deploy(second,m2['release'],update=True)
        self.manager.rollback(self.m1['release'])
        self.assertEqual(sum(c[0]=='bootstrap' for c in self.calls()),count)
        self.assertTrue((self.manager.home/'disabled').exists())
        self.manager.enable(); self.assertFalse((self.manager.home/'disabled').exists())
        self.assertTrue((self.root/'loaded').exists())
        self.manager.disable(); (self.root/'fail-next-bootstrap').write_text('fail')
        with self.assertRaises(DeploymentError): self.manager.enable()
        self.assertTrue((self.manager.home/'disabled').exists())
    def test_uninstall_preserves_database_log_disabled_and_preferences(self):
        self.install(); self.manager.home.joinpath('state.sqlite').write_bytes(b'synthetic-state')
        self.manager.home.joinpath('host.log').write_text('synthetic-metadata')
        preferences=self.manager.account/'Library/Preferences/local.arl.control.plist'
        preferences.parent.mkdir(); preferences.write_bytes(b'local-ui-preferences')
        self.manager.uninstall()
        self.assertFalse(self.manager.ui.exists()); self.assertFalse(self.manager.plist.exists()); self.assertFalse(self.manager.runtime.exists())
        self.assertEqual((self.manager.home/'state.sqlite').read_bytes(),b'synthetic-state')
        self.assertTrue((self.manager.home/'disabled').exists()); self.assertTrue(preferences.exists())
    def test_unapproved_tampered_symlink_and_unmanaged_targets_rejected(self):
        with self.assertRaises(DeploymentError): verify(self.one,'0.1.2-'+'0'*16)
        (self.one/'code/arl/host.py').write_text('unreviewed')
        with self.assertRaises(DeploymentError): self.install()
        three=self.root/'three'; m3=package(three,self.ui)
        (three/'code/arl/host.py').unlink(); (three/'code/arl/host.py').symlink_to(ROOT/'arl/host.py')
        with self.assertRaises(DeploymentError): verify(three,m3['release'])
        self.manager.ui.parent.mkdir(parents=True); self.manager.ui.mkdir()
        four=self.root/'four'; m4=package(four,self.ui)
        with self.assertRaises(DeploymentError): self.manager.deploy(four,m4['release'])
        self.assertTrue(all(c[0]=='print' for c in self.calls()))
    def test_future_store_and_changed_launcher_refuse_without_bootout(self):
        self.install(); self.calls()
        p=self.manager.home/'state.sqlite'; import sqlite3
        db=sqlite3.connect(str(p)); db.execute('PRAGMA user_version=5'); db.close()
        second,m2=self.second(); count=len(self.calls())
        with self.assertRaises(DeploymentError): self.manager.deploy(second,m2['release'],update=True)
        self.assertEqual(len(self.calls()),count)
        db=sqlite3.connect(str(p)); db.execute('PRAGMA user_version=4'); db.close()
        self.manager.runtime.joinpath('run_host.py').write_text('unreviewed')
        with self.assertRaises(DeploymentError): self.manager.deploy(second,m2['release'],update=True)
        self.assertEqual(len(self.calls()),count)
    def test_ready_check_has_overall_deadline(self):
        self.manager.home.mkdir(parents=True,mode=0o700)
        started=time.monotonic()
        with self.assertRaises(DeploymentError): self.manager.await_ready(timeout=.15)
        self.assertLess(time.monotonic()-started,.5)
    def test_launch_template_cannot_expand_the_approved_profile(self):
        template=self.one/'local.arl.runtime.plist'
        value=plistlib.loads(template.read_bytes()); value['WatchPaths']=['/private/sensitive']
        template.write_bytes(plistlib.dumps(value))
        manifest=json.loads((self.one/'manifest.json').read_text())
        import hashlib
        manifest['files']['local.arl.runtime.plist']=hashlib.sha256(template.read_bytes()).hexdigest()
        aggregate=hashlib.sha256(json.dumps(manifest['files'],sort_keys=True,separators=(',',':')).encode()).hexdigest()
        manifest['release']='0.1.2-'+aggregate[:16]
        (self.one/'manifest.json').write_text(json.dumps(manifest))
        with self.assertRaises(DeploymentError): self.manager.deploy(self.one,manifest['release'])
        self.assertEqual(self.calls(),[]); self.assertFalse(self.manager.home.exists())
    def test_test_mode_cannot_fall_back_to_real_launchctl(self):
        with self.assertRaises(DeploymentError): Manager(test_root=self.root)
        with self.assertRaises(DeploymentError): Manager(test_root=self.root,fake_launchctl='/bin/launchctl')
    def test_installed_fixed_entry_real_process_metadata_and_sanitized_logs(self):
        self.install()
        # Launch only the exact test-installed host; fake launchctl never runs it.
        process=subprocess.Popen([sys.executable,'-I',str(self.manager.runtime/'run_host.py'),'--isolated-test'],
            stdout=subprocess.PIPE,stderr=subprocess.PIPE,env={**os.environ,'OPENAI_API_KEY':'synthetic-secret-never-log'})
        client=Client(self.manager.home,'settings')
        try:
            self.assertTrue(client.connect(timeout=5)['ready'])
            self.manager.await_ready(timeout=1)
            result=client.rpc('overview'); self.assertFalse(result['policy']['local_inference_enabled'])
            self.assertEqual({b['app']:b['max_calls'] for b in result['budgets']},{'settings':0,'tisra':0,'friday':0,'mio':0})
            with self.assertRaises(Fault): Client(self.manager.home,'tisra').submit('runtime.ping',{},'forged')
            with self.assertRaises(Fault): client.rpc('stop')
            self.manager.disable(); stdout,stderr=process.communicate(timeout=5)
            self.assertEqual(process.returncode,0); self.assertEqual(stdout,b''); self.assertEqual(stderr,b'')
            self.assertNotIn('synthetic-secret',(self.manager.home/'host.log').read_text())
            # Verify code discovery did not create immutable-release __pycache__.
            verify(self.manager.runtime/'releases'/self.m1['release'],self.m1['release'])
        finally:
            if process.poll() is None: process.terminate()
            process.communicate(timeout=5)


class HostTests(unittest.TestCase):
    def test_keepalive_successful_exit_false_stops_and_explicit_enable_recovers(self):
        with tempfile.TemporaryDirectory(prefix='arl-h-',dir='/tmp') as directory:
            home=Path(directory); command=[sys.executable,'-m','arl.host','--isolated-test','--home',str(home)]
            attempts=[]; exits=[]; done=threading.Event()
            def launchd_model():
                for _ in range(3):
                    process=subprocess.Popen(command,cwd=ROOT,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,
                        env={**os.environ,'PYTHONDONTWRITEBYTECODE':'1'})
                    attempts.append(process); code=process.wait(); exits.append(code)
                    if code == 0: break
                done.set()
            thread=threading.Thread(target=launchd_model); thread.start()
            client=Client(home,'settings')
            try:
                client.connect(timeout=5)
                # Unexpected SIGKILL is non-success and therefore gets one restart.
                attempts[0].kill()
                deadline=time.monotonic()+5
                while len(attempts)<2 and time.monotonic()<deadline: time.sleep(.01)
                client.connect(timeout=5)
                (home/'disabled').write_bytes(b''); (home/'disabled').chmod(0o600)
                self.assertTrue(done.wait(5)); thread.join(5)
                self.assertEqual(len(attempts),2); self.assertEqual(exits[-1],0)
                # Next-login launch of a persistently disabled job is also success.
                disabled=subprocess.run(command,cwd=ROOT,capture_output=True,timeout=5)
                self.assertEqual(disabled.returncode,0); self.assertEqual(disabled.stderr,b'')
                cli=subprocess.run([sys.executable,'-m','arl','serve','--home',str(home)],cwd=ROOT,capture_output=True,timeout=5)
                self.assertEqual(cli.returncode,0)
                (home/'disabled').unlink() # Explicit isolated admin enable.
                recovered=subprocess.Popen(command,cwd=ROOT,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
                attempts.append(recovered); self.assertTrue(client.connect(timeout=5)['ready'])
                recovered.terminate(); recovered.wait(5)
            finally:
                for process in attempts:
                    if process.poll() is None: process.terminate(); process.wait(5)
                thread.join(5)
    def test_metadata_host_does_not_claim_or_replay_historical_jobs(self):
        with tempfile.TemporaryDirectory(prefix='arl-q-',dir='/tmp') as directory:
            home=Path(directory); store=Store(home/'state.sqlite')
            tool=Tool('runtime.ping',object_schema(),lambda a,c: {'pong':True})
            job=store.submit('tisra','history',tool,{},AppPolicy(frozenset({tool.name})))
            store.close(); runtime=make_runtime(home); thread=threading.Thread(target=runtime.run); thread.start()
            try:
                self.assertTrue(runtime.ready.wait(5))
                self.assertEqual(runtime.store.get('tisra',job['id'])['state'],'queued')
                self.assertEqual(runtime.store.get('tisra',job['id'])['attempts'],0)
                self.assertIsNone(runtime.worker)
            finally: runtime.shutdown(); thread.join(5)
    def test_peer_composition_not_identity_grant_and_log_is_bounded(self):
        composition=PeerComposition([lambda c,a:'wrong',lambda c,a:a])
        self.assertEqual(composition(None,'tisra'),'tisra'); self.assertIsNone(composition(None,'settings'))
        self.assertIsNone(PeerComposition()(None,'tisra'))
        with tempfile.TemporaryDirectory(prefix='arl-l-',dir='/tmp') as directory:
            log=MetadataLog(Path(directory))
            for _ in range(1500): log.event('error','host_startup_failed')
            self.assertLessEqual(log.path.stat().st_size,65536)
            self.assertEqual(log.path.stat().st_mode & 0o777,0o600)
            with self.assertRaises(ValueError): log.event('synthetic-secret')


if __name__=='__main__': unittest.main()
