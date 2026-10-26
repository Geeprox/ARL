"""Friday-consumable composition over its existing ARLRuntime._bounded gate.

No direct provider, second queue, device interface, enrollment or launcher.
"""
import hashlib,json,time
from dataclasses import dataclass
from .contracts import Fault,validate,encode
from .friday_planning import NAME,FORMAT,SCHEMA,PERMISSIONS,checked_request,checked_proposal
TERMINAL={'succeeded','failed','cancelled','needs_review','needs_unlock'}
@dataclass(frozen=True,init=False)
class ReviewedRemoval:
 raw:str
 model:str
 digest:str
 execution_id:str
 @property
 def request(self):return json.loads(self.raw)
 def __init__(self,request,model):
  # The product must create this AFTER explicit content review, never typing.
  raw=json.dumps(request,ensure_ascii=False,sort_keys=True,allow_nan=False)
  checked_request(raw)
  object.__setattr__(self,'raw',raw);object.__setattr__(self,'model',model)
  validate({'model':model,'request_json':self.raw},SCHEMA)
  object.__setattr__(self,'digest',hashlib.sha256(raw.encode()).hexdigest())
  object.__setattr__(self,'execution_id',self.request['execution_id'])
 def args(self):return {'model':self.model,'request_json':self.raw}

async def plan_removal(runtime,reviewed,*,deadline,current_context,scheduling=None):
 """current_context is Friday's local fingerprint, never a model claim.

 Sharing runtime._bounded keeps status/probe/planning on its existing single-flight
 gate. No lost-submit resubmission; unresolved jobs are not resumed after restart.
 """
 if type(reviewed)!=ReviewedRemoval or not callable(current_context):raise Fault('reviewed_planning_required')
 if scheduling is not None:
  from .priority import validate_request
  validate_request(scheduling)
  scheduling=json.loads(encode(scheduling))
  if scheduling['deadline_at_ms']>reviewed.request['expires_at_ms']:raise Fault('invalid_deadline')
 if not 0<deadline-time.monotonic()<=30:raise Fault('invalid_deadline')
 home=runtime.home()
 def work(stop):
  nonlocal scheduling
  client=runtime.client_factory(home,False);job_id=None;complete=False
  def check():
   if stop.is_set() or time.monotonic()>=deadline:raise Fault('planning_cancelled_or_expired')
   if home!=runtime.home() or current_context()!=reviewed.request['context_fingerprint']:raise Fault('planning_context_changed')
   checked_request(reviewed.raw)
  try:
   check();client.connect(timeout=min(2,deadline-time.monotonic()));check()
   caps=client.rpc('capabilities')
   if caps.get('protocol')!='arl/1' or caps.get('version')!=1:raise Fault('unsupported_planning_contract')
   descriptors=[d for d in caps.get('tools',[]) if d.get('name')==NAME]
   if len(descriptors)!=1:raise Fault('friday_planning_unavailable')
   tool=descriptors[0]
   if type(tool.get('version'))!=int or tool.get('version')!=1 or tool.get('inputSchema')!=SCHEMA or tuple(tool.get('permissions',[]))!=PERMISSIONS or tool.get('idempotent') is not False or tool.get('availability')!='adapter':raise Fault('unsupported_planning_contract')
   check()
   if scheduling is None and tool.get('priority_required') is True:
    from .client import Client
    from .priority import validate_profile_v2
    profile=client.rpc('priority.negotiate.v2',{'requested_profile':{'classes':['background','interactive']}})
    validate_profile_v2(profile);check()
    rows=[row for row in profile['task_bindings'] if row['submit_method']=='priority.submit.v1' and
          row['tool']==NAME and row['route']=={'provider':'codex_app_server','model':reviewed.model,'model_fingerprint':None}]
    if len(rows)!=1:raise Fault('priority_route_binding_unavailable')
    row=rows[0];wall_now_ms=int(time.time()*1000)
    remaining_ms=int((deadline-time.monotonic())*1000)
    budget=min(remaining_ms,reviewed.request['expires_at_ms']-wall_now_ms,
               profile['limits']['max_deadline_ms'],30000)
    if budget<=row['execution_budget_ms']+100:raise Fault('planning_cancelled_or_expired')
    requested='interactive' if 'interactive' in row['allowed_classes'] else 'background'
    scheduling=Client.priority_request_v2(profile,submit_method='priority.submit.v1',tool=NAME,
      task_kind=row['task_kind'],requested_class=requested,deadline_at_ms=wall_now_ms+budget,
      estimate_ms=row['estimate_floor_ms'],provider='codex_app_server',model=reviewed.model)
    check()
   if scheduling is None:
    job=client.rpc('submit',{'tool':NAME,'args':reviewed.args(),'key':reviewed.execution_id})
   else:
    from .priority import validate_acceptance
    job=client.rpc('priority.submit.v1',{'tool':NAME,'args':reviewed.args(),'key':reviewed.execution_id,'scheduling':scheduling})
    validate_acceptance(scheduling,job.get('scheduling'))
   job_id=job['id']
   first_request=encode(scheduling) if scheduling is not None else None
   first_facts=encode(job['scheduling']) if scheduling is not None else None
   def check_receipt(value):
    if value.get('id')!=job_id or value.get('tool')!=NAME:raise Fault('planning_receipt_mismatch')
    if scheduling is not None:
     if encode(scheduling)!=first_request:raise Fault('planning_receipt_mismatch')
     validate_acceptance(scheduling,value.get('scheduling'))
     if encode(value['scheduling'])!=first_facts:raise Fault('planning_receipt_mismatch')
   check_receipt(job)
   while job['state'] not in TERMINAL:
    check();job=client.rpc('get',{'id':job_id});check_receipt(job);stop.wait(.02)
   check()
   if job['state']!='succeeded':raise Fault('planning_job_'+job['state'])
   # arl/1 generic job projection does not expose owner/key/args. The new
   # typed tool result carries actual owner/job/run/hash; do not invent fields.
   if job.get('id')!=job_id or job.get('tool')!=NAME:raise Fault('planning_receipt_mismatch')
   result=job.get('result')
   if (type(result)!=dict or type(result.get('schema_version'))!=int or result.get('schema_version')!=1 or result.get('format')!=FORMAT
       or result.get('owner')!='friday' or result.get('job_id')!=job_id
       or result.get('execution_id')!=reviewed.execution_id or result.get('context_fingerprint')!=current_context()
       or result.get('request_sha256')!=reviewed.digest or result.get('model')!=reviewed.model
       or result.get('provider')!='codex_app_server' or result.get('action_authority') is not False
       or result.get('simulated') is not False or result.get('expires_at_ms')!=reviewed.request['expires_at_ms']):raise Fault('planning_receipt_mismatch')
   checked_proposal(result['proposal'],reviewed.request);check();complete=True;return result
  finally:
   if job_id and not complete:
    try:client.rpc('cancel',{'id':job_id})
    except Exception:pass
 return await runtime._bounded(work,min(30,deadline-time.monotonic()))
