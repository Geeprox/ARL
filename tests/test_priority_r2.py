"""Six retained independent cases, plus focused r2 integration boundaries.

No listener, worker, handler, provider inference, native helper or real account.
"""
import copy, json, tempfile, threading, time, unittest, uuid
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch
from arl.contracts import AppPolicy, Fault, Tool, encode, object_schema
from arl.priority import (PriorityAuthority, ResourcePolicy, TaskPolicy,
    AppProfilePolicy, RouteContext, RouteBinding, release_lease,
    validate_profile, validate_profile_v2, select_binding_v2)
from arl.storage import Store
from arl.client import Client
from arl.research import FORMATS, ResearchEngine
from arl.research_client import ResearchClient

TRACES=[]
HANDLER_CALLS=[]
def immediate(coroutine):
    # The generated _bounded implementation runs synchronously. No event loop,
    # socket pair, IPC or worker thread is needed for this adapter boundary.
    try:coroutine.send(None)
    except StopIteration as completed:return completed.value
    finally:coroutine.close()
    raise AssertionError('Unexpected suspension in generated bounded fixture')
def never_handler(args,context):
    HANDLER_CALLS.append(True)
    raise AssertionError('No handler in r2 source checks')


class PriorityR2Tests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='priority-r2-')
        self.home=Path(self.temp.name); self.stores=[]
    def tearDown(self):
        for store in self.stores:store.close()
        self.temp.cleanup()
    def store(self):
        store=Store(self.home/(str(uuid.uuid4())+'.sqlite')); self.stores.append(store); return store
    def fixture(self):
        store=self.store()
        resources=(ResourcePolicy('model',slots=2,realtime_reserved=1,queue_limit=64,class_queue_limit=64,
                                  capacity_evidence='synthetic-only'),
                   ResourcePolicy('nas',queue_limit=64,class_queue_limit=64,capacity_evidence='synthetic-only'))
        tasks=(TaskPolicy('fixture.model','model.low','model',maximum_class='interactive',estimate_floor_ms=5,execution_budget_ms=50),
               TaskPolicy('fixture.model','household.response','model',owners=frozenset({'friday'}),maximum_class='realtime',estimate_floor_ms=5,execution_budget_ms=50),
               TaskPolicy('fixture.nas','nas.read','nas',estimate_floor_ms=5,execution_budget_ms=50))
        profile=AppProfilePolicy(frozenset({'background','interactive','realtime'}),queue_limit=64,
                                 per_resource_inflight=2,burst_calls=100,max_deadline_ms=60000)
        authority=PriorityAuthority(resources,tasks,{'tisra':profile,'friday':profile},
                                    identity_binding=lambda owner:'synthetic-registration-'+owner)
        authority.bind(store)
        tools={n:Tool(n,object_schema(),never_handler,permissions=('fixture',)) for n in ('fixture.model','fixture.nas')}
        policy=AppPolicy(frozenset(tools),max_pending=100,max_calls=1000)
        return store,authority,tools,policy
    def request(self,authority,owner,kind,cls,remaining=60000,fallback=False):
        profile=authority.negotiate(owner,owner,{'classes':['background','interactive','realtime']})
        task=next(t for t in authority.tasks if t.task_kind==kind)
        return {'profile_id':profile['profile_id'],'policy_epoch':profile['policy_epoch'],
                'task_kind':kind,'requested_class':cls,'resource_kind':task.resource_kind,
                'deadline_at_ms':int(time.time()*1000)+remaining,'estimate_ms':5,
                'allow_interrupt':False,'allow_fallback':fallback}
    def submit(self,store,tools,policy,owner,request,key):
        tool=tools['fixture.nas' if request['resource_kind']=='nas' else 'fixture.model']
        return store.submit(owner,key,tool,{},policy,verified=True,priority_request=request)
    def assert_fault(self,code,call):
        with self.assertRaises(Fault) as caught:call()
        self.assertEqual(caught.exception.code,code)
    def fairness_case(self,label,kind,remaining):
        clock=[2000000000.0]
        with patch('time.time',side_effect=lambda:clock[0]):
            store,authority,tools,policy=self.fixture()
            low=self.submit(store,tools,policy,'tisra',self.request(authority,'tisra',kind,'background',remaining),'background')
            for i in range(16):
                self.submit(store,tools,policy,'friday',self.request(authority,'friday','household.response','realtime'),'rt-'+str(i))
            if label!='background-deadline-expires':clock[0]+=31
            claims=[]
            for i in range(16):
                row=store.claim(); self.assertIsNotNone(row)
                claims.append({'owner':row['owner'],'class':row['priority']})
                store.finish(row,'succeeded',{'generated':True}); self.assertTrue(release_lease(store,row))
                if label=='background-deadline-expires':clock[0]+=.075
            row=store.row('tisra',low['id'])
            self.assertEqual(row['attempts'],1); self.assertEqual(row['state'],'succeeded')
            position=next(i for i,c in enumerate(claims) if c['owner']=='tisra')
            self.assertLessEqual(position,8)
            if label!='background-deadline-expires':self.assertEqual(position,0)
            self.assertEqual(store.db.execute('SELECT COUNT(*) FROM resource_leases').fetchone()[0],0)
            TRACES.append({'case':label,'claims':claims,'background_claim_position_zero_based':position,
                           'background_state':row['state'],'background_attempts':row['attempts'],'fixed':True})
    def test_review_1_same_resource_aged(self):self.fairness_case('same-resource-aged','model.low',60000)
    def test_review_2_independent_idle_resource(self):self.fairness_case('independent-idle-resource','nas.read',60000)
    def test_review_3_background_deadline(self):self.fairness_case('background-deadline-expires','model.low',1000)
    def test_review_4_realtime_first_reservation(self):
        with patch('time.time',return_value=2000000000.0):
            store=self.store()
            profiles={o:AppProfilePolicy(frozenset({'background','realtime'}),burst_calls=10) for o in ('tisra','friday')}
            authority=PriorityAuthority((ResourcePolicy('model',slots=2,realtime_reserved=1,capacity_evidence='synthetic-only'),),
                (TaskPolicy('fixture.model','model.any','model',maximum_class='realtime',estimate_floor_ms=5,execution_budget_ms=50),),
                profiles,identity_binding=lambda owner:'synthetic-registration-'+owner)
            authority.bind(store); tool=Tool('fixture.model',object_schema(),never_handler,permissions=('fixture',))
            policy=AppPolicy(frozenset({tool.name})); jobs=[]
            for owner,cls in [('friday','realtime'),('tisra','background')]:
                grant=authority.negotiate(owner,owner,{'classes':[cls]})
                req={'profile_id':grant['profile_id'],'policy_epoch':grant['policy_epoch'],'task_kind':'model.any',
                    'resource_kind':'model','requested_class':cls,'deadline_at_ms':2000000010000,
                    'estimate_ms':5,'allow_interrupt':False,'allow_fallback':False}
                jobs.append(store.submit(owner,cls,tool,{},policy,verified=True,priority_request=req))
            first,second=store.claim(),store.claim()
            self.assertEqual([first['id'],second['id']],[j['id'] for j in jobs])
            leases=list(store.db.execute('SELECT * FROM resource_leases'))
            self.assertEqual((len(leases),sum(r['class']!='realtime' for r in leases)),(2,1))
            TRACES.append({'case':'N2_R1_realtime_first_blocks_empty_ordinary_slot','fixed':True,
                           'total_leases':2,'ordinary_leases':1,'second_claim':'background'})
            for row in (first,second):store.finish(row,'succeeded',{'generated':True}); release_lease(store,row)

    def responses_receipts(self):
        with patch('time.time',return_value=2000000000.0):
            store,authority,tools,policy=self.fixture()
            request=self.request(authority,'tisra','model.low','interactive',fallback=True)
            accepted=self.submit(store,tools,policy,'tisra',request,'typed-scheduling-fixture')['scheduling']
        args={'schema_version':1,'run_id':str(uuid.uuid4()),'epoch':0,
            'request':{'payload_id':str(uuid.uuid4()),'sha256':'a'*64,'byte_count':10},
            'descriptor':{'payload_id':str(uuid.uuid4()),'sha256':'c'*64,'byte_count':10},
            'provider':'synthetic-provider','model':'synthetic-model','model_fingerprint':'b'*64,
            'request_format':FORMATS[0],'output_format':FORMATS[1],'history_version':FORMATS[2],
            'max_output_tokens':128,'priority':'explicit','deadline_ms':60000,'scheduling':request}
        ResearchEngine.submit_args(ResearchEngine.__new__(ResearchEngine),args)
        first={'schema_version':1,'job_id':str(uuid.uuid4()),'owner':'tisra','run_id':args['run_id'],
            'request_sha256':args['request']['sha256'],'epoch':0,'auth_epoch':'synthetic-authorization-epoch',
            'state':'queued',**{k:args[k] for k in ['provider','model','model_fingerprint','request_format','output_format','history_version']},
            'result_ref':None,'error_code':None,'cancel_requested':False,'external_stop':'not_started','scheduling':accepted}
        return first,args
    def test_review_5_responses_accepted_facts_drift(self):
        first,args=self.responses_receipts(); changed=copy.deepcopy(first)
        changed['scheduling'].update(effective_class='background',estimate_ms=6,execution_budget_ms=60,reasons=['authorized_class_downgrade'])
        calls=[]
        client=SimpleNamespace(app='tisra',rpc=lambda method,p:(calls.append(method),copy.deepcopy(changed))[1])
        sdk=ResearchClient(client); sdk.check(first,args)
        self.assert_fault('research_receipt_mismatch',lambda:sdk.status(first,args))
        TRACES.append({'case':'responses-accepted-facts-drift','fixed':True,'rpc_calls':calls,
                       'drift_rejected':'research_receipt_mismatch','full_server_args_grammar_checked':True})

    def route_authority(self,rows,tasks=None,policy=None):
        store=self.store(); policy=policy or AppPolicy(frozenset({'fixture.research','fixture.other'}))
        tasks=tasks or (TaskPolicy('fixture.research','model.inference','model',maximum_class='interactive',estimate_floor_ms=5,execution_budget_ms=100),)
        authority=PriorityAuthority((ResourcePolicy('model',slots=2,realtime_reserved=1),ResourcePolicy('nas')),
            tasks,{'tisra':AppProfilePolicy(frozenset({'background','interactive'}),burst_calls=100)},
            identity_binding=lambda owner:'synthetic-registered-'+owner,route_capabilities=lambda owner:tuple(rows))
        authority.bind(store,{'tisra':policy})
        return store,authority,policy
    def row(self,resource='model',provider=None,model=None,fingerprint=None,tool='fixture.research',method='priority.submit.v1',ready=True):
        return RouteBinding(tool,'model.inference',resource,RouteContext(method,provider,model,fingerprint),
                            'interactive',5,80,ready)
    def v2_request(self,profile,**route):
        return Client.priority_request_v2(profile,task_kind='model.inference',requested_class='interactive',
            deadline_at_ms=int(time.time()*1000)+10000,estimate_ms=5,
            submit_method=route.pop('submit_method','priority.submit.v1'),tool=route.pop('tool','fixture.research'),**route)
    def test_review_6_visible_task_resource_mapping(self):
        profiles=[]; outcomes=[]
        for label,research_resource,other_resource in [('A','model','nas'),('B','nas','model')]:
            tasks=(TaskPolicy('fixture.research','model.inference',research_resource,maximum_class='interactive'),
                   TaskPolicy('fixture.other','other.task',other_resource))
            row=RouteBinding('fixture.research','model.inference',research_resource,RouteContext('priority.submit.v1'),'interactive',100,1000,True)
            store,authority,policy=self.route_authority([row],tasks)
            profile=authority.negotiate_v2('tisra','tisra',{'classes':['interactive']}); validate_profile_v2(profile)
            req=self.v2_request(profile); req['estimate_ms']=100
            task,cls,_=authority.authorize('tisra','fixture.research',req,RouteContext('priority.submit.v1'))
            self.assertEqual(task.resource_kind,research_resource)
            wrong=dict(req,resource_kind=other_resource)
            self.assert_fault('priority_resource_not_authorized',lambda:authority.authorize('tisra','fixture.research',wrong,RouteContext('priority.submit.v1')))
            self.assertEqual(store.db.execute('SELECT COUNT(*) FROM jobs').fetchone()[0],0)
            profiles.append(profile['task_bindings']); outcomes.append({'host':label,'selected':req['resource_kind'],'authorized':cls})
        self.assertNotEqual(profiles[0],profiles[1])
        TRACES.append({'case':'task-resource-negotiation-ambiguity','fixed':True,'visible_bindings_distinct':True,
                       'exact_host_selections':outcomes,'wrong_resource_rejected':True,'jobs_inserted':0})

    def test_distinct_provider_same_task_and_exact_method_fingerprint(self):
        rows=[self.row(provider='provider-A',model='model-A',fingerprint='revision-A'),
              self.row(resource='nas',provider='provider-B',model='model-B',fingerprint='revision-B')]
        tasks=tuple(TaskPolicy('fixture.research','model.inference',kind,maximum_class='interactive',estimate_floor_ms=10,execution_budget_ms=100) for kind in ('model','nas'))
        store,authority,policy=self.route_authority(rows,tasks)
        profile=authority.negotiate_v2('tisra','tisra',{'classes':['interactive']})
        tool=Tool('fixture.research',object_schema(),never_handler,permissions=('fixture',))
        for row in rows:
            req=self.v2_request(profile,**row.route.projection())
            accepted=store.submit('tisra',row.route.provider,tool,{},policy,verified=True,
                                  priority_request=req,priority_route=row.route)
            self.assertEqual(accepted['scheduling']['resource_kind'],row.resource_kind)
            self.assertEqual((accepted['scheduling']['estimate_ms'],accepted['scheduling']['execution_budget_ms']),(10,80))
        req=self.v2_request(profile,**rows[0].route.projection())
        self.assert_fault('priority_resource_not_authorized',lambda:authority.authorize('tisra',tool.name,dict(req,resource_kind='nas'),rows[0].route))
        self.assert_fault('priority_route_binding_unavailable',lambda:authority.authorize('tisra',tool.name,req,RouteContext('research.submit.v1','provider-A','model-A','revision-A')))
        self.assert_fault('priority_route_binding_unavailable',lambda:self.v2_request(profile,provider='provider-A',model='model-A',model_fingerprint='other-revision'))
        self.assertEqual(store.db.execute('SELECT COUNT(*) FROM jobs').fetchone()[0],2)
        # Different providers in one pool still cannot share a logical key/body.
        shared=[self.row(provider='A',model='A'),self.row(provider='B',model='B')]
        store,authority,policy=self.route_authority(shared)
        profile=authority.negotiate_v2('tisra','tisra',{'classes':['interactive']})
        req=self.v2_request(profile,provider='A',model='A')
        store.submit('tisra','fixed-key',tool,{},policy,verified=True,priority_request=req,priority_route=shared[0].route)
        self.assert_fault('idempotency_conflict',lambda:store.submit('tisra','fixed-key',tool,{},policy,verified=True,priority_request=req,priority_route=shared[1].route))

    def test_unready_missing_unknown_app_and_ambiguous_routes_hold(self):
        rows=[self.row(ready=False)]
        store,authority,policy=self.route_authority(rows)
        for owner in ('tisra','unknown-authenticated'):
            profile=authority.negotiate_v2(owner,owner,{'classes':['interactive']})
            self.assertEqual(profile['task_bindings'],[])
            self.assert_fault('priority_route_binding_unavailable',lambda:self.v2_request(profile))
        authority.route_capabilities=None
        # Host configuration mutation requires a fresh epoch, then absence stays closed.
        authority.bind(store,{'tisra':policy}); self.assertEqual(authority.negotiate_v2('tisra','tisra',{})['task_bindings'],[])
        rows[:]=[self.row(),self.row(resource='nas')]
        tasks=(TaskPolicy('fixture.research','model.inference','model',maximum_class='interactive',estimate_floor_ms=5,execution_budget_ms=100),
               TaskPolicy('fixture.research','model.inference','nas',maximum_class='interactive',estimate_floor_ms=5,execution_budget_ms=100))
        _,ambiguous,_=self.route_authority(rows,tasks)
        self.assert_fault('priority_route_binding_unavailable',lambda:ambiguous.negotiate_v2('tisra','tisra',{'classes':['interactive']}))
        self.assertEqual(store.db.execute('SELECT COUNT(*) FROM jobs').fetchone()[0],0)

    def test_current_capability_change_blocks_claim_and_idempotent_replay(self):
        rows=[self.row()]; store,authority,policy=self.route_authority(rows)
        profile=authority.negotiate_v2('tisra','tisra',{'classes':['interactive']}); req=self.v2_request(profile)
        tool=Tool('fixture.research',object_schema(),never_handler,permissions=('fixture',))
        job=store.submit('tisra','same-key',tool,{},policy,verified=True,priority_request=req,priority_route=rows[0].route)
        rows[:]=[self.row(ready=False)]
        self.assert_fault('priority_route_binding_changed',lambda:store.submit('tisra','same-key',tool,{},policy,verified=True,priority_request=req,priority_route=RouteContext('priority.submit.v1')))
        self.assertIsNone(store.claim()); self.assertEqual(store.row('tisra',job['id'])['attempts'],0)
        self.assertEqual(store.db.execute('SELECT COUNT(*) FROM resource_leases').fetchone()[0],0)

    def test_optin_params_dictionary_mutation_cannot_replace_first_pin(self):
        first,args=self.responses_receipts(); sdk=ResearchClient(SimpleNamespace(app='tisra'))
        sdk.check(first,args)
        first['scheduling']['execution_budget_ms']=60
        self.assert_fault('research_receipt_mismatch',lambda:sdk.check(first,args))
        first,args=self.responses_receipts(); sdk=ResearchClient(SimpleNamespace(app='tisra')); sdk.check(first,args)
        args['max_output_tokens']=129
        self.assert_fault('research_receipt_mismatch',lambda:sdk.check(first,args))
        args['run_id']=str(uuid.uuid4()); changed=copy.deepcopy(first); changed['run_id']=args['run_id']
        self.assert_fault('research_receipt_mismatch',lambda:sdk.check(changed,args))

    def test_v1_wire_unchanged_and_v2_decoder_strict(self):
        _,authority,_,_=self.fixture(); v1=authority.negotiate('tisra','tisra',{'classes':['interactive']})
        validate_profile(v1); self.assertNotIn('task_bindings',v1)
        _,authority,_=self.route_authority([self.row()]); v2=authority.negotiate_v2('tisra','tisra',{'classes':['interactive']})
        self.assert_fault('priority_invalid_response',lambda:validate_profile(v2))
        for mutation in ('extra','duplicate','dangling-resource','non-list-reasons'):
            bad=copy.deepcopy(v2)
            if mutation=='extra':bad['task_bindings'][0]['binding_id']='guessed'
            elif mutation=='duplicate':bad['task_bindings'].append(copy.deepcopy(bad['task_bindings'][0]))
            elif mutation=='dangling-resource':bad['task_bindings'][0]['resource_kind']='invented'
            else:bad['reasons']=''
            self.assert_fault('priority_invalid_response',lambda:validate_profile_v2(bad))
        # Build one exact legacy receipt from the same arguments, without queue fields.
        legacy,args=self.responses_receipts(); legacy.pop('scheduling'); args.pop('scheduling')
        ResearchClient(SimpleNamespace(app='tisra')).check(legacy,args)

    def test_actual_typed_submit_uses_validated_route_without_inference(self):
        from tests.test_research import Adapter,body,metadata,MODEL,FINGERPRINT
        from arl.research import ResearchGrant,NAME,METHODS
        store=self.store(); adapter=Adapter()
        engine=ResearchEngine({'tisra':ResearchGrant('responses_fixture',frozenset({MODEL}),'synthetic-auth-epoch')},{'responses_fixture':adapter})
        engine.attach(store)
        route=RouteContext('research.submit.v1','responses_fixture',MODEL,FINGERPRINT)
        rows=[RouteBinding(NAME,'model.inference','model',route,'interactive',5,100,True)]
        policy=AppPolicy(frozenset({NAME}),methods=METHODS)
        authority=PriorityAuthority((ResourcePolicy('model',slots=2,realtime_reserved=1),),
            (TaskPolicy(NAME,'model.inference','model',maximum_class='interactive',estimate_floor_ms=5,execution_budget_ms=100),),
            {'tisra':AppProfilePolicy(frozenset({'background','interactive'}),burst_calls=10)},
            identity_binding=lambda owner:'synthetic-subject-'+owner,route_capabilities=lambda owner:tuple(rows))
        authority.bind(store,{'tisra':policy}); profile=authority.negotiate_v2('tisra','tisra',{'classes':['interactive']})
        req=self.v2_request(profile,submit_method=route.submit_method,tool=NAME,**route.projection())
        class Direct:
            app='tisra'
            def rpc(self,method,p):return engine.dispatch(self.app,method,p,policy)
        sdk=ResearchClient(Direct()); raw=body(); run=str(uuid.uuid4())
        receipt,args=sdk.submit(raw,metadata(raw,run),epoch=0,provider=route.provider,model_fingerprint=FINGERPRINT,scheduling=req)
        self.assertEqual(json.loads(store.row('tisra',receipt['job_id'])['schedule_v1'])['route'],{
            'submit_method':route.submit_method,**route.projection()})
        self.assertEqual(sdk.status(receipt,args)['scheduling'],receipt['scheduling'])
        duplicate=engine.dispatch('tisra','research.submit.v1',args,policy)
        self.assertEqual(duplicate['job_id'],receipt['job_id']); self.assertEqual(adapter.calls,[])

    def test_codex_method_forwarding_retains_original_namespace(self):
        from arl.codex_research import CodexResearchEngine
        engine=CodexResearchEngine.__new__(CodexResearchEngine)
        with patch.object(ResearchEngine,'dispatch',return_value={'generated':True}) as dispatch:
            engine.dispatch('tisra','codex.research.submit.v1',{},None)
            self.assertEqual(dispatch.call_args.kwargs,{'submit_method':'codex.research.submit.v1','in_transaction':False})

    def test_generic_runtime_derives_route_after_router_check(self):
        from arl.service import Runtime
        from arl.capabilities import build_tools
        store=self.store(); policy=AppPolicy(frozenset({'model.complete'}))
        rows=[RouteBinding('model.complete','model.inference','model',RouteContext('priority.submit.v1','mock','deterministic-v1'),'interactive',5,80,True)]
        _,authority,_=self.route_authority(rows,(TaskPolicy('model.complete','model.inference','model',maximum_class='interactive',estimate_floor_ms=5,execution_budget_ms=100),),policy)
        # Dispatch uses actual Runtime method and actual Store, no constructor/start/listener.
        runtime=Runtime.__new__(Runtime); runtime.policies={'tisra':policy}; runtime.store=authority.store
        runtime.priority_authority=authority; runtime.priority_producer=None; runtime.identity_verifier=lambda c,a:None
        runtime.capture=None; runtime.admission=None; runtime.control=SimpleNamespace(apps=SimpleNamespace(observe_verified=lambda owner:None))
        runtime.ready=threading.Event(); runtime.ready.set(); runtime.stopping=threading.Event(); runtime.job_signal=threading.Event()
        runtime.router=SimpleNamespace(check=Mock()); runtime.tools=build_tools(runtime.router,SimpleNamespace(tools=lambda:[]),SimpleNamespace(tools=lambda:[]))
        profile=runtime.dispatch({'protocol':'arl/1','app':'tisra','method':'priority.negotiate.v2','params':{'requested_profile':{'classes':['interactive']}}},verified_app='tisra')
        req=self.v2_request(profile,tool='model.complete',provider='mock',model='deterministic-v1')
        args={'provider':'mock','model':'deterministic-v1','prompt':'synthetic','max_tokens':8}
        job=runtime.dispatch({'protocol':'arl/1','app':'tisra','method':'priority.submit.v1','params':{'tool':'model.complete','args':args,'key':'generated','scheduling':req}},verified_app='tisra')
        runtime.router.check.assert_called_once_with('tisra',args)
        self.assertEqual(json.loads(runtime.store.row('tisra',job['id'])['schedule_v1'])['route']['model'],'deterministic-v1')
        bad=copy.deepcopy(args); bad['model']='other'
        self.assert_fault('priority_route_binding_unavailable',lambda:runtime.dispatch({'protocol':'arl/1','app':'tisra','method':'priority.submit.v1','params':{'tool':'model.complete','args':bad,'key':'wrong','scheduling':req}},verified_app='tisra'))

    def test_friday_status_drift_rejected_with_single_submit_and_cleanup(self):
        from arl.friday_planning import NAME,SCHEMA,PERMISSIONS
        from arl.friday_planning_client import ReviewedRemoval,plan_removal
        _,args=self.responses_receipts(); scheduling=args['scheduling']
        facts=self.responses_receipts()[0]['scheduling']; facts.update({k:scheduling[k] for k in ('profile_id','policy_epoch','deadline_at_ms')})
        now=int(time.time()*1000)
        scheduling['deadline_at_ms']=now+2500;facts['deadline_at_ms']=now+2500
        request={'schema_version':1,'execution_id':str(uuid.uuid4()),'text':'synthetic reviewed removal',
            'context_fingerprint':'a'*64,'captured_at_ms':now,'expires_at_ms':now+50000,
            'choices':[{'record_id':'simulated:arrival:v1','action_id':'arrival-ac','expected_fingerprint':'b'*64,'rule_label':'arrival','action_label':'AC'}]}
        action=ReviewedRemoval(request,'synthetic-model'); calls=[]
        first={'id':'generated-job','tool':NAME,'state':'queued','scheduling':facts}
        changed=copy.deepcopy(first); changed['scheduling']['execution_budget_ms']=60
        class GeneratedClient:
            def connect(self,timeout):pass
            def rpc(self,method,p=None):
                calls.append(method)
                if method=='capabilities':return {'protocol':'arl/1','version':1,'tools':[{'name':NAME,'version':1,'inputSchema':SCHEMA,'permissions':list(PERMISSIONS),'idempotent':False,'availability':'adapter'}]}
                if method=='priority.submit.v1':return copy.deepcopy(first)
                return copy.deepcopy(changed)
        async def bounded(work,timeout):return work(threading.Event())
        runtime=SimpleNamespace(home=lambda:self.home,client_factory=lambda home,flag:GeneratedClient(),_bounded=bounded)
        self.assert_fault('planning_receipt_mismatch',lambda:immediate(plan_removal(runtime,action,deadline=time.monotonic()+3,current_context=lambda:request['context_fingerprint'],scheduling=scheduling)))
        self.assertEqual(calls.count('priority.submit.v1'),1); self.assertEqual(calls.count('get'),1); self.assertEqual(calls.count('cancel'),1)
