import base64
import json
import os
import sys
import threading
import time
import uuid
from unittest.mock import Mock

from arl import PROTOCOL
from arl.client import Client
from arl.contracts import AppPolicy, Fault, encode
from arl.identity import RegisteredPeerVerifier, process_identity
from arl.research import ResearchEngine, ResearchGrant, NAME, METHODS, FORMATS, REQUEST, DESCRIPTOR, sha
from arl.research_client import ResearchClient
from arl.service import Runtime, JobContext
from arl.storage import Store
from tests.test_runtime import RuntimeCase, running

MODEL='fixture-model'
FINGERPRINT='test-double-revision-1'

def body(size=None):
    data={'model':MODEL,'store':False,'stream':False,'background':False,'truncation':'disabled',
        'max_output_tokens':4096,'include':['reasoning.encrypted_content'],
        'input':[{'type':'reasoning','id':'rs_prior','encrypted_content':'opaque-encrypted-fixture','summary':[]},
                 {'role':'user','content':'synthetic question'}],
        'text':{'format':{'type':'json_schema','name':'sourced_research','strict':True,'schema':{'type':'object'}}},
        'instructions':'Use supplied evidence'}
    raw=encode(data)
    return raw+b' '*(size-len(raw)) if size else raw

def metadata(raw,run):
    return {'version':1,'executionID':run,'threadID':str(uuid.uuid4()),'sequence':0,
        'parentRunID':None,'parentFingerprint':None,'startsAlternatePath':False,'model':MODEL,
        'format':'openai.responses.v1','requestDigest':sha(raw),'requestBytes':len(raw),
        'maximumResponseBytes':1048576,'maximumOutputTokens':4096,
        'evidence':[{'evidenceID':str(uuid.uuid4()),'snapshotDigest':sha(b'synthetic evidence')}]}

def response(size=None):
    raw=encode({'id':'resp_fixture','model':MODEL,'status':'completed',
        'output':[{'type':'reasoning','encrypted_content':'opaque-original-output'},
                  {'type':'message','role':'assistant','content':[{'type':'output_text','text':'{}'}]}],
        'usage':{'output_tokens':10},'future_envelope_field':{'must':'survive unchanged'}})
    return raw+b' '*(size-len(raw)) if size else raw

class Adapter:
    name='responses_fixture'
    formats=FORMATS
    token_hard_cap=True
    evidence='test_double'
    model_fingerprints={MODEL:FINGERPRINT}
    def __init__(self, effect=None):
        self.calls=[]; self.effect=effect
    def complete(self,raw,args,context):
        self.calls.append(raw)
        return self.effect(raw,args,context) if self.effect else response()

class DirectClient:
    app='tisra'
    def __init__(self,runtime,app='tisra',verified=True):self.runtime=runtime;self.app=app;self.verified=verified
    def rpc(self,method,params=None):
        request={'protocol':PROTOCOL,'app':self.app,'method':method,'params':params or {}}
        assert len(encode(request))+1<=16384
        result=self.runtime.dispatch(request,verified_app=self.app if self.verified else None)
        assert len(encode({'protocol':PROTOCOL,'ok':True,'result':result}))+1<=65536
        return result

class ResearchTests(RuntimeCase):
    def setUp(self):
        super().setUp();self.adapter=Adapter()
        self.grants={'tisra':ResearchGrant('responses_fixture',frozenset({MODEL}),'grant-epoch-1'),
                     'friday':ResearchGrant('responses_fixture',frozenset({MODEL}),'grant-epoch-1')}
        self.engine=ResearchEngine(self.grants,{'responses_fixture':self.adapter})
        self.policy=AppPolicy(frozenset({NAME}),methods=METHODS|{'health','ready','get','cancel','submit'},max_pending=4)
        self.runtime=Runtime(self.home,policies={'tisra':self.policy,'friday':self.policy},research=self.engine,
                             identity_verifier=lambda c,a:None)
        self.runtime.store=Store(self.home/'state.sqlite');self.engine.attach(self.runtime.store);self.runtime.ready.set()
        self.client=DirectClient(self.runtime);self.sdk=ResearchClient(self.client)
    def tearDown(self):
        self.runtime.store.close();super().tearDown()
    def submit(self,raw=None,**kw):
        raw=raw or body();run=str(uuid.uuid4());return self.sdk.submit(raw,metadata(raw,run),epoch=0,provider='responses_fixture',model_fingerprint=FINGERPRINT,**kw)
    def execute(self):
        row=self.runtime.store.claim();ctx=JobContext(self.runtime,row)
        try:self.engine.complete(row,self.engine.execute(json.loads(row['args']),ctx))
        except Fault as exc:self.engine.complete(row,error=exc.code)
        return row
    def test_full_512k_request_separate_descriptor_and_1m_reply_are_byte_exact(self):
        raw=body(524288);reply=response(1048576);self.adapter.effect=lambda *_:reply
        receipt,args=self.submit(raw);self.execute();current=self.sdk.status(receipt,args)
        self.assertEqual(current['state'],'succeeded');self.assertEqual(self.adapter.calls,[raw])
        self.assertEqual(self.sdk.read_response(receipt,args),reply)
        self.assertEqual(json.loads(reply)['output'][0]['encrypted_content'],'opaque-original-output')
    def test_chunk_retry_conflict_order_seal_immutability_and_strict_base64(self):
        run=str(uuid.uuid4());raw=body();p=self.client.rpc('payload.begin.v1',{'purpose':REQUEST,'run_id':run,'epoch':0,'sha256':sha(raw),'byte_count':len(raw)})
        args={'payload_id':p['payload_id'],'index':0,'data_base64':base64.b64encode(raw).decode(),'sha256':sha(raw)}
        self.assert_fault('invalid_chunk_order',lambda:self.client.rpc('payload.write.v1',dict(args,index=1)))
        self.client.rpc('payload.write.v1',args);self.client.rpc('payload.write.v1',args)
        other=b'changed';self.assert_fault('chunk_conflict',lambda:self.client.rpc('payload.write.v1',dict(args,data_base64=base64.b64encode(other).decode(),sha256=sha(other))))
        self.assert_fault('invalid_arguments',lambda:self.client.rpc('payload.write.v1',dict(args,data_base64=args['data_base64']+'\n')))
        ref={'payload_id':p['payload_id'],'sha256':sha(raw),'byte_count':len(raw)}
        self.client.rpc('payload.seal.v1',ref)
        self.assert_fault('payload_immutable',lambda:self.client.rpc('payload.write.v1',dict(args,index=1)))
    def test_cross_owner_and_spoof_identity_fail_closed(self):
        receipt,args=self.submit();foreign=DirectClient(self.runtime,'friday')
        self.assert_fault('payload_not_found',lambda:foreign.rpc('payload.read.v1',{'payload_id':args['request']['payload_id'],'offset':0,'limit':8192}))
        self.assert_fault('research_not_found',lambda:foreign.rpc('research.status.v1',self.sdk.binding(receipt)))
        self.assert_fault('app_identity_unverified',lambda:DirectClient(self.runtime,verified=False).rpc('research.capabilities.v1'))
        self.assertEqual(self.adapter.calls,[])
    def test_semantic_dedupe_new_handle_reconnect_and_conflict(self):
        receipt,args=self.submit();raw=body()
        replacement=self.sdk.upload(raw,REQUEST,args['run_id'],0)
        again=self.client.rpc('research.submit.v1',dict(args,request=replacement))
        self.assertEqual(again['job_id'],receipt['job_id']);self.execute()
        self.assertEqual(len(self.adapter.calls),1)
        self.assert_fault('idempotency_conflict',lambda:self.client.rpc('research.submit.v1',dict(args,max_output_tokens=1)))
    def test_cancel_before_start_no_effect_and_receipt_match(self):
        receipt,args=self.submit()
        self.assert_fault('research_receipt_mismatch',lambda:self.client.rpc('research.cancel.v1',dict(self.sdk.binding(receipt),epoch=1)))
        cancel=self.sdk.cancel(receipt,args);self.assertEqual(cancel['state'],'cancelled')
        self.assertIsNone(self.runtime.store.claim());self.assertEqual(self.adapter.calls,[])
    def test_cancel_during_noncooperative_external_call_cas_discards_reply(self):
        receipt,args=self.submit();row=self.runtime.store.claim();ctx=JobContext(self.runtime,row)
        self.adapter.effect=lambda *_:(self.sdk.cancel(receipt,args),response())[1]
        raw=self.engine.execute(json.loads(row['args']),ctx);self.engine.complete(row,raw)
        result=self.sdk.status(receipt,args)
        self.assertEqual(result['state'],'needs_review');self.assertIsNone(result['result_ref']);self.assertTrue(result['cancel_requested'])
        self.assertEqual(result['external_stop'],'unknown')
        self.assert_fault('research_not_completed',lambda:self.sdk.read_response(receipt,args))
    def test_revoke_during_call_and_after_success_blocks_future_reads(self):
        receipt,args=self.submit()
        self.adapter.effect=lambda *_:(self.client.rpc('payload.revoke.v1',{'payload_id':args['request']['payload_id']}),response())[1]
        self.execute();self.assertIsNone(self.sdk.status(receipt,args)['result_ref'])
        self.adapter.effect=None;receipt,args=self.submit();self.execute()
        value=self.sdk.status(receipt,args)['result_ref'];self.sdk.cancel(receipt,args)
        self.assert_fault('payload_revoked',lambda:self.client.rpc('payload.read.v1',{'payload_id':value['payload_id'],'offset':0,'limit':32768}))
    def test_input_expiry_and_deadline_before_publication(self):
        receipt,args=self.submit();row=self.runtime.store.claim()
        raw=self.engine.execute(json.loads(row['args']),JobContext(self.runtime,row))
        with self.runtime.store.transaction():self.runtime.store.db.execute('UPDATE research_payloads SET expires=0 WHERE id=?',(args['request']['payload_id'],))
        self.engine.complete(row,raw);self.assertIsNone(self.sdk.status(receipt,args)['result_ref'])
    def test_grant_epoch_and_model_fingerprint_drift_never_publish(self):
        receipt,args=self.submit();row=self.runtime.store.claim()
        raw=self.engine.execute(json.loads(row['args']),JobContext(self.runtime,row))
        self.engine.replace_grant('tisra',ResearchGrant('responses_fixture',frozenset({MODEL}),'grant-epoch-2'))
        self.engine.complete(row,raw);self.assertIsNone(self.sdk.status(receipt,args)['result_ref'])
        self.assert_fault('research_not_authorized',lambda:self.client.rpc('research.submit.v1',dict(args,model_fingerprint='wrong')))
    def test_restart_inflight_uncertainty_never_replays(self):
        receipt,args=self.submit();row=self.runtime.store.claim()
        self.engine.execute(json.loads(row['args']),JobContext(self.runtime,row))
        self.runtime.store.close();self.runtime.store=Store(self.home/'state.sqlite');self.engine.attach(self.runtime.store)
        self.runtime.store.recover(self.runtime.tools)
        self.assertEqual(self.sdk.status(receipt,args)['state'],'needs_review')
        self.assertEqual(self.client.rpc('research.submit.v1',args)['job_id'],receipt['job_id'])
        self.assertIsNone(self.runtime.store.claim());self.assertEqual(len(self.adapter.calls),1)
    def test_invalid_response_token_overflow_and_unknown_error_are_not_success(self):
        receipt,args=self.submit();self.adapter.effect=lambda *_:encode({'id':'x','model':MODEL,'status':'completed','output':[],'usage':{'output_tokens':4097}})
        self.execute();self.assertEqual(self.sdk.status(receipt,args)['state'],'needs_review')
        receipt,args=self.submit();row=self.runtime.store.claim();self.engine.complete(row,error='SECRET_UPSTREAM_EXCEPTION')
        self.assertEqual(self.sdk.status(receipt,args)['error_code'],'research_provider_error')
    def test_budget_and_no_caller_owned_endpoints_extra_fields(self):
        for _ in range(16):self.sdk.upload(body(),REQUEST,str(uuid.uuid4()),0)
        self.assert_fault('payload_budget_exceeded',lambda:self.sdk.upload(body(),REQUEST,str(uuid.uuid4()),0))
        self.assert_fault('invalid_arguments',lambda:self.client.rpc('payload.begin.v1',{'owner':'tisra'}))
    def test_generic_job_methods_cannot_bypass_typed_receipt(self):
        receipt,args=self.submit()
        self.assert_fault('typed_research_method_required',lambda:self.client.rpc('get',{'id':receipt['job_id']}))
        self.assert_fault('typed_research_method_required',lambda:self.client.rpc('cancel',{'id':receipt['job_id']}))
        self.assert_fault('typed_research_method_required',lambda:self.client.rpc('submit',{'tool':NAME,'args':{'run_id':receipt['run_id']},'key':receipt['run_id']}))
    def test_descriptor_budget_and_raw_unknown_fields_rejected_not_stripped(self):
        raw=body();run=str(uuid.uuid4());d=metadata(raw,run);d['requestBytes']-=1
        self.assert_fault('descriptor_mismatch',lambda:self.sdk.submit(raw,d,epoch=0,provider='responses_fixture',model_fingerprint=FINGERPRINT))
        obj=json.loads(raw);obj['tools']=[{'type':'web_search'}];raw=encode(obj);run=str(uuid.uuid4())
        self.assert_fault('invalid_arguments',lambda:self.sdk.submit(raw,metadata(raw,run),epoch=0,provider='responses_fixture',model_fingerprint=FINGERPRINT))
    def test_default_runtime_has_no_research_api_or_provider(self):
        r=Runtime(self.home,execute_jobs=False)
        self.assertNotIn(NAME,r.tools)
        request={'protocol':PROTOCOL,'app':'tisra','method':'research.capabilities.v1','params':{}}
        self.assert_fault('method_not_authorized',lambda:r.dispatch(request,verified_app='tisra'))
    def test_codex_text_adapter_is_explicitly_incompatible_not_a_responses_conversion(self):
        from arl.codex_server import CodexTextAdapter
        self.engine.adapters['responses_fixture']=CodexTextAdapter()
        self.assert_fault('unsupported_research_provider',lambda:self.client.rpc('research.capabilities.v1'))
    def test_completed_reply_ttl_separate_from_input_and_queue_deadline(self):
        receipt,args=self.submit();self.execute()
        with self.runtime.store.transaction():
            self.runtime.store.db.execute('UPDATE research_payloads SET expires=0 WHERE id=?',(args['request']['payload_id'],))
            self.runtime.store.db.execute('UPDATE jobs SET deadline_at=0 WHERE id=?',(receipt['job_id'],))
        self.assertEqual(self.sdk.read_response(receipt,args),response())
        value=self.sdk.status(receipt,args)['result_ref']
        with self.runtime.store.transaction():self.runtime.store.db.execute('UPDATE research_payloads SET expires=0 WHERE id=?',(value['payload_id'],))
        self.assert_fault('payload_expired',lambda:self.sdk.read_response(receipt,args))
        self.assertEqual(self.client.rpc('research.submit.v1',args)['job_id'],receipt['job_id'])
        self.assertIsNone(self.runtime.store.claim());self.assertEqual(len(self.adapter.calls),1)
    def test_reply_space_reserved_before_any_external_call(self):
        receipt,args=self.submit()
        row=self.runtime.store.db.execute('SELECT p.state,p.size FROM research_payloads p JOIN research_runs r ON r.reply_slot=p.id WHERE r.job=?',(receipt['job_id'],)).fetchone()
        self.assertEqual(tuple(row),('reserved',1048576));self.assertEqual(self.adapter.calls,[])
    def test_concurrent_cancel_and_completion_never_leave_visible_success(self):
        receipt,args=self.submit();row=self.runtime.store.claim()
        raw=self.engine.execute(json.loads(row['args']),JobContext(self.runtime,row))
        barrier=threading.Barrier(3);errors=[]
        def action(fn):
            try:barrier.wait();fn()
            except Exception as exc:errors.append(exc)
        threads=[threading.Thread(target=action,args=(lambda:self.engine.complete(row,raw),)),
                 threading.Thread(target=action,args=(lambda:self.sdk.cancel(receipt,args),))]
        for t in threads:t.start()
        barrier.wait()
        for t in threads:t.join(2)
        self.assertEqual(errors,[]);self.assertIsNone(self.sdk.status(receipt,args)['result_ref'])
        self.assertEqual(self.sdk.status(receipt,args)['state'],'needs_review')
    def test_real_socket_registered_mac_peer_raw_roundtrip_and_other_process_rejected(self):
        self.runtime.store.close()
        # Separate temp home from the direct-unit state. This registers a test
        # process lifetime, not a production product identity or interpreter grant.
        native=RegisteredPeerVerifier({'tisra','friday'})
        native.register('tisra',os.getpid(),process_identity(os.getpid())['executable'])
        home=self.home/'socket-test'
        with running(home,policies={'tisra':self.policy,'friday':self.policy},research=self.engine,identity_verifier=native) as (r,c):
            sdk=ResearchClient(c);raw=body(524288);run=str(uuid.uuid4())
            receipt,args=sdk.submit(raw,metadata(raw,run),epoch=0,provider='responses_fixture',model_fingerprint=FINGERPRINT)
            end=time.monotonic()+5
            while sdk.status(receipt,args)['state'] not in {'succeeded','failed','needs_review'} and time.monotonic()<end:time.sleep(.01)
            self.assertEqual(sdk.status(receipt,args)['state'],'succeeded');self.assertEqual(sdk.read_response(receipt,args),response())
            self.assert_fault('app_identity_unverified',lambda:Client(home,'friday').rpc('research.capabilities.v1'))
            import subprocess
            program="from arl.client import Client;from arl.contracts import Fault;import sys;\ntry:Client(sys.argv[1],'tisra').rpc('research.capabilities.v1')\nexcept Fault as e:print(e.code)"
            result=subprocess.run([sys.executable,'-c',program,str(home)],capture_output=True,timeout=5)
            self.assertEqual(result.stdout.decode().strip(),'app_identity_unverified')
        self.runtime.store=Store(self.home/'state.sqlite')
