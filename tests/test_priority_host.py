"""Eight finite real-domain source checks. Generated identities, files and transport only.

No listener, worker, provider, subprocess, model, account, credential or device call.
The adapter's existing validated thread acknowledgement branch runs with Session
replaced by an in-memory transport that stops before an inference turn.
"""
import copy
import json
import os
import struct
import tempfile
import threading
import time
import unittest
import uuid
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from arl import PROTOCOL
from arl.client import Client
from arl.codex_research import (CONTRACT_SHA256, METHODS, NAME, CodexResearchEngine,
                                 CodexResearchGrant, NativeCodexAdapter)
from arl.codex_research_client import CodexResearchClient
from arl.codex_sourced_research import (CodexSourcedAdapter,
                                         CodexSourcedResearchEngine, NAME as SOURCED,
                                         CONTRACT_SHA256 as SOURCED_SHA)
from arl.codex_server import CodexTextAdapter
from arl.contracts import AppPolicy, Fault, encode
from arl.friday_planning import FridayRemovalPlanner, NAME as FRIDAY
from arl.friday_profile import PlanningAdmission, compose_isolated
from arl.identity import RegisteredPeerVerifier
from arl.priority import (AppProfilePolicy, ResourcePolicy, TaskPolicy,
                          release_lease, select_binding_v2)
from arl.priority_host import PriorityHostConfig, RegisteredRouteProducer
from arl.service import JobContext, Runtime
from arl.storage import Store
from arl.supervisor import ControlledSupervisor
from arl import codex_contract as contract
from arl.research import sha

MODEL='synthetic-model'
TRACES=[]


class Connection:
    def __init__(self,pid):self.pid=pid
    def getsockopt(self,level,option,size):
        assert (level,option,size)==(0,2,4)
        return struct.pack('i',self.pid)


class DirectClient(Client):
    """Actual SDK and Runtime.dispatch, without socket creation or launch."""
    def __init__(self,home,app,runtime,verifier,pid):
        super().__init__(home,app)
        self.runtime,self.verifier,self.pid=runtime,verifier,pid
        self.calls=[]
    def connect(self,timeout=10):return {'ready':True}
    def rpc(self,method,params=None):
        self.calls.append(method)
        owner=self.verifier(Connection(self.pid),self.app)
        return self.runtime.dispatch({'protocol':PROTOCOL,'app':self.app,
                                      'method':method,'params':params or {}},verified_app=owner)


class MemorySession:
    on_thread=None
    override_model=None
    created=0
    def __init__(self,binary,workspace,**kwargs):
        type(self).created+=1
        self.thread_id=None;self.turn_id=None
        self.process=SimpleNamespace(returncode=0)
        self.model=None
    def initialize(self):return None
    def send(self,method,params):
        if method=='thread/start':
            self.model=params['model'];return 'thread-start'
        if method=='turn/start':raise Fault('synthetic_stopped_before_inference')
        raise AssertionError(method)
    def response(self,request):
        assert request=='thread-start'
        if type(self).on_thread:type(self).on_thread()
        return {'model':type(self).override_model or self.model,
                'thread':{'id':'generated-thread','ephemeral':True}}
    def cancel_turn(self):raise AssertionError('No turn was started')
    def close(self):return None


class HostProducerTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='priority-host-')
        self.home=Path(self.temp.name)
        self.binary=self.home/'generated-transport-pin';self.binary.write_bytes(b'generated fixture bytes only')
        self.pid=51001;self.birth=(1,2)
        self.identity={'uid':os.geteuid(),'birth':self.birth,'executable':str(self.binary.resolve())}
        self.identity_patch=patch('arl.identity.process_identity',side_effect=lambda pid:dict(self.identity))
        self.identity_patch.start()
        self.verifier=RegisteredPeerVerifier({'tisra','friday'})
        self.verifier.register('tisra',self.pid,self.binary)
        self.resources=(ResourcePolicy('model',slots=1,realtime_reserved=0,
                                      background_start_limit_ms=12000,
                                      capacity_evidence='synthetic-only'),)
        self.tasks=(TaskPolicy(NAME,'model.inference','model',owners=frozenset({'tisra'}),
                               maximum_class='interactive',estimate_floor_ms=5,
                               execution_budget_ms=12000),)
        self.profiles={'tisra':AppProfilePolicy(frozenset({'background','interactive'}),
                                                 burst_calls=100,max_deadline_ms=30000),
                       'friday':AppProfilePolicy(frozenset({'background','interactive'}),
                                                  burst_calls=100,max_deadline_ms=30000)}
        self.store=None;self.runtime=None;self.producer=None;self.direct=None
        self.session_patch=patch('arl.codex_server.Session',MemorySession);self.session_patch.start()
        MemorySession.on_thread=None;MemorySession.override_model=None;MemorySession.created=0

    def tearDown(self):
        MemorySession.on_thread=None;MemorySession.override_model=None;self.session_patch.stop()
        if self.store is not None:self.store.close()
        self.identity_patch.stop();self.temp.cleanup()

    def fault(self,code,call):
        with self.assertRaises(Fault) as caught:call()
        self.assertEqual(caught.exception.code,code)

    def config(self,*,synthetic=True):
        return PriorityHostConfig(self.resources,self.tasks,self.profiles,10000,synthetic)

    def native(self,*,synthetic=True,use_test_command=True):
        self.text=CodexTextAdapter(binary=self.binary,enabled=True,
                                   test_command=(str(self.binary),) if use_test_command else None)
        self.adapter=NativeCodexAdapter([MODEL],text_adapter=self.text)
        self.grant=CodexResearchGrant('codex_app_server',frozenset({MODEL}),
                                      'generated-auth',CONTRACT_SHA256)
        self.engine=CodexResearchEngine({'tisra':self.grant},{'codex_app_server':self.adapter})
        policy=AppPolicy(frozenset({NAME}),methods=METHODS|frozenset({'submit','get','cancel','health','ready'}),
                         max_pending=16,max_calls=500,max_deadline_ms=30000)
        self.runtime=Runtime(self.home/'runtime',policies={'tisra':policy},codex_research=self.engine,
                             identity_verifier=self.verifier,providers={},execute_jobs=True)
        self.store=Store(self.home/'state.sqlite');self.runtime.store=self.store
        self.engine.attach(self.store)
        self.producer=RegisteredRouteProducer(self.runtime,self.verifier,self.config(synthetic=synthetic))
        self.producer.register_native(self.engine,task_kind='model.inference',
                                      resource_kind='model',backend='codex_app_server')
        self.runtime.bind_priority();self.runtime.ready.set()
        self.direct=DirectClient(self.home/'runtime','tisra',self.runtime,self.verifier,self.pid)
        return self.direct

    def seed_native(self):
        sdk=CodexResearchClient(self.direct)
        raw=encode({'schema_version':1,'text':'generated reviewed input','public_history':[],
                    'evidence':[],'migration':None})
        run=str(uuid.uuid4())
        descriptor={'version':1,'executionID':run,'threadID':str(uuid.uuid4()),'sequence':0,
            'parentRunID':None,'parentFingerprint':None,'startsAlternatePath':False,
            'model':MODEL,'format':'tisra.codex.v1','requestDigest':sha(raw),'requestBytes':len(raw),
            'maximumResponseBytes':262144,'maximumOutputTokens':None,'maximumTextBytes':128,'evidence':[]}
        receipt,args=sdk.submit(raw,descriptor,epoch=0,provider='codex_app_server',
                                model_fingerprint=self.adapter.model_fingerprints[MODEL])
        row=self.store.claim();self.assertIsNotNone(row)
        self.assertEqual(row['id'],receipt['job_id'])
        self.assertEqual(row['owner'],'tisra')
        self.assertEqual(row['state'],'running')
        self.assertEqual(self.store.db.execute('SELECT COUNT(*) FROM resource_leases').fetchone()[0],1)
        return receipt,args,row,sdk

    def observe_native(self,row):
        # Actual engine admission and provider context perform the correlation.
        # MemorySession stops at turn/start before any model work.
        self.fault('synthetic_stopped_before_inference',
                   lambda:self.engine.execute(json.loads(row['args']),JobContext(self.runtime,row)))
        return self.producer.snapshot('tisra')

    def test_P1_current_registration_generation_and_supervisor_loss(self):
        first=self.verifier.registration_subject('tisra')
        self.assertEqual(self.verifier(Connection(self.pid),'tisra'),'tisra')
        generation=self.verifier.registration_generation('tisra',self.pid)
        self.assertFalse(self.verifier.revoke(self.pid,expected_generation=generation+1))
        spec=SimpleNamespace(validate=lambda:None)
        process=SimpleNamespace(pid=self.pid,poll=lambda:1)
        host=ControlledSupervisor([],self.verifier)
        host.specs['tisra']=spec;host.children['tisra']=process
        host.owned['tisra']=(spec,process,generation)
        cleanup=[]
        host.control=SimpleNamespace(apps=SimpleNamespace(revoke=lambda app:cleanup.append(('app',app))),
            resources=SimpleNamespace(unregister=lambda pid:cleanup.append(('resource',pid))))
        self.verifier.register('tisra',self.pid,self.binary)
        replacement=self.verifier.registration_generation('tisra',self.pid)
        self.assertNotEqual(self.verifier.registration_subject('tisra'),first)
        self.assertFalse(host.metadata_active('tisra',spec,process,generation))
        self.assertIsNone(host.peer_verifier(Connection(self.pid),'tisra'))
        self.assertEqual(self.verifier.registration_generation('tisra',self.pid),replacement)
        self.assertEqual(cleanup,[])
        good=dict(self.identity);self.identity['birth']=(7,8)
        self.fault('priority_identity_binding_unavailable',
                   lambda:self.verifier.registration_subject('tisra'))
        self.identity=good
        self.assertFalse(self.verifier.revoke(self.pid,expected_generation=generation))
        host.owned['tisra']=(spec,process,replacement)
        self.assertFalse(host.metadata_active('tisra',SimpleNamespace(validate=lambda:None),process))
        self.assertFalse(host.metadata_active('tisra',spec,process,replacement))
        self.fault('priority_identity_binding_unavailable',lambda:self.verifier.registration_subject('tisra'))
        self.assertIsNone(self.verifier(Connection(self.pid),'tisra'))
        self.verifier.register('tisra',self.pid,self.binary)
        latest=self.verifier.registration_generation('tisra',self.pid)
        process.poll=lambda:None
        def replace_during_validate():
            self.verifier.register('tisra',self.pid,self.binary)
        spec.validate=replace_during_validate
        host.owned['tisra']=(spec,process,latest)
        self.assertFalse(host.metadata_active('tisra',spec,process,latest))
        self.assertGreater(self.verifier.registration_generation('tisra',self.pid),latest)
        self.assertEqual(cleanup,[])
        latest=self.verifier.registration_generation('tisra',self.pid)
        host.owned['tisra']=(spec,process,latest)
        self.assertIsNone(host.peer_verifier(Connection(self.pid),'tisra'))
        self.assertGreater(self.verifier.registration_generation('tisra',self.pid),latest)
        self.assertEqual(cleanup,[])
        spec.validate=lambda:None
        latest=self.verifier.registration_generation('tisra',self.pid)
        host.owned['tisra']=(spec,process,latest)
        process.poll=lambda:1
        original_revoke=self.verifier.revoke
        def replacement_after_revoke(pid,*,expected_generation=None):
            removed=original_revoke(pid,expected_generation=expected_generation)
            if removed:self.verifier.register('tisra',pid,self.binary)
            return removed
        with patch.object(self.verifier,'revoke',side_effect=replacement_after_revoke):
            self.assertIsNone(host.peer_verifier(Connection(self.pid),'tisra'))
        self.assertGreater(self.verifier.registration_generation('tisra',self.pid),latest)
        self.assertEqual(cleanup,[])
        self.verifier.register('tisra',self.pid+1,self.binary)
        self.fault('priority_identity_binding_unavailable',lambda:self.verifier.registration_subject('tisra'))
        TRACES.append({'id':'P1','registered_peer_verified':True,'generation_rotated':True,
                       'exit_revoked':True,'ambiguous_registration_held':True,
                       'old_callback_preserved_replacement_and_control':True,
                       'replacement_during_validation_preserved':True,
                       'replacement_after_conditional_revoke_preserved_control':True})

    def test_P2_actual_adapter_thread_ack_and_late_failure(self):
        self.native();self.assertEqual(self.producer.snapshot('tisra'),())
        MemorySession.override_model='wrong-model'
        context=SimpleNamespace(check_cancelled=lambda:None,remaining=lambda limit:limit)
        self.fault('provider_contract_mismatch',lambda:self.text.run(
            {'model':MODEL,'input':'generated input','max_output_bytes':128},context))
        self.assertEqual(self.producer.snapshot('tisra'),())
        MemorySession.override_model=None;MemorySession.created=0
        receipt,args,row,sdk=self.seed_native()
        self.assertEqual(self.producer.snapshot('tisra'),())
        observed=self.observe_native(row)
        self.assertEqual(len(observed),1)
        self.assertEqual(observed[0].route.model_fingerprint,self.adapter.model_fingerprints[MODEL])
        self.assertEqual(self.engine.native_row(row['id'])['thread_id'],'generated-thread')
        self.assertEqual(self.producer.attempts,{})
        self.assertEqual(MemorySession.created,1)
        self.assertEqual(self.store.db.execute('SELECT COUNT(*) FROM resource_leases').fetchone()[0],1)
        original=self.binary.read_bytes()
        self.binary.write_bytes(b'changed generated transport bytes')
        self.assertEqual(self.producer.snapshot('tisra'),())
        self.binary.write_bytes(original)
        self.assertEqual(len(self.producer.snapshot('tisra')),1)
        self.store.db.execute('DELETE FROM resource_leases WHERE job=?',(row['id'],))
        self.assertEqual(self.producer.snapshot('tisra'),())
        TRACES.append({'id':'P2','actual_thread_branch':True,'native_record':True,
                       'no_turn_or_inference':True,'private_ready_rows':len(observed),
                       'changed_transport_and_missing_running_lease_held':True})

    def test_native_first_readiness_uses_only_read_only_preflight(self):
        self.native(synthetic=False,use_test_command=False)
        self.assertEqual(self.producer.snapshot('tisra'),())
        with patch.object(self.text,'preflight_model',return_value={
                'model':MODEL,'ephemeral':True,'read_only':True,'synthetic':False}) as preflight:
            self.producer.probe_native('tisra',MODEL)
        preflight.assert_called_once_with(MODEL)
        rows=self.producer.snapshot('tisra')
        self.assertEqual(len(rows),1)
        self.assertEqual((rows[0].tool,rows[0].task_kind),(NAME,'model.inference'))
        self.assertEqual(rows[0].route.model_fingerprint,self.adapter.model_fingerprints[MODEL])
        self.assertEqual(MemorySession.created,0)  # producer never starts a model session
        self.assertEqual(self.store.db.execute('SELECT COUNT(*) FROM jobs').fetchone()[0],0)
        self.engine.grants['tisra']=CodexResearchGrant(
            'codex_app_server',frozenset({MODEL}),'rotated-auth',CONTRACT_SHA256)
        self.assertEqual(self.producer.snapshot('tisra'),())
        self.engine.grants['tisra']=self.grant
        self.assertEqual(len(self.producer.snapshot('tisra')),1)
        self.verifier.revoke(self.pid)
        self.assertEqual(self.producer.snapshot('tisra'),())

    def test_native_readiness_rejects_drift_during_preflight(self):
        self.native(synthetic=False,use_test_command=False)
        def drift(model):
            self.binary.write_bytes(b'drift during preflight')
            return {'model':model,'ephemeral':True,'read_only':True,'synthetic':False}
        with patch.object(self.text,'preflight_model',side_effect=drift):
            self.fault('priority_route_binding_unavailable',
                       lambda:self.producer.probe_native('tisra',MODEL))
        self.assertEqual(self.producer.preflights,{})

    def test_P3_current_grant_capability_and_registration_invalidate(self):
        self.native();_,_,row,_=self.seed_native();self.observe_native(row)
        self.assertEqual(len(self.producer.snapshot('tisra')),1)
        self.engine.grants['tisra']=CodexResearchGrant('codex_app_server',frozenset({MODEL}),
                                                       'replaced-auth',CONTRACT_SHA256)
        self.assertEqual(self.producer.snapshot('tisra'),())
        self.engine.grants['tisra']=self.grant
        self.assertEqual(len(self.producer.snapshot('tisra')),1)
        self.adapter.model_fingerprints[MODEL]='0'*64
        self.assertEqual(self.producer.snapshot('tisra'),())
        self.adapter.model_fingerprints[MODEL]=contract.model_fingerprint(self.adapter.model_evidence(MODEL))
        oldclock=self.producer.clock
        self.producer.clock=lambda:oldclock()+100
        self.assertEqual(self.producer.snapshot('tisra'),())
        self.producer.clock=oldclock
        self.verifier.revoke(self.pid)
        self.assertEqual(self.producer.snapshot('tisra'),())
        self.fault('app_identity_unverified',lambda:self.direct.negotiate_priority_v2(('interactive',)))
        TRACES.append({'id':'P3','grant_swap_held':True,'fingerprint_swap_held':True,
                       'disconnect_held':True})

    def test_P4_friday_actual_admission_planner_and_composition(self):
        self.verifier.revoke(self.pid)
        self.verifier.register('friday',self.pid,self.binary)
        now=int(time.time()*1000)
        review={'schema_version':1,'execution_id':str(uuid.uuid4()),'text':'generated reviewed removal',
                'context_fingerprint':'a'*64,'captured_at_ms':now,'expires_at_ms':now+30000,
                'choices':[{'record_id':'generated:1','action_id':'generated-action',
                            'expected_fingerprint':'b'*64,'rule_label':'generated rule',
                            'action_label':'generated action'}]}
        admission=PlanningAdmission(review)
        self.text=CodexTextAdapter(binary=self.binary,enabled=True,test_command=(str(self.binary),))
        planner=FridayRemovalPlanner(self.text)
        self.tasks=(TaskPolicy(FRIDAY,'friday.reviewed.plan','model',owners=frozenset({'friday'}),
                               maximum_class='interactive',estimate_floor_ms=5,execution_budget_ms=12000),)
        policy=AppPolicy(frozenset({FRIDAY}),methods=frozenset({'submit','get','cancel','health','ready'}),
                         max_pending=16,max_calls=500,max_deadline_ms=30000)
        self.runtime=Runtime(self.home/'friday',policies={'friday':policy},extra_tools=(planner.tool(),),
                             identity_verifier=self.verifier,admission=admission,providers={},execute_jobs=True)
        self.store=Store(self.home/'friday.sqlite');self.runtime.store=self.store
        self.producer=RegisteredRouteProducer(self.runtime,self.verifier,self.config())
        self.producer.register_planner(planner,task_kind='friday.reviewed.plan',
                                       resource_kind='model',backend='codex_app_server')
        self.runtime.bind_priority();self.runtime.ready.set()
        client=DirectClient(self.home/'friday','friday',self.runtime,self.verifier,self.pid)
        self.assertEqual(client.negotiate_priority_v2(('interactive',))['task_bindings'],[])
        args=admission.args
        self.fault('priority_route_binding_unavailable',lambda:client.rpc('submit',
            {'tool':FRIDAY,'args':args,'key':review['execution_id']}))
        self.producer.probe_planner('friday',args['model'])
        profile=client.negotiate_priority_v2(('interactive',))
        binding=profile['task_bindings'][0]
        scheduling=Client.priority_request_v2(profile,submit_method='priority.submit.v1',tool=FRIDAY,
            task_kind=binding['task_kind'],requested_class='interactive',deadline_at_ms=int(time.time()*1000)+20000,
            estimate_ms=binding['estimate_floor_ms'],provider='codex_app_server',model=args['model'])
        job=client.rpc('priority.submit.v1',{'tool':FRIDAY,'args':args,'key':review['execution_id'],
                                             'scheduling':scheduling})
        row=self.store.claim();self.assertEqual(row['id'],job['id'])
        self.fault('synthetic_stopped_before_inference',lambda:planner.run(args,JobContext(self.runtime,row)))
        rows=self.producer.snapshot('friday');self.assertEqual(len(rows),1)
        self.assertEqual(rows[0].route.model,args['model'])
        profile=client.negotiate_priority_v2(('interactive',))
        self.assertEqual(len(profile['task_bindings']),1)
        self.assertEqual(profile['task_bindings'][0]['tool'],FRIDAY)
        admission.args=dict(admission.args,model='changed')
        self.assertEqual(self.producer.snapshot('friday'),())
        # The source-only isolated composition installs the same producer class
        # through its optional host-owned argument, without supervisor.launch.
        self.store.close();self.store=None
        composed_adapter=CodexTextAdapter(binary=self.binary,enabled=True,
                                          test_command=(str(self.binary),))
        with patch('arl.friday_profile.planning_spec',return_value=(SimpleNamespace(app='friday'),review)):
            composed,supervisor=compose_isolated(self.home/'composition','pin','pin',
                                                  adapter=composed_adapter,priority_config=self.config())
        self.assertIsInstance(composed.priority_authority,type(self.producer.authority))
        self.assertEqual(supervisor.children,{})
        TRACES.append({'id':'P4','actual_admission_and_planner':True,'composition_wired':True,
                       'review_change_held':True})

    def test_P5_explicit_capacity_pool_and_lease_association(self):
        self.fault('priority_host_capacity_unqualified',lambda:PriorityHostConfig(
            (ResourcePolicy('model',slots=2,realtime_reserved=1),),self.tasks,self.profiles,10000))
        self.native();_,_,row,_=self.seed_native();self.observe_native(row)
        self.assertEqual(self.store.db.execute('SELECT COUNT(*) FROM resource_leases').fetchone()[0],1)
        self.store.db.execute('DELETE FROM resource_leases WHERE job=?',(row['id'],))
        # A positive thread ack cannot create a new pool/lease after capacity is lost.
        self.assertEqual(self.producer.begin_model_run(self.text,SimpleNamespace(row=row),MODEL,
                                                       'codex.appserver.text.v1'),None)
        self.assertEqual(self.store.claim(),None)
        self.assertEqual(self.producer.config.resources[0].slots,1)
        second_text=CodexTextAdapter(binary=self.binary,enabled=True,
                                      test_command=(str(self.binary),))
        sourced=CodexSourcedAdapter([MODEL],text_adapter=second_text)
        sourced_engine=CodexSourcedResearchEngine(
            {'tisra':CodexResearchGrant('codex_app_server',frozenset({MODEL}),
                                         'generated-auth',SOURCED_SHA)},
            {'codex_app_server':sourced})
        first_text=CodexTextAdapter(binary=self.binary,enabled=True,
                                    test_command=(str(self.binary),))
        first_adapter=NativeCodexAdapter([MODEL],text_adapter=first_text)
        first_engine=CodexResearchEngine({'tisra':self.grant},
                                          {'codex_app_server':first_adapter})
        host=SimpleNamespace(priority_authority=None,
             research_engines={NAME:first_engine,SOURCED:sourced_engine},
             tools={NAME:first_engine.tool,SOURCED:sourced_engine.tool})
        self.fault('priority_host_capacity_unqualified',lambda:PriorityHostConfig(
            (self.resources[0],ResourcePolicy('other')),
            (self.tasks[0],TaskPolicy(SOURCED,'model.sourced','other',
               owners=frozenset({'tisra'}))),self.profiles,10000,True))
        config=PriorityHostConfig(self.resources,
            (self.tasks[0],TaskPolicy(SOURCED,'model.sourced','model',
               owners=frozenset({'tisra'}))),self.profiles,10000,True)
        producer=RegisteredRouteProducer(host,self.verifier,config)
        producer.register_native(first_engine,task_kind='model.inference',
                                  resource_kind='model',backend='codex_app_server')
        self.fault('priority_backend_pool_conflict',lambda:producer.register_native(
            sourced_engine,task_kind='model.sourced',resource_kind='model',
            backend='alias-two'))
        producer.register_native(sourced_engine,task_kind='model.sourced',
                                  resource_kind='model',backend='codex_app_server')
        self.assertEqual(len(producer.domains),2)
        self.assertEqual({d.task.resource_kind for d in producer.domains},{'model'})
        TRACES.append({'id':'P5','explicit_N1_R0':True,'lease_loss_cannot_bootstrap':True,
                       'shared_backend_cannot_split_pool':True,
                       'different_transport_pins_same_pool':True})

    def test_P6_actual_v2_sdk_selection_runtime_dispatch_and_claim(self):
        self.native();_,_,seed,_=self.seed_native();self.observe_native(seed)
        self.store.finish(seed,'succeeded',{'generated':True});self.assertTrue(release_lease(self.store,seed))
        profile=self.direct.negotiate_priority_v2(('interactive',))
        self.assertEqual(len(profile['task_bindings']),1)
        selected=select_binding_v2(profile,submit_method='codex.research.submit.v1',tool=NAME,
                                   task_kind='model.inference',provider='codex_app_server',
                                   model=MODEL,model_fingerprint=self.adapter.model_fingerprints[MODEL])
        self.assertEqual(selected['resource_kind'],'model')
        scheduling=self.direct.priority_request_v2(profile,task_kind='model.inference',
            requested_class='interactive',deadline_at_ms=int(time.time()*1000)+20000,
            estimate_ms=5,submit_method='codex.research.submit.v1',tool=NAME,
            provider='codex_app_server',model=MODEL,
            model_fingerprint=self.adapter.model_fingerprints[MODEL])
        sdk=CodexResearchClient(self.direct)
        raw=encode({'schema_version':1,'text':'second generated reviewed input',
                    'public_history':[],'evidence':[],'migration':None})
        run=str(uuid.uuid4())
        desc={'version':1,'executionID':run,'threadID':str(uuid.uuid4()),'sequence':0,
            'parentRunID':None,'parentFingerprint':None,'startsAlternatePath':False,
            'model':MODEL,'format':'tisra.codex.v1','requestDigest':sha(raw),'requestBytes':len(raw),
            'maximumResponseBytes':262144,'maximumOutputTokens':None,'maximumTextBytes':128,'evidence':[]}
        receipt,args=sdk.submit(raw,desc,epoch=0,provider='codex_app_server',
             model_fingerprint=self.adapter.model_fingerprints[MODEL],scheduling=scheduling)
        self.assertEqual(receipt['scheduling']['resource_kind'],'model')
        claimed=self.store.claim();self.assertEqual(claimed['id'],receipt['job_id'])
        self.verifier.revoke(self.pid)
        self.assertEqual(self.producer.snapshot('tisra'),())
        self.assertTrue(self.store.finish(claimed,'succeeded',{'generated':True}))
        self.assertEqual(self.store.row('tisra',claimed['id'])['state'],'needs_review')
        TRACES.append({'id':'P6','actual_sdk_submit_and_claim':True,
                       'route_tuple_selected':True,'registration_revoke_closes':True,
                       'publication_held':True})

    def test_P7_first_acceptance_late_ack_and_no_replay(self):
        self.native();_,_,row,_=self.seed_native()
        MemorySession.on_thread=lambda:self.verifier.revoke(self.pid)
        self.fault('priority_identity_binding_unavailable',
                   lambda:self.engine.execute(json.loads(row['args']),JobContext(self.runtime,row)))
        self.assertEqual(self.producer.snapshot('tisra'),())
        self.assertEqual(self.producer.attempts,{})
        self.assertEqual(self.store.db.execute('SELECT COUNT(*) FROM resource_leases').fetchone()[0],1)
        self.assertEqual(len([r for r in self.direct.calls if r=='codex.research.submit.v1']),1)
        TRACES.append({'id':'P7','late_ack_held':True,'single_submit':True,'no_replay':True})

    def test_P8_defaults_unknown_paid_local_and_missing_observer_held(self):
        self.native(synthetic=False)
        self.assertEqual(self.producer.snapshot('tisra'),())
        self.fault('priority_identity_binding_unavailable',lambda:self.producer.subject('unknown'))
        _,_,row,_=self.seed_native()
        self.observe_native(row)
        self.assertEqual(self.producer.snapshot('tisra'),())
        self.text.enabled=False
        self.assertEqual(self.producer.snapshot('tisra'),())
        self.assertEqual(self.runtime.router.local_enabled,False)
        self.assertEqual(self.runtime.research_engines.get('tisra.research.v1'),None)
        TRACES.append({'id':'P8','synthetic_not_live':True,'unknown_held':True,
                       'disabled_held':True,'no_responses_producer':True})


if __name__=='__main__':unittest.main()
