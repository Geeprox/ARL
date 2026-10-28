import hashlib,time,sys
from pathlib import Path
from unittest.mock import Mock, patch
from arl.codex_server import CodexTextAdapter,NAME,Session
from arl.contracts import AppPolicy,Fault,Cancelled
from tests.test_runtime import RuntimeCase,running
ARGS={'model':'synthetic-model','input':'synthetic nonsensitive input','max_output_bytes':128}
FIXTURE=Path(__file__).resolve().parents[1]/'integrations/codex/fake_server.py'
class Context:
 def __init__(self,timeout=2,cancel_after=None):self.end=time.monotonic()+timeout;self.cancel_at=time.monotonic()+cancel_after if cancel_after else None
 def check_cancelled(self):
  if self.cancel_at and time.monotonic()>=self.cancel_at:raise Cancelled()
 def remaining(self,maximum=30):return min(maximum,max(.01,self.end-time.monotonic()))
class CodexTests(RuntimeCase):
 def adapter(self,mode='ok',enabled=True):return CodexTextAdapter(enabled=enabled,test_command=[sys.executable,'-I',str(FIXTURE),mode])
 def test_default_disabled_without_process_or_paid_fallback(self):
  self.assert_fault('paid_provider_disabled',lambda:self.adapter(enabled=False).run(ARGS,Context()))
 def test_real_fixture_process_typed_response_hash_and_format(self):
  d=self.adapter().run(ARGS,Context());self.assertEqual(d['text'],'synthetic plan');self.assertEqual(d['request_sha256'],hashlib.sha256(ARGS['input'].encode()).hexdigest());self.assertTrue(d['simulated']);self.assertFalse(d['token_hard_cap_supported']);self.assertEqual(d['format'],'codex.appserver.text.v1');self.assertIsNone(d['usage']['tokens'])
 def test_unknown_fields_raw_responses_envelope_overflow_and_action_rejected(self):
  self.assert_fault('invalid_arguments',lambda:self.adapter().run(dict(ARGS,request_format='openai.responses.v1'),Context()))
  self.assert_fault('model_budget_exceeded',lambda:self.adapter().run(dict(ARGS,input='中'*3000),Context()))
  for mode,code in [('mismatch','provider_contract_mismatch'),('large','invalid_provider_response'),('extra','invalid_provider_response'),('action','provider_action_rejected')]:
   self.assert_fault(code,lambda:self.adapter(mode).run(ARGS,Context()))
 def test_deadline_and_cancel_bound_nonpreemptible_upstream_no_replay_claim(self):
  start=time.monotonic();self.assert_fault('provider_deadline_exceeded',lambda:self.adapter('wait').run(ARGS,Context(.15)));self.assertLess(time.monotonic()-start,2)
  self.assert_fault('cancelled',lambda:self.adapter('wait').run(ARGS,Context(2,.15)))
 def test_actual_arl_to_fixture_scope_and_uncertain_cancellation(self):
  adapter=self.adapter();policies={'tisra':AppPolicy(frozenset({NAME}),frozenset(),0,1,2)}
  with running(self.home,policies=policies,extra_tools=[adapter.tool()],identity_verifier=lambda c,a:'tisra' if a=='tisra' else None) as (r,c):
   self.assert_fault('app_identity_unverified',lambda:r.dispatch({'protocol':'arl/1','app':'tisra','method':'submit','params':{'tool':NAME,'args':ARGS,'key':'same'}}))
   job=c.submit(NAME,ARGS,'same');d=c.wait(job['id']);self.assertEqual(d['result']['text'],'synthetic plan')
   self.assertEqual(c.submit(NAME,ARGS,'same')['id'],job['id'])
 def test_verified_user_message_completion_is_receipt_not_tool_action(self):
  self.assertEqual(self.adapter('user_receipt').run(ARGS,Context())['text'],'synthetic plan')
  self.assert_fault('provider_contract_mismatch',lambda:self.adapter('bad_user_receipt').run(ARGS,Context()))
 def test_rejection_diagnostics_are_finite_and_cancel_is_sent(self):
  events=[];adapter=CodexTextAdapter(enabled=True,test_command=[sys.executable,'-I',str(FIXTURE),'action'],observer=lambda e:events.append(e))
  self.assert_fault('provider_action_rejected',lambda:adapter.run(ARGS,Context()))
  self.assertIn({'event':'server_request_rejected','category':'approval'},events)
  self.assertTrue(any(e['event']=='interrupt_sent' and e['request_sent'] for e in events))
  self.assertFalse(any('params' in e or 'input' in e or 'text' in e for e in events))
 def test_success_has_no_interrupt(self):
  events=[];a=CodexTextAdapter(enabled=True,test_command=[sys.executable,'-I',str(FIXTURE),'ok'],observer=events.append)
  self.assertEqual(a.run(ARGS,Context())['text'],'synthetic plan')
  self.assertFalse(any(e['event'].startswith('interrupt') for e in events))
 def test_active_cancel_ack_and_terminal_are_separate_and_strict(self):
  for mode,terminal in [('wait_interrupt',True),('wait_ack_only',False),('wait_wrong_terminal',False)]:
   events=[];context=Context(.8)
   def observe(event):
    events.append(event)
    if event['event']=='turn_started':context.cancel_at=time.monotonic()-.001
   a=CodexTextAdapter(enabled=True,test_command=[sys.executable,'-I',str(FIXTURE),mode],observer=observe)
   self.assert_fault('cancelled',lambda:a.run(ARGS,context))
   self.assertEqual(sum(e['event']=='interrupt_sent' for e in events),1)
   self.assertTrue(any(e['event']=='interrupt_ack' for e in events))
   self.assertEqual(any(e['event']=='cancel_terminal' and e['status']=='interrupted' for e in events),terminal)


class ScopedCodexServiceTests(RuntimeCase):
 def make_route(self, mode='ok', calls=1, observer=None):
  from arl.codex_server import CodexService
  from arl.compat_host import compose_codex_service
  from arl.identity import RegisteredPeerVerifier
  from arl.storage import Store
  adapter=CodexTextAdapter(enabled=True,test_command=[sys.executable,'-I',str(FIXTURE),mode],observer=observer)
  service=CodexService(adapter,caller='independent-codex',model=ARGS['model'],max_calls=calls,
      authorization_current=lambda:True,peer_current=lambda:True,allow_test_command=True)
  peer=RegisteredPeerVerifier({service.caller})
  runtime=compose_codex_service(self.home/'host',service=service,peer_verifier=peer,isolated=True)
  runtime.store=Store(self.home/'jobs.sqlite')
  runtime.ready.set()
  service.preflight()
  return runtime,service

 def rpc(self, runtime, method, params=None, verified=True):
  return runtime.dispatch({'protocol':'arl/1','app':'independent-codex','method':method,'params':params or {}},
      verified_app='independent-codex' if verified else None)

 def run_job(self, runtime, job):
  import threading
  worker=threading.Thread(target=runtime.work);worker.start()
  try:
   deadline=time.monotonic()+4
   while time.monotonic()<deadline:
    result=self.rpc(runtime,'get',{'id':job['id']})
    if result['state'] in {'succeeded','failed','cancelled','needs_review'}:return result
    time.sleep(.01)
   self.fail('scoped fixture did not finish')
  finally:
   runtime.stopping.set();runtime.job_signal.set();worker.join(5)
   self.assertFalse(worker.is_alive())

 def test_independent_composition_receipt_budget_identity_and_duplicate(self):
  runtime,service=self.make_route()
  try:
   self.assertEqual(runtime.work_scope,frozenset({('independent-codex',NAME)}))
   self.assertEqual(runtime.router.providers,{})
   params={'tool':NAME,'args':ARGS,'key':'one'}
   self.assert_fault('app_identity_unverified',lambda:self.rpc(runtime,'submit',params,verified=False))
   self.assert_fault('provider_model_change_not_authorized',lambda:self.rpc(runtime,'submit',
       dict(params,args=dict(ARGS,model='not-granted'))))
   job=self.rpc(runtime,'submit',params)
   result=self.run_job(runtime,job)
   self.assertEqual(result['state'],'succeeded')
   self.assertEqual(result['result']['text'],'synthetic plan')
   self.assertEqual(result['result']['execution_preferences']['reasoning_effort'],'xhigh')
   self.assertEqual(result['result']['execution_preferences']['service_tier'],'default')
   self.assertEqual(result['progress']['native']['terminal'],'completed')
   self.assertEqual(result['result']['completion']['reason'],None)
   runtime.stopping.clear()
   self.assertEqual(self.rpc(runtime,'submit',params)['id'],job['id'])
   self.assert_fault('call_budget_exceeded',lambda:self.rpc(runtime,'submit',dict(params,key='two')))
   self.assertEqual(runtime.store.db.execute('SELECT calls FROM budget WHERE owner=?',(service.caller,)).fetchone()[0],1)
   self.assertFalse(service.status()['inference_verified'])
   self.assertEqual(service.status()['remaining_calls'],0)
   self.assertEqual(service.status()['state'],'budget_exhausted')
  finally:runtime.store.close();runtime.control.close();runtime.service_portal.close()

 def test_running_cancel_uses_exact_terminal_and_does_not_publish_text(self):
  holder={}
  def observer(event):
   if event['event']=='turn_started':
    self.rpc(holder['runtime'],'cancel',{'id':holder['job']['id']})
  runtime,service=self.make_route('wait_interrupt',observer=observer)
  try:
   job=self.rpc(runtime,'submit',{'tool':NAME,'args':ARGS,'key':'cancel'})
   holder.update(runtime=runtime,job=job)
   result=self.run_job(runtime,job)
   self.assertEqual(result['state'],'cancelled')
   self.assertEqual(result['result']['native']['terminal'],'interrupted')
   self.assertEqual(result['result']['native']['interrupt'],'acknowledged')
   self.assertNotIn('text',result['result'])
  finally:runtime.store.close();runtime.control.close();runtime.service_portal.close()

 def test_scoped_recovery_claim_and_expiry_preserve_other_work(self):
  from arl.contracts import Tool,object_schema
  runtime,service=self.make_route(calls=2)
  store=runtime.store
  try:
   other_tool=Tool('unrelated.local',object_schema(),lambda a,c:{})
   policy=AppPolicy(frozenset({other_tool.name}),max_calls=3)
   other=store.submit('unrelated','old-running',other_tool,{},policy)
   store.claim(scope=frozenset({('unrelated',other_tool.name)}))
   expired=store.submit('unrelated','old-expired',other_tool,{},policy)
   store.db.execute('UPDATE jobs SET deadline_at=0 WHERE id=?',(expired['id'],))
   old=[dict(store.row('unrelated',j['id'])) for j in (other,expired)]
   job=self.rpc(runtime,'submit',{'tool':NAME,'args':ARGS,'key':'interrupted'})
   store.claim(scope=runtime.work_scope)
   store.recover(runtime.tools,scope=runtime.work_scope)
   self.assertEqual(store.get(service.caller,job['id'])['state'],'needs_review')
   self.assertIsNone(store.claim(scope=runtime.work_scope))
   from dataclasses import replace
   queued=store.submit(service.caller,'old-scope',service.tool(),ARGS,runtime.policies[service.caller],verified=True)
   replacement=replace(service.tool(),permissions=('codex_app_server_inference','codex_scope:replacement'))
   store.recover({NAME:replacement},scope=runtime.work_scope)
   self.assertEqual(store.get(service.caller,queued['id'])['state'],'needs_review')
   self.assertEqual([dict(store.row('unrelated',j['id'])) for j in (other,expired)],old)
  finally:store.close();runtime.control.close();runtime.service_portal.close()


 def test_native_configuration_is_stable_and_source_process_cannot_activate_it(self):
  import json,uuid
  from arl.compat_host import read_codex_configuration,build_codex_activation,CODEX_CONFIGURATION
  scope={'schema_version':1,'caller':'arl-control','provider':'codex_app_server','model':ARGS['model'],
      'reasoning_effort':'xhigh','service_tier':'default','scope_generation':str(uuid.uuid4()),
      'max_calls':32,'max_output_bytes':32768,'core_manifest_sha256':'0'*64,
      'caller_requirement':'cdhash H"'+('a'*40)+'"','explicit_submission_only':True}
  path=self.home/CODEX_CONFIGURATION
  path.write_text(json.dumps(scope));path.chmod(0o600)
  value,seal=read_codex_configuration(self.home)
  self.assertEqual(value,scope);self.assertEqual(len(seal),64)
  with patch('arl.codex_server.subprocess.Popen') as launch:
   service,peer,state=build_codex_activation(self.home)
  self.assertIsNone(service);self.assertIsNone(peer)
  self.assertEqual(state,'codex_native_owner_unavailable');launch.assert_not_called()
  scope['schema_version']=2;scope['max_calls']=None;path.write_text(json.dumps(scope))
  self.assertIsNone(read_codex_configuration(self.home)[0]['max_calls'])
  scope['schema_version']=1;path.write_text(json.dumps(scope))
  self.assert_fault('codex_configuration_invalid',lambda:read_codex_configuration(self.home))
  scope['schema_version']=2;scope['max_calls']=True;path.write_text(json.dumps(scope))
  self.assert_fault('codex_configuration_invalid',lambda:read_codex_configuration(self.home))
  scope['max_calls']=None
  scope['service_tier']='priority';path.write_text(json.dumps(scope))
  self.assert_fault('codex_configuration_invalid',lambda:read_codex_configuration(self.home))
