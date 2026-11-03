"""Real local SDK handshake/queue with synthetic provider processes, no account calls."""
import json,os,sys,tempfile,threading,time,unittest,uuid
from pathlib import Path
from arl.application_platform import ApplicationPlatform,scenarios,kernel_peer
from arl.application_session import ApplicationSession
from arl.client import Client
from arl.codex_server import CodexService,CodexTextAdapter
from arl.contracts import AppPolicy,Fault
from arl.service import Runtime
from arl.diagnostics import Diagnostics

ROOT=Path(__file__).resolve().parents[1]
class ApplicationPlatformTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.home=Path(self.tmp.name);self.home.chmod(0o700)
        self.route=CodexService(CodexTextAdapter(enabled=True,test_command=[sys.executable,'-I','-B',str(ROOT/'tests/fixtures/CodexProductionServer.py')]),caller='host-owner',model='synthetic-model',max_calls=None,reasoning_effort='medium',authorization_current=lambda:True,peer_current=lambda:True,allow_model_selection=True,allow_test_command=True,package_home=self.home/'CodexPackages')
        policy=AppPolicy(frozenset(),frozenset(),0,0,0,methods=frozenset({'ready','settings.snapshot','settings.logs.v3'}),public_metadata=True)
        self.runtime=Runtime(self.home,policies={'settings':policy},providers={},local_enabled=False,extra_tools=[self.route.tool()],identity_verifier=lambda *_:None,codex_service=self.route,admission=self.route.admit,work_scope=frozenset(),application_catalog=lambda _:self.route.status()['execution_catalog'])
        self.route.runtime=self.runtime;self.runtime.application_platform=ApplicationPlatform(self.runtime)
        self.route.preflight();self.thread=threading.Thread(target=self.runtime.run,daemon=True);self.thread.start()
        Client(self.home,'settings').connect(timeout=10)
        self.sessions=[]
    def tearDown(self):
        for session in self.sessions:session.close()
        self.runtime.shutdown();self.thread.join(15);self.assertFalse(self.thread.is_alive());self.tmp.cleanup()
    def session(self,app='arbitrary-opensource-app',priority='interactive',package='high'):
        s=ApplicationSession(self.home,app,'Independent SDK application',[{'id':'summarize','name':'总结文字','task_kind':'explain','priority':priority,'package_id':package}],icon_ref='sf:cpu',version='1')
        self.sessions.append(s);s.register();s.start();return s
    def test_unknown_app_discovers_registers_heartbeats_resolves_exact_package_and_executes(self):
        s=self.session();entry=self.runtime.control.apps.entries[s.client.app]
        self.assertIsNotNone(self.runtime.control.apps.live_session(entry));self.assertEqual(entry['scenarios'][0]['package_id'],'high')
        job=s.submit('summarize','synthetic input');self.assertEqual(job['resolved'],{'model':'synthetic-model','reasoning_effort':'high','service_tier':'default','priority':'interactive'})
        final=s.wait(job,timeout=15);self.assertEqual(final['state'],'succeeded',final)
        self.assertEqual(final['result']['model'],'synthetic-model');self.assertEqual(final['result']['execution_preferences']['reasoning_effort'],'high')
        self.assertEqual(len(self.runtime.workers),8);self.assertEqual(self.runtime.application_platform.concurrency,2)
    def test_no_undeclared_scenario_or_raw_submit_or_other_data_tools(self):
        s=self.session()
        for method,params in [('application.tasks.submit.v1',{'schema_version':1,'session_id':s.client.app_session,'request_id':str(uuid.uuid4()),'scenario_id':'not-declared','input':'synthetic input'}),('submit',{'tool':'codex.text.plan.v1','key':str(uuid.uuid4()),'args':{}}),('mio_notes_search',{})]:
            with self.assertRaises(Fault):s.client.rpc(method,params)
        self.assertEqual(self.runtime.store.db.execute('SELECT COUNT(*) FROM jobs').fetchone()[0],0)
    def test_key_replay_is_one_job_and_packages_are_independent_of_priority(self):
        a=self.session('app-first','background','highest');b=self.session('app-second','interactive','low')
        key=str(uuid.uuid4());first=a.submit('summarize','synthetic input',request_id=key);again=a.submit('summarize','synthetic input',request_id=key)
        self.assertEqual(first['id'],again['id']);other=b.submit('summarize','synthetic input')
        self.assertEqual(first['resolved']['reasoning_effort'],'max');self.assertEqual(other['resolved']['reasoning_effort'],'low')
        self.assertEqual(a.wait(first,timeout=15)['state'],'succeeded');self.assertEqual(b.wait(other,timeout=15)['state'],'succeeded')
        from arl.codex_packages import PackageRegistry
        registry=PackageRegistry(self.route.package_home)
        config=registry.load();version=registry.version(self.route.catalog,config)
        config['packages']['highest']['reasoning_effort']='low'
        registry.save({'schema_version':2,'base_revision':config['revision'],
            'catalog_version':version,'packages':config['packages']},self.route.catalog)
        again=a.submit('summarize','synthetic input',request_id=key)
        self.assertEqual(again['id'],first['id']);self.assertEqual(again['resolved'],first['resolved'])
        with self.assertRaises(Fault):a.submit('summarize','different input',request_id=key)
    def test_parallel_limit_and_priority_use_actual_store_claims(self):
        from dataclasses import replace
        gate=threading.Event();entered=[];guard=threading.Lock()
        original=self.runtime.tools[self.route.name]
        def hold(args,context):
            with guard:entered.append(context.owner)
            gate.wait(5)
            return original.handler(args,context)
        self.runtime.tools[self.route.name]=replace(original,handler=hold)
        self.runtime.application_platform.concurrency=1
        blocker=self.session('blocker');low=self.session('queued-background','background');high=self.session('queued-interactive','interactive')
        first=blocker.submit('summarize','synthetic input')
        deadline=time.monotonic()+3
        while not entered and time.monotonic()<deadline:time.sleep(.01)
        a=low.submit('summarize','synthetic input');b=high.submit('summarize','synthetic input')
        status=self.runtime.application_platform.snapshot();self.assertEqual(status['running'],1);self.assertEqual(status['queued'],2)
        gate.set()
        for client,job in [(blocker,first),(high,b),(low,a)]:self.assertEqual(client.wait(job,timeout=15)['state'],'succeeded')
        self.assertEqual(entered,['blocker','queued-interactive','queued-background'])
        entered.clear();gate.clear();self.runtime.application_platform.concurrency=2
        jobs=[(client,client.submit('summarize','synthetic input')) for client in [blocker,low,high]]
        deadline=time.monotonic()+3
        while len(entered)<2 and time.monotonic()<deadline:time.sleep(.01)
        self.assertEqual(len(entered),2);self.assertEqual(self.runtime.application_platform.snapshot()['queued'],1)
        gate.set()
        for client,job in jobs:self.assertEqual(client.wait(job,timeout=15)['state'],'succeeded')
    def test_second_live_process_binding_cannot_take_over_and_expired_session_reopens(self):
        s=self.session();platform=self.runtime.application_platform;real=platform.peer
        platform.peer=lambda _:('different-process-binding',lambda:True)
        try:
            with self.assertRaises(Fault) as error:Client(self.home,s.client.app).open_app_session('Duplicate identity')
            self.assertEqual(error.exception.code,'app_instance_conflict')
        finally:platform.peer=real
        registry=self.runtime.control.apps;clock=registry.monotonic;registry.monotonic=lambda:clock()+31000
        with self.assertRaises(Fault):s.client.ping_app_session()
        s.register();self.assertTrue(s.connected);self.assertTrue(s.client.ping_app_session()['connected'])
    def test_reserved_identity_and_challenge_and_revoked_session_rejected(self):
        with self.assertRaises(Fault):Client(self.home,'settings').open_app_session('Forged settings')
        s=self.session();sid=s.client.app_session;s.client.close_app_session()
        with self.assertRaises(Fault):s.client.rpc('application.tasks.submit.v1',{'schema_version':1,'session_id':sid,'request_id':str(uuid.uuid4()),'scenario_id':'summarize','input':'synthetic input'})
    def test_scheduler_configuration_validation_and_persistent_redacted_logs(self):
        from arl.codex_packages import atomic
        atomic(self.home/'model-scheduler-v1.json',{'schema_version':1,'max_parallel':1});self.runtime.application_platform.refresh_settings();self.assertEqual(self.runtime.application_platform.concurrency,1)
        atomic(self.home/'model-scheduler-v1.json',{'schema_version':1,'max_parallel':99});self.runtime.application_platform.refresh_settings();self.assertEqual(self.runtime.application_platform.concurrency,1)
        s=self.session();old=self.runtime.control.diagnostics;old.emit('rpc_rejected',app=s.client.app,code='sensitive input')
        loaded=Diagnostics({'settings'},path=self.home/'diagnostics-v1.json');self.assertNotEqual(loaded.boot,old.boot);self.assertEqual(loaded.sequence,old.sequence)
        self.assertTrue(loaded.query({})['records']);self.assertNotIn('sensitive input',(self.home/'diagnostics-v1.json').read_text());self.assertEqual((self.home/'diagnostics-v1.json').stat().st_mode&0o777,0o600)
        (self.home/'diagnostics-v1.json').write_text('{broken')
        recovered=Diagnostics({'settings'},path=self.home/'diagnostics-v1.json')
        self.assertEqual(recovered.query({})['records'][0]['event'],'diagnostic_history_reset')
    def test_global_finite_budget_not_multiplied_by_registrations(self):
        self.route.max_calls=1
        a=self.session('quota-first');b=self.session('quota-second')
        key=str(uuid.uuid4());job=a.submit('summarize','synthetic input',request_id=key)
        self.assertEqual(a.submit('summarize','synthetic input',request_id=key)['id'],job['id'])
        with self.assertRaises(Fault) as error:b.submit('summarize','synthetic input')
        self.assertEqual(error.exception.code,'call_budget_exceeded')
    def test_registration_remains_available_with_model_service_disabled(self):
        self.runtime.codex_service=None
        try:
            s=self.session('metadata-only-application')
            self.assertTrue(s.connected);self.assertEqual(s.accepted,[])
            self.assertEqual(self.runtime.application_platform.snapshot()['running'],0)
            with self.assertRaises(Fault) as error:s.submit('summarize','synthetic input')
            self.assertEqual(error.exception.code,'model_service_not_enabled')
        finally:self.runtime.codex_service=self.route
    def test_previous_fixed_metadata_log_migrates_without_importing_arbitrary_fields(self):
        root=self.home/'legacy';root.mkdir(mode=0o700)
        raw='\n'.join(json.dumps(row) for row in [
            {'at':int(time.time()),'event':'ready','version':'1'},
            {'at':int(time.time()),'event':'ready','version':'1','prompt':'private input'}])
        path=root/'host.log';path.write_text(raw);path.chmod(0o600)
        history=Diagnostics({'settings'},path=root/'diagnostics-v1.json')
        self.assertEqual(len(history.records),1)
        self.assertEqual(history.query({})['records'][0]['event'],'runtime_ready')
if __name__=='__main__':unittest.main()
