"""Generated-data protocol/admission/queue regressions, no live adapters."""
from collections import Counter
from dataclasses import replace
import json
from pathlib import Path
import tempfile
import threading
import time
import unittest
import uuid
from unittest.mock import patch
from arl import PROTOCOL
from arl.client import Client
from arl.contracts import AppPolicy, Fault, Tool, object_schema
from arl.priority import (PriorityAuthority, ResourcePolicy, TaskPolicy, AppProfilePolicy,
    release_lease, validate_profile, validate_request, validate_acceptance)
from arl.service import Runtime
from arl.storage import Store
import arl.storage as storage_module
import arl.priority as priority_module

TOOL='fixture.model'


class LocalClient(Client):
    def __init__(self,runtime,app):
        self.runtime,self.app=runtime,app
    def connect(self,timeout=10):return {'ready':True}
    def rpc(self,method,params=None):
        return self.runtime.dispatch({'protocol':PROTOCOL,'app':self.app,'method':method,'params':params or {}},verified_app=self.app)


class PriorityV1Tests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='arl-priority-v1-')
        self.home=Path(self.temp.name)
        self.store=Store(self.home/'state.sqlite')
        self.tools={TOOL:Tool(TOOL,object_schema(),lambda a,c:{'generated':True},permissions=('fixture',)),
            'fixture.nas':Tool('fixture.nas',object_schema(),lambda a,c:{'generated':True},permissions=('fixture',)),
            'fixture.control':Tool('fixture.control',object_schema(),lambda a,c:{'generated':True},permissions=('fixture',))}
        self.policy=AppPolicy(frozenset(self.tools),max_pending=100,max_calls=1000,
            methods=frozenset({'health','ready','capabilities','submit','submit_scheduled','get','cancel','resume'}))
        self.profiles={o:AppProfilePolicy(frozenset({'background','interactive','realtime'}),
            queue_limit=100,per_resource_inflight=2,burst_calls=100,max_deadline_ms=60000) for o in ('tisra','friday')}
        self.subjects={'tisra':'synthetic-tisra-registration-1','friday':'synthetic-friday-registration-1'}
        self.identity_binding=lambda owner:self.subjects.get(owner,'synthetic-unknown-registration-'+owner)
        self.tasks=(TaskPolicy(TOOL,'model.inference','model',maximum_class='interactive',estimate_floor_ms=5,execution_budget_ms=50),
            TaskPolicy(TOOL,'household.response','model',owners=frozenset({'friday'}),maximum_class='realtime',estimate_floor_ms=5,execution_budget_ms=50),
            TaskPolicy('fixture.nas','nas.read','nas',maximum_class='background',estimate_floor_ms=5,execution_budget_ms=50),
            TaskPolicy('fixture.control','control.deterministic','control',maximum_class='realtime',estimate_floor_ms=5,execution_budget_ms=50))
        self.authority=self.new_authority()
        self.authority.bind(self.store)
        self.runtime=None
        self.threads=[]
        self.barriers=[]
    def tearDown(self):
        for barrier in self.barriers:barrier.set()
        if self.runtime is not None:
            self.runtime.stopping.set();self.runtime.job_signal.set()
        for worker in self.threads:
            worker.join(2)
            self.assertFalse(worker.is_alive(),'Controlled worker must actually exit before Store closes')
        self.store.close();self.temp.cleanup()
    def new_authority(self,resources=None,tasks=None,profiles=None):
        resources=resources or (ResourcePolicy('model',slots=2,realtime_reserved=1,queue_limit=64,class_queue_limit=64,capacity_evidence='controlled_synthetic'),
            ResourcePolicy('nas',queue_limit=64,class_queue_limit=64,capacity_evidence='controlled_synthetic'),
            ResourcePolicy('control',queue_limit=64,class_queue_limit=64,capacity_evidence='controlled_synthetic'))
        return PriorityAuthority(resources,tasks or self.tasks,self.profiles if profiles is None else profiles,identity_binding=self.identity_binding)
    def rebind(self,authority):
        self.authority=authority;authority.bind(self.store)
        if self.runtime is not None:self.runtime.priority_authority=authority
    def request(self,owner='tisra',kind='model.inference',cls='interactive',remaining=10000,estimate=5,**extra):
        profile=self.authority.negotiate(owner,owner,{'classes':['background','interactive','realtime']})
        resource=next(t.resource_kind for t in self.authority.available_tasks(owner) if t.task_kind==kind)
        request=Client.priority_request(profile,task_kind=kind,requested_class=cls,
            deadline_at_ms=int(time.time()*1000)+remaining,resource_kind=resource,estimate_ms=estimate)
        request.update(extra)
        return request
    def submit(self,owner='tisra',request=None,key=None,tool=TOOL):
        return self.store.submit(owner,key or str(uuid.uuid4()),self.tools[tool],{},self.policy,
            verified=True,priority_request=request or self.request(owner))
    def finish(self,row,result=None):
        self.store.finish(row,'succeeded',result or {'generated':True})
        release_lease(self.store,row)
    def fault(self,code,call):
        with self.assertRaises(Fault) as raised:call()
        self.assertEqual(raised.exception.code,code)
    def make_runtime(self):
        self.runtime=Runtime(self.home,policies={o:self.policy for o in self.profiles},extra_tools=self.tools.values(),
            identity_verifier=lambda c,a:None,priority_authority=self.authority)
        self.runtime.store=self.store;self.runtime.ready.set()
        return self.runtime
    def test_friday_realtime_precedes_tisra_background(self):
        low=self.submit(request=self.request(cls='background'))
        high=self.submit('friday',self.request('friday','household.response','realtime'))
        self.assertEqual(self.store.claim()['id'],high['id'])
        self.assertEqual(self.store.get('tisra',low['id'])['state'],'queued')
    def test_tisra_interactive_precedes_friday_background(self):
        self.submit('friday',self.request('friday',cls='background'))
        high=self.submit(request=self.request())
        self.assertEqual(self.store.claim()['id'],high['id'])
    def test_n2_reserved_slot_is_not_taken_by_second_background(self):
        first=self.submit(request=self.request(cls='background'))
        self.submit('friday',self.request('friday',cls='background'))
        self.assertEqual(self.store.claim()['id'],first['id'])
        self.assertIsNone(self.store.claim())
        high=self.submit('friday',self.request('friday','household.response','realtime'))
        self.assertEqual(self.store.claim()['id'],high['id'])
        self.assertEqual(self.store.db.execute('SELECT COUNT(*) FROM resource_leases').fetchone()[0],2)
    def test_n1_nonpreemptible_impossible_deadline_rejected(self):
        self.rebind(self.new_authority(resources=(ResourcePolicy('model'),ResourcePolicy('nas'),ResourcePolicy('control'))))
        self.submit(request=self.request(cls='background'));row=self.store.claim()
        self.fault('priority_deadline_unsatisfiable',lambda:self.submit('friday',self.request('friday','household.response','realtime',remaining=60)))
        self.assertEqual(self.store.db.execute('SELECT COUNT(*) FROM resource_leases').fetchone()[0],1)
        self.assertEqual(self.store.get(row['owner'],row['id'])['state'],'running')
    def test_n1_protection_window_limits_long_background_start(self):
        tasks=(replace(self.tasks[0],execution_budget_ms=2000),*self.tasks[1:])
        self.rebind(self.new_authority(resources=(ResourcePolicy('model',background_start_limit_ms=100),ResourcePolicy('nas'),ResourcePolicy('control')),tasks=tasks))
        self.fault('priority_background_protection_window',lambda:self.submit(request=self.request(cls='background')))
        self.assertEqual(self.store.db.execute('SELECT COUNT(*) FROM jobs').fetchone()[0],0)
    def test_unknown_authenticated_app_is_background_only_no_tool_grant(self):
        runtime=self.make_runtime();client=LocalClient(runtime,'new-app')
        profile=client.negotiate_priority(('realtime',))
        self.assertEqual(profile['allowed_classes'],['background'])
        self.assertIn('unknown_authenticated_app_background_only',profile['reasons'])
        self.fault('unknown_app',lambda:client.submit_priority(TOOL,{},'unknown',Client.priority_request(profile,
            task_kind='model.inference',requested_class='background',deadline_at_ms=int(time.time()*1000)+1000,resource_kind='model',estimate_ms=5)))
    def test_unverified_handshake_rejected(self):
        runtime=self.make_runtime()
        self.fault('app_identity_unverified',lambda:runtime.dispatch({'protocol':PROTOCOL,'app':'tisra','method':'priority.negotiate.v1','params':{'requested_profile':{}}}))
    def test_forged_foreign_and_epoch_profiles_rejected(self):
        request=self.request()
        self.fault('priority_profile_not_authorized',lambda:self.submit(request=dict(request,profile_id='f'*64)))
        self.fault('priority_profile_not_authorized',lambda:self.submit('friday',request))
        self.fault('priority_policy_epoch_changed',lambda:self.submit(request=dict(request,policy_epoch='authorization-epoch')))
    def test_cannot_self_assign_realtime_or_other_resource(self):
        self.fault('priority_class_not_authorized',lambda:self.submit(request=self.request(cls='realtime')))
        self.fault('priority_task_not_authorized',lambda:self.submit(request=dict(self.request(),task_kind='household.response')))
        self.fault('priority_resource_not_authorized',lambda:self.submit(request=dict(self.request(),resource_kind='control')))
    def test_registration_generation_change_cannot_restore_old_profile(self):
        request=self.request();job=self.submit(request=request,key='registration')
        self.subjects['tisra']='synthetic-tisra-registration-2'
        self.fault('priority_identity_binding_changed',lambda:self.submit(request=request,key='registration'))
        self.assertIsNone(self.store.claim());self.assertEqual(self.store.get('tisra',job['id'])['attempts'],0)
        self.assertNotEqual(self.request()['profile_id'],request['profile_id'])
    def test_multiple_connections_profiles_share_burst_and_duplicate_budget(self):
        profiles=dict(self.profiles,tisra=replace(self.profiles['tisra'],burst_calls=2))
        self.rebind(self.new_authority(profiles=profiles));runtime=self.make_runtime()
        one,two=LocalClient(runtime,'tisra'),LocalClient(runtime,'tisra')
        p1=one.negotiate_priority(('interactive',));p2=two.negotiate_priority(('background','interactive'))
        def req(p):return Client.priority_request(p,task_kind='model.inference',requested_class='interactive',deadline_at_ms=int(time.time()*1000)+10000,resource_kind='model',estimate_ms=5)
        frozen=req(p1);accepted=one.submit_priority(TOOL,{},'same-key',frozen)
        self.assertEqual(two.submit_priority(TOOL,{},'same-key',frozen)['id'],accepted['id'])
        two.submit_priority(TOOL,{},'second',req(p2))
        self.fault('priority_burst_exceeded',lambda:one.submit_priority(TOOL,{},'third',req(p1)))
        self.assertEqual(self.store.db.execute("SELECT calls FROM budget WHERE owner='tisra'").fetchone()[0],2)
    def test_weighted_fairness_same_class(self):
        self.rebind(self.new_authority(profiles=dict(self.profiles,friday=replace(self.profiles['friday'],weight=3))))
        for _ in range(24):
            self.submit();self.submit('friday',self.request('friday'))
        counts=Counter()
        for _ in range(24):
            row=self.store.claim();counts[row['owner']]+=1;self.finish(row)
        self.assertEqual(counts,{'tisra':6,'friday':18})
    def test_aging_and_bounded_bypass_never_create_realtime_authority(self):
        low=self.submit(request=self.request(cls='background'))
        for _ in range(12):self.submit('friday',self.request('friday'))
        claims=[]
        for _ in range(9):
            row=self.store.claim();claims.append(row['id']);self.assertNotEqual(row['priority'],'realtime');self.finish(row)
        self.assertIn(low['id'],claims)
    def test_deadline_order_inside_same_app_class(self):
        later=self.submit(request=self.request(remaining=10000));earlier=self.submit(request=self.request(remaining=1000))
        self.assertEqual(self.store.claim()['id'],earlier['id'])
        self.assertEqual(self.store.get('tisra',later['id'])['state'],'queued')
    def test_low_estimate_clamped_and_actual_overrun_charged(self):
        job=self.submit(request=self.request(estimate=1))
        self.assertEqual(job['scheduling']['estimate_ms'],5)
        row=self.store.claim()
        self.store.db.execute('UPDATE resource_leases SET started_ms=started_ms-20 WHERE job=?',(row['id'],))
        self.finish(row)
        service=self.store.db.execute("SELECT service FROM priority_fair WHERE owner='tisra'").fetchone()[0]
        self.assertGreaterEqual(service,20)
    def test_overload_bounded_and_expiry_zero_claim(self):
        self.rebind(self.new_authority(resources=(ResourcePolicy('model',slots=2,queue_limit=1,class_queue_limit=1),ResourcePolicy('nas'),ResourcePolicy('control'))))
        job=self.submit();self.fault('priority_resource_queue_exceeded',self.submit)
        self.store.db.execute('UPDATE jobs SET deadline_at=0 WHERE id=?',(job['id'],))
        self.assertIsNone(self.store.claim());self.assertEqual(self.store.get('tisra',job['id'])['attempts'],0)
    def test_authorized_overload_downgrade_and_minimum_class(self):
        self.rebind(self.new_authority(resources=(ResourcePolicy('model',slots=2,queue_limit=4,class_queue_limit=1),ResourcePolicy('nas'),ResourcePolicy('control'))))
        self.submit()
        job=self.submit('friday',self.request('friday',allow_fallback=True))
        self.assertEqual(job['scheduling']['effective_class'],'background')
        self.fault('priority_class_queue_exceeded',lambda:self.submit('friday',self.request('friday',allow_fallback=True,minimum_class='interactive')))
    def test_cancel_before_claim_zero_dispatch(self):
        job=self.submit();self.store.cancel('tisra',job['id'])
        self.assertIsNone(self.store.claim());self.assertEqual(self.store.get('tisra',job['id'])['attempts'],0)
    def test_cancel_ack_during_adapter_does_not_release_slot(self):
        job=self.submit();row=self.store.claim();self.store.cancel('tisra',job['id'])
        self.assertEqual(self.store.db.execute('SELECT COUNT(*) FROM resource_leases').fetchone()[0],1)
        self.assertEqual(self.store.get('tisra',job['id'])['state'],'running')
        self.store.finish(row,'succeeded',{'generated':True})
        self.assertEqual(self.store.db.execute('SELECT COUNT(*) FROM resource_leases').fetchone()[0],1)
        release_lease(self.store,row)
        self.assertEqual(self.store.db.execute('SELECT COUNT(*) FROM resource_leases').fetchone()[0],0)
    def test_post_return_cancel_encoding_cut_preserves_committed_fact(self):
        self.tools[TOOL]=replace(self.tools[TOOL],idempotent=False)
        job=self.submit();row=self.store.claim();effect={'status':'committed','generated':True}
        original=storage_module.encode;observed=[]
        def encoding(value):
            if value is effect:
                observed.append(self.store.cancel('tisra',job['id']))
            return original(value)
        with patch.object(storage_module,'encode',encoding):self.store.finish(row,'succeeded',effect)
        held=self.store.get('tisra',job['id'])
        self.assertEqual(len(observed),1);self.assertEqual(held['state'],'needs_review')
        self.assertEqual(held['result']['effect']['status'],'committed')
        self.assertFalse(held['result']['completion']['automatic_replay'])
        release_lease(self.store,row);self.assertIsNone(self.store.claim())
    def test_cancel_after_publication_preserves_success_and_audits_order(self):
        job=self.submit();row=self.store.claim();self.finish(row)
        self.assertEqual(self.store.cancel('tisra',job['id'])['state'],'succeeded')
        self.assertIsNotNone(self.store.db.execute("SELECT 1 FROM audit WHERE job=? AND event='cancel_after_priority_completion'",(job['id'],)).fetchone())
    def test_concurrent_cancel_waits_for_completion_and_is_separately_audited(self):
        self.rebind(self.new_authority(tasks=(replace(self.tasks[0],execution_budget_ms=500),*self.tasks[1:])))
        job=self.submit();row=self.store.claim();entered=threading.Event();proceed=threading.Event();ack=threading.Event()
        self.barriers.append(proceed);errors=[];original=priority_module.check_running
        def boundary(store,current):
            entered.set();proceed.wait(1);original(store,current)
        def publish():
            try:self.store.finish(row,'succeeded',{'generated':True})
            except Exception as exc:errors.append(type(exc).__name__)
        def cancel():
            self.store.cancel('tisra',job['id']);ack.set()
        with patch.object(priority_module,'check_running',boundary):
            publisher=threading.Thread(target=publish,daemon=True);self.threads.append(publisher);publisher.start()
            self.assertTrue(entered.wait(.5))
            canceler=threading.Thread(target=cancel,daemon=True);self.threads.append(canceler);canceler.start()
            self.assertFalse(ack.wait(.02));proceed.set();publisher.join(1);canceler.join(1)
        self.assertEqual(errors,[]);self.assertTrue(ack.is_set())
        self.assertEqual(self.store.get('tisra',job['id'])['state'],'succeeded')
        self.assertIsNotNone(self.store.db.execute("SELECT 1 FROM audit WHERE job=? AND event='cancel_after_priority_completion'",(job['id'],)).fetchone())
        release_lease(self.store,row)
    def test_stale_finish_and_slot_release_do_not_overwrite_new_attempt(self):
        job=self.submit();row=self.store.claim();self.finish(row)
        self.assertFalse(self.store.finish(row,'failed',error='stale'))
        self.assertFalse(release_lease(self.store,dict(row,attempts=row['attempts']+1)))
        self.assertEqual(self.store.get('tisra',job['id'])['state'],'succeeded')
    def test_policy_epoch_change_and_same_key_do_not_restore_authority_or_deadline(self):
        request=self.request();job=self.submit(request=request,key='fixed')
        before=self.store.row('tisra',job['id'])['deadline_at'];self.rebind(self.new_authority())
        self.fault('priority_policy_epoch_changed',lambda:self.submit(request=request,key='fixed'))
        self.fault('idempotency_conflict',lambda:self.submit(request=self.request(),key='fixed'))
        self.assertEqual(self.store.row('tisra',job['id'])['deadline_at'],before)
        self.assertIsNone(self.store.claim());self.assertEqual(self.store.get('tisra',job['id'])['attempts'],0)
    def test_restart_recovery_holds_inflight_without_replay(self):
        request=self.request();job=self.submit(request=request,key='restart');self.store.claim()
        self.store.close();self.store=Store(self.home/'state.sqlite');self.authority=self.new_authority();self.authority.bind(self.store)
        self.assertEqual(self.store.db.execute('SELECT COUNT(*) FROM resource_leases').fetchone()[0],1)
        self.store.recover(self.tools)
        self.assertEqual(self.store.db.execute('SELECT COUNT(*) FROM resource_leases').fetchone()[0],0)
        self.assertEqual(self.store.get('tisra',job['id'])['state'],'needs_review')
        self.assertIsNone(self.store.claim())
        self.fault('priority_policy_epoch_changed',lambda:self.submit(request=request,key='restart'))
    def test_legacy_wire_remains_exact_conservative_background(self):
        job=self.store.submit('tisra','legacy',self.tools[TOOL],{},self.policy,verified=True)
        self.assertNotIn('scheduling',job)
        row=self.store.claim();self.assertEqual(row['priority'],'background');deadline=row['deadline_at'];self.finish(row)
        again=self.store.submit('tisra','legacy',self.tools[TOOL],{},self.policy,verified=True)
        self.assertEqual(again['id'],job['id']);self.assertNotIn('scheduling',again)
        self.assertEqual(self.store.row('tisra',job['id'])['deadline_at'],deadline)
    def test_model_nas_control_share_one_queue_independent_leases(self):
        model=self.submit();self.store.claim()
        nas=self.submit(request=self.request(kind='nas.read',cls='background'),tool='fixture.nas')
        control=self.submit('friday',self.request('friday','control.deterministic','realtime'),tool='fixture.control')
        self.assertEqual(self.store.claim()['id'],control['id'])
        self.assertEqual(self.store.claim()['id'],nas['id'])
        self.assertEqual({r[0] for r in self.store.db.execute('SELECT kind FROM resource_leases')},{'model','nas','control'})
        self.assertEqual(self.store.db.execute('SELECT COUNT(*) FROM jobs').fetchone()[0],3)
    def test_actual_Runtime_work_dispatches_other_resource_while_model_blocks(self):
        entered,release,control=threading.Event(),threading.Event(),threading.Event();self.barriers.append(release)
        def model_handler(args,context):
            entered.set();release.wait(1);return {'generated':True}
        self.tools[TOOL]=replace(self.tools[TOOL],handler=model_handler)
        self.tools['fixture.control']=replace(self.tools['fixture.control'],handler=lambda a,c:(control.set(),{'generated':True})[1])
        runtime=self.make_runtime();client=LocalClient(runtime,'tisra')
        client.submit_priority(TOOL,{},'blocked',self.request())
        one=threading.Thread(target=runtime.work,daemon=True);self.threads.append(one);one.start();self.assertTrue(entered.wait(.5))
        LocalClient(runtime,'friday').submit_priority('fixture.control',{},'control',self.request('friday','control.deterministic','realtime'))
        two=threading.Thread(target=runtime.work,daemon=True);self.threads.append(two);two.start()
        self.assertTrue(control.wait(.5));self.assertFalse(release.is_set())
        self.assertIs(runtime.store,self.store);release.set()
    def test_busy_overrun_capacity_not_freed_by_estimate_or_cancel(self):
        self.rebind(self.new_authority(resources=(ResourcePolicy('model'),ResourcePolicy('nas'),ResourcePolicy('control'))))
        self.submit();row=self.store.claim()
        self.store.db.execute('UPDATE resource_leases SET expected_return_ms=0 WHERE job=?',(row['id'],))
        self.store.cancel(row['owner'],row['id'])
        self.fault('priority_capacity_unverified',lambda:self.submit('friday',self.request('friday','household.response','realtime')))
        self.assertEqual(self.store.db.execute('SELECT COUNT(*) FROM resource_leases').fetchone()[0],1)
    def test_profile_and_accepted_facts_are_strict_and_do_not_extend_deadline(self):
        profile=self.authority.negotiate('tisra','tisra',{'classes':['interactive']});validate_profile(profile)
        self.fault('priority_invalid_response',lambda:validate_profile(dict(profile,resources={'model':{'slots':99}})))
        request=self.request();facts=self.submit(request=request)['scheduling'];validate_acceptance(request,facts)
        self.fault('priority_receipt_mismatch',lambda:validate_acceptance(request,dict(facts,deadline_at_ms=facts['deadline_at_ms']+1)))
    def test_new_submission_sdk_has_no_lost_reply_retry(self):
        runtime=self.make_runtime();client=LocalClient(runtime,'tisra');calls=[]
        def rpc(method,params=None):
            calls.append(method);raise Fault('disconnected')
        client.rpc=rpc
        self.fault('disconnected',lambda:client.submit_priority(TOOL,{},'lost',self.request()))
        self.assertEqual(calls,['priority.submit.v1'])


class TypedPriorityTests(unittest.TestCase):
    """Actual typed Responses submit/receipt plus native schema validation."""
    def setUp(self):
        from test_research import Adapter, body, metadata, MODEL, FINGERPRINT
        from arl.research import ResearchEngine, ResearchGrant, NAME, METHODS
        from arl.research_client import ResearchClient
        self.fixture_body,self.metadata,self.model,self.fingerprint=body,metadata,MODEL,FINGERPRINT
        self.temp=tempfile.TemporaryDirectory(prefix='arl-priority-typed-');self.home=Path(self.temp.name)
        self.store=Store(self.home/'state.sqlite');self.adapter=Adapter()
        self.engine=ResearchEngine({'tisra':ResearchGrant('responses_fixture',frozenset({MODEL}),'authorization-epoch-1')},{'responses_fixture':self.adapter})
        self.policy=AppPolicy(frozenset({NAME}),methods=METHODS|{'health','ready','capabilities','get','cancel','submit'},max_pending=8)
        self.authority=PriorityAuthority((ResourcePolicy('model',slots=2,realtime_reserved=1),),
            (TaskPolicy(NAME,'model.inference','model',maximum_class='interactive',estimate_floor_ms=5,execution_budget_ms=100),),
            {'tisra':AppProfilePolicy(frozenset({'background','interactive'}),burst_calls=10)},
            identity_binding=lambda owner:'controlled-registered-subject-'+owner)
        self.runtime=Runtime(self.home,policies={'tisra':self.policy},research=self.engine,
            identity_verifier=lambda c,a:None,priority_authority=self.authority)
        self.runtime.store=self.store;self.runtime.bind_priority();self.runtime.ready.set();self.engine.attach(self.store)
        self.client=LocalClient(self.runtime,'tisra');self.sdk=ResearchClient(self.client)
    def tearDown(self):self.store.close();self.temp.cleanup()
    def submit(self,scheduled=True):
        profile=self.client.negotiate_priority(('interactive',))
        request=Client.priority_request(profile,task_kind='model.inference',requested_class='interactive',
            deadline_at_ms=int(time.time()*1000)+10000,resource_kind='model',estimate_ms=5)
        raw=self.fixture_body();run=str(uuid.uuid4())
        return self.sdk.submit(raw,self.metadata(raw,run),epoch=0,provider='responses_fixture',model_fingerprint=self.fingerprint,
            **({'scheduling':request} if scheduled else {}))
    def test_actual_typed_submit_receipt_status_epoch_and_no_replay(self):
        receipt,args=self.submit();self.assertEqual(receipt['scheduling']['effective_class'],'interactive')
        self.assertNotEqual(receipt['scheduling']['policy_epoch'],receipt['auth_epoch'])
        duplicate=self.client.rpc('research.submit.v1',args);self.assertEqual(duplicate['job_id'],receipt['job_id'])
        row=self.store.claim()
        from arl.service import JobContext
        reply=self.engine.execute(json.loads(row['args']),JobContext(self.runtime,row));self.engine.complete(row,reply);release_lease(self.store,row)
        self.assertEqual(self.sdk.status(receipt,args)['state'],'succeeded');self.assertEqual(len(self.adapter.calls),1)
        self.assertEqual(self.sdk.read_response(receipt,args),reply)
    def test_legacy_typed_receipt_preserves_exact_original_field_set(self):
        receipt,args=self.submit(scheduled=False)
        self.assertNotIn('scheduling',receipt);self.assertNotIn('scheduling',args)
        row=self.store.claim();self.assertEqual(row['priority'],'background')
        self.sdk.check(receipt,args)
    def test_typed_duplicate_after_policy_epoch_change_fails_without_adapter(self):
        receipt,args=self.submit();self.authority.bind(self.store)
        with self.assertRaises(Fault) as caught:self.client.rpc('research.submit.v1',args)
        self.assertEqual(caught.exception.code,'priority_policy_epoch_changed')
        self.assertEqual(self.adapter.calls,[]);self.assertIsNone(self.store.claim())
    def test_both_native_sdk_argument_schemas_accept_only_explicit_scheduling_extension(self):
        from arl.codex_research_client import _params
        from arl import codex_contract, codex_sourced_contract
        request=self.submit()[1]['scheduling']
        for contract in (codex_contract,codex_sourced_contract):
            args={'schema_version':1,'run_id':str(uuid.uuid4()),'epoch':0,
                'request':{'payload_id':str(uuid.uuid4()),'sha256':'a'*64,'byte_count':10},
                'descriptor':{'payload_id':str(uuid.uuid4()),'sha256':'b'*64,'byte_count':10},
                'provider':contract.PROVIDER,'model':'synthetic-model','model_fingerprint':'c'*64,
                'request_format':contract.FORMATS[0],'output_format':contract.FORMATS[1],'history_version':contract.FORMATS[2],
                'max_output_tokens':None,'max_output_bytes':128,'priority':'explicit','deadline_ms':30000}
            _params(args,contract);_params(dict(args,scheduling=request),contract)
            with self.assertRaises(Fault):_params(dict(args,scheduling=request,policy_epoch=request['policy_epoch']),contract)


if __name__=='__main__':unittest.main()
