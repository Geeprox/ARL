"""Only residual B3 logical-run/job binding and its compatibility boundaries."""
import copy, unittest, uuid
from types import SimpleNamespace
from arl.contracts import Fault
from arl.research import FORMATS, ResearchEngine
from arl.research_client import ResearchClient

TRACES=[]
def fixture():
    # Exact data/grammar of task-8's B3_first_receipt_job_id_mutation.
    request={'profile_id':'generated-profile','policy_epoch':'generated-policy','task_kind':'model.inference',
        'resource_kind':'model','requested_class':'interactive','deadline_at_ms':2000000010000,
        'estimate_ms':5,'allow_interrupt':False,'allow_fallback':True}
    args={'schema_version':1,'run_id':str(uuid.uuid4()),'epoch':0,
        'request':{'payload_id':str(uuid.uuid4()),'sha256':'a'*64,'byte_count':10},
        'descriptor':{'payload_id':str(uuid.uuid4()),'sha256':'c'*64,'byte_count':10},
        'provider':'synthetic-provider','model':'synthetic-model','model_fingerprint':'b'*64,
        'request_format':FORMATS[0],'output_format':FORMATS[1],'history_version':FORMATS[2],
        'max_output_tokens':128,'priority':'explicit','deadline_ms':60000,'scheduling':request}
    ResearchEngine.submit_args(ResearchEngine.__new__(ResearchEngine),args)
    facts={'schema_version':1,**{k:request[k] for k in ['profile_id','policy_epoch','task_kind','requested_class','resource_kind','deadline_at_ms']},
        'effective_class':'interactive','estimate_ms':5,'execution_budget_ms':50,'allow_interrupt_effective':False,'reasons':[]}
    first={'schema_version':1,'job_id':str(uuid.uuid4()),'owner':'tisra','run_id':args['run_id'],
        'request_sha256':args['request']['sha256'],'epoch':0,'auth_epoch':'generated-auth','state':'queued',
        **{k:args[k] for k in ['provider','model','model_fingerprint','request_format','output_format','history_version']},
        'result_ref':None,'error_code':None,'cancel_requested':False,'external_stop':'not_started','scheduling':facts}
    calls=[]
    client=SimpleNamespace(app='tisra',rpc=lambda method,params:(calls.append({'method':method,'params':copy.deepcopy(params)}),copy.deepcopy(first))[1])
    return ResearchClient(client),first,args,calls

def observe_counterexample():
    sdk,first,args,calls=fixture(); sdk.check(first,args)
    old_job=first['job_id']; first['job_id']=str(uuid.uuid4()); new_job=first['job_id']
    error=None
    try:sdk.status(first,args)
    except Fault as exc:error=exc.code
    return {'case':'B3_first_receipt_job_id_mutation','old_job_id':old_job,'new_job_id':new_job,
        'rejection':error,'status_rpc_calls':calls,'scheduling_pin_count':len(sdk._scheduling_pins),
        'same_run_hash_epoch_auth_params_and_scheduling':True,
        'full_original_server_args_grammar_checked':True}

class PriorityR3Tests(unittest.TestCase):
    def assert_fault(self,call):
        with self.assertRaises(Fault) as caught:call()
        self.assertEqual(caught.exception.code,'research_receipt_mismatch')
    def assert_single_pin(self,sdk,calls):
        self.assertEqual(calls,[]); self.assertEqual(len(sdk._scheduling_pins),1)
        self.assertEqual(len(sdk._priority_run_pins),1)
    def test_review_jobid_mutation_status_rejected_locally(self):
        observed=observe_counterexample()
        self.assertEqual(observed['rejection'],'research_receipt_mismatch')
        self.assertEqual(observed['status_rpc_calls'],[]); self.assertEqual(observed['scheduling_pin_count'],1)
        TRACES.append(observed)
    def test_jobid_mutation_cancel_rejected_locally(self):
        sdk,first,args,calls=fixture(); sdk.check(first,args); first['job_id']=str(uuid.uuid4())
        self.assert_fault(lambda:sdk.cancel(first,args)); self.assert_single_pin(sdk,calls)
    def test_jobid_plus_valid_facts_change_cannot_establish_second_baseline(self):
        sdk,first,args,calls=fixture(); sdk.check(first,args)
        first['job_id']=str(uuid.uuid4()); first['scheduling'].update(effective_class='background',
            estimate_ms=6,execution_budget_ms=60,reasons=['authorized_class_downgrade'])
        self.assert_fault(lambda:sdk.status(first,args)); self.assert_single_pin(sdk,calls)
    def test_same_run_second_job_and_hash_auth_parameter_drift_rejected(self):
        for field in ('job','hash','auth','params'):
            sdk,first,args,calls=fixture(); sdk.check(first,args); second=copy.deepcopy(first); altered=copy.deepcopy(args)
            second['job_id']=str(uuid.uuid4())
            if field=='hash':second['request_sha256']='d'*64; altered['request']['sha256']='d'*64
            elif field=='auth':second['auth_epoch']='another-valid-auth'
            elif field=='params':altered['max_output_tokens']=129
            self.assert_fault(lambda:sdk.check(second,altered)); self.assert_single_pin(sdk,calls)
    def test_genuine_multiple_runs_accept_and_dispatch_each_correct_job(self):
        sdk,first,args,calls=fixture(); sdk.check(first,args)
        second=copy.deepcopy(first); other=copy.deepcopy(args)
        other['run_id']=str(uuid.uuid4()); other['request']['sha256']='d'*64
        other['request']['payload_id']=str(uuid.uuid4()); other['descriptor']['payload_id']=str(uuid.uuid4())
        second.update(job_id=str(uuid.uuid4()),run_id=other['run_id'],request_sha256='d'*64)
        ResearchEngine.submit_args(ResearchEngine.__new__(ResearchEngine),other); sdk.check(second,other)
        receipts={r['job_id']:copy.deepcopy(r) for r in (first,second)}
        def rpc(method,params):
            calls.append({'method':method,'params':copy.deepcopy(params)})
            result=copy.deepcopy(receipts[params['job_id']])
            if method=='research.cancel.v1':result.update(state='cancelled',cancel_requested=True)
            return result
        sdk.client.rpc=rpc
        self.assertEqual(sdk.status(first,args)['job_id'],first['job_id'])
        self.assertEqual(sdk.status(second,other)['job_id'],second['job_id'])
        self.assertEqual(sdk.cancel(first,args)['job_id'],first['job_id'])
        self.assertEqual(sdk.cancel(second,other)['job_id'],second['job_id'])
        self.assertEqual([c['params']['job_id'] for c in calls],[first['job_id'],second['job_id']]*2)
        self.assertEqual((len(sdk._priority_run_pins),len(sdk._scheduling_pins)),(2,2))
    def test_old_job_reused_by_new_run_rejected_without_partial_pin(self):
        sdk,first,args,calls=fixture(); sdk.check(first,args)
        second=copy.deepcopy(first); other=copy.deepcopy(args); other['run_id']=str(uuid.uuid4()); second['run_id']=other['run_id']
        self.assert_fault(lambda:sdk.check(second,other)); self.assert_single_pin(sdk,calls)
        # A rejected cross-run receipt must not reserve the new run against a valid new job.
        second['job_id']=str(uuid.uuid4()); sdk.check(second,other)
        self.assertEqual((len(sdk._priority_run_pins),len(sdk._scheduling_pins)),(2,2))
    def test_same_old_job_cannot_move_to_new_execution_epoch(self):
        sdk,first,args,calls=fixture(); sdk.check(first,args)
        second=copy.deepcopy(first); other=copy.deepcopy(args); second['epoch']=1; other['epoch']=1
        self.assert_fault(lambda:sdk.check(second,other)); self.assert_single_pin(sdk,calls)
    def test_optin_run_or_job_cannot_reenter_legacy_by_dropping_fields(self):
        for scope in ('same-run-new-job','same-job-new-run'):
            sdk,first,args,calls=fixture(); sdk.check(first,args)
            second=copy.deepcopy(first); other=copy.deepcopy(args)
            second.pop('scheduling'); other.pop('scheduling')
            if scope=='same-run-new-job':second['job_id']=str(uuid.uuid4())
            else:other['run_id']=str(uuid.uuid4()); second['run_id']=other['run_id']
            self.assert_fault(lambda:sdk.status(second,other)); self.assert_single_pin(sdk,calls)
    def test_legacy_without_scheduling_exact_fields_and_status_cancel_compatible(self):
        sdk,first,args,calls=fixture(); first.pop('scheduling'); args.pop('scheduling')
        ResearchEngine.submit_args(ResearchEngine.__new__(ResearchEngine),args)
        keys=set(first); sdk.check(first,args); self.assertEqual(set(sdk.status(first,args)),keys)
        self.assertEqual(set(sdk.cancel(first,args)),keys)
        self.assertEqual([c['method'] for c in calls],['research.status.v1','research.cancel.v1'])
        self.assertEqual(len(sdk._scheduling_pins),0); self.assertEqual(len(sdk._priority_run_pins),0)
    def test_continuation_uses_immutable_first_handle_after_checked_receipt_mutation(self):
        sdk,first,args,calls=fixture(); sdk.check(first,args)
        saved=copy.deepcopy(first); original_check=sdk.check
        def checked_then_mutated(receipt,params,job_id=None):
            result=original_check(receipt,params,job_id)
            if receipt is first:first['job_id']=str(uuid.uuid4())
            return result
        def rpc(method,params):
            calls.append({'method':method,'params':copy.deepcopy(params)})
            return copy.deepcopy(saved)
        sdk.check=checked_then_mutated; sdk.client.rpc=rpc
        self.assertEqual(sdk.status(first,args)['job_id'],saved['job_id'])
        self.assertEqual(calls[0]['params']['job_id'],saved['job_id'])
        self.assertNotEqual(first['job_id'],saved['job_id'])
        self.assertEqual((len(sdk._priority_run_pins),len(sdk._scheduling_pins)),(1,1))
