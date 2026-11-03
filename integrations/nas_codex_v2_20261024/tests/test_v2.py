import copy,hashlib,json,sys,tempfile,time,unittest,uuid
from pathlib import Path
import os
runtime=Path(os.environ['ARL_V2_RUNTIME']).resolve()
sys.path.insert(0,str(runtime/'core'))
sys.path.insert(0,str(runtime))
from arl.codex_server import CodexTextAdapter
from arl.codex_service_v2 import CodexServiceV2,NAME
from arl.codex_packages import digest
from arl.compat_host import compose_codex_service
from arl.identity import RegisteredPeerVerifier
from arl.storage import Store
from arl.contracts import Fault
from contract import normalize
class V2Tests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.home=Path(self.tmp.name)
        self.a=CodexTextAdapter(enabled=True,test_command=[sys.executable,'-I',str(Path(__file__).with_name('fake_v2_server.py')),'ok'])
        self.a.max_wall_seconds=600
        self.s=CodexServiceV2(self.a,caller='v2-test',model='synthetic-model',reasoning_effort='xhigh',max_calls=None,package_home=self.home/'packages',authorization_current=lambda:True,peer_current=lambda:True,allow_test_command=True)
        self.r=compose_codex_service(self.home/'runtime',service=self.s,peer_verifier=RegisteredPeerVerifier({'v2-test'}),isolated=True)
        self.r.store=Store(self.home/'jobs.sqlite');self.r.codex_v2.initialize();self.r.ready.set()
        self.s.catalog=[{'model':'synthetic-model','display_name':'Synthetic','description':'','default_effort':'medium','efforts':[{'id':e,'description':''} for e in ('low','medium','high','xhigh','ultra')],'fast_available':False,'fast_description':''}]
        self.s.checked_mono=time.monotonic();self.s.registry.publish(self.s.catalog,{'model':'synthetic-model','reasoning_effort':'xhigh','service_tier':'default'})
        self.binding=('test-peer-generation',lambda:True)
        opened=self.rpc('connection.open',{'client_nonce':'a'*64,'name':'Synthetic','icon_ref':'sf:doc.text','version':'1','capabilities':[NAME]})
        self.session=opened['session_id'];self.rpc('connection.confirm',{'session_id':self.session,'challenge':opened['challenge']})
        self.messages=[{'role':'user','content':'synthetic nonsensitive request'}]
    def tearDown(self):
        self.r.store.close();self.r.control.close();self.r.service_portal.close();self.tmp.cleanup()
    def rpc(self,method,params):
        return self.r.dispatch({'protocol':'arl/1','app':'v2-test','method':method,'params':params},verified_app='v2-test',peer_binding=self.binding)
    def resolve(self,selector=None,**changes):
        p={'schema_version':2,'session_id':self.session,'request_id':str(uuid.uuid4()),'catalog_version':self.s.registry.version(self.s.catalog),'content_sha256':digest({'messages':self.messages}),'task_kind':'text.translate','selector':selector or {'kind':'package','package_id':'medium'},'schedule':{'priority':'explicit','execution_timeout_ms':180000,'queue_timeout_ms':0},'output':{'max_bytes':32768},'service_tier':'default'};p.update(changes)
        return self.rpc('application.models.request.v2',p)
    def submit(self,r,messages=None,key=None):return self.rpc('submit',{'tool':NAME,'key':key or r['request_id'],'args':{'schema_version':2,'resolution_id':r['resolution_id'],'messages':messages or self.messages}})
    def fault(self,code,call):
        with self.assertRaises(Fault) as e:call()
        self.assertEqual(e.exception.code,code)
    def edit(self,effort):
        old=self.s.registry.load();old['packages']['medium']['reasoning_effort']=effort
        return self.s.registry.save({'schema_version':2,'base_revision':old['revision'],'catalog_version':self.s.registry.version(self.s.catalog),'packages':old['packages']},self.s.catalog)
    def test_packages_five_independent_combinations_and_cas(self):
        self.assertEqual(len(self.s.registry.load()['packages']),5)
        old=self.s.registry.load();self.edit('low')
        self.fault('package_revision_conflict',lambda:self.s.registry.save({'schema_version':2,'base_revision':old['revision'],'catalog_version':self.s.registry.version(self.s.catalog),'packages':old['packages']},self.s.catalog))
    def test_explicit_and_model_default(self):
        r=self.resolve({'kind':'model','model':'synthetic-model','reasoning_effort':'ultra'});self.assertEqual(r['resolved']['reasoning_effort'],'ultra');self.assertIsNone(r['package_revision'])
        r=self.resolve({'kind':'model','model':'synthetic-model'});self.assertEqual(r['resolved']['reasoning_effort'],'medium')
    def test_blind_package_and_frozen_admission_after_change(self):
        r=self.resolve();job=self.submit(r);self.edit('low')
        proof,base=self.s.admit('v2-test',NAME,{'schema_version':2,'resolution_id':r['resolution_id'],'messages':self.messages})
        self.assertEqual(base['reasoning_effort'],'medium');self.assertEqual(proof['job_id'],job['id'])
        self.assertEqual(self.resolve()['resolved']['reasoning_effort'],'low')
    def test_package_edit_before_admission_rejected(self):
        r=self.resolve();self.edit('low');self.fault('package_changed_before_admission',lambda:self.submit(r))
        self.assertEqual(self.r.store.db.execute('SELECT count(*) FROM jobs').fetchone()[0],0)
    def test_duplicate_submit_and_lookup_no_new_budget(self):
        r=self.resolve();first=self.submit(r);self.assertEqual(first['id'],self.submit(r)['id'])
        self.assertEqual(self.r.store.db.execute('SELECT calls FROM budget').fetchone()[0],1)
        row=self.rpc('codex.requests.lookup.v2',{'session_id':self.session,'request_id':r['request_id']});self.assertEqual(row['job']['id'],first['id'])
    def test_content_and_request_id_bound(self):
        r=self.resolve();self.fault('content_hash_mismatch',lambda:self.submit(r,[{'role':'user','content':'changed'}]))
        self.fault('resolution_binding_mismatch',lambda:self.submit(r,key=str(uuid.uuid4())))
    def test_foreign_peer_and_missing_session_rejected(self):
        old=self.binding;self.binding=('another-peer',lambda:True)
        self.fault('app_session_changed',lambda:self.resolve());self.binding=old
        self.fault('app_session_changed',lambda:self.rpc('application.models.discover.v2',{'session_id':'a'*64}))
    def test_expiry_only_before_admission(self):
        r=self.resolve();job=self.submit(r)
        with self.r.store.transaction():
            stored=self.r.codex_v2.resolution(r['resolution_id'],'v2-test');stored['expires_at']=time.time()-1
            self.r.store.db.execute('UPDATE codex_resolutions_v2 SET value=? WHERE id=?',(json.dumps(stored),r['resolution_id']))
        self.assertEqual(self.submit(r)['id'],job['id'])
    def test_unsupported_mixed_fast_and_effort_rejected(self):
        self.fault('invalid_selector',lambda:self.resolve({'kind':'package','package_id':'medium','model':'synthetic-model'}))
        self.fault('provider_effort_unavailable',lambda:self.resolve({'kind':'model','model':'synthetic-model','reasoning_effort':'guessed'}))
        self.fault('provider_service_tier_unavailable',lambda:self.resolve({'kind':'model','model':'synthetic-model'},service_tier='fast'))
    def test_fast_package_freezes_before_later_configuration_change(self):
        self.s.catalog[0]['fast_available']=True
        old=self.s.registry.load();old['packages']['medium']['service_tier']='fast'
        self.s.registry.save({'schema_version':2,'base_revision':old['revision'],'catalog_version':self.s.registry.version(self.s.catalog),'packages':old['packages']},self.s.catalog)
        r=self.resolve();self.assertEqual(r['resolved']['service_tier'],'fast')
        self.submit(r)
        old=self.s.registry.load();old['packages']['medium']['service_tier']='default'
        self.s.registry.save({'schema_version':2,'base_revision':old['revision'],'catalog_version':self.s.registry.version(self.s.catalog),'packages':old['packages']},self.s.catalog)
        _,base=self.s.admit('v2-test',NAME,{'schema_version':2,'resolution_id':r['resolution_id'],'messages':self.messages})
        self.assertEqual(base['service_tier'],'fast')
        self.assertEqual(self.resolve()['resolved']['service_tier'],'default')
    def test_catalog_change_rejected(self):self.fault('catalog_changed',lambda:self.resolve(catalog_version='0'*64))
    def test_no_lifetime_cap_and_no_inference_in_discovery(self):
        self.r.store.db.execute("INSERT INTO budget(owner,calls) VALUES('v2-test',99)")
        row=self.rpc('application.models.discover.v2',{'session_id':self.session});self.assertIsNone(row['local_lifetime_call_limit']);self.assertEqual(row['admitted_requests_total'],99)
        self.submit(self.resolve());self.assertEqual(self.r.store.db.execute('SELECT calls FROM budget').fetchone()[0],100)
    def test_compatibility_explicit_package_and_option_alias(self):
        c=self.r.codex_v2.discovery();c['published_at']=time.time()
        v={'model':'synthetic-model','reasoning_effort':'low','messages':self.messages};self.assertEqual(normalize('pdf2zh',v,c)['selector']['reasoning_effort'],'low')
        v['model']='arl/package/medium';del v['reasoning_effort'];self.assertEqual(normalize('bilinote',v,c)['selector'],{'kind':'package','package_id':'medium'})
        v['reasoning_effort']='low'
        with self.assertRaisesRegex(ValueError,'mixed_selector'):normalize('pdf2zh',v,c)
    def test_running_turn_survives_preflight_expiry_but_new_admission_is_blocked(self):
        def observed(event):
            if event['event']=='turn_started':
                self.s.checked_mono=None
                self.s.catalog=[]
        self.a.observer=observed
        self.test_end_to_end_fixture_fence_and_frozen_receipt()
        self.assertIsNone(self.s.checked_mono)
        self.assertFalse(self.s.status()['route_enabled'])

    def test_end_to_end_fixture_fence_and_frozen_receipt(self):
        import threading
        r=self.resolve({'kind':'model','model':'synthetic-model','reasoning_effort':'low'})
        job=self.submit(r);worker=threading.Thread(target=self.r.work);worker.start()
        try:
            end=time.monotonic()+5
            while time.monotonic()<end:
                result=self.r.store.get('v2-test',job['id'])
                if result['state'] not in {'queued','running'}:break
                time.sleep(.01)
            self.assertEqual(result['state'],'succeeded',result)
            self.assertTrue(result['result']['simulated'])
            self.assertEqual(result['result']['selection_receipt']['resolved']['reasoning_effort'],'low')
            self.assertEqual(result['result']['execution_preferences']['reasoning_effort'],'low')
        finally:
            self.r.stopping.set();self.r.job_signal.set();worker.join(5)
        self.assertFalse(worker.is_alive())
    def test_readable_immutable_options_match_explicit_selection(self):
        from worker import publish_metadata
        gateway=self.r.codex_v2;session=self.session
        class Client:
            app_session=session
            def ping_app_session(self):pass
            def rpc(self,method,params):return gateway.discovery()
        queue=self.home/'queue';queue.mkdir()
        for app in ('pdf2zh','bilinote'):(queue/app).mkdir()
        catalog=publish_metadata(Client(),queue)
        request=normalize('pdf2zh',{'model':'arl/option/synthetic-model/low','messages':self.messages},catalog)
        self.assertEqual(request['selector'],{'kind':'model','model':'synthetic-model','reasoning_effort':'low'})
        self.assertEqual(request['content_sha256'],digest({'messages':request['messages']}))
        self.assertTrue((queue/'bilinote/catalog.json').exists())
    def test_v2_wire_rejects_duplicate_keys_and_nan(self):
        from arl.codex_service_v2 import decode_request
        frames=[b'{"method":"submit","params":{"tool":"codex.text.generate.v2","tool":"codex.text.generate.v2"}}',b'{"method":"application.models.request.v2","params":{"x":NaN}}']
        for raw in frames:self.fault('invalid_payload',lambda:decode_request(raw))
        self.assertEqual(decode_request(b'{"method":"health","params":{}}')['method'],'health')
    def test_full_default_research_payload_exceeds_old_limit_without_loss(self):
        from contract import encode
        c=self.r.codex_v2.discovery();c['published_at']=time.time()
        content='\n'.join('SOURCE %d: '%i + ('public research evidence 中'*400) for i in range(10))
        request=normalize('robin',{'model':'arl/package/medium','messages':[{'role':'user','content':content}]},c)
        self.assertGreater(len(encode(request['messages'])),80000)
        self.assertEqual(request['messages'][-1]['content'],content)
        self.messages=request['messages'];resolved=self.resolve();job=self.submit(resolved)
        proof,base=self.s.admit('v2-test',NAME,{'schema_version':2,'resolution_id':resolved['resolution_id'],'messages':self.messages})
        self.assertEqual(json.loads(base['input'])[-1]['content'],content)
        self.assertIsNone(c['limits']['max_input_bytes']);self.assertEqual(c['limits']['input_policy'],'provider_context_window')
    def test_admitted_failure_prohibits_client_retries(self):
        import threading,http.client
        from local_api import server,atomic
        root=self.home/'http-queue';root.mkdir()
        for name in ('requests','responses','cancelled'):(root/name).mkdir()
        catalog=self.r.codex_v2.discovery();catalog['published_at']=time.time();atomic(root/'catalog.json',catalog)
        http=server('robin',root,'synthetic-secret');thread=threading.Thread(target=http.serve_forever);thread.start()
        def worker():
            end=time.monotonic()+4
            while time.monotonic()<end:
                requests=list((root/'requests').glob('*.json'))
                if requests:
                    request=json.loads(requests[0].read_text())
                    atomic(root/'responses'/requests[0].name,{'id':request['id'],'app':'robin','state':'needs_review','error':'codex_preflight_required','job_id':'original-job'})
                    return
                time.sleep(.01)
        task=threading.Thread(target=worker);task.start()
        import http.client as http_client
        connection=http_client.HTTPConnection('127.0.0.1',19421,timeout=5)
        try:
            connection.request('POST','/v1/chat/completions',json.dumps({'model':'arl/package/medium','messages':self.messages}),{'Authorization':'Bearer synthetic-secret','Content-Type':'application/json'})
            response=connection.getresponse();body=json.loads(response.read())
            self.assertEqual(response.status,422);self.assertEqual(response.getheader('x-should-retry'),'false')
            self.assertFalse(body['error']['retryable']);self.assertEqual(body['error']['job_id'],'original-job')
            self.assertEqual(len(list((root/'requests').glob('*.json'))),1)
        finally:
            connection.close();http.shutdown();http.server_close();thread.join(3);task.join(3)

    def test_execution_schedule_is_frozen_and_applied_to_durable_deadline(self):
        for timeout in (180000,600000):
            resolved=self.resolve(schedule={'priority':'explicit','execution_timeout_ms':timeout,'queue_timeout_ms':0})
            job=self.submit(resolved)
            row=self.r.store.db.execute('SELECT created,deadline_at FROM jobs WHERE id=?',(job['id'],)).fetchone()
            self.assertAlmostEqual(row[1]-row[0],timeout/1000,places=3)
            self.assertEqual(resolved['schedule']['execution_timeout_ms'],timeout)
            self.r.store.db.execute("UPDATE jobs SET state='cancelled' WHERE id=?",(job['id'],))
        self.fault('unsupported_execution_options',lambda:self.resolve(schedule={'priority':'explicit','execution_timeout_ms':600001,'queue_timeout_ms':0}))

    def test_token_caps_remain_rejected(self):
        c=self.r.codex_v2.discovery();c['published_at']=time.time()
        with self.assertRaisesRegex(ValueError,'token_hard_cap_unsupported'):normalize('bilinote',{'model':'arl/package/medium','messages':self.messages,'max_tokens':1},c)
if __name__=='__main__':unittest.main()
