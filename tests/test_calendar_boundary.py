"""Actual native sealed-boundary negatives; effects use a compile-time double only."""
import hashlib,json,os,shutil,subprocess,tempfile,time,unittest
from pathlib import Path
from integrations.apple_calendar.launcher_source import render
ROOT=Path(__file__).resolve().parents[1]
SOURCE=ROOT/'integrations/apple_calendar'
PROPOSAL=json.loads((SOURCE/'approval-proposal.json').read_text())['args']
BINARY=SOURCE/'dist/ARLCalendarBridge.app/Contents/MacOS/ARLCalendarBridge'
class CalendarBoundaryTests(unittest.TestCase):
 @classmethod
 def setUpClass(cls):
  cls.fixture=SOURCE/'dist/build/CalendarBoundaryFixture'
  subprocess.run(['/usr/bin/xcrun','swiftc','-D','CALENDAR_EFFECT_FIXTURE','-swift-version','6','-module-cache-path',str(SOURCE/'dist/module-cache'),str(SOURCE/'dist/build/main.swift'),str(SOURCE/'NativeEffectBoundary.swift'),str(SOURCE/'CalendarSeal.swift'),str(SOURCE/'ReviewClient.swift'),str(ROOT/'examples/ARLClient.swift'),'-framework','EventKit','-framework','AppKit','-o',str(cls.fixture)],check=True,capture_output=True,timeout=60)
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory(prefix='cb-',dir='/tmp');self.home=Path(self.tmp.name).resolve();self.home.chmod(0o700)
  self.review={'args':PROPOSAL,'expires_at_ms':int(time.time()*1000)+120000};self.seal()
 def tearDown(self):self.tmp.cleanup()
 def seal(self):
  p=self.home/'review.json';p.write_text(json.dumps(self.review));p.chmod(0o600)
 def host(self,args=None):
  request={'native_effect':{'tool':'apple.calendar.create.v1','args':args or PROPOSAL}}
  p=self.home/'host.py';p.write_text("import json,sys\nprint("+repr(json.dumps(request))+",flush=True)\nr=json.loads(sys.stdin.readline())\nprint(json.dumps({'broker_receipt':r}),flush=True)\n");p.chmod(0o600);return p
 def argv(self,args=None):
  p=self.host(args);return [str(self.fixture),'--fixture-broker',str(self.home),str(p),hashlib.sha256(p.read_bytes()).hexdigest()]
 def run_broker(self,args=None,env=None):
  result=subprocess.run(self.argv(args),stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=8,env=env);return result,json.loads(result.stdout) if result.stdout else None
 def test_direct_unregistered_production_stdin_cannot_save_even_schema_valid(self):
  for args in (PROPOSAL,dict(PROPOSAL,title='other schema-valid event')):
   p=subprocess.run([str(BINARY)],input=json.dumps({'tool':'apple.calendar.create.v1','args':args}).encode(),capture_output=True,timeout=3)
   self.assertEqual(json.loads(p.stdout),{'status':'native_broker_required'})
  self.assertFalse((self.home/'native-consumed.json').exists())
 def test_native_changed_request_and_seal_reject_before_effect(self):
  _,r=self.run_broker(dict(PROPOSAL,title='changed'))
  self.assertEqual(r['receipt']['status'],'review_not_authorized');self.assertFalse((self.home/'fixture-effect').exists());self.assertFalse((self.home/'native-consumed.json').exists())
  self.review['args']=dict(PROPOSAL,operation_id='00000000-0000-0000-0000-000000000001');self.seal()
  _,r=self.run_broker();self.assertEqual(r['status'],'review_not_authorized');self.assertFalse((self.home/'fixture-effect').exists())
 def test_expired_boolean_expiry_and_changed_launcher_reject_before_effect(self):
  for expiry,want in ((int(time.time()*1000)-1,'review_expired'),(True,'review_not_authorized')):
   self.review['expires_at_ms']=expiry;self.seal();_,r=self.run_broker();self.assertEqual(r['status'],want)
  self.review['expires_at_ms']=int(time.time()*1000)+120000;self.seal();argv=self.argv();Path(argv[3]).write_text('raise Exception()')
  r=subprocess.run(argv,capture_output=True,timeout=3);self.assertEqual(json.loads(r.stdout)['status'],'launcher_changed');self.assertFalse((self.home/'fixture-effect').exists())
 def test_repeat_and_concurrent_native_budget_single_effect(self):
  argv=self.argv();first=subprocess.Popen(argv,stdout=subprocess.PIPE,stderr=subprocess.PIPE);second=subprocess.Popen(argv,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
  receipts=[json.loads(p.communicate(timeout=8)[0]) for p in (first,second)]
  states=[r['receipt']['status'] if r['status']=='host_completed' else r['status'] for r in receipts]
  self.assertCountEqual(states,['saved_local','operation_consumed']);self.assertTrue((self.home/'fixture-effect').exists())
  p=subprocess.run(argv,capture_output=True,timeout=3);self.assertEqual(json.loads(p.stdout)['status'],'operation_consumed')
 def test_crash_after_durable_consumption_never_replays_on_restart(self):
  env=dict(os.environ,ARL_FIXTURE_CRASH_AFTER_CONSUME='1');p,_=self.run_broker(env=env);self.assertEqual(p.returncode,77)
  self.assertTrue((self.home/'native-consumed.json').exists());self.assertFalse((self.home/'fixture-effect').exists())
  _,r=self.run_broker();self.assertEqual(r['status'],'operation_consumed');self.assertFalse((self.home/'fixture-effect').exists())
 def test_production_binary_has_no_fixture_or_generic_effect_entry(self):
  p=subprocess.run([str(BINARY),'--fixture-broker',str(self.home),'x','x'],capture_output=True,timeout=3)
  self.assertEqual(json.loads(p.stdout)['status'],'invalid_arguments')
 def test_isolated_launcher_ignores_hostile_cwd_pythonpath_and_uses_hashed_bytes(self):
  code=self.home/'code/arl';code.mkdir(parents=True);(code/'__init__.py').write_text('')
  (code/'contracts.py').write_text('class Fault(Exception): pass\n')
  (code/'calendar_review.py').write_text("import json\ndef main():\n print(json.dumps({'source':'sealed'}));return 0\n")
  files={str(p.relative_to(self.home/'code')):hashlib.sha256(p.read_bytes()).hexdigest() for p in code.iterdir()}
  launcher=self.home/'launch_calendar.py';launcher.write_text(render(files,self.home));launcher.chmod(0o600)
  hostile=self.home/'hostile';(hostile/'arl').mkdir(parents=True);(hostile/'arl/__init__.py').write_text('raise RuntimeError("cwd shadow")')
  env=dict(os.environ,PYTHONPATH=str(hostile));r=subprocess.run(['/usr/bin/python3','-I',str(launcher)],cwd=hostile,env=env,capture_output=True,timeout=3)
  self.assertEqual(r.returncode,0);self.assertEqual(json.loads(r.stdout),{'source':'sealed'})
  (code/'calendar_review.py').write_text('raise RuntimeError("mutated source")')
  r=subprocess.run(['/usr/bin/python3','-I',str(launcher)],cwd=hostile,env=env,capture_output=True,timeout=3)
  self.assertEqual(r.returncode,1);self.assertEqual(json.loads(r.stdout),{'status':'sealed_source_changed'});self.assertFalse(r.stderr)

 def test_native_owned_isolated_host_real_registered_rpc_to_compiletime_effect(self):
  account=self.home/'account';base=account/'Library/Application Support/ARL/calendar-once';base.mkdir(parents=True,mode=0o700);base.chmod(0o700)
  code=base/'code';shutil.copytree(SOURCE/'dist/calendar-release-v2/code',code)
  # Only this fixture's sealed host source substitutes its isolated account home.
  hp=code/'arl/host.py';hs=hp.read_text().replace('return Path(pwd.getpwuid(os.geteuid()).pw_dir)', 'return Path('+repr(str(account))+')');hp.write_text(hs)
  bundle=account/'Applications/ARLCalendarBridge.app';shutil.copytree(SOURCE/'dist/ARLCalendarBridge.app',bundle)
  shutil.copy2(self.fixture,bundle/'Contents/MacOS/ARLCalendarBridge')
  subprocess.run(['/usr/bin/codesign','--force','--sign','-','--identifier','local.arl.calendarbridge','--options','runtime',str(bundle)],check=True,capture_output=True,timeout=5)
  import re
  signed=subprocess.run(['/usr/bin/codesign','-dvvvv',str(bundle)],check=True,capture_output=True,timeout=5)
  cdhash=re.search(r'^CDHash=([0-9a-f]{40})$',signed.stderr.decode(),re.M).group(1)
  manifest=json.loads((SOURCE/'calendar-package.json').read_text());manifest['files']={str(p.relative_to(bundle)):hashlib.sha256(p.read_bytes()).hexdigest() for p in bundle.rglob('*') if p.is_file()};manifest['cdhash']=cdhash;manifest['requirement']='cdhash H"'+cdhash+'"'
  (base/'calendar-package.json').write_text(json.dumps(manifest));(base/'calendar-package.json').chmod(0o600)
  (base/'review.json').write_text(json.dumps(self.review));(base/'review.json').chmod(0o600)
  files={str(p.relative_to(code)):hashlib.sha256(p.read_bytes()).hexdigest() for p in code.rglob('*') if p.is_file()}
  launcher=base/'launch_calendar.py';launcher.write_text(render(files,base));launcher.chmod(0o600)
  # Direct -I invocation lacks the native parent, before any job/effect/TCC.
  direct=subprocess.run(['/usr/bin/python3','-I',str(launcher),'--native-broker','--approved-sha256',json.loads((SOURCE/'approval-proposal.json').read_text())['request_sha256']],capture_output=True,timeout=5)
  self.assertEqual(json.loads(direct.stdout)['broker_receipt']['error'],'native_broker_required');self.assertFalse((base/'state.sqlite').exists())
  result=subprocess.run([str(bundle/'Contents/MacOS/ARLCalendarBridge'),'--fixture-broker',str(base),str(launcher),hashlib.sha256(launcher.read_bytes()).hexdigest()],capture_output=True,timeout=15)
  receipt=json.loads(result.stdout);self.assertEqual(receipt['status'],'host_completed',receipt);self.assertEqual(receipt['receipt']['state'],'succeeded',receipt)
  self.assertTrue((base/'fixture-effect').exists());self.assertTrue((base/'native-consumed.json').exists())
  self.assertEqual(receipt['receipt']['result']['persistence'],'saved_local')
