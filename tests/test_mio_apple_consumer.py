"""Real controlled native process/MCP consumer; injected effects only, no keys/TCC."""
import hashlib,json,subprocess,tempfile,time,unittest,uuid,os,plistlib
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1];SRC=ROOT/'integrations/mio_apple';REVIEW=ROOT/'integrations/apple_review'
ORIGINAL=Path(os.environ.get('ARL_MIO_ORIGINAL',str(ROOT/'build/optional-mio-original.py')))
class MioAppleConsumerTests(unittest.TestCase):
 @classmethod
 def setUpClass(cls):
  cls.tmp=tempfile.TemporaryDirectory(prefix='mio-consumer-build-',dir='/tmp');cls.folder=Path(cls.tmp.name);cls.bundle=cls.folder/'Consumer Fixture.app';(cls.bundle/'Contents/MacOS').mkdir(parents=True);cls.binary=cls.bundle/'Contents/MacOS/ARLMioAppleBridge'
  (cls.bundle/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'local.arl.mioapplebridge.fixture','CFBundleExecutable':'ARLMioAppleBridge','CFBundlePackageType':'APPL'}))
  main=cls.folder/'main.swift';main.write_text('''import Foundation
import Darwin
signal(SIGPIPE,SIG_IGN)
do {
 let a=CommandLine.arguments
 if a[1]=="--transport-fixture" {try sendLine(jsonBytes(transportFixture(a[2])),STDOUT_FILENO)}
 else if a[1]=="--fixture-tunnel" {
  _=try boundedLine(STDIN_FILENO,seconds:3)
  try fixtureTunnel(home:a[2],host:Int32(a[3])!,mode:a[4])
 } else if a[1]=="--disconnect-gateway" {try fixtureDisconnectGateway(home:a[2],host:Int32(a[4])!)}
 else if a[1]=="--gateway" {try runGateway(home:a[2],expectedHostPID:Int32(a[4])!)}
 else {
  let batch=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:a[3]))) as! [String:Any]
  let result=try fixtureSession(home:a[2],mode:batch["mode"] as! String,requests:batch["requests"] as! [[String:Any]],tools:batch["tools"] as! [[String:Any]])
  try sendLine(jsonBytes(result),STDOUT_FILENO)
 }
} catch {try! sendLine(jsonBytes(["code":(error as? ReviewFault)?.code ?? "fixture_failed"]),STDOUT_FILENO);exit(1)}
''')
  recipe=json.loads((ROOT/'script/mio_native_recipe.json').read_text())
  sources=[ROOT/row['path'] for row in recipe['sources'] if not row['path'].endswith('/main.swift')]
  if SRC/'Fixture.swift' not in sources:sources.append(SRC/'Fixture.swift')

  subprocess.run(['/usr/bin/xcrun','swiftc','-swift-version','6','-D','ARL_MIO_HOST_TEST_ONLY','-module-cache-path',str(SRC/'dist/module-cache'),str(main),*[str(s) for s in sources],'-framework','Security','-framework','AppKit','-framework','EventKit','-framework','CoreGraphics','-o',str(cls.binary)],check=True,capture_output=True,timeout=60)
  subprocess.run(['/usr/bin/codesign','--force','--sign','-','--identifier','local.arl.mioapplebridge.fixture',str(cls.bundle)],check=True,capture_output=True,timeout=5)
  # Public checked-in readonly descriptors; no private installed module import.
  cls.tools=json.loads((ROOT/'docs/mio-tools.json').read_text())['tools']
  assert len(cls.tools)==14
 @classmethod
 def tearDownClass(cls):cls.tmp.cleanup()
 def request(self,**patch):
  args={'operation_id':str(uuid.uuid4()),'target_alias':'approved_calendar','title':'Synthetic Mio event','time_zone':'Asia/Shanghai','start':'2026-10-03T10:00:00+08:00','end':'2026-10-03T10:05:00+08:00','expires_at_ms':int(time.time()*1000)+30000};args.update(patch)
  return {'jsonrpc':'2.0','id':1,'method':'tools/call','params':{'name':'mio_calendar_create_v1','arguments':args}}
 def run_session(self,mode='ok',requests=None,home=None):
  if home is None:
   with tempfile.TemporaryDirectory(prefix='mio-consumer-',dir='/tmp') as d:return self.run_session(mode,requests,str(Path(d).resolve()))
  payload=Path(home)/'fixture.json';payload.write_text(json.dumps({'mode':mode,'requests':requests or [self.request()],'tools':self.tools}))
  p=subprocess.run([str(self.binary),'--fixture',home,str(payload)],capture_output=True,timeout=10)
  self.assertEqual(p.returncode,0,p.stdout);return json.loads(p.stdout)
 def code(self,r,index=0):return json.loads(r['responses'][index]['result']['content'][0]['text']).get('code')
 def test_retired_calendar_is_not_advertised_even_after_setup(self):
  for mode in ['ok','disabled','locked','unknown']:
   r=self.run_session(mode,requests=[{'jsonrpc':'2.0','id':1,'method':'tools/list'}])
   tools=r['responses'][0]['result']['tools']
   self.assertEqual(tools,self.tools);self.assertNotIn('mio_calendar_create_v1',[t['name'] for t in tools])
   self.assertEqual(r['saves'],0);self.assertEqual(r['auths'],0)
 def test_retired_calls_and_duplicate_ids_never_resume_an_effect(self):
  original=self.request()
  with tempfile.TemporaryDirectory(prefix='retired-calendar-',dir='/tmp') as d:
   for request in [original,original,self.request(approved=True),self.request(target_alias='other')]:
    r=self.run_session(requests=[request],home=str(Path(d).resolve()))
    self.assertEqual(self.code(r),'calendar_v1_retired')
    self.assertEqual(r['saves'],0);self.assertEqual(r['reads'],0);self.assertEqual(r['auths'],0)
 def test_same_signed_binary_wrong_controlled_parent_denied(self):
  r=self.run_session('rogue_parent');self.assertEqual(r['code'],'unregistered_adapter');self.assertEqual(r['saves'],0)
 def test_transport_failures_keep_the_actual_stage(self):
  for name,status in [('eof','eof'),('poll_error','transport_unavailable')]:
   p=subprocess.run([str(self.binary),'--transport-fixture',name],capture_output=True,timeout=5)
   self.assertEqual(p.returncode,0,p.stderr)
   self.assertEqual(json.loads(p.stdout)['status'],status)
