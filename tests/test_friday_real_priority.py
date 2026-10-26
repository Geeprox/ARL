"""Four generated consumer-to-Store checks. No socket, account, model or device."""
import asyncio
import ast
import hashlib
import importlib.util
import json
import os
import struct
import tempfile
import time
import unittest
import uuid
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from arl import PROTOCOL
from arl.client import Client
from arl.codex_server import CodexTextAdapter
from arl.contracts import AppPolicy, Fault
from arl.friday_planning import FridayRemovalPlanner, NAME as PLANNING
from arl.friday_planning_client import ReviewedRemoval, plan_removal
from arl.friday_profile import PlanningAdmission
from arl.identity import RegisteredPeerVerifier
from arl.priority import AppProfilePolicy, ResourcePolicy, TaskPolicy, release_lease
from arl.priority_host import PriorityHostConfig, RegisteredRouteProducer
from arl.providers import MockProvider
from arl.service import JobContext, Runtime
from arl.storage import Store

FRIDAY_SOURCE=Path(os.environ.get('ARL_FRIDAY_ADAPTER',str(Path(__file__).resolve().parents[1]/'build/optional-friday/arl.py')))
FRIDAY_PLANNING_SOURCE=FRIDAY_SOURCE.with_name('arl_rule_planning.py')
FRIDAY_SOURCE_SHA='f584b2b71f0c4d180cf21569988b46ce7f931005cb9fe3e1d7bcd4478f91b4b8'
FRIDAY_PLANNING_SHA='0ceffceb0565d1dadd2d2a442a3183e69153e1e93b8aac14a952115110970433'

class Connection:
    def __init__(self,pid):self.pid=pid
    def getsockopt(self,level,option,size):
        assert (level,option,size)==(0,2,4)
        return struct.pack('i',self.pid)

class DirectClient(Client):
    def __init__(self,home,runtime,verifier,pid,hook=None):
        super().__init__(home,'friday')
        self.runtime,self.verifier,self.pid,self.hook=runtime,verifier,pid,hook
        self.calls=[]
    def connect(self,timeout=10):return {'ready':True}
    def rpc(self,method,params=None):
        self.calls.append((method,params))
        result=self.runtime.dispatch({'protocol':PROTOCOL,'app':'friday','method':method,'params':params or {}},
                                     verified_app=self.verifier(Connection(self.pid),'friday'))
        if self.hook:self.hook(method,result)
        return result

class FixtureMock(MockProvider):
    model='deterministic-v1'
    def discover(self):
        return {'name':self.name,'availability':'ready','models':[self.model],
                'paid':False,'evidence':'test_double'}
    def complete(self,args,context):
        context.check_cancelled()
        return {'provider':self.name,'model':args['model'],'text':'fixture','simulated':True}

class MemorySession:
    on_thread=None
    def __init__(self,binary,workspace,**kwargs):
        self.model=None;self.thread_id=None;self.turn_id=None
        self.process=SimpleNamespace(returncode=0)
    def initialize(self):pass
    def send(self,method,params):
        if method=='thread/start':self.model=params['model'];return method
        if method=='turn/start':raise Fault('synthetic_stopped_before_inference')
        raise AssertionError(method)
    def response(self,request):
        assert request=='thread/start'
        if type(self).on_thread:type(self).on_thread()
        return {'model':self.model,'thread':{'id':'fixture-thread','ephemeral':True}}
    def close(self):pass
    def cancel_turn(self):raise AssertionError('no turn')

@unittest.skipUnless(FRIDAY_SOURCE.is_file(), 'Set ARL_FRIDAY_ADAPTER to the separately pinned consumer source')
class FridayPriorityTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='arl-friday-priority-')
        self.root=Path(self.tmp.name);self.binary=self.root/'pin';self.binary.write_bytes(b'fixture-only')
        self.pid=51003
        self.identity={'uid':os.geteuid(),'birth':(4,5),'executable':str(self.binary.resolve())}
        self.patch=patch('arl.identity.process_identity',side_effect=lambda pid:dict(self.identity));self.patch.start()
        self.verifier=RegisteredPeerVerifier({'friday'});self.verifier.register('friday',self.pid,self.binary)
        self.store=None;self.runtime=None;self.producer=None
    def tearDown(self):
        if self.store:self.store.close()
        self.patch.stop();self.tmp.cleanup()
    def setup_host(self,*,planner=False):
        self.provider=FixtureMock()
        self.tasks=[TaskPolicy('model.complete','household.model','model',owners=frozenset({'friday'}),
                               maximum_class='interactive',estimate_floor_ms=5,execution_budget_ms=3000)]
        self.adapter=None;self.admission=None;extra=()
        if planner:
            now=int(time.time()*1000)
            review={'schema_version':1,'execution_id':str(uuid.uuid4()),'text':'remove generated action',
                    'context_fingerprint':'a'*64,'captured_at_ms':now,'expires_at_ms':now+30000,
                    'choices':[{'record_id':'fixture:1','action_id':'fixture-action',
                                'expected_fingerprint':'b'*64,'rule_label':'fixture rule','action_label':'fixture action'}]}
            self.admission=PlanningAdmission(review)
            self.adapter=CodexTextAdapter(binary=self.binary,enabled=True,test_command=(str(self.binary),))
            self.planner=FridayRemovalPlanner(self.adapter);extra=(self.planner.tool(),)
            self.tasks.append(TaskPolicy(PLANNING,'friday.reviewed.plan','model',owners=frozenset({'friday'}),
                                         maximum_class='interactive',estimate_floor_ms=5,execution_budget_ms=3000))
        methods=frozenset({'health','ready','capabilities','providers','submit','get','cancel'})
        tools={'model.complete'} | ({PLANNING} if planner else set())
        policy=AppPolicy(frozenset(tools),frozenset({'mock'}),max_tokens=256,max_pending=4,max_calls=4,
                         methods=methods,max_deadline_ms=30000)
        self.runtime=Runtime(self.root/'runtime',policies={'friday':policy},providers={'mock':self.provider},
                             local_enabled=True,extra_tools=extra,admission=self.admission,
                             identity_verifier=self.verifier,execute_jobs=True)
        self.store=Store(self.root/'state.sqlite');self.runtime.store=self.store
        self.store.publication_admission=self.runtime.check_publication_admission
        config=PriorityHostConfig((ResourcePolicy('model',slots=1,realtime_reserved=0,
                                  capacity_evidence='fixture-only'),),tuple(self.tasks),
                                  {'friday':AppProfilePolicy(frozenset({'background','interactive'}),
                                   burst_calls=10,max_deadline_ms=30000)},10000,True)
        self.producer=RegisteredRouteProducer(self.runtime,self.verifier,config)
        self.producer.register_generic(self.provider,self.provider.model,task_kind='household.model',resource_kind='model')
        if planner:self.producer.register_planner(self.planner,task_kind='friday.reviewed.plan',
                                                  resource_kind='model',backend='codex_app_server')
        self.runtime.bind_priority();self.runtime.ready.set();self.runtime.control.providers._probe()
        return review if planner else None

    def test_generic_actual_friday_consumer_to_store(self):
        self.setup_host();claimed=[]
        if hashlib.sha256(FRIDAY_SOURCE.read_bytes()).hexdigest() != FRIDAY_SOURCE_SHA:
            self.skipTest('External Friday consumer differs from the reviewed pin; no implicit repinning')
        def hook(method,result):
            if method=='submit' and not claimed:
                row=self.store.claim();claimed.append(row)
                self.assertEqual(row['state'],'running')
                self.assertEqual(self.store.db.execute('SELECT COUNT(*) FROM resource_leases').fetchone()[0],1)
                value=self.runtime.tools['model.complete'].handler(json.loads(row['args']),JobContext(self.runtime,row))
                self.store.finish(row,'succeeded',value);release_lease(self.store,row)
        direct=DirectClient(self.root/'runtime',self.runtime,self.verifier,self.pid,hook)
        spec=importlib.util.spec_from_file_location('actual_friday_arl_consumer',FRIDAY_SOURCE)
        module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
        consumer=module.ARLRuntime(home=lambda:self.runtime.home,client_factory=lambda home,start:direct)
        value=asyncio.run(consumer.complete('mock',self.provider.model,'fixture household input',
                                             deadline=time.monotonic()+5,max_tokens=32))
        self.assertEqual(value['text'],'fixture')
        self.assertEqual(len(claimed),1)
        self.assertTrue(json.loads(claimed[0]['schedule_v1'])['protocol_optin'])
        self.assertEqual(json.loads(claimed[0]['schedule_v1'])['request']['task_kind'],'household.model')
        key=claimed[0]['key'];args=json.loads(claimed[0]['args'])
        replay=direct.rpc('submit',{'tool':'model.complete','args':args,'key':key})
        self.assertEqual(replay['id'],claimed[0]['id'])
        self.assertEqual(self.store.db.execute('SELECT COUNT(*) FROM jobs').fetchone()[0],1)

    def test_typed_first_v2_without_legacy_bootstrap(self):
        review=self.setup_host(planner=True)
        self.assertEqual(hashlib.sha256(FRIDAY_PLANNING_SOURCE.read_bytes()).hexdigest(),FRIDAY_PLANNING_SHA)
        app_calls=[node for node in ast.walk(ast.parse(FRIDAY_PLANNING_SOURCE.read_text()))
                   if isinstance(node,ast.Call) and isinstance(node.func,ast.BoolOp) and
                   any(isinstance(v,ast.Name) and v.id=='plan_removal' for v in node.func.values)]
        self.assertEqual(len(app_calls),1)
        self.assertEqual({keyword.arg for keyword in app_calls[0].keywords},{'deadline','current_context'})
        with patch('arl.codex_server.Session',MemorySession):
            self.producer.probe_planner('friday',self.admission.args['model'])
        self.assertEqual(len(self.producer.snapshot('friday')),2)
        claimed=[]
        def hook(method,result):
            if method=='priority.submit.v1':
                row=self.store.claim();claimed.append(row)
                self.store.finish(row,'needs_review',error='synthetic_stopped_before_inference')
                release_lease(self.store,row)
        direct=DirectClient(self.root/'runtime',self.runtime,self.verifier,self.pid,hook)
        gate=SimpleNamespace(home=lambda:self.runtime.home,client_factory=lambda home,start:direct,
                             _bounded=lambda operation,timeout:asyncio.to_thread(operation,SimpleNamespace(is_set=lambda:False,wait=lambda t:None)))
        reviewed=ReviewedRemoval(review,self.admission.args['model'])
        with self.assertRaises(Fault) as caught:
            asyncio.run(plan_removal(gate,reviewed,deadline=time.monotonic()+5,
                                     current_context=lambda:review['context_fingerprint']))
        self.assertEqual(caught.exception.code,'planning_job_needs_review')
        self.assertEqual([m for m,_ in direct.calls if m in {'submit','priority.submit.v1'}],['priority.submit.v1'])
        self.assertEqual(len(claimed),1);self.assertEqual(claimed[0]['key'],review['execution_id'])
        self.assertTrue(json.loads(claimed[0]['schedule_v1'])['protocol_optin'])

    def test_review_expiry_is_hard_priority_deadline_and_replay_keeps_facts(self):
        review=self.setup_host(planner=True)
        with patch('arl.codex_server.Session',MemorySession):
            self.producer.probe_planner('friday',self.admission.args['model'])
        claimed=[]
        def hook(method,result):
            if method=='priority.submit.v1' and not claimed:
                row=self.store.claim();claimed.append(row)
                self.store.finish(row,'needs_review',error='synthetic_stopped_before_inference')
                release_lease(self.store,row)
        direct=DirectClient(self.root/'runtime',self.runtime,self.verifier,self.pid,hook)
        gate=SimpleNamespace(home=lambda:self.runtime.home,client_factory=lambda home,start:direct,
                             _bounded=lambda operation,timeout:asyncio.to_thread(operation,SimpleNamespace(is_set=lambda:False,wait=lambda t:None)))
        reviewed=ReviewedRemoval(review,self.admission.args['model'])
        wall_ms=review['expires_at_ms']-5000
        mono=100.0
        sdk_clock=SimpleNamespace(time=lambda:(wall_ms+0.5)/1000,monotonic=lambda:mono)
        self.assertEqual(int(sdk_clock.time()*1000),wall_ms)
        self.assertEqual(int((mono+5.001-mono)*1000),5001)
        with patch('arl.friday_planning_client.time',sdk_clock):
            with self.assertRaises(Fault) as caught:
                asyncio.run(plan_removal(gate,reviewed,deadline=mono+5.001,
                                         current_context=lambda:review['context_fingerprint']))
        self.assertEqual(caught.exception.code,'planning_job_needs_review')
        submits=[params for method,params in direct.calls if method=='priority.submit.v1']
        self.assertEqual(len(submits),1)
        request=submits[0]
        self.assertEqual(request['scheduling']['deadline_at_ms'],review['expires_at_ms'])
        first=direct.rpc('get',{'id':claimed[0]['id']})
        replay=direct.rpc('priority.submit.v1',json.loads(json.dumps(request)))
        self.assertEqual(replay['id'],claimed[0]['id'])
        self.assertEqual(replay['scheduling'],first['scheduling'])
        self.assertEqual(self.store.db.execute('SELECT COUNT(*) FROM jobs').fetchone()[0],1)
        near_expiry=SimpleNamespace(time=lambda:(review['expires_at_ms']-3099.5)/1000,
                                    monotonic=lambda:mono)
        self.assertEqual(int(near_expiry.time()*1000),review['expires_at_ms']-3100)
        with patch('arl.friday_planning_client.time',near_expiry):
            with self.assertRaises(Fault) as too_short:
                asyncio.run(plan_removal(gate,reviewed,deadline=mono+20,
                                         current_context=lambda:review['context_fingerprint']))
        self.assertEqual(too_short.exception.code,'planning_cancelled_or_expired')
        late=json.loads(json.dumps(request['scheduling']))
        late['deadline_at_ms']=review['expires_at_ms']+1
        with self.assertRaises(Fault) as rejected:
            asyncio.run(plan_removal(gate,reviewed,deadline=time.monotonic()+5,
                                     current_context=lambda:review['context_fingerprint'],scheduling=late))
        self.assertEqual(rejected.exception.code,'invalid_deadline')
        self.assertEqual(len([m for m,_ in direct.calls if m=='priority.submit.v1']),2)

    def test_revoke_holds_generic_and_typed_binding(self):
        self.setup_host(planner=True)
        with patch('arl.codex_server.Session',MemorySession):
            self.producer.probe_planner('friday',self.admission.args['model'])
        direct=DirectClient(self.root/'runtime',self.runtime,self.verifier,self.pid)
        profile=direct.rpc('priority.negotiate.v2',{'requested_profile':{'classes':['background','interactive']}})
        self.assertEqual(len(profile['task_bindings']),2)
        legacy=direct.rpc('priority.negotiate.v1',{'requested_profile':{'classes':['background','interactive']}})
        weak=Client.priority_request(legacy,task_kind='household.model',requested_class='interactive',
            deadline_at_ms=int(time.time()*1000)+10000,resource_kind='model',estimate_ms=5)
        with self.assertRaises(Fault) as weak_rejected:
            direct.rpc('priority.submit.v1',{'tool':'model.complete','args':{'provider':'mock',
                'model':self.provider.model,'prompt':'x','max_tokens':32},'key':'weak-v1','scheduling':weak})
        self.assertEqual(weak_rejected.exception.code,'priority_route_binding_unavailable')
        self.verifier.revoke(self.pid)
        self.assertIsNone(self.verifier(Connection(self.pid),'friday'))
        self.assertEqual(self.producer.snapshot('friday'),())
        with self.assertRaises(Fault):direct.rpc('submit',{'tool':'model.complete','args':{'provider':'mock',
            'model':self.provider.model,'prompt':'x','max_tokens':32},'key':'revoked'})
        self.assertEqual(self.store.db.execute('SELECT COUNT(*) FROM jobs').fetchone()[0],0)

    def test_replacement_during_preflight_preserves_new_generation(self):
        self.setup_host(planner=True)
        before=self.verifier.registration_generation('friday',self.pid)
        def replace():self.verifier.register('friday',self.pid,self.binary)
        MemorySession.on_thread=replace
        try:
            with patch('arl.codex_server.Session',MemorySession):
                with self.assertRaises(Fault) as caught:
                    self.producer.probe_planner('friday',self.admission.args['model'])
            self.assertEqual(caught.exception.code,'priority_route_binding_changed')
            self.assertGreater(self.verifier.registration_generation('friday',self.pid),before)
            self.assertEqual(len(self.producer.preflights),0)
            self.assertEqual(self.store.db.execute('SELECT COUNT(*) FROM jobs').fetchone()[0],0)
        finally:MemorySession.on_thread=None

    def test_revoke_after_claim_and_late_publication_held(self):
        self.setup_host()
        direct=DirectClient(self.root/'runtime',self.runtime,self.verifier,self.pid)
        args={'provider':'mock','model':self.provider.model,'prompt':'fixture','max_tokens':32}
        first=direct.rpc('submit',{'tool':'model.complete','args':args,'key':'late-fixture'})
        row=self.store.claim();self.assertEqual(row['id'],first['id'])
        generation=self.verifier.registration_generation('friday',self.pid)
        self.verifier.revoke(self.pid,expected_generation=generation)
        self.verifier.register('friday',self.pid,self.binary)
        replacement=self.verifier.registration_generation('friday',self.pid)
        self.assertTrue(self.store.finish(row,'succeeded',{'provider':'mock','model':args['model'],
                                                            'text':'late','simulated':True}))
        held=self.store.get('friday',first['id'])
        self.assertEqual(held['state'],'needs_review')
        self.assertIsNone(held['result'])
        self.assertEqual(self.verifier.registration_generation('friday',self.pid),replacement)
        self.assertEqual(self.store.db.execute('SELECT COUNT(*) FROM jobs').fetchone()[0],1)

    def test_review_change_before_publication_held(self):
        review=self.setup_host(planner=True)
        with patch('arl.codex_server.Session',MemorySession):
            self.producer.probe_planner('friday',self.admission.args['model'])
        direct=DirectClient(self.root/'runtime',self.runtime,self.verifier,self.pid)
        profile=direct.rpc('priority.negotiate.v2',{'requested_profile':{'classes':['background','interactive']}})
        row=next(r for r in profile['task_bindings'] if r['tool']==PLANNING)
        request=Client.priority_request_v2(profile,submit_method='priority.submit.v1',tool=PLANNING,
            task_kind=row['task_kind'],requested_class='interactive',deadline_at_ms=int(time.time()*1000)+10000,
            estimate_ms=row['estimate_floor_ms'],provider='codex_app_server',model=self.admission.args['model'])
        submitted=direct.rpc('priority.submit.v1',{'tool':PLANNING,'args':self.admission.args,
                                    'key':review['execution_id'],'scheduling':request})
        claimed=self.store.claim();self.assertEqual(claimed['id'],submitted['id'])
        changed=dict(review,text='different reviewed action')
        self.admission.args=PlanningAdmission(changed).args
        self.assertTrue(self.store.finish(claimed,'succeeded',{'proposal':'stale'}))
        held=self.store.get('friday',submitted['id'])
        self.assertEqual(held['state'],'needs_review')
        self.assertEqual(held['error'],'planning_review_not_authorized')
        self.assertIsNone(held['result'])

    def typed_claim(self):
        review=self.setup_host(planner=True)
        with patch('arl.codex_server.Session',MemorySession):
            self.producer.probe_planner('friday',self.admission.args['model'])
        direct=DirectClient(self.root/'runtime',self.runtime,self.verifier,self.pid)
        profile=direct.rpc('priority.negotiate.v2',{'requested_profile':{'classes':['background','interactive']}})
        binding=next(row for row in profile['task_bindings'] if row['tool']==PLANNING)
        scheduling=Client.priority_request_v2(profile,submit_method='priority.submit.v1',tool=PLANNING,
            task_kind=binding['task_kind'],requested_class='interactive',deadline_at_ms=int(time.time()*1000)+10000,
            estimate_ms=binding['estimate_floor_ms'],provider='codex_app_server',model=self.admission.args['model'])
        receipt=direct.rpc('priority.submit.v1',{'tool':PLANNING,'args':self.admission.args,
                              'key':review['execution_id'],'scheduling':scheduling})
        row=self.store.claim()
        self.assertEqual(row['id'],receipt['id'])
        return review,receipt,row

    def test_replaced_admission_same_model_holds_old_publication(self):
        review,receipt,row=self.typed_claim()
        old=self.runtime.admission
        changed=dict(review,text='new separately reviewed removal')
        self.runtime.admission=PlanningAdmission(changed)
        self.assertIsNot(self.runtime.admission,old)
        self.assertEqual(self.runtime.admission.args['model'],old.args['model'])
        # Model/host readiness is deliberately independent of review bytes.
        self.assertEqual(len(self.producer.snapshot('friday')),2)
        self.assertTrue(self.store.finish(row,'succeeded',{'proposal':'old-review-fixture'}))
        held=self.store.get('friday',receipt['id'])
        self.assertEqual((held['state'],held['error'],held['result']),
                         ('needs_review','planning_review_not_authorized',None))
        self.assertEqual(self.store.db.execute('SELECT COUNT(*) FROM jobs').fetchone()[0],1)
        self.assertEqual(self.store.row('friday',receipt['id'])['key'],review['execution_id'])

    def test_removed_admission_holds_old_publication(self):
        _,receipt,row=self.typed_claim()
        self.runtime.admission=None
        self.assertTrue(self.store.finish(row,'succeeded',{'proposal':'old-review-fixture'}))
        held=self.store.get('friday',receipt['id'])
        self.assertEqual(held['state'],'needs_review')
        self.assertIn(held['error'],{'planning_review_not_authorized','priority_route_binding_changed'})
        self.assertIsNone(held['result'])

    def test_replaced_equivalent_current_admission_can_publish(self):
        review,receipt,row=self.typed_claim()
        old=self.runtime.admission
        self.runtime.admission=PlanningAdmission(review)
        self.assertIsNot(self.runtime.admission,old)
        self.assertTrue(self.store.finish(row,'succeeded',{'source_fixture':'current-review-only'}))
        current=self.store.get('friday',receipt['id'])
        self.assertEqual(current['state'],'succeeded')
        self.assertEqual(current['result'],{'source_fixture':'current-review-only'})
        self.assertEqual(self.store.db.execute('SELECT COUNT(*) FROM jobs').fetchone()[0],1)
