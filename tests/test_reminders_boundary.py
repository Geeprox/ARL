"""Native boundary and real SDK/peer tests; compile-time store double, no TCC."""
import hashlib,json,os,re,shutil,subprocess,tempfile,time,unittest
from pathlib import Path
from integrations.apple_reminders.launcher_source import render

ROOT=Path(__file__).resolve().parents[1];SOURCE=ROOT/'integrations/apple_reminders'
PROPOSAL=json.loads((SOURCE/'approval-proposal.json').read_text())['args']
BINARY=SOURCE/'dist/ARLRemindersBridge.app/Contents/MacOS/ARLRemindersBridge'

class RemindersBoundaryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture=SOURCE/'dist/build/RemindersBoundaryFixture'
        sources=[SOURCE/'dist/build/main.swift',SOURCE/'ConfirmationWindow.swift',SOURCE/'ReminderStore.swift',SOURCE/'NativeEffectBoundary.swift',SOURCE/'RemindersSeal.swift',SOURCE/'ReviewClient.swift',ROOT/'examples/ARLClient.swift']
        subprocess.run(['/usr/bin/xcrun','swiftc','-D','REMINDERS_EFFECT_FIXTURE','-swift-version','6','-module-cache-path',str(SOURCE/'dist/module-cache'),*[str(p) for p in sources],'-framework','EventKit','-framework','AppKit','-framework','CoreGraphics','-o',str(cls.fixture)],check=True,capture_output=True,timeout=60)
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='rb-',dir='/tmp');self.home=Path(self.tmp.name).resolve();self.home.chmod(0o700)
        self.review={'args':PROPOSAL,'expires_at_ms':int(time.time()*1000)+120000};self.seal()
    def tearDown(self):self.tmp.cleanup()
    def seal(self):
        p=self.home/'review.json';p.write_text(json.dumps(self.review));p.chmod(0o600)
    def argv(self,args=None,commit=True):
        req={'native_effect':{'tool':'apple.reminders.create.v1','args':args or PROPOSAL}}
        host=self.home/'host.py'
        host.write_text('import json,sys\nprint('+repr(json.dumps(req))+',flush=True)\nr=json.loads(sys.stdin.readline())\nif r.get("status")=="awaiting_commit":\n print(json.dumps({"native_commit":'+repr(commit)+',"operation_id":'+repr(PROPOSAL['operation_id'])+'}),flush=True)\n r=json.loads(sys.stdin.readline())\nprint(json.dumps({"broker_receipt":r}),flush=True)\n')
        host.chmod(0o600)
        return [str(self.fixture),'--fixture-broker',str(self.home),str(host),hashlib.sha256(host.read_bytes()).hexdigest()]
    def broker(self,args=None,mode='saved_local',commit=True):
        p=subprocess.run(self.argv(args,commit),capture_output=True,timeout=8,env=dict(os.environ,ARL_REMINDER_FIXTURE_MODE=mode))
        return p,json.loads(p.stdout) if p.stdout else None
    def status(self,r):return r['receipt']['status'] if r.get('status')=='host_completed' else r['status']
    def no_store(self):
        self.assertFalse((self.home/'fixture-constructed').exists());self.assertFalse((self.home/'fixture-effect').exists())
    def test_production_direct_stdin_and_fixture_flags_cannot_reach_store_or_tcc(self):
        for args in (PROPOSAL,dict(PROPOSAL,title='another schema-valid item')):
            p=subprocess.run([str(BINARY)],input=json.dumps({'tool':'apple.reminders.create.v1','args':args}).encode(),capture_output=True,timeout=3)
            self.assertEqual(json.loads(p.stdout),{'status':'native_broker_required'})
        p=subprocess.run([str(BINARY),'--fixture-broker',str(self.home),'x','x'],capture_output=True,timeout=3)
        self.assertEqual(json.loads(p.stdout),{'status':'invalid_arguments'});self.no_store()
    def test_changed_title_target_uuid_or_seal_refused_before_store(self):
        for key,value in (('title','changed'),('target_policy','arbitrary-list'),('operation_id','00000000-0000-0000-0000-000000000001')):
            _,r=self.broker(dict(PROPOSAL,**{key:value}));self.assertEqual(self.status(r),'review_not_authorized');self.no_store()
        self.review['args']=dict(PROPOSAL,title='changed');self.seal();_,r=self.broker()
        self.assertEqual(self.status(r),'review_not_authorized');self.no_store()
    def test_expiry_boolean_permission_lock_unknown_fail_before_store(self):
        for expires,want in ((1,'review_expired'),(True,'review_not_authorized'),(int(time.time()*1000)+700000,'review_expired')):
            self.review['expires_at_ms']=expires;self.seal();_,r=self.broker();self.assertEqual(self.status(r),want);self.no_store()
        self.review['expires_at_ms']=int(time.time()*1000)+120000;self.seal()
        for state in ('needs_permission','needs_unlock','lock_state_unknown'):
            _,r=self.broker(mode=state);self.assertEqual(self.status(r),state);self.no_store()
        self.assertFalse((self.home/'native-consumed.json').exists())
    def test_changed_launcher_and_unsafe_review_refused_before_store(self):
        argv=self.argv();Path(argv[3]).write_text('raise Exception()')
        p=subprocess.run(argv,capture_output=True,timeout=3);self.assertEqual(json.loads(p.stdout)['status'],'launcher_changed');self.no_store()
        (self.home/'review.json').chmod(0o644);_,r=self.broker();self.assertEqual(self.status(r),'review_not_authorized');self.no_store()
    def test_real_shaped_success_reports_hash_only_and_never_replays(self):
        _,r=self.broker();receipt=r['receipt'];self.assertEqual(receipt['status'],'saved_local')
        self.assertEqual(receipt['target_identifier_sha256'],hashlib.sha256(b'synthetic-list').hexdigest())
        self.assertEqual(set(receipt),{'status','operation_id','target_identifier_sha256'})
        self.assertTrue((self.home/'native-consumed.json').exists());self.assertTrue((self.home/'fixture-effect').exists())
        _,r=self.broker();self.assertEqual(self.status(r),'operation_consumed')
    def test_concurrent_starts_only_one_effect(self):
        argv=self.argv();children=[subprocess.Popen(argv,stdout=subprocess.PIPE,stderr=subprocess.PIPE) for _ in range(2)]
        results=[json.loads(p.communicate(timeout=8)[0]) for p in children]
        self.assertCountEqual([self.status(r) for r in results],['saved_local','operation_consumed'])
    def test_user_cancel_consumes_without_save_and_cannot_replay(self):
        _,r=self.broker(mode='user_cancelled');self.assertEqual(self.status(r),'user_cancelled')
        self.assertTrue((self.home/'native-consumed.json').exists());self.assertFalse((self.home/'fixture-save-attempt').exists())
        _,r=self.broker();self.assertEqual(self.status(r),'operation_consumed')
    def test_late_modal_confirmation_consumes_without_save(self):
        _,r=self.broker(mode='late_confirmation');self.assertEqual(self.status(r),'user_cancelled')
        self.assertTrue((self.home/'native-consumed.json').exists());self.assertFalse((self.home/'fixture-save-attempt').exists())
        _,r=self.broker();self.assertEqual(self.status(r),'operation_consumed')
    def test_host_cancellation_and_non_boolean_commit_refuse_effect(self):
        # False represents the real host's cancellation recheck after user review.
        _,r=self.broker(commit=False);self.assertEqual(self.status(r),'user_cancelled');self.assertFalse((self.home/'fixture-save-attempt').exists())
        # A fresh isolated state verifies that JSON integer1 is not boolean consent.
        (self.home/'native-consumed.json').unlink()
        _,r=self.broker(commit=1);self.assertEqual(self.status(r),'user_cancelled');self.assertFalse((self.home/'fixture-save-attempt').exists())
    def test_default_changed_or_expired_after_confirmation_no_save(self):
        for mode,want in (('target_changed','target_changed'),('expire_during_confirmation','review_expired')):
            with self.subTest(mode=mode):
                if (self.home/'native-consumed.json').exists():(self.home/'native-consumed.json').unlink()
                self.review['expires_at_ms']=int(time.time()*1000)+120000;self.seal()
                _,r=self.broker(mode=mode);self.assertEqual(self.status(r),want)
                self.assertFalse((self.home/'fixture-save-attempt').exists())
    def test_uncertain_save_and_crash_keep_durable_no_replay(self):
        _,r=self.broker(mode='outcome_unknown');self.assertEqual(self.status(r),'outcome_unknown')
        self.assertTrue((self.home/'fixture-save-attempt').exists());_,r=self.broker();self.assertEqual(self.status(r),'operation_consumed')
    def test_crash_before_save_keeps_consumed(self):
        p,_=self.broker(mode='crash_after_consume');self.assertEqual(p.returncode,77)
        self.assertTrue((self.home/'native-consumed.json').exists());self.assertFalse((self.home/'fixture-save-attempt').exists())
        _,r=self.broker();self.assertEqual(self.status(r),'operation_consumed')
    def test_sealed_launcher_ignores_pythonpath_and_rejects_changed_source(self):
        code=self.home/'code/arl';code.mkdir(parents=True);(code/'__init__.py').write_text('')
        (code/'contracts.py').write_text('class Fault(Exception): pass\n')
        (code/'reminders_review.py').write_text('import json\ndef main():\n print(json.dumps({"source":"sealed"}));return 0\n')
        files={str(p.relative_to(self.home/'code')):hashlib.sha256(p.read_bytes()).hexdigest() for p in code.iterdir()}
        launcher=self.home/'launch_reminders.py';launcher.write_text(render(files,self.home));launcher.chmod(0o600)
        hostile=self.home/'hostile';(hostile/'arl').mkdir(parents=True);(hostile/'arl/__init__.py').write_text('raise Exception("cwd")')
        p=subprocess.run(['/usr/bin/python3','-I',str(launcher)],cwd=hostile,env=dict(os.environ,PYTHONPATH=str(hostile)),capture_output=True,timeout=3)
        self.assertEqual(json.loads(p.stdout),{'source':'sealed'})
        (code/'reminders_review.py').write_text('raise Exception("changed")')
        p=subprocess.run(['/usr/bin/python3','-I',str(launcher)],cwd=hostile,capture_output=True,timeout=3)
        self.assertEqual(json.loads(p.stdout),{'status':'sealed_source_changed'});self.assertFalse(p.stderr)
    def test_owned_signed_native_client_actual_sdk_rpc_with_injected_store(self):
        account=self.home/'account';base=account/'Library/Application Support/ARL/reminders-once';base.mkdir(parents=True,mode=0o700);base.chmod(0o700)
        release=SOURCE/'dist/reminders-release-source-v3';code=base/'code';shutil.copytree(release/'code',code)
        host=code/'arl/host.py';host.write_text(host.read_text().replace('return Path(pwd.getpwuid(os.geteuid()).pw_dir)','return Path('+repr(str(account))+')'))
        bundle=account/'Applications/ARLRemindersBridge.app';shutil.copytree(release/'ARLRemindersBridge.app',bundle)
        shutil.copy2(self.fixture,bundle/'Contents/MacOS/ARLRemindersBridge')
        subprocess.run(['/usr/bin/codesign','--force','--sign','-','--identifier','local.arl.remindersbridge','--options','runtime',str(bundle)],check=True,capture_output=True,timeout=5)
        cdhash=re.search(r'^CDHash=([0-9a-f]{40})$',subprocess.run(['/usr/bin/codesign','-dvvvv',str(bundle)],check=True,capture_output=True,timeout=5).stderr.decode(),re.M).group(1)
        manifest=json.loads((SOURCE/'reminders-package.json').read_text())
        manifest['files']={str(p.relative_to(bundle)):hashlib.sha256(p.read_bytes()).hexdigest() for p in bundle.rglob('*') if p.is_file()}
        manifest['cdhash']=cdhash;manifest['requirement']='cdhash H"'+cdhash+'"'
        (base/'reminders-package.json').write_text(json.dumps(manifest));(base/'reminders-package.json').chmod(0o600)
        (base/'review.json').write_text(json.dumps(self.review));(base/'review.json').chmod(0o600)
        files={str(p.relative_to(code)):hashlib.sha256(p.read_bytes()).hexdigest() for p in code.rglob('*') if p.is_file()}
        launcher=base/'launch_reminders.py';launcher.write_text(render(files,base));launcher.chmod(0o600)
        direct=subprocess.run(['/usr/bin/python3','-I',str(launcher),'--native-broker','--approved-sha256',json.loads((SOURCE/'approval-proposal.json').read_text())['request_sha256']],capture_output=True,timeout=5)
        self.assertEqual(json.loads(direct.stdout)['broker_receipt']['error'],'native_broker_required');self.assertFalse((base/'state.sqlite').exists())
        p=subprocess.run([str(bundle/'Contents/MacOS/ARLRemindersBridge'),'--fixture-broker',str(base),str(launcher),hashlib.sha256(launcher.read_bytes()).hexdigest()],capture_output=True,timeout=15)
        receipt=json.loads(p.stdout);self.assertEqual(receipt['status'],'host_completed',receipt)
        self.assertEqual(receipt['receipt']['state'],'succeeded',receipt)
        self.assertEqual(receipt['receipt']['result']['target_selection'],'system_default_confirmed')
        self.assertTrue((base/'fixture-effect').exists())
        self.assertEqual(receipt['receipt']['result']['cloud_sync'],'not_checked')
