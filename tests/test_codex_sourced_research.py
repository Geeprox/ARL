"""Native sourced integration with owned synthetic stdio and local ARL only."""
import base64
import json
import sys
import time
import uuid
from dataclasses import replace
from pathlib import Path
from unittest.mock import patch

from arl import PROTOCOL
from arl import codex_sourced_contract as contract
from arl.contracts import AppPolicy, Fault, encode
from arl.codex_server import CodexTextAdapter
from arl.codex_research import NativeCodexAdapter
from arl.codex_sourced_research import (CodexSourcedAdapter, CodexSourcedResearchEngine,
    CodexResearchGrant, METHODS, NAME, CONTRACT_SHA256)
from arl.codex_research_client import CodexSourcedResearchClient
from arl.research import sha
from arl.service import Runtime, JobContext
from arl.storage import Store
from tests.test_runtime import RuntimeCase, running

MODEL = 'synthetic-model'
FIXTURE = Path(__file__).resolve().parents[1] / 'integrations/codex/fake_server.py'
EID = '33333333-3333-4333-8333-333333333333'
RID = '44444444-4444-4444-8444-444444444444'


def request(*, empty=False):
    parts = [] if empty else [{
        'evidence_id': EID, 'snapshot_digest': sha(b'complete trusted synthetic snapshot'),
        'record_id': RID, 'revision': 3, 'unit': 0, 'attachment_sha256': sha(b'synthetic artifact'),
        'text': '中文 exact original quotation.', 'title': 'Synthetic source',
        'locator': 'page 1', 'extraction_state': 'ready',
    }]
    if parts:
        note = dict(parts[0], unit=None, attachment_sha256=None, locator=None, text='Original note.')
        other = dict(parts[0], record_id='55555555-5555-4555-8555-555555555555', text='Other source.')
        parts.extend([note, other])
    return b'\n ' + encode({'schema_version': 2, 'text': 'Summarize reviewed sources.',
        'public_history': [], 'evidence': parts, 'migration': None}) + b' \n'


def descriptor(raw, run):
    return {'version': 2, 'executionID': run, 'threadID': str(uuid.uuid4()), 'sequence': 1,
        'parentRunID': None, 'parentFingerprint': None, 'startsAlternatePath': False,
        'model': MODEL, 'format': 'tisra.codex.v2', 'requestDigest': sha(raw), 'requestBytes': len(raw),
        'maximumResponseBytes': 262144, 'maximumOutputTokens': None, 'maximumTextBytes': 128,
        'evidence': contract.snapshot_bindings(contract.request_body(raw))}


class SourcedResearchTests(RuntimeCase):
    def setUp(self):
        super().setUp(); self.configure()

    def configure(self, mode='ok'):
        self.text = CodexTextAdapter(enabled=True, test_command=[sys.executable, '-I', str(FIXTURE), mode])
        self.adapter = CodexSourcedAdapter([MODEL], text_adapter=self.text)
        self.grant = CodexResearchGrant('codex_app_server', frozenset({MODEL}), 'original-auth-epoch', CONTRACT_SHA256)
        self.engine = CodexSourcedResearchEngine({'tisra': self.grant}, {'codex_app_server': self.adapter})
        self.policy = AppPolicy(frozenset({NAME}), methods=METHODS | {'get', 'cancel', 'resume', 'submit', 'health', 'ready'},
            max_pending=16, max_deadline_ms=30000)
        self.runtime = Runtime(self.home, policies={'tisra': self.policy, 'other': self.policy},
            codex_research=self.engine, identity_verifier=lambda *_: None)
        self.runtime.store = Store(self.home/'state.sqlite'); self.engine.attach(self.runtime.store)
        self.runtime.ready.set()

    def tearDown(self):
        self.runtime.store.close(); super().tearDown()

    def rpc(self, method, params=None, owner='tisra', verified=True):
        return self.runtime.dispatch({'protocol':PROTOCOL,'app':owner,'method':method,'params':params or {}},
            verified_app=owner if verified else None)

    def upload(self, raw, purpose, run):
        value=self.rpc('codex.payload.begin.v1',{'purpose':purpose,'run_id':run,'epoch':0,
            'sha256':sha(raw),'byte_count':len(raw)})
        for index,offset in enumerate(range(0,len(raw),8192)):
            chunk=raw[offset:offset+8192]
            self.rpc('codex.payload.write.v1',{'payload_id':value['payload_id'],'index':index,
                'data_base64':base64.b64encode(chunk).decode(),'sha256':sha(chunk)})
        ref={'payload_id':value['payload_id'],'sha256':sha(raw),'byte_count':len(raw)}
        self.rpc('codex.payload.seal.v1',ref);return ref

    def submit(self, raw=None, *, deadline_ms=800, mutate=None):
        raw=request() if raw is None else raw;run=str(uuid.uuid4());meta=descriptor(raw,run)
        if mutate:mutate(meta)
        args={'schema_version':1,'run_id':run,'epoch':0,
            'request':self.upload(raw,contract.REQUEST,run),'descriptor':self.upload(encode(meta),contract.DESCRIPTOR,run),
            'provider':'codex_app_server','model':MODEL,'model_fingerprint':self.adapter.model_fingerprints[MODEL],
            'request_format':contract.REQUEST,'output_format':contract.RESPONSE,'history_version':contract.FORMATS[2],
            'max_output_tokens':None,'max_output_bytes':128,'priority':'explicit','deadline_ms':deadline_ms}
        return self.rpc('codex.research.submit.v1',args),args

    @staticmethod
    def binding(receipt):return {k:receipt[k] for k in ('job_id','run_id','request_sha256','epoch')}
    def status(self, receipt):return self.rpc('codex.research.status.v1',self.binding(receipt))
    def cancel(self, receipt):return self.rpc('codex.research.cancel.v1',self.binding(receipt))

    def execute(self):
        row=self.runtime.store.claim();ctx=JobContext(self.runtime,row)
        try:self.engine.complete(row,self.engine.execute(json.loads(row['args']),ctx))
        except Fault as exc:self.engine.complete(row,error=exc.code)
        return row

    def switch_mode(self, mode):
        self.runtime.store.close();self.configure(mode)

    def result(self, receipt,args):
        current=self.status(receipt);ref=current['result_ref']
        raw=bytes(self.engine.payload('tisra',ref['payload_id'])['data'])
        return contract.result_body(raw,args,binding=current,native=current['native'],request=request())

    def test_caps_and_source_pin_are_distinct_from_text_candidate_and_token_caps(self):
        caps=self.rpc('codex.research.capabilities.v1')
        self.assertTrue(caps['structured_generated_citations']);self.assertEqual(caps['contract_sha256'],contract.CONTRACT_SHA256)
        self.assertEqual(caps['formats']['output'],contract.RESPONSE);self.assertIsNone(caps['max_output_tokens'])
        self.assertFalse(caps['token_hard_cap_supported']);self.assertFalse(caps['cost_hard_cap_supported'])
        old=NativeCodexAdapter([MODEL],text_adapter=self.text)
        self.assertNotEqual(old.model_fingerprints[MODEL],self.adapter.model_fingerprints[MODEL])
        self.assert_fault('app_identity_unverified',lambda:self.rpc('codex.research.capabilities.v1',verified=False))
        self.engine.grants['tisra']=replace(self.grant,contract_sha256='0'*64)
        self.assert_fault('unsupported_research_provider',lambda:self.rpc('codex.research.capabilities.v1'))

    def test_frozen_cross_language_bytes_hashes_and_sourced_envelope(self):
        path=FIXTURE.parents[1]/'tisra/codex-native-sourced-v2-fixtures.json'
        fixtures=json.loads(path.read_bytes());self.assertEqual(fixtures['contract_sha256'],CONTRACT_SHA256)
        for vector in fixtures['vectors']:
            raw=base64.b64decode(vector['request_utf8_base64'],validate=True)
            self.assertEqual(sha(raw),vector['request_sha256']);self.assertEqual(len(raw),vector['request_byte_count'])
            parsed=contract.request_body(raw,vector['binding_args']);self.assertEqual(parsed,vector['request'])
            output=base64.b64decode(vector['output_digest_utf8_base64'],validate=True)
            self.assertEqual(contract.structured_body(output,parsed),vector['generated_body'])
            self.assertEqual(contract.output_digest(vector['generated_body']),vector['output_sha256'])
            reply=base64.b64decode(vector['result_utf8_base64'],validate=True)
            self.assertEqual(sha(reply),vector['result_payload_sha256'])
            self.assertEqual(contract.result_body(reply,vector['binding_args'],request=raw),vector['result'])

    def test_control_schema_drift_rejects_before_external_start(self):
        receipt,_=self.submit()
        self.adapter.control_contract=dict(self.adapter.control_contract,generated_body_bytes=32769)
        with patch.object(self.text,'run_sourced',side_effect=AssertionError('must not launch')):
            self.execute()
        self.assertEqual(self.status(receipt)['state'],'failed')
        self.assertFalse(self.engine.run(receipt['job_id'])['external_started'])
        self.assertEqual(self.status(receipt)['native']['terminal'],'not_started')

    def test_original_input_and_citation_ranges_attachment_and_native_ids_survive(self):
        seen=[];original=self.text.run_sourced
        def capture(args,context):seen.append(args['input'].encode());return original(args,context)
        self.text.run_sourced=capture;receipt,args=self.submit();self.execute();result=self.result(receipt,args)
        self.assertEqual(seen,[request()]);self.assertEqual(result['provider_input_sha256'],sha(request()))
        c=result['citations'][0];part=contract.request_body(request())['evidence'][0]
        self.assertEqual(c['unit'],0);self.assertEqual(c['attachment_sha256'],part['attachment_sha256'])
        self.assertEqual(part['text'].encode()[c['start_utf8']:c['end_utf8']],c['quote'].encode())
        self.assertEqual(result['output_sha256'],contract.output_digest(result));self.assertEqual(len(result['reviewed_evidence_bindings']),3)
        self.assertEqual(result['native'],{'thread_id':'thread-synthetic','turn_id':'turn-synthetic','terminal':'completed','interrupt':'not_requested'})
        self.assertNotIn('output',result);self.assertNotIn('reasoning',result)
        self.assertEqual(self.rpc('codex.research.submit.v1',args)['job_id'],receipt['job_id']);self.assertIsNone(self.runtime.store.claim())

    def test_schema_double_and_every_invalid_reference_reject_whole_result_no_repair(self):
        modes=('sourced_id','sourced_digest','sourced_record','sourced_revision','sourced_unit','sourced_attachment',
            'sourced_quote','sourced_range','sourced_split_utf8','sourced_range_bool','sourced_duplicate',
            'sourced_extra','sourced_large','sourced_refusal')
        for mode in modes:
            with self.subTest(mode=mode):
                self.switch_mode(mode);receipt,args=self.submit();self.execute();current=self.status(receipt)
                self.assertEqual(current['state'],'needs_review');self.assertIsNone(current['result_ref'])
                self.assertEqual(self.rpc('codex.research.submit.v1',args)['job_id'],receipt['job_id']);self.assertIsNone(self.runtime.store.claim())
                self.assertEqual(self.runtime.store.row('tisra',receipt['job_id'])['attempts'],1)
                for key in ('request','descriptor'):
                    self.rpc('codex.payload.revoke.v1',{'payload_id':args[key]['payload_id']})

    def test_multiple_parts_share_one_original_snapshot_descriptor_and_excess_is_rejected(self):
        raw=request();self.assertEqual(len(descriptor(raw,str(uuid.uuid4()))['evidence']),1)
        before=self.runtime.store.db.execute('SELECT count(*) FROM jobs').fetchone()[0]
        self.assert_fault('codex_input_too_large',lambda:self.upload(raw+b' '*(8193-len(raw)),contract.REQUEST,str(uuid.uuid4())))
        self.assert_fault('descriptor_mismatch',lambda:self.submit(mutate=lambda m:m.update(evidence=[])))
        self.assertEqual(self.runtime.store.db.execute('SELECT count(*) FROM jobs').fetchone()[0],before)
        self.assertEqual(self.runtime.store.db.execute('SELECT count(*) FROM budget').fetchone()[0],0)

    def test_original_full_8k_bytes_pass_sole_input_without_truncation(self):
        raw=encode({'schema_version':2,'text':'\\'*3700,'public_history':[],'evidence':[],'migration':None})
        raw+=b' '*(8192-len(raw));seen=[];original=self.text.run_sourced
        def capture(args,context):seen.append(args['input'].encode());return original(args,context)
        self.text.run_sourced=capture;receipt,_=self.submit(raw,deadline_ms=2000);self.execute()
        self.assertEqual(self.status(receipt)['state'],'succeeded');self.assertEqual(seen,[raw]);self.assertEqual(len(raw),8192)

    def test_zero_citations_are_explicit_and_do_not_invent_or_strip_sources(self):
        self.switch_mode('sourced_no_citations');receipt,args=self.submit();self.execute();result=self.result(receipt,args)
        self.assertEqual(result['citations'],[]);self.assertEqual(len(result['reviewed_evidence_bindings']),3)

    def test_cancel_ack_terminal_and_late_completion_never_publish(self):
        for mode,terminal in [('wait_interrupt','interrupted'),('wait_ack_only','unknown'),('late_completed','completed')]:
            self.switch_mode(mode);receipt,_=self.submit(deadline_ms=300)
            self.text.observer=lambda e:self.cancel(receipt) if e['event']=='turn_started' else None
            self.execute();current=self.status(receipt)
            self.assertEqual(current['state'],'needs_review');self.assertIsNone(current['result_ref'])
            self.assertEqual(current['native']['interrupt'],'acknowledged');self.assertEqual(current['native']['terminal'],terminal)

    def test_lost_ack_and_crash_never_replay_ephemeral_turn(self):
        for mode,thread in [('lost_thread_ack',None),('lost_turn_ack','thread-synthetic')]:
            self.switch_mode(mode);receipt,args=self.submit();self.execute();current=self.status(receipt)
            self.assertEqual(current['state'],'needs_review');self.assertEqual(current['native']['thread_id'],thread)
            self.assertIsNone(current['native']['turn_id']);self.assertIsNone(current['result_ref'])
            self.assertEqual(self.rpc('codex.research.submit.v1',args)['job_id'],receipt['job_id']);self.assertIsNone(self.runtime.store.claim())
        self.switch_mode('ok');receipt,args=self.submit();row=self.runtime.store.claim()
        with self.runtime.store.transaction():
            self.engine.external_admission(self.engine.run(row['id']))
            self.runtime.store.db.execute('UPDATE research_runs SET external_started=1 WHERE job=?',(row['id'],))
        self.runtime.store.close();self.runtime.store=Store(self.home/'state.sqlite');self.engine.attach(self.runtime.store)
        self.runtime.store.recover(self.runtime.tools);self.engine.recover()
        with patch.object(self.text,'run_sourced',side_effect=AssertionError('must not replay')):
            self.assertEqual(self.status(receipt)['state'],'needs_review');self.assertIsNone(self.runtime.store.claim())

    def test_v2_generic_task_calls_require_native_binding(self):
        receipt,_=self.submit()
        for method in ('get','cancel','resume'):
            self.assert_fault('typed_research_method_required',lambda:self.rpc(method,{'id':receipt['job_id']}))
        self.assert_fault('typed_research_method_required',lambda:self.rpc('submit',{'tool':NAME,'args':{'run_id':receipt['run_id']},'key':'wrong'}))

    def test_socket_worker_source_required_restore_and_cancellation(self):
        self.runtime.store.close()
        with running(self.home/'socket',policies={'tisra':self.policy},codex_research=self.engine,
            identity_verifier=lambda c,a:'tisra' if a=='tisra' else None) as (runtime,client):
            sdk=CodexSourcedResearchClient(client);raw=request();meta=descriptor(raw,str(uuid.uuid4()))
            self.assertEqual(sdk.capabilities()['contract_sha256'],CONTRACT_SHA256)
            receipt,args=sdk.submit(raw,meta,epoch=0,provider='codex_app_server',model_fingerprint=self.adapter.model_fingerprints[MODEL],deadline_ms=2000)
            record=sdk.durable_record(receipt,args);end=time.monotonic()+3
            while sdk.status(receipt,args)['state'] in {'queued','running'} and time.monotonic()<end:time.sleep(.01)
            reply=json.loads(sdk.read_response(receipt,args));self.assertEqual(reply['citations'][0]['quote'],'中文 exact original quotation.')
            restored=CodexSourcedResearchClient(client);accepted,params=restored.restore_submission(record,sha(record))
            self.assert_fault('codex_source_unavailable',lambda:restored.read_response(accepted,params))
            self.assertEqual(json.loads(restored.read_response(accepted,params,source_request=raw))['citations'],reply['citations'])
            self.assertEqual(restored.cancel(accepted,params)['state'],'needs_review')
            self.assert_fault('research_not_completed',lambda:restored.read_response(accepted,params,source_request=raw))
            self.assertEqual(runtime.store.row('tisra',receipt['job_id'])['attempts'],1)
        self.runtime.store=Store(self.home/'state.sqlite');self.engine.attach(self.runtime.store)
