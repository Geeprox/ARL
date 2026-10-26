"""Fixed foreground proposal host. Default disabled; never installed/started here."""
import sys
sys.dont_write_bytecode=True
sys.path[:]=[path for path in sys.path if not path.lower().endswith('.zip')]
if sys.flags.no_site:
 _root=__file__.rsplit('/',1)[0]
 if sys.executable!=_root+'/runtime/bin/python3.12':raise SystemExit('untrusted_runtime')
 sys.path[:]=[_root+'/runtime/lib/python3.12',_root+'/runtime/lib/python3.12/lib-dynload']
import os,json,stat,hashlib,importlib.abc,importlib.util,asyncio,time,threading,argparse
from pathlib import Path
sys.dont_write_bytecode=True
BASE=Path(__file__).resolve().parent
if not sys.flags.isolated:raise SystemExit('isolated_launcher_required')
p=argparse.ArgumentParser();p.add_argument('--manifest-sha256');p.add_argument('--approved-review-sha256');p.add_argument('--validate-only',action='store_true');args=p.parse_args()
if not args.manifest_sha256 or not args.approved_review_sha256:
 print(json.dumps({'status':'disabled','execution_grants':False}));raise SystemExit(0)
def finite(code):
 print(json.dumps({'status':'rejected','code':code if code in {'source_changed','invalid_manifest','planning_profile_changed'} else 'planning_unavailable'}),flush=True);raise SystemExit(1)
if hashlib.sha256((BASE/'source-manifest.json').read_bytes()).hexdigest()!=args.manifest_sha256:finite('invalid_manifest')
manifest=json.loads((BASE/'source-manifest.json').read_text());sealed={}
if manifest.get('schema_version')==2 and not sys.flags.no_site:finite('invalid_manifest')
for name,digest in manifest['files'].items():
 if name.startswith('sdk/arl/') and name.endswith('.py'):
  module='arl' if name=='sdk/arl/__init__.py' else 'arl.'+Path(name).stem
 elif name in {'product/homeplane/__init__.py','product/homeplane/arl.py'}:
  module='homeplane' if name.endswith('__init__.py') else 'homeplane.arl'
 else:finite('invalid_manifest')
 path=BASE/name;info=path.lstat()
 if path.is_symlink() or not stat.S_ISREG(info.st_mode) or info.st_uid!=os.geteuid() or info.st_mode&0o022:finite('source_changed')
 raw=path.read_bytes()
 if hashlib.sha256(raw).hexdigest()!=digest:finite('source_changed')
 sealed[module]=(raw,path)
class Loader(importlib.abc.MetaPathFinder,importlib.abc.Loader):
 def find_spec(self,name,path=None,target=None):
  if name in sealed:return importlib.util.spec_from_loader(name,self,is_package=name in {'arl','homeplane'})
 def create_module(self,spec):return None
 def exec_module(self,module):
  raw,path=sealed[module.__name__];module.__file__=str(path)
  if module.__name__ in {'arl','homeplane'}:module.__path__=[]
  exec(compile(raw,'sealed/'+module.__name__,'exec'),module.__dict__)
sys.meta_path.insert(0,Loader());sys.dont_write_bytecode=True
from arl.friday_profile import planning_spec,compose_isolated
from arl.codex_server import CodexTextAdapter,DEFAULT_BINARY
from arl.contracts import Fault
try:
 spec,request=planning_spec(BASE,args.manifest_sha256,args.approved_review_sha256)
 if args.validate_only:
  print(json.dumps({'status':'source_and_review_verified','calls_started':0,'execution_grants':False}));raise SystemExit(0)
 # This exact operator argv requires separate permission. No RPC, environment,
 # timer or default installation invokes it or resets its persistent call budget.
 adapter=CodexTextAdapter(enabled=True)
 if adapter.pin!='ccd1b9441d35ce30102059c78514a125d676e6765ea1d001033e8cbe88718314':raise Fault('provider_binary_changed')
 if manifest.get('schema_version')==2:
  import signal
  from arl.friday_actor_host import execute
  cancel=threading.Event()
  signal.signal(signal.SIGINT,lambda *_:cancel.set());signal.signal(signal.SIGTERM,lambda *_:cancel.set())
  result=execute(BASE,args.manifest_sha256,args.approved_review_sha256,adapter=adapter,
   on_event=lambda event:print(json.dumps(event),flush=True),cancel=cancel)
  print(json.dumps(result),flush=True);raise SystemExit(0)
 runtime,supervisor=compose_isolated(BASE,args.manifest_sha256,args.approved_review_sha256,adapter=adapter)
 errors=[]
 def serve():
  try:runtime.run()
  except Exception:errors.append('planning_host_failed')
 thread=threading.Thread(target=serve);thread.start()
 try:
  if not runtime.ready.wait(3) or errors:raise Fault('planning_host_failed')
  child=supervisor.launch('friday');out,_=child.communicate(timeout=35)
  if child.returncode or len(out.encode())>16384:raise Fault('planning_outcome_unknown')
  result=json.loads(out)
  # This advisory pipe receipt is not a device/rule effect or cloud sync receipt.
  print(json.dumps(result),flush=True)
 finally:
  supervisor.close();runtime.shutdown();thread.join(5)
except Fault as exc:
 allowed={'planning_profile_changed','planning_context_expired','provider_binary_changed','call_budget_exceeded','planning_outcome_unknown'}
 print(json.dumps({'status':'rejected','code':exc.code if exc.code in allowed else 'planning_unavailable'}));raise SystemExit(1)
except Exception:
 print(json.dumps({'status':'rejected','code':'planning_outcome_unknown'}));raise SystemExit(1)
