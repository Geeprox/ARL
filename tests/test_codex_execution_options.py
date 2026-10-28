import copy,json,sys,time,threading
from pathlib import Path
from unittest.mock import Mock
from arl.contracts import Fault
from arl.codex_execution_options import read_catalog,selection
from arl.codex_server import CodexTextAdapter,CodexService,confirmed_preferences,NAME
from arl.compat_host import compose_codex_service
from arl.identity import RegisteredPeerVerifier
from arl.storage import Store
from tests.test_runtime import RuntimeCase
FIXTURE=Path(__file__).parent/'fixtures/CodexExecutionOptionsServer.py'
class OptionsTests(RuntimeCase):
 def route(self, max_calls=32):
  adapter=CodexTextAdapter(enabled=True,test_command=[sys.executable,'-I',str(FIXTURE)])
  service=CodexService(adapter,caller='options-fixture',model='synthetic-model',authorization_current=lambda:True,
   peer_current=lambda:True,max_calls=max_calls,allow_test_command=True,allow_model_selection=True)
  runtime=compose_codex_service(self.home/'host',service=service,peer_verifier=RegisteredPeerVerifier({'options-fixture'}),isolated=True)
  runtime.store=Store(self.home/'jobs.sqlite');runtime.ready.set();service.preflight();return runtime,service
 def test_selected_model_effort_and_fast_cross_real_stdio_and_receipt(self):
  runtime,service=self.route()
  try:
   catalog=service.status()['execution_catalog'];self.assertEqual(catalog['current']['service_tier'],'default')
   self.assertTrue(catalog['models'][0]['fast_available']);self.assertFalse(catalog['models'][1]['fast_available'])
   def rpc(method,params):return runtime.dispatch({'protocol':'arl/1','app':service.caller,'method':method,'params':params},verified_app=service.caller)
   for i,(model,effort,tier) in enumerate([('synthetic-small','low','default'),('synthetic-model','medium','fast')]):
    args={'model':model,'input':'offline selected input','max_output_bytes':4096,'reasoning_effort':effort,'service_tier':tier}
    job=rpc('submit',{'tool':NAME,'args':args,'key':str(i)})
    worker=threading.Thread(target=runtime.work);worker.start()
    try:
     end=time.monotonic()+5
     while time.monotonic()<end:
      result=rpc('get',{'id':job['id']})
      if result['state'] in {'succeeded','failed','needs_review'}:break
      time.sleep(.01)
     self.assertEqual(result['state'],'succeeded',result)
     self.assertEqual(json.loads(result['result']['text']),{'model':model,'effort':effort,'tier':tier})
     self.assertEqual(result['result']['execution_preferences']['service_tier'],tier)
     self.assertTrue(result['result']['simulated'])
    finally:runtime.stopping.set();runtime.job_signal.set();worker.join(5);runtime.stopping.clear()
   self.assertEqual(runtime.store.db.execute('SELECT calls FROM budget WHERE owner=?',(service.caller,)).fetchone()[0],2)
  finally:runtime.store.close();runtime.control.close();runtime.service_portal.close()
 def test_unsupported_combinations_rejected_before_budget_or_turn(self):
  runtime,service=self.route()
  try:
   args={'model':'synthetic-small','input':'offline','max_output_bytes':128,'reasoning_effort':'low','service_tier':'fast'}
   self.assert_fault('provider_service_tier_unavailable',lambda:service.admit(service.caller,NAME,args))
   self.assert_fault('provider_effort_unavailable',lambda:service.admit(service.caller,NAME,dict(args,service_tier='default',reasoning_effort='xhigh')))
   self.assert_fault('provider_model_change_not_authorized',lambda:service.admit(service.caller,NAME,dict(args,model='not-listed')))
   self.assertIsNone(runtime.store.db.execute('SELECT calls FROM budget WHERE owner=?',(service.caller,)).fetchone())
  finally:runtime.store.close();runtime.control.close();runtime.service_portal.close()
 def test_unlimited_local_policy_keeps_usage_and_explicit_finite_policy(self):
  from arl.contracts import AppPolicy
  from arl.contracts import Tool
  tool=Tool('synthetic.read',{},lambda args,ctx:None)
  store=Store(self.home/'unlimited.sqlite')
  policy=AppPolicy(frozenset({tool.name}),frozenset(),max_pending=1,max_calls=None)
  try:
   for index in range(40):
    job=store.submit('synthetic',str(index),tool,{'prompt':'offline'},policy,verified=True)
    store.db.execute("UPDATE jobs SET state='succeeded' WHERE id=?",(job['id'],))
   self.assertEqual(store.db.execute("SELECT calls FROM budget WHERE owner='synthetic'").fetchone()[0],40)
   finite=AppPolicy(frozenset({tool.name}),frozenset(),max_pending=1,max_calls=32)
   self.assert_fault('call_budget_exceeded',lambda:store.submit('synthetic','finite',tool,{'prompt':'offline'},finite,verified=True))
  finally:store.close()
  runtime,service=self.route(max_calls=None)
  try:
   self.assertIsNone(runtime.policies[service.caller].max_calls)
   runtime.store.db.execute('INSERT INTO budget(owner,calls) VALUES(?,4000)',(service.caller,))
   status=service.status()
   self.assertTrue(status['route_enabled']);self.assertIsNone(status['max_calls']);self.assertIsNone(status['remaining_calls'])
  finally:runtime.store.close();runtime.control.close();runtime.service_portal.close()

 def test_ack_is_required_and_priority_is_not_fast(self):
  self.assert_fault('provider_preferences_unverified',lambda:confirmed_preferences({'reasoningEffort':'low','serviceTier':'default'},'low','fast'))
  self.assert_fault('provider_preferences_invalid',lambda:confirmed_preferences({},'low','priority'))
 def test_catalog_pagination_cycle_and_unknown_capabilities_fail_closed(self):
  session=Mock();session.response.return_value={'data':[],'nextCursor':'same'}
  self.assert_fault('provider_catalog_invalid',lambda:read_catalog(session))
  self.assertEqual(session.send.call_count,2)
  session=Mock();session.response.return_value={'data':[{'model':'m','hidden':False,'displayName':'m','description':'',
   'defaultReasoningEffort':'custom','supportedReasoningEfforts':[{'reasoningEffort':'custom','description':'catalog-defined'}],
   'serviceTiers':[{'id':'priority','description':'not Fast'}]}]}
  rows=read_catalog(session);self.assertFalse(rows[0]['fast_available']);selection(rows,'m','custom','default')
  self.assert_fault('provider_service_tier_unavailable',lambda:selection(rows,'m','custom','fast'))

 def test_large_catalog_and_long_display_text_do_not_block_model_selection(self):
  session=Mock();pages=[]
  for page in range(10):
   rows=[{'model':'m'+str(page*20+i),'displayName':'中'*1000,'description':'long'*3000,
    'defaultReasoningEffort':'low','supportedReasoningEfforts':[{'reasoningEffort':'low','description':'x'*3000}]} for i in range(20)]
   pages.append({'data':rows,'nextCursor':str(page+1) if page<9 else None})
  session.response.side_effect=pages
  rows=read_catalog(session)
  self.assertEqual(len(rows),200);selection(rows,'m199','low','default')
  self.assertLessEqual(len(rows[0]['display_name'].encode()),200)
