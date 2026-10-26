"""Isolated source-only Swift/native v2 integration. No installed runtime or UI."""
import copy,json,os,socket,subprocess,tempfile,threading,time
from pathlib import Path
import sys
sys.dont_write_bytecode=True
ROOT=Path(os.environ.get('ARL_CONTROL_SOURCE',Path(__file__).resolve().parents[3]))
HARNESS=Path(os.environ.get('ARL_CONTROL_HARNESS',ROOT/'control-metadata-harness'))
sys.path.insert(0,str(ROOT))
from arl.service import Runtime
from arl.host import metadata_policies
from arl.providers import MockProvider
from arl.control import AppDescriptor
from arl.metrics import ResourceSampler

cases=[]
def record(name,result,passed):
 cases.append({'name':name,'passed':bool(passed),'result':result}); print(name,':',bool(passed),flush=True)
def call(home,mode='refresh',*extra):
 p=subprocess.run([str(HARNESS),str(home),mode,*extra],capture_output=True,text=True,timeout=15)
 assert p.returncode==0,p.stderr[-1000:]
 return json.loads(p.stdout)
with tempfile.TemporaryDirectory(prefix='arl-cv2-',dir='/tmp') as directory:
 home=Path(directory); errors=[]
 runtime=Runtime(home,policies=metadata_policies(),providers={'mock':MockProvider()},execute_jobs=False,identity_verifier=lambda c,a:None,start_delay=1)
 def run():
  try:runtime.run()
  except Exception as e:errors.append(type(e).__name__)
 thread=threading.Thread(target=run);thread.start()
 try:
  until=time.monotonic()+3
  while not (home/'runtime.sock').exists() and time.monotonic()<until:time.sleep(.01)
  early=call(home);record('real-v2-before-ready',early,early['has_v2'] and early['title'] in ('正在准备','运行时已就绪') and not early['task_execution'])
  assert runtime.ready.wait(5)
  result=call(home);record('real-v2-metadata-only-ready',result,result['ok'] and result['has_v2'] and result['apps']==4 and result['apple_apps']==4 and not result['task_execution'] and not result['control_error'])
  record('real-first-interval-cpu-null',result,result.get('process_cpu') and all(v is None for v in result['process_cpu']))
  time.sleep(5.1)
  sample=call(home);record('real-interval-cpu-metadata',sample,sample['metrics_available'] and (sample.get('system_cpu') is None or 0<=sample['system_cpu']<=100) and all(v is None or v>=0 for v in sample.get('process_cpu',[])))
  logs=call(home,'logs');record('real-redacted-logs',logs,logs['ok'] and logs['count']>=2)
  export=call(home,'export');record('real-bounded-jsonl-export',export,export['ok'] and export['bytes']<=65536 and export['count']<=500)
  foreign=call(home,'logs','0'*32+':0');record('foreign-boot-cursor-refused',foreign,foreign.get('error')=='invalid_cursor')
  runtime.control.apps.register(AppDescriptor('friday','Friday','sf:house',capabilities=('household.state.read',)))
  runtime.control.apps.observe_verified('friday');runtime.control.apps.observe_capability('friday','household.state.read',True)
  runtime.control.credentials.fixture('demo.provider','Dummy service purpose')
  result=call(home);record('trusted-host-descriptors-without-secret',result,result['has_v2'] and not result['control_error'])
  for _ in range(150):runtime.control.diagnostics.emit('rpc_rejected',code='method_not_authorized',app='tisra',level='warning')
  result=call(home,'more');record('bounded-log-pagination',result,result['logs']==100 and result['logs_after_more']>100 and result['logs_after_more']<=500)
  before=runtime.store.state_counts()
  result=call(home,'export');record('read-controls-never-submit-jobs',result,before==runtime.store.state_counts() and runtime.worker is None)
 finally:
  runtime.shutdown();thread.join(5);assert not thread.is_alive() and not errors,errors
 offline=call(home);record('offline-clears-v2',offline,not offline['ok'] and not offline['has_v2'] and offline['overview_error']=='disconnected')

# Exact old packaged host in an independent temporary root: no production home.
PACKAGE=Path(os.environ.get('ARL_TEST_OLD_PACKAGE',ROOT/'deployment/packages/metadata-only-20260930-final'))/'code'
with tempfile.TemporaryDirectory(prefix='arl-old-',dir='/tmp') as d:
 home=Path(d)
 p=subprocess.Popen([sys.executable,'-B','-m','arl.host','--isolated-test','--home',str(home)],cwd=PACKAGE,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
 try:
  until=time.monotonic()+5
  while not (home/'runtime.sock').exists() and time.monotonic()<until:time.sleep(.02)
  r=call(home);record('immutable-v1-host-fallback',r,r['ok'] and not r['has_v2'] and not r['control_error'])
 finally:p.terminate();p.wait(5)

# Fake RPC server: strict v2 failure must not hide the valid legacy overview.
# Fixtures exported by Swift are not obtained from real/private user data.
fixture=json.loads(Path(os.environ.get('ARL_CONTROL_FIXTURES',ROOT/'control-v2-fixtures.json')).read_text())
for name,mutation in [('invalid-v2-extra',lambda s:s.update(endpoint='synthetic')),('invalid-v2-state',lambda s:s['runtime'].update(state='green'))]:
 with tempfile.TemporaryDirectory(prefix='arl-fv2-',dir='/tmp') as d:
  home=Path(d);srv=socket.socket(socket.AF_UNIX);srv.bind(str(home/'runtime.sock'));srv.listen(5);srv.settimeout(1);captured=[];done=threading.Event()
  def serve():
   while not done.is_set():
    try:c,_=srv.accept()
    except socket.timeout:continue
    except OSError:break
    with c:
     request=b''
     while b'\n' not in request:request+=c.recv(4096)
     q=json.loads(request);captured.append(q['method'])
     payload=copy.deepcopy(fixture['overview'] if q['method']=='overview' else fixture['snapshot'])
     if q['method']!='overview':mutation(payload)
     c.sendall(json.dumps({'protocol':'arl/1','ok':True,'result':payload}).encode()+b'\n')
  th=threading.Thread(target=serve);th.start()
  try:
   r=call(home);record(name,r,r['ok'] and not r['has_v2'] and r['control_error']=='invalid_response' and captured==['overview','settings.snapshot'])
  finally:done.set();srv.close();th.join(2)
Path(os.environ.get('ARL_METADATA_EVIDENCE',ROOT/'control-metadata-integration.json')).write_text(json.dumps({'scope':'copied source + immutable old package, temporary homes only','cases':cases,'count':len(cases),'passed':all(c['passed'] for c in cases),'installed_runtime_touched':False},indent=2)+'\n')
assert all(c['passed'] for c in cases),[c['name'] for c in cases if not c['passed']]
