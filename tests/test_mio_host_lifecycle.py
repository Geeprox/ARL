"""Actual native host/process group/peer/profile-parser checks, injected Apple only."""
import hashlib,json,os,plistlib,signal,subprocess,tempfile,time,unittest,uuid
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1];SRC=ROOT/'integrations/mio_apple';REVIEW=ROOT/'integrations/apple_review'
class HostLifecycleTests(unittest.TestCase):
 @classmethod
 def setUpClass(cls):
  cls.temp=tempfile.TemporaryDirectory(prefix='mio-host-build-',dir='/tmp');cls.folder=Path(cls.temp.name).resolve()
  main=cls.folder/'main.swift';main.write_text(r'''import Foundation
import Darwin
signal(SIGPIPE,SIG_IGN)
do {
 let a=CommandLine.arguments
 if a[1]=="--fixture-host"{try fixtureHost(policy:a[2],sha:a[3])}
 else if a[1]=="--fixture-client"{try fixtureClient(policy:a[2],sha:a[3])}
 else if a[1]=="--gateway"{signal(SIGTERM,SIG_IGN);try runGateway(home:a[2],expectedHostPID:Int32(a[4])!)}
 else if a[1]=="--authorize"{try sendLine(jsonBytes(requestSession(home:a[2])),STDOUT_FILENO)}
 else if a[1]=="--prepare-session"{
  _ = try sealedActivation(a[2],a[4]);try verifyOwnedSignature(getppid(),requirement:ownRequirement())
  try sendLine(jsonBytes(["schema_version":1,"target_alias":"approved_calendar","calendar_identifier":"synthetic","expires_at_ms":Int64(Date().timeIntervalSince1970*1000)+2000]),STDOUT_FILENO);usleep(100000)
 }
 else if a[1]=="--group-proof" {
  let p=Process();p.executableURL=Bundle.main.executableURL;p.arguments=["--group-child"]
  p.environment=["PATH":"/usr/bin:/bin"];p.standardInput=FileHandle.nullDevice
  let out=Pipe();p.standardOutput=out;p.standardError=FileHandle.nullDevice;try p.run()
  guard let raw=try boundedLine(out.fileHandleForReading.fileDescriptor,seconds:3) else{throw ReviewFault("fixture_failed")}
  p.waitUntilExit();guard p.terminationStatus==0 else{throw ReviewFault("fixture_failed")}
  try sendLine(raw,STDOUT_FILENO)
 }
 else if a[1]=="--group-child" {
  try verifyOwnedSignature(getppid(),requirement:ownRequirement())
  let leader=getpgid(getpid())==getpid();try establishControlledClientGroup()
  try sendLine(jsonBytes(["already_group_leader":leader,"old_guard_accepts":!leader,"own_group_verified":getpgid(getpid())==getpid(),"signed_parent_verified":true]),STDOUT_FILENO)
 }
 else if a[1]=="--diagnostics-proof" {
  let parser=MioStderrClassifier()
  let codes=parser.feed(Data(("unexpected argument SECRET_TOKEN /private/user/project"+String(UnicodeScalar(10))).utf8))
  let unknown=parser.feed(Data(("{\"code\":\"SECRET_TOKEN\",\"path\":\"/private/user\"}"+String(UnicodeScalar(10))).utf8))
  let oversized=parser.feed(Data((String(repeating:"S",count:2000)+String(UnicodeScalar(10))).utf8))
  let native=parser.feed(Data(("{\"code\":\"caller_unverified\"}"+String(UnicodeScalar(10))).utf8))
  let error=NSError(domain:NSPOSIXErrorDomain,code:13,userInfo:[NSLocalizedDescriptionKey:"SECRET_TOKEN /private/user"])
  let metadata=MioStartupDiagnostics.object("client_launch_rejected",error:error,role:"client",phase:"client_exec")
  try sendLine(jsonBytes(["codes":codes,"unknown":unknown,"oversized":oversized,"native":native,"metadata":metadata,"duplicates":parser.feed(Data(("unexpected argument SECRET_TOKEN"+String(UnicodeScalar(10))).utf8))]),STDOUT_FILENO)
 }
 else if a[1]=="--check-production-pins"{_ = try MioBundledRuntime.load()}
 else{exit(2)}
}catch{FileHandle.standardError.write(Data(((error as? ReviewFault)?.code ?? "fixture_failed").utf8));exit(1)}
''')
  cls.binary=cls.folder/'fixture'
  recipe=json.loads((ROOT/'script/mio_native_recipe.json').read_text())
  sources=[ROOT/row['path'] for row in recipe['sources'] if not row['path'].endswith('/main.swift')]
  for extra in [SRC/'HostFixture.swift',SRC/'SetupFlow.swift']:
   if extra not in sources:sources.append(extra)
  subprocess.run(['/usr/bin/xcrun','swiftc','-swift-version','6','-D','ARL_MIO_HOST_TEST_ONLY','-module-cache-path',str(ROOT/'build/cache/ModuleCache'),str(main),*[str(p) for p in sources],'-framework','Security','-framework','EventKit','-framework','AppKit','-framework','CoreGraphics','-o',str(cls.binary)],check=True,capture_output=True,timeout=60)
 @classmethod
 def tearDownClass(cls):cls.temp.cleanup()
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory(prefix='mio-host-case-',dir='/tmp');self.folder=Path(self.temp.name).resolve();self.home=self.folder/'state';self.home.mkdir(mode=0o700)
  self.bundle=self.folder/'Native Fixture.app';(self.bundle/'Contents/MacOS').mkdir(parents=True);self.exe=self.bundle/'Contents/MacOS/ARLMioAppleBridge';self.exe.write_bytes(self.binary.read_bytes());self.exe.chmod(0o700)
  self.profile=self.home/'profile.yaml';command=f'"{self.exe}" --gateway "{self.home}" --host-pid {{{{ARL_MIO_HOST_PID}}}}'
  self.profile.write_text('config_version: 1\ncontrol_plane:\n  base_url: https://example.invalid\n  tunnel_id: tunnel_00000000000000000000000000000000\n  api_key: env:ARL_TEST_ONLY_NON_CREDENTIAL\nmcp:\n  commands:\n    - channel: main\n      command: '+json.dumps(command)+'\n');self.profile.chmod(0o600)
  config=dict(schema_version=2,enabled=1,home=str(self.home),profile=str(self.profile),profile_sha256=hashlib.sha256(self.profile.read_bytes()).hexdigest(),client_home=str(self.home),health_url_file=str(self.home/'health-url.txt'),audience_org='org-example',tunnel_id='tunnel_'+'0'*32,target_rule='defaultCalendarForNewEvents',max_effects=3,session_seconds=3600,locked_qualified=0)
  self.config=self.home/'activation.json';self.config.write_text(json.dumps(config));self.config.chmod(0o600);self.sha=hashlib.sha256(self.config.read_bytes()).hexdigest()
  import shutil
  runtime=ROOT/'build/local-config/MioTemplate.app/Contents/Resources/MioRuntime'
  if not runtime.is_dir():runtime=Path.home()/'Applications/ARL.app/Contents/Library/LoginItems/ARLMioAppleBridge.app/Contents/Resources/MioRuntime'
  if not (runtime/'manifest.json').is_file():self.skipTest('approved offline tunnel runtime unavailable')
  manifest_sha=hashlib.sha256((runtime/'manifest.json').read_bytes()).hexdigest()
  shutil.copytree(runtime,self.bundle/'Contents/Resources/MioRuntime')
  (self.bundle/'Contents/Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier='local.arl.mioapplebridge.fixture',CFBundleExecutable='ARLMioAppleBridge',CFBundlePackageType='APPL',ARLApprovedPolicySHA256=self.sha,ARLMioRuntimeManifestSHA256=manifest_sha)))
  subprocess.run(['/usr/bin/codesign','--force','--sign','-',str(self.bundle)],check=True,capture_output=True,timeout=5)
  (self.home/'requests.jsonl').write_text('');self.p=None;self.group=None
 def tearDown(self):
  if self.p and self.p.poll() is None:
   self.p.terminate()
   try:self.p.wait(timeout=7)
   except subprocess.TimeoutExpired:self.p.kill();self.p.wait(timeout=2)
  if self.p and self.p.stderr:self.p.stderr.close()
  self.temp.cleanup()
 def await_value(self,fn,seconds=5):
  end=time.monotonic()+seconds
  while time.monotonic()<end:
   value=fn()
   if value:return value
   if getattr(self,'p',None) is not None and self.p.poll() is not None:
    self.fail('fixture host exited: '+self.p.stderr.read().decode()[:1000])
   time.sleep(.02)
  self.fail('bounded fixture timeout')
 def start(self):
  if self.p and self.p.stderr:self.p.stderr.close()
  self.p=subprocess.Popen([str(self.exe),'--fixture-host',str(self.config),self.sha],stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
  child=self.await_value(lambda:json.loads((self.home/'owned-child.json').read_text()) if (self.home/'owned-child.json').exists() else None)
  self.group=child['pid'];self.await_value(lambda:(self.home/'gateway_0').exists());return child
 def request(self,obj):
  out=self.home/'responses.jsonl';n=len(out.read_text().splitlines()) if out.exists() else 0
  with (self.home/'requests.jsonl').open('a') as f:f.write(json.dumps(obj)+'\n')
  return self.await_value(lambda:json.loads(out.read_text().splitlines()[n]) if out.exists() and len(out.read_text().splitlines())>n else None)
 def tools(self):return self.request(dict(jsonrpc='2.0',id=1,method='tools/list'))['result']['tools']
 def authorize(self):
  p=subprocess.run([str(self.exe),'--authorize',str(self.home)],capture_output=True,check=True,timeout=5);return json.loads(p.stdout)
 def test_readonly_then_native_session_expiry_retains14_health_and_restart_denies_renewal(self):
  self.start();self.assertEqual(len(self.tools()),14);self.assertEqual(self.authorize()['status'],'session_active');self.assertEqual(len(self.tools()),14)
  time.sleep(2.1);self.assertEqual(len(self.tools()),14);self.assertTrue((self.home/'health-url.txt').exists());self.assertIsNone(self.p.poll())
  self.assertEqual(self.authorize()['status'],'inactive');self.p.terminate();self.p.wait(timeout=7);self.assertEqual(self.p.returncode,0)
  self.assertFalse((self.home/'owned-child.json').exists());(self.home/'health-url.txt').unlink();(self.home/'gateway_0').unlink();self.start();self.assertEqual(len(self.tools()),14);self.assertEqual(self.authorize()['status'],'inactive')
 def test_gateway_reconnection_same_controlled_client_and_group_shutdown_proven(self):
  self.start();self.assertEqual(len(self.tools()),14)
  with (self.home/'requests.jsonl').open('a') as f:f.write('RECONNECT\n')
  self.await_value(lambda:(self.home/'gateway_1').exists());self.assertEqual(len(self.tools()),14)
  self.p.terminate();self.p.wait(timeout=7);self.assertEqual(self.p.returncode,0)
  with self.assertRaises(ProcessLookupError):os.killpg(self.group,0)
  for name in ['owned-child.json','active-profile.yaml','mio.sock','control.sock']:self.assertFalse((self.home/name).exists())
 def test_second_host_rejected_before_second_client(self):
  self.start();p=subprocess.run([str(self.exe),'--fixture-host',str(self.config),self.sha],capture_output=True,timeout=3);self.assertEqual(p.returncode,1);self.assertIsNone(self.p.poll());self.assertEqual(len(self.tools()),14)
 def test_real_host_private_setup_pipe_arbitrary_event_and_durable_duplicate(self):
  self.start();(self.home/'target-registration.json').write_text('{"approved":true,"calendar_identifier":"forged"}')
  self.assertEqual(len(self.tools()),14);self.assertEqual(self.authorize()['status'],'session_active')
  op=str(uuid.uuid4());args=dict(operation_id=op,target_alias='approved_calendar',title='Ordinary user proposal',time_zone='Asia/Shanghai',start='2026-10-03T14:00:00+08:00',end='2026-10-03T14:05:00+08:00',expires_at_ms=int(time.time()*1000)+30000)
  req=dict(jsonrpc='2.0',id=5,method='tools/call',params=dict(name='mio_calendar_create_v1',arguments=args))
  response=self.request(req);receipt=json.loads(response['result']['content'][0]['text']);self.assertEqual(receipt['code'],'calendar_v1_retired');self.assertFalse((self.home/('saved_'+op)).exists())
  duplicate=self.request(req);self.assertEqual(json.loads(duplicate['result']['content'][0]['text'])['code'],'calendar_v1_retired');self.assertEqual(len(list(self.home.glob('saved_*'))),0)
 def test_official_profile_yaml_parser_offline_no_key_reference_or_tunnel_start(self):
  # profiles add parses/copies configuration only. Dummy env ref, no real key,
  # doctor/run/dev proxy are never called. stdout contains no config/credential.
  target=self.folder/'parsed';p=subprocess.run(['/opt/homebrew/bin/tunnel-client','profiles','add','fixture','--profile-dir',str(target),'--from-file',str(self.profile)],env={'PATH':'/usr/bin:/bin','HOME':str(self.folder)},capture_output=True,timeout=5)
  self.assertEqual(p.returncode,0,'official offline profile parser rejected fixture')
  files=list(target.glob('*.yaml'));self.assertEqual(len(files),1);self.assertIn('commands:',files[0].read_text());self.assertIsNone(self.p)
 def test_bundled_runtime_pins_without_owner_activation(self):
  p=subprocess.run([str(self.exe),'--check-production-pins'],capture_output=True,timeout=5);self.assertEqual(p.returncode,0,p.stderr)

 def test_foundation_group_leader_supported_with_signed_parent_unchanged(self):
  p=subprocess.run([str(self.exe),'--group-proof'],capture_output=True,check=True,timeout=5)
  r=json.loads(p.stdout);self.assertTrue(r['already_group_leader']);self.assertFalse(r['old_guard_accepts']);self.assertTrue(r['own_group_verified']);self.assertTrue(r['signed_parent_verified'])
 def test_startup_diagnostics_finite_redacted_bounded_and_native_detail_preserved(self):
  p=subprocess.run([str(self.exe),'--diagnostics-proof'],capture_output=True,check=True,timeout=5)
  self.assertNotIn(b'SECRET_TOKEN',p.stdout);self.assertNotIn(b'/private',p.stdout)
  r=json.loads(p.stdout);self.assertEqual(r['codes'],['upstream_cli_argument']);self.assertEqual(r['unknown'],['upstream_stderr_other']);self.assertEqual(r['oversized'],['stderr_oversize']);self.assertEqual(r['native'],['caller_unverified']);self.assertEqual(r['duplicates'],[])
  self.assertEqual(set(r['metadata']),{'schema_version','code','phase','role','checked_at_ms','os_domain','os_code'});self.assertEqual(r['metadata']['os_code'],13);self.assertEqual(r['metadata']['phase'],'client_exec')
