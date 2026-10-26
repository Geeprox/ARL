"""Read-only Friday snapshot into task-owned candidate. No launch/grant/model/install."""
import hashlib,json,os,shutil,stat
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
FRIDAY=Path(os.environ.get('ARL_FRIDAY_SOURCE',str(ROOT.parent/'Friday')))
DEST=Path(__file__).resolve().parent/'dist/planning-candidate-v2'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()

def stage(dest=DEST):
 if dest.exists():raise ValueError('candidate_exists_stop')
 sources={**{'sdk/arl/'+p.name:p for p in (ROOT/'arl').glob('*.py')},
    'product/homeplane/__init__.py':FRIDAY/'homeplane/__init__.py',
    'product/homeplane/arl.py':FRIDAY/'homeplane/arl.py'}
 before={name:sha(p) for name,p in sources.items()}
 if any(p.is_symlink() or p.stat().st_uid!=os.geteuid() or p.stat().st_mode&0o022 for p in sources.values()):raise ValueError('unsafe_source')
 dest.mkdir(parents=True,mode=0o700)
 try:
  for name,p in sources.items():
   out=dest/name;out.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(p,out);out.chmod(0o600)
  after={name:sha(p) for name,p in sources.items()};copied={name:sha(dest/name) for name in sources}
  if before!=after or copied!=before:raise ValueError('concurrent_source_change')
  shutil.copyfile(ROOT/'integrations/friday/planning_consumer.py',dest/'planning_consumer.py');(dest/'planning_consumer.py').chmod(0o600)
  shutil.copyfile(ROOT/'integrations/friday/planning_host.py',dest/'planning_host.py');(dest/'planning_host.py').chmod(0o600)
  exe=(FRIDAY/'.venv/bin/python3.12').resolve(strict=True)
  manifest={'schema_version':1,'files':copied,'source_set_sha256':hashlib.sha256(json.dumps(copied,sort_keys=True,separators=(',',':')).encode()).hexdigest(),
   'product':'Friday Planning','owner':'friday','product_version':'0.2.0','identity':'host_owned_pid_uid_birth_plus_exact_source_set',
   'python_executable':str(exe),'python_sha256':sha(exe),'entry_sha256':sha(dest/'planning_consumer.py'),'host_sha256':sha(dest/'planning_host.py'),'production_enabled':False,
   'trusted_product_subset':{'homeplane/__init__.py':before['product/homeplane/__init__.py'],'homeplane/arl.py':before['product/homeplane/arl.py']}}
  (dest/'source-manifest.json').write_text(json.dumps(manifest,indent=2,sort_keys=True)+'\n');(dest/'source-manifest.json').chmod(0o600)
  return manifest
 except BaseException:shutil.rmtree(dest);raise

def stage_controlled(dest):
 """Full local actor closure, including existing CPython; no installs/downloads."""
 dest=Path(dest).resolve();m=stage(dest)
 try:
  exe=Path(m['python_executable']);prefix=exe.parent.parent
  proposal=FRIDAY/'docs/evidence/arl-rule-planning-registration-proposal.json'
  closure={'runtime/bin/python3.12':exe}
  for p in sorted((prefix/'lib').rglob('*')):
   relative=p.relative_to(prefix)
   if p.is_file() and 'site-packages' not in relative.parts and '__pycache__' not in relative.parts and p.suffix!='.pyc':closure['runtime/'+str(relative)]=p.resolve(strict=True)
  before={name:sha(p) for name,p in closure.items()};ph=sha(proposal)
  if len(closure)>4096:raise ValueError('runtime_closure_unbounded')
  for name,p in closure.items():
   out=dest/name;out.parent.mkdir(parents=True,exist_ok=True,mode=0o700);shutil.copyfile(p,out);out.chmod(0o700 if name=='runtime/bin/python3.12' else 0o600)
  if {n:sha(p) for n,p in closure.items()}!=before or {n:sha(dest/n) for n in closure}!=before:raise ValueError('concurrent_runtime_change')
  shutil.copyfile(proposal,dest/'registration-proposal.json');(dest/'registration-proposal.json').chmod(0o600)
  if sha(proposal)!=ph or sha(dest/'registration-proposal.json')!=ph:raise ValueError('concurrent_proposal_change')
  loader=ROOT/'integrations/friday/load_sdk.py';lh=sha(loader);shutil.copyfile(loader,dest/'load_sdk.py');(dest/'load_sdk.py').chmod(0o600)
  if sha(loader)!=lh or sha(dest/'load_sdk.py')!=lh:raise ValueError('concurrent_loader_change')
  for n,h in m['files'].items():
   source=ROOT/'arl'/Path(n).name if n.startswith('sdk/arl/') else FRIDAY/'homeplane'/Path(n).name
   if sha(source)!=h or sha(dest/n)!=h:raise ValueError('concurrent_source_change')
  for name,field in [('planning_consumer.py','entry_sha256'),('planning_host.py','host_sha256')]:
   if sha(ROOT/'integrations/friday'/name)!=m[field]:raise ValueError('concurrent_entry_change')
  m.update(schema_version=2,python_executable='runtime/bin/python3.12',runtime_files=before,
    asset_files={'registration-proposal.json':ph,'load_sdk.py':lh},review_binding='Friday review_id/boot_id/backend/approval_digest plus exact immutable SDK request',
    runtime_trust='copied CPython executable, libpython, standard-library code/extensions/data; site disabled; macOS frameworks/system dylibs remain OS trusted base',
    production_enabled=False,source_deployment=False,provider_calls=0)
  payload={**m['files'],**m['runtime_files'],**m['asset_files'],'planning_consumer.py':m['entry_sha256'],'planning_host.py':m['host_sha256']}
  m['sealed_payload_sha256']=hashlib.sha256(json.dumps(payload,sort_keys=True,separators=(',',':')).encode()).hexdigest()
  raw=json.dumps(m,indent=2,sort_keys=True)+'\n';(dest/'source-manifest.json').write_text(raw)
  return m
 except BaseException:shutil.rmtree(dest);raise
if __name__=='__main__':print(json.dumps(stage(),sort_keys=True))
