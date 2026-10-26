"""Host-only bounded Friday Planning profile; not used by installed metadata host."""
import hashlib,json,os,stat
from pathlib import Path
from .contracts import AppPolicy,Fault,encode
from .friday_planning import NAME,FridayRemovalPlanner,checked_request
from .supervisor import LaunchSpec
from .identity import RegisteredPeerVerifier
from .supervisor import ControlledSupervisor
from .service import Runtime
from .control import AppDescriptor
from .providers import MockProvider
class NoExternalTools:
 transport=None
 def tools(self):return []
MODEL='gpt-6.1-sol'

def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def planning_spec(candidate,manifest_sha,review_sha):
 candidate=Path(candidate).resolve(strict=True)
 manifest_path=candidate/'source-manifest.json';review_path=candidate/'reviewed-request.json'
 if sha(manifest_path)!=manifest_sha or sha(review_path)!=review_sha:raise Fault('planning_profile_changed')
 m=json.loads(manifest_path.read_bytes());review=json.loads(review_path.read_bytes())
 if m.get('owner')!='friday' or m.get('production_enabled') is not False or review.get('model')!=MODEL:raise Fault('invalid_planning_profile')
 if m.get('schema_version')==2:
  from .friday_binding import FridayReviewBinding
  FridayReviewBinding(review_path.read_text())
 elif set(review)!={'request','model'}:raise Fault('invalid_planning_profile')
 req=checked_request(encode(review['request']).decode())
 paths=[manifest_path,review_path,candidate/'planning_consumer.py',candidate/'planning_host.py']
 for name,digest in m['files'].items():
  if not ((name.startswith('sdk/arl/') and Path(name).suffix=='.py' and len(Path(name).parts)==3)
          or name in {'product/homeplane/__init__.py','product/homeplane/arl.py'}):raise Fault('invalid_planning_profile')
  p=candidate/name
  if sha(p)!=digest:raise Fault('launch_source_changed')
  paths.append(p)
 actual={str(p.relative_to(candidate)) for p in candidate.rglob('*') if p.is_file() and p.relative_to(candidate).parts[0]!='state'}
 if any(p.is_symlink() for p in candidate.rglob('*')):raise Fault('unsafe_planning_profile')
 assets=m.get('asset_files',{}) if m.get('schema_version')==2 else {}
 if set(assets)-{'registration-proposal.json','load_sdk.py'}:raise Fault('invalid_planning_profile')
 for name,digest in assets.items():
  p=candidate/name
  if sha(p)!=digest:raise Fault('launch_source_changed')
  paths.append(p)
 runtime_files=m.get('runtime_files',{}) if m.get('schema_version')==2 else {}
 if len(runtime_files)>4096:raise Fault('invalid_planning_profile')
 for name,digest in runtime_files.items():
  parts=Path(name).parts
  if '..' in parts or not (name=='runtime/bin/python3.12' or name.startswith('runtime/lib/')) or 'site-packages' in parts or '__pycache__' in parts:raise Fault('invalid_planning_profile')
  p=candidate/name
  if sha(p)!=digest:raise Fault('launch_source_changed')
  paths.append(p)
 expected=set(m['files'])|set(assets)|set(runtime_files)|{'planning_consumer.py','planning_host.py','source-manifest.json','reviewed-request.json'}
 if actual!=expected:raise Fault('planning_profile_changed')
 for p in paths:
  s=p.lstat()
  if p.is_symlink() or not stat.S_ISREG(s.st_mode) or s.st_uid!=os.geteuid() or s.st_mode&0o022:raise Fault('unsafe_planning_profile')
 if sha(candidate/'planning_host.py')!=m['host_sha256']:raise Fault('launch_source_changed')
 if sha(candidate/'planning_consumer.py')!=m['entry_sha256']:raise Fault('launch_source_changed')
 if m.get('schema_version')==2:
  payload={**m['files'],**runtime_files,**assets,'planning_consumer.py':m['entry_sha256'],'planning_host.py':m['host_sha256']}
  if hashlib.sha256(json.dumps(payload,sort_keys=True,separators=(',',':')).encode()).hexdigest()!=m.get('sealed_payload_sha256'):raise Fault('planning_profile_changed')
 if m.get('schema_version')==2:
  if m.get('python_executable')!='runtime/bin/python3.12':raise Fault('invalid_planning_profile')
  exe=candidate/m['python_executable']
 else:exe=Path(m['python_executable'])
 if exe.is_symlink() or sha(exe)!=m['python_sha256']:raise Fault('launch_source_changed')
 paths.append(exe)
 flags=('-I','-S','-B') if m.get('schema_version')==2 else ('-I',)
 spec=LaunchSpec('friday',exe,(*flags,str(candidate/'planning_consumer.py')),candidate,
     tuple((p,sha(p)) for p in paths),closure_root=candidate if m.get('schema_version')==2 else None,
     closure_mutable_directory='state' if m.get('schema_version')==2 else None)
 spec.validate()
 return spec,req

class PlanningAdmission:
 def __init__(self,request):
  self.args={'model':MODEL,'request_json':encode(request).decode()}
 def __call__(self,owner,name,args):
  if name!=NAME:return
  if owner!='friday' or args!=self.args:raise Fault('planning_review_not_authorized')
  checked_request(args['request_json'])

def compose_isolated(candidate,manifest_sha,review_sha,*,adapter=None,priority_config=None):
 """Source integration only. Default has no task grants/worker; no CLI/env switch.

 Real host enablement requires a reviewed fixed host composition and permission,
 not a public profile argument or a claim that this constructor deployed it.
 """
 spec,request=planning_spec(candidate,manifest_sha,review_sha)
 verifier=RegisteredPeerVerifier({'friday'})
 enabled=adapter is not None
 policies={'settings':AppPolicy(frozenset(),frozenset(),0,0,0,methods=frozenset({'health','ready'}),public_metadata=True),
  'friday':AppPolicy(frozenset({NAME}) if enabled else frozenset(),frozenset(),0,1 if enabled else 0,1 if enabled else 0,
   methods=frozenset({'health','ready','capabilities','submit','get','cancel'}) if enabled else frozenset(),
   priority_bands=frozenset({'explicit'}),default_priority='explicit',max_deadline_ms=30000)}
 planner=FridayRemovalPlanner(adapter)
 runtime=Runtime(Path(candidate)/'state',policies=policies,extra_tools=[planner.tool()],
  identity_verifier=lambda c,a:supervisor.peer_verifier(c,a),admission=PlanningAdmission(request),execute_jobs=enabled,
  local_enabled=False,providers={'mock':MockProvider()},apple=NoExternalTools(),travel=NoExternalTools())
 descriptor=AppDescriptor('friday','Friday Planning','sf:house','0.2.0',(NAME,))
 supervisor=ControlledSupervisor([spec],verifier,control=runtime.control,descriptors=[descriptor])
 if priority_config is not None:
  from .priority_host import RegisteredRouteProducer
  producer=RegisteredRouteProducer(runtime,verifier,priority_config)
  if enabled:
   tasks=[t for t in priority_config.tasks if t.tool==NAME and ('friday' in t.owners or '*' in t.owners)]
   if len(tasks)!=1:raise Fault('priority_route_binding_unavailable')
   producer.register_planner(planner,task_kind=tasks[0].task_kind,
       resource_kind=tasks[0].resource_kind,backend='codex_app_server')
 return runtime,supervisor
