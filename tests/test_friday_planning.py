import asyncio,copy,hashlib,json,tempfile,time,uuid,unittest
from pathlib import Path
from unittest.mock import Mock
from arl.contracts import Fault,AppPolicy,encode
from arl.friday_planning import NAME,FridayRemovalPlanner,checked_request,rendered,checked_proposal
from arl.friday_planning_client import ReviewedRemoval,plan_removal
from tests.test_runtime import RuntimeCase,running

def request():
 now=int(time.time()*1000)
 return {'schema_version':1,'execution_id':str(uuid.uuid4()),'text':'以后回家别自动开空调了','context_fingerprint':'a'*64,
  'captured_at_ms':now,'expires_at_ms':now+50000,'choices':[{'record_id':'simulated:arrival:v1','action_id':'arrival-ac','expected_fingerprint':'b'*64,'rule_label':'回家','action_label':'开空调'}]}
def proposal(req):return dict(schema_version=1,status='proposal',summary='建议移除回家开空调指令',**{k:req['choices'][0][k] for k in ('record_id','action_id','expected_fingerprint')})
def provider(req,simulated=False):
 def run(args,context):
  context.check_cancelled();text=json.dumps(proposal(req),ensure_ascii=False)
  return {'schema_version':1,'format':'codex.appserver.text.v1','provider':'codex_app_server','model':args['model'],
   'text':text,'request_sha256':hashlib.sha256(args['input'].encode()).hexdigest(),'output_sha256':hashlib.sha256(text.encode()).hexdigest(),
   'thread_id':'synthetic-thread','turn_id':'synthetic-turn','simulated':simulated,'token_hard_cap_supported':False,'usage':{'tokens':None,'cost':None}}
 return Mock(run=Mock(side_effect=run))
class Context:
 def __init__(self,req,owner='friday'):self.row={'id':'job-1','owner':owner,'key':req['execution_id']}
 def check_cancelled(self):pass
 def remaining(self,max=30):return max
class FridayPlanningTests(RuntimeCase):
 def setUp(self):super().setUp();self.req=request();self.args={'model':'synthetic-model','request_json':encode(self.req).decode()}
 def test_disabled_and_owner_or_logical_key_do_not_call_provider(self):
  self.assert_fault('friday_planning_disabled',lambda:FridayRemovalPlanner().run(self.args,Context(self.req)))
  p=provider(self.req);a=FridayRemovalPlanner(p)
  self.assert_fault('planning_owner_or_key_mismatch',lambda:a.run(self.args,Context(self.req,'tisra')))
  c=Context(self.req);c.row['key']='different';self.assert_fault('planning_owner_or_key_mismatch',lambda:a.run(self.args,c));p.run.assert_not_called()
 def test_typed_result_is_only_a_supplied_advisory_candidate(self):
  result=FridayRemovalPlanner(provider(self.req)).run(self.args,Context(self.req))
  self.assertFalse(result['action_authority']);self.assertEqual(result['proposal'],proposal(self.req));self.assertEqual(result['usage'],{'tokens':None,'cost':None})
 def test_strict_input_no_endpoint_ha_calls_or_silent_truncation(self):
  for change in ({'ha_url':'private'},{'choices':[]},{'captured_at_ms':True},{'schema_version':True},{'expires_at_ms':int(time.time()*1000)-1}):
   with self.assertRaises(Fault):checked_request(encode(dict(self.req,**change)).decode())
  with self.assertRaises(Fault):checked_request('{"schema_version":1,"schema_version":1}')
  big=copy.deepcopy(self.req);big['choices']=[dict(big['choices'][0],action_id=str(i),rule_label='中'*120,action_label='中'*120) for i in range(16)]
  self.assert_fault('planning_context_overflow',lambda:checked_request(encode(big).decode()))
 def test_proposal_unknown_identifier_write_instructions_and_extra_fields_reject(self):
  for change in ({'action_id':'invented'},{'service':'light.turn_off'},{'schema_version':True},{'status':'executed'},{'summary':'\n'}):
   with self.assertRaises(Fault):checked_proposal(dict(proposal(self.req),**change),self.req)
  clarify=dict(proposal(self.req),status='clarification',record_id=None,action_id=None,expected_fingerprint=None)
  self.assertEqual(checked_proposal(clarify,self.req),clarify)
 def test_provider_hash_model_format_drift_and_late_expiry_reject(self):
  for field,value in [('format','openai.responses.v1'),('request_sha256','f'*64),('model','other'),('usage',{'tokens':4096,'cost':0}),('simulated',None)]:
   p=provider(self.req);old=p.run.side_effect;p.run.side_effect=lambda args,context,f=field,v=value:dict(old(args,context),**{f:v})
   self.assert_fault('planning_provider_contract_mismatch',lambda:FridayRemovalPlanner(p).run(self.args,Context(self.req)))
  now=[self.req['captured_at_ms']];p=provider(self.req);old=p.run.side_effect
  def late(args,c):r=old(args,c);now[0]=self.req['expires_at_ms'];return r
  p.run.side_effect=late;self.assert_fault('planning_context_expired',lambda:FridayRemovalPlanner(p,clock=lambda:now[0]).run(self.args,Context(self.req)))
 def test_real_queue_budget_identity_owner_and_dedupe(self):
  p=provider(self.req);policy=AppPolicy(frozenset({NAME}),frozenset(),0,1,1)
  with running(self.home,policies={'friday':policy,'tisra':AppPolicy(frozenset(),frozenset(),0,0,0,methods=frozenset({'health','ready','get'}),public_metadata=True)},extra_tools=[FridayRemovalPlanner(p).tool()],identity_verifier=lambda c,a:a if a in {'friday','tisra'} else None) as (r,unused):
   from arl.client import Client
   c=Client(self.home,'friday')
   self.assert_fault('app_identity_unverified',lambda:r.dispatch({'protocol':'arl/1','app':'friday','method':'submit','params':{'tool':NAME,'args':self.args,'key':self.req['execution_id']}}))
   first=c.submit(NAME,self.args,self.req['execution_id']);self.assertEqual(c.wait(first['id'])['state'],'succeeded')
   self.assertEqual(c.submit(NAME,self.args,self.req['execution_id'])['id'],first['id']);self.assertEqual(p.run.call_count,1)
   from arl.client import Client
   self.assert_fault('job_not_found',lambda:Client(self.home,'tisra').rpc('get',{'id':first['id']}))
   next_request=dict(self.req,execution_id=str(uuid.uuid4()))
   self.assert_fault('call_budget_exceeded',lambda:c.submit(NAME,{'model':'synthetic-model','request_json':encode(next_request).decode()},next_request['execution_id']))
class FridayPlanningClientTests(unittest.TestCase):
 def setUp(self):self.req=request();self.action=ReviewedRemoval(self.req,'synthetic-model')
 def client_fixture(self,change=None):
  import threading
  from arl.friday_planning import SCHEMA,PERMISSIONS
  result=FridayRemovalPlanner(provider(self.req)).run(self.action.args(),Context(self.req))
  if change:result.update(change)
  job={'id':'job-1','tool':NAME,'state':'succeeded','result':result}
  client=Mock()
  def rpc(method,params=None):
   if method=='capabilities':return {'protocol':'arl/1','version':1,'tools':[FridayRemovalPlanner(provider(self.req)).tool().descriptor()]}
   if method=='submit':return job
   if method=='cancel':return job
  client.rpc.side_effect=rpc
  runtime=Mock();runtime.home.return_value=Path('/tmp/unused-friday-home');runtime.client_factory.return_value=client
  async def bounded(work,timeout):return work(threading.Event())
  runtime._bounded=bounded
  return runtime,client,job
 def call(self,r,current=None):return asyncio.run(plan_removal(r,self.action,deadline=time.monotonic()+3,current_context=current or (lambda:self.req['context_fingerprint'])))
 def test_consumer_receipt_and_candidate_no_device_authority(self):
  r,c,j=self.client_fixture();self.assertEqual(self.call(r)['proposal'],proposal(self.req));self.assertFalse(any(x.args[0]=='cancel' for x in c.rpc.call_args_list))
 def test_context_change_no_submit_and_lost_submit_no_resend(self):
  r,c,j=self.client_fixture()
  with self.assertRaises(Fault):self.call(r,lambda:'f'*64)
  self.assertFalse(c.rpc.called)
  r,c,j=self.client_fixture();old=c.rpc.side_effect
  def lost(m,p=None):
   if m=='submit':raise Fault('disconnected')
   return old(m,p)
  c.rpc.side_effect=lost
  with self.assertRaises(Fault):self.call(r)
  self.assertEqual(sum(x.args[0]=='submit' for x in c.rpc.call_args_list),1)
 def test_mock_and_stale_mismatched_receipts_are_not_live_candidates(self):
  for change in ({'simulated':True},{'execution_id':str(uuid.uuid4())},{'request_sha256':'b'*64},{'action_authority':True},{'context_fingerprint':'f'*64}):
   r,c,j=self.client_fixture(change)
   with self.assertRaises(Fault):self.call(r)
   self.assertTrue(any(x.args[0]=='cancel' for x in c.rpc.call_args_list))
  r,c,j=self.client_fixture({'owner':'tisra'})
  with self.assertRaises(Fault):self.call(r)
class ControlledFridayPlanningTests(unittest.TestCase):
 def test_reviewed_payload_snapshot_not_mutable_claim(self):
  from dataclasses import FrozenInstanceError
  req=request();a=ReviewedRemoval(req,'synthetic-model');req['text']='changed'
  self.assertNotEqual(a.request['text'],req['text']);copy=a.request;copy['choices'].clear();self.assertEqual(len(a.request['choices']),1)
  with self.assertRaises(FrozenInstanceError):a.model='other'
 def test_actual_friday_sdk_sealed_process_identity_roundtrip_default_disabled_and_drift(self):
  import threading
  from integrations.friday.prepare_planning_candidate import stage
  from arl.friday_profile import compose_isolated,planning_spec,MODEL
  with tempfile.TemporaryDirectory(prefix='fp-',dir='/tmp') as tmp:
   candidate=Path(tmp).resolve()/'c';stage(candidate);req=request()
   review=candidate/'reviewed-request.json';review.write_text(json.dumps({'request':req,'model':MODEL}));review.chmod(0o600)
   manifest=candidate/'source-manifest.json';mh=hashlib.sha256(manifest.read_bytes()).hexdigest();rh=hashlib.sha256(review.read_bytes()).hexdigest()
   import subprocess
   checked=subprocess.run([__import__('sys').executable,'-I',str(candidate/'planning_host.py'),'--validate-only','--manifest-sha256',mh,'--approved-review-sha256',rh],capture_output=True,timeout=3)
   self.assertEqual(json.loads(checked.stdout)['status'],'source_and_review_verified');self.assertEqual(json.loads(checked.stdout)['calls_started'],0)
   disabled,unused=compose_isolated(candidate,mh,rh);self.assertFalse(disabled.execute_jobs);self.assertFalse(disabled.policies['friday'].tools);unused.close()
   p=provider(req,simulated=False);runtime,supervisor=compose_isolated(candidate,mh,rh,adapter=p)
   errors=[]
   def serve():
    try:runtime.run()
    except Exception as e:errors.append(e)
   thread=threading.Thread(target=serve);thread.start()
   try:
    self.assertTrue(runtime.ready.wait(3));child=supervisor.launch('friday');out,_=child.communicate(timeout=8)
    result=json.loads(out);self.assertEqual(result['status'],'advisory_only',result);self.assertFalse(result['result']['action_authority']);self.assertEqual(p.run.call_count,1)
    self.assertEqual(runtime.store.db.execute('SELECT calls FROM budget WHERE owner=?',('friday',)).fetchone()[0],1)
    # A process claiming Friday after the registered child has exited is rejected.
    from arl.client import Client
    with self.assertRaises(Fault):Client(candidate/'state','friday').rpc('capabilities')
    source=candidate/'product/homeplane/arl.py';source.write_text(source.read_text()+'\n# source drift\n')
    with self.assertRaises(Fault):supervisor.launch('friday')
   finally:supervisor.close();runtime.shutdown();thread.join(8)
   self.assertFalse(errors,errors);self.assertFalse(thread.is_alive())
