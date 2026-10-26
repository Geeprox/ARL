"""Owner loads sealed SDK under a private namespace; never rewrites live arl."""
import hashlib,importlib.abc,importlib.util,json,os,stat,sys
from pathlib import Path
def load_client_module(candidate,expected_manifest):
 root=Path(candidate).resolve(strict=True);manifest=root/'source-manifest.json'
 sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
 if sha(manifest)!=expected_manifest:raise ValueError('invalid_manifest')
 m=json.loads(manifest.read_bytes())
 if m.get('schema_version')!=2 or m.get('owner')!='friday' or m.get('production_enabled') is not False:raise ValueError('invalid_manifest')
 files={**m['files'],**m['runtime_files'],**m['asset_files'],'planning_consumer.py':m['entry_sha256'],'planning_host.py':m['host_sha256']}
 actual={str(p.relative_to(root)) for p in root.rglob('*') if p.is_file() and 'state' not in p.relative_to(root).parts}
 if actual-set(['source-manifest.json','reviewed-request.json'])!=set(files) or any(p.is_symlink() for p in root.rglob('*')):raise ValueError('source_changed')
 for n,h in files.items():
  if Path(n).is_absolute() or '..' in Path(n).parts:raise ValueError('invalid_manifest')
  p=root/n;s=p.lstat()
  if not stat.S_ISREG(s.st_mode) or s.st_uid!=os.geteuid() or s.st_mode&0o022 or sha(p)!=h:raise ValueError('source_changed')
 prefix='_friday_actor_'+expected_manifest;sealed={}
 for n,h in m['files'].items():
  if n.startswith('sdk/arl/') and len(Path(n).parts)==3 and n.endswith('.py'):
   module=prefix if n.endswith('/__init__.py') else prefix+'.'+Path(n).stem
   raw=(root/n).read_bytes()
   if hashlib.sha256(raw).hexdigest()!=h:raise ValueError('source_changed')
   sealed[module]=(raw,root/n)
 class Loader(importlib.abc.MetaPathFinder,importlib.abc.Loader):
  def find_spec(self,name,path=None,target=None):
   if name in sealed:return importlib.util.spec_from_loader(name,self,is_package=name==prefix)
  def create_module(self,spec):return None
  def exec_module(self,module):
   raw,path=sealed[module.__name__];module.__file__=str(path)
   if module.__name__==prefix:module.__path__=[]
   exec(compile(raw,'sealed/'+module.__name__,'exec'),module.__dict__)
 if any(name==prefix or name.startswith(prefix+'.') for name in sys.modules):raise ValueError('sdk_namespace_already_loaded')
 sys.meta_path.insert(0,Loader())
 return __import__(prefix+'.friday_actor_client',fromlist=['ReviewedActorFactory'])
