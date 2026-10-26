"""Fixed host-owned Friday Planning actor; -I, prepared/go, sealed imports only."""
import sys
sys.dont_write_bytecode=True
# CPython -I/-S retains a possibly absent python312.zip search entry. Remove
# it BEFORE any stdlib imports, and use only copied stdlib paths for v2's -S
# actor. Full host validation independently rejects added files at every gate.
sys.path[:]=[path for path in sys.path if not path.lower().endswith('.zip')]
if sys.flags.no_site:
 _root=__file__.rsplit('/',1)[0]
 if sys.executable!=_root+'/runtime/bin/python3.12':raise SystemExit('untrusted_runtime')
 sys.path[:]=[_root+'/runtime/lib/python3.12',_root+'/runtime/lib/python3.12/lib-dynload']
import os,json,stat,hashlib,importlib.abc,importlib.util,asyncio,time
from pathlib import Path
BASE=Path(__file__).resolve().parent

def finite(code):
 allowed={'invalid_manifest','source_changed','review_expired','planning_context_changed','planning_receipt_mismatch','friday_planning_unavailable','unsupported_planning_contract','app_identity_unverified','call_budget_exceeded','planning_job_needs_review','planning_candidate_not_supplied'}
 print(json.dumps({'status':'rejected','code':code if code in allowed else 'planning_unavailable'}),flush=True)
 raise SystemExit(1)
sys.dont_write_bytecode=True
if not sys.flags.isolated:finite('invalid_manifest')
print('prepared',flush=True)
if sys.stdin.readline()!='go\n':raise SystemExit(1)
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
from homeplane.arl import ARLRuntime
from arl.friday_planning_client import ReviewedRemoval,plan_removal
from arl.contracts import Fault
try:
 review=json.loads((BASE/'reviewed-request.json').read_text())
 if manifest.get('schema_version')==2:
  from arl.friday_binding import FridayReviewBinding
  FridayReviewBinding((BASE/'reviewed-request.json').read_text())
 elif set(review)!={'request','model'}:finite('review_expired')
 action=ReviewedRemoval(review['request'],review['model'])
 # File is fixed/pinned by the host as part of LaunchSpec; no runtime config/path
 # or policy comes from a network caller, environment or request body.
 if manifest.get('schema_version')==2:
  from arl.client import Client
  class TrackedClient(Client):
   def rpc(self,method,params=None):
    result=super().rpc(method,params)
    if method=='submit':print(json.dumps({'event':'submitted','job':result}),flush=True)
    return result
  runtime=ARLRuntime(lambda:BASE/'state',client_factory=lambda home,start:TrackedClient(home,'friday'))
 else:runtime=ARLRuntime(lambda:BASE/'state')
 result=asyncio.run(plan_removal(runtime,action,deadline=time.monotonic()+30,
    current_context=lambda:json.loads((BASE/'reviewed-request.json').read_text())['request']['context_fingerprint']))
 print(json.dumps({'status':'advisory_only','result':result}),flush=True)
except Exception as exc:finite(getattr(exc,'code','planning_unavailable'))
