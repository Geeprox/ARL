"""Real local worker/stdio, synthetic provider; old and opt-in contracts."""
import copy,json,sys,uuid
from pathlib import Path
from dataclasses import replace
from arl.contracts import AppPolicy,Fault,encode
from arl.codex_research import CodexResearchGrant
from arl.codex_sourced_research import CONTRACT_SHA256,NAME,METHODS
from arl.codex_sourced_execution import CodexExecutionAdapter,CodexExecutionEngine
from arl import codex_execution_contract as execution
from arl.codex_server import CodexTextAdapter
from arl.service import Runtime
from arl.storage import Store
from arl.research import sha
from tests.test_runtime import RuntimeCase
from tests.test_codex_sourced_research import SourcedResearchTests,request,descriptor,MODEL

class ExecutionContractTests(RuntimeCase):
 rpc=SourcedResearchTests.rpc
 upload=SourcedResearchTests.upload
 execute=SourcedResearchTests.execute
 binding=staticmethod(SourcedResearchTests.binding)
 status=SourcedResearchTests.status
 cancel=SourcedResearchTests.cancel
 def setUp(self):
  super().setUp();self.configure()
 def configure(self,mode='ok'):
  fixture=Path(__file__).parent/'fixtures/CodexSourcedExecutionServer.py'
  self.text=CodexTextAdapter(enabled=True,test_command=[sys.executable,'-I',str(fixture),mode])
  self.adapter=CodexExecutionAdapter([MODEL],text_adapter=self.text)
  self.grant=CodexResearchGrant('codex_app_server',frozenset({MODEL}),'original-auth-epoch',CONTRACT_SHA256)
  self.snapshot={'schema_version':1,'source':'test_double','selection_enabled':True,'current':{'model':MODEL},
   'models':[{'model':MODEL,'default_effort':'high','efforts':[{'id':e,'description':''} for e in ['low','medium','high','xhigh']], 'fast_available':True}]}
  self.engine=CodexExecutionEngine({'tisra':self.grant},{'codex_app_server':self.adapter},execution_catalog=lambda _:self.snapshot)
  self.policy=AppPolicy(frozenset({NAME}),methods=METHODS|{'get','health','ready'},max_pending=16,
   max_deadline_ms=30000,priority_bands=frozenset({'background','explicit','interactive'}))
  self.runtime=Runtime(self.home,policies={'tisra':self.policy},codex_research=self.engine,identity_verifier=lambda *_:None)
  self.runtime.store=Store(self.home/'state.sqlite');self.engine.attach(self.runtime.store);self.runtime.ready.set()
 def tearDown(self):self.runtime.store.close();super().tearDown()
 def catalog(self):return self.rpc('codex.research.capabilities.v1',{'execution_contract':execution.CONTRACT})['execution_options']
 def selected(self,**changes):
  value={'contract':execution.CONTRACT,'contract_sha256':execution.CONTRACT_SHA256,'schema_version':1,
   'catalog_version':self.catalog()['catalog_version'],'package_id':'high','thinking_effort':'low',
   'priority':'background','service_tier':'default','allow_degradation':False}
  value.update(changes);return value
 def submit(self,selected=None,*,mutate_descriptor=None,legacy=False):
  raw=request();run=str(uuid.uuid4());meta=descriptor(raw,run)
  selected=self.selected() if selected is None and not legacy else selected
  if selected is not None:meta.update(version=3,executionOptions=copy.deepcopy(selected))
  if mutate_descriptor:mutate_descriptor(meta)
  args={'schema_version':2 if selected is not None else 1,'run_id':run,'epoch':0,
   'request':self.upload(raw,execution.REQUEST,run),'descriptor':self.upload(encode(meta),execution.DESCRIPTOR,run),
   'provider':'codex_app_server','model':MODEL,'model_fingerprint':self.adapter.model_fingerprints[MODEL],
   'request_format':execution.REQUEST,'output_format':execution.RESPONSE,'history_version':execution.FORMATS[2],
   'max_output_tokens':None,'max_output_bytes':128,'priority':selected['priority'] if selected else 'explicit','deadline_ms':2000}
  if selected is not None:args['execution_options']=copy.deepcopy(selected)
  return self.rpc('codex.research.submit.v1',args),args
 def output(self,receipt,args):
  current=self.status(receipt);ref=current['result_ref'];self.assertIsNotNone(ref,current)
  raw=bytes(self.engine.payload('tisra',ref['payload_id'])['data'])
  return execution.result_body(raw,args,binding=current,native=current['native'],request=request()),raw
 def assert_no_job(self):
  self.assertEqual(self.runtime.store.db.execute('SELECT COUNT(*) FROM jobs').fetchone()[0],0)
  self.assertIsNone(self.runtime.store.db.execute('SELECT calls FROM budget').fetchone())
 def test_legacy_capability_and_request_shapes_remain_unchanged(self):
  caps=self.rpc('codex.research.capabilities.v1');self.assertNotIn('execution_options',caps)
  receipt,args=self.submit(legacy=True);self.assertEqual(receipt['schema_version'],1);self.assertNotIn('execution_options',receipt)
  self.execute();result,raw=self.output(receipt,args);self.assertEqual(result['schema_version'],2)
  self.assertNotIn('execution_options',result)
 def test_selected_priority_effort_reach_actual_thread_turn_and_receipt(self):
  selected=self.selected();receipt,args=self.submit(selected);self.assertEqual(receipt['execution_options'],selected)
  self.assertIsNone(receipt['execution_preferences']);self.execute();current=self.status(receipt)
  self.assertEqual(self.runtime.store.row('tisra',receipt['job_id'])['priority'],'background')
  self.assertEqual(current['execution_preferences']['reasoning_effort'],'low')
  result,raw=self.output(receipt,args);self.assertEqual(result['text'],'effort=low;tier=default')
  self.assertEqual(result['execution_options'],selected);self.assertEqual(result['schema_version'],3)
  self.assertEqual(result['execution_preferences'],current['execution_preferences'])
  self.assertEqual(self.runtime.store.db.execute('SELECT calls FROM budget').fetchone()[0],1)
 def test_unavailable_catalog_has_five_unavailable_packages_and_no_admission(self):
  self.snapshot.update(selection_enabled=False,models=[]);catalog=self.catalog()
  self.assertEqual(len(catalog['packages']),5);self.assertTrue(all(not p['available'] for p in catalog['packages']))
  self.assert_fault('package_unavailable',lambda:self.submit(self.selected()));self.assert_no_job()
 def test_unsupported_effort_and_fast_are_not_silently_substituted(self):
  for changes,code in [({'thinking_effort':'max'},'provider_effort_unavailable'),({'service_tier':'fast'},'fast_authorization_required')]:
   self.assert_fault(code,lambda:self.submit(self.selected(**changes)));self.assert_no_job()
 def test_highest_requires_explicit_degradation(self):
  self.assert_fault('degradation_not_allowed',lambda:self.submit(self.selected(package_id='highest',thinking_effort='xhigh')))
  self.assert_no_job();receipt,args=self.submit(self.selected(package_id='highest',thinking_effort='xhigh',allow_degradation=True))
  self.execute();result,_=self.output(receipt,args);self.assertEqual(result['text'],'effort=xhigh;tier=default')
 def test_changed_catalog_and_descriptor_options_reject_before_budget(self):
  selected=self.selected();self.snapshot['models'][0]['fast_available']=False
  self.assert_fault('catalog_changed',lambda:self.submit(selected));self.assert_no_job()
  self.assert_fault('descriptor_mismatch',lambda:self.submit(self.selected(),mutate_descriptor=lambda m:m['executionOptions'].update(thinking_effort='high')))
  self.assert_no_job()
 def test_native_ack_mismatch_never_starts_turn_or_publishes_success(self):
  self.runtime.store.close();self.configure('bad_ack');receipt,args=self.submit();self.execute()
  current=self.status(receipt);self.assertNotEqual(current['state'],'succeeded');self.assertIsNone(current['result_ref'])
  self.assertEqual(current['error_code'],'research_provider_error');self.assertIsNone(current['execution_preferences'])
 def test_result_options_tampering_and_restore_never_replays(self):
  receipt,args=self.submit();self.execute();result,raw=self.output(receipt,args)
  result['execution_options']['thinking_effort']='high'
  self.assert_fault('execution_options_mismatch',lambda:execution.result_body(encode(result),args,request=request()))
  self.engine.recover();self.assertIsNone(self.runtime.store.claim())
  current=self.status(receipt);self.assertEqual(current['execution_options'],args['execution_options'])

 def test_same_run_choice_change_is_not_replayed_or_charged_again(self):
  receipt,args=self.submit();changed=copy.deepcopy(args)
  changed['priority']='interactive';changed['execution_options']['priority']='interactive'
  self.assert_fault('idempotency_conflict',lambda:self.rpc('codex.research.submit.v1',changed))
  self.assertEqual(self.runtime.store.db.execute('SELECT calls FROM budget').fetchone()[0],1)
  self.assertEqual(self.runtime.store.db.execute('SELECT COUNT(*) FROM jobs').fetchone()[0],1)
  self.assertEqual(self.status(receipt)['execution_options'],args['execution_options'])
 def test_discovery_does_not_start_a_provider_process(self):
  from unittest.mock import patch
  with patch('arl.codex_server.subprocess.Popen',side_effect=AssertionError('discovery cannot launch')):
   self.assertTrue(self.catalog()['catalog_available'])
   self.snapshot.update(selection_enabled=False,models=[])
   self.assertFalse(self.catalog()['catalog_available'])
  self.assert_no_job()
 def test_product_review_accepts_only_valid_versioned_priority_without_widening_model(self):
  from types import SimpleNamespace
  from arl.research_product import ResearchAdmission
  consent=SimpleNamespace(model=MODEL,current=lambda _:True)
  review=ResearchAdmission(self.home,consent)
  args={'schema_version':2,'provider':'codex_app_server','model':MODEL,'priority':'background',
   'max_output_tokens':None,'max_output_bytes':128,'deadline_ms':2000,'request':{'byte_count':10},
   'descriptor':{'byte_count':10},'execution_options':self.selected()}
  review('tisra',NAME,args)
  altered=copy.deepcopy(args);altered['execution_options']['contract_sha256']='0'*64
  self.assert_fault('research_review_not_authorized',lambda:review('tisra',NAME,altered))
  altered=copy.deepcopy(args);altered['model']='not-granted'
  self.assert_fault('research_review_not_authorized',lambda:review('tisra',NAME,altered))
  legacy=copy.deepcopy(args);legacy['schema_version']=1;legacy.pop('execution_options')
  self.assert_fault('research_review_not_authorized',lambda:review('tisra',NAME,legacy))
  legacy['priority']='explicit';review('tisra',NAME,legacy)

 def test_changed_provider_pin_rejects_selected_submission_before_budget(self):
  from unittest.mock import patch
  with patch.object(self.text,'verify',side_effect=Fault('provider_binary_changed')):
   self.assert_fault('provider_binary_changed',lambda:self.submit())
  self.assert_no_job()
