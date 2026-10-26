import base64
import json
import sys
import time
import uuid
from dataclasses import replace
from pathlib import Path
from unittest.mock import patch

from arl import PROTOCOL
from arl.contracts import AppPolicy, Fault, encode
from arl.codex_server import CodexTextAdapter
from arl.codex_research import CodexResearchEngine, CodexResearchGrant, NativeCodexAdapter, NAME, METHODS, CONTRACT_SHA256
from arl import codex_contract as contract
from arl.research import ResearchEngine, ResearchGrant, METHODS as RESPONSE_METHODS, NAME as RESPONSE_NAME, REQUEST as RESPONSE_REQUEST, sha
from arl.service import Runtime, JobContext
from arl.codex_research_client import CodexResearchClient
from arl.storage import Store
from tests.test_runtime import RuntimeCase, running
from tests.test_research import Adapter as ResponsesDouble, MODEL as RESPONSE_MODEL, FINGERPRINT as RESPONSE_FP
from tests.test_research import DirectClient, body as responses_body, metadata as responses_metadata
from arl.research_client import ResearchClient

MODEL = 'synthetic-model'
FIXTURE = Path(__file__).resolve().parents[1] / 'integrations/codex/fake_server.py'


def request():
    # Whitespace is intentional and must reach the transport without rewriting.
    return b'\n ' + encode({'schema_version': 1, 'text': 'reviewed synthetic question',
        'public_history': [], 'evidence': [], 'migration': None}) + b' \n'


def descriptor(raw, run):
    return {'version': 1, 'executionID': run, 'threadID': str(uuid.uuid4()), 'sequence': 0,
        'parentRunID': None, 'parentFingerprint': None, 'startsAlternatePath': False,
        'model': MODEL, 'format': 'tisra.codex.v1', 'requestDigest': sha(raw), 'requestBytes': len(raw),
        'maximumResponseBytes': 262144, 'maximumOutputTokens': None, 'maximumTextBytes': 128, 'evidence': []}


class NativeResearchTests(RuntimeCase):
    def setUp(self):
        super().setUp()
        self.configure()

    def configure(self, mode='ok'):
        self.text = CodexTextAdapter(enabled=True, test_command=[sys.executable, '-I', str(FIXTURE), mode])
        self.adapter = NativeCodexAdapter([MODEL], text_adapter=self.text)
        self.grant = CodexResearchGrant('codex_app_server', frozenset({MODEL}), 'original-auth-epoch', CONTRACT_SHA256)
        self.engine = CodexResearchEngine({'tisra': self.grant}, {'codex_app_server': self.adapter})
        self.policy = AppPolicy(frozenset({NAME}), methods=METHODS | {'get', 'cancel', 'resume', 'submit', 'health', 'ready'},
            max_pending=16, max_deadline_ms=30000)
        self.runtime = Runtime(self.home, policies={'tisra': self.policy, 'other': self.policy},
            codex_research=self.engine, identity_verifier=lambda *_: None)
        self.runtime.store = Store(self.home / 'state.sqlite'); self.engine.attach(self.runtime.store)
        self.runtime.ready.set()

    def tearDown(self):
        self.runtime.store.close()
        super().tearDown()

    def rpc(self, method, p=None, *, owner='tisra', verified=True):
        return self.runtime.dispatch({'protocol': PROTOCOL, 'app': owner, 'method': method, 'params': p or {}},
            verified_app=owner if verified else None)

    def upload(self, raw, purpose, run):
        value = self.rpc('codex.payload.begin.v1', {'purpose': purpose, 'run_id': run, 'epoch': 0,
            'sha256': sha(raw), 'byte_count': len(raw)})
        for index, offset in enumerate(range(0, len(raw), 8192)):
            chunk = raw[offset:offset+8192]
            self.rpc('codex.payload.write.v1', {'payload_id': value['payload_id'], 'index': index,
                'data_base64': base64.b64encode(chunk).decode(), 'sha256': sha(chunk)})
        ref = {'payload_id': value['payload_id'], 'sha256': sha(raw), 'byte_count': len(raw)}
        self.rpc('codex.payload.seal.v1', ref)
        return ref

    def submit(self, raw=None, *, deadline_ms=800, meta_mutation=None):
        raw = request() if raw is None else raw; run = str(uuid.uuid4()); meta = descriptor(raw, run)
        if meta_mutation: meta_mutation(meta)
        args = {'schema_version': 1, 'run_id': run, 'epoch': 0,
            'request': self.upload(raw, contract.REQUEST, run), 'descriptor': self.upload(encode(meta), contract.DESCRIPTOR, run),
            'provider': 'codex_app_server', 'model': MODEL, 'model_fingerprint': self.adapter.model_fingerprints[MODEL],
            'request_format': contract.FORMATS[0], 'output_format': contract.FORMATS[1], 'history_version': contract.FORMATS[2],
            'max_output_tokens': None, 'max_output_bytes': 128, 'priority': 'explicit', 'deadline_ms': deadline_ms}
        return self.rpc('codex.research.submit.v1', args), args

    @staticmethod
    def binding(receipt): return {k: receipt[k] for k in ('job_id', 'run_id', 'request_sha256', 'epoch')}

    def status(self, receipt): return self.rpc('codex.research.status.v1', self.binding(receipt))
    def cancel(self, receipt): return self.rpc('codex.research.cancel.v1', self.binding(receipt))

    def execute(self):
        row = self.runtime.store.claim(); ctx = JobContext(self.runtime, row)
        try: self.engine.complete(row, self.engine.execute(json.loads(row['args']), ctx))
        except Fault as exc: self.engine.complete(row, error=exc.code)
        return row

    def switch_mode(self, mode):
        self.runtime.store.close(); self.configure(mode)

    def test_opt_in_capabilities_identity_and_honest_budgets(self):
        caps = self.rpc('codex.research.capabilities.v1')
        self.assertEqual(caps['formats']['request'], contract.REQUEST)
        self.assertEqual(caps['max_request_bytes'], 8192); self.assertIsNone(caps['max_output_tokens'])
        self.assertFalse(caps['token_hard_cap_supported']); self.assertFalse(caps['structured_generated_citations'])
        self.assertEqual(caps['provider_evidence'], 'test_double')
        self.assert_fault('app_identity_unverified', lambda: self.rpc('codex.research.capabilities.v1', verified=False))
        self.engine.grants['tisra'] = replace(self.grant, contract_sha256='0'*64)
        self.assert_fault('unsupported_research_provider', lambda: self.rpc('codex.research.capabilities.v1'))
        plain = Runtime(self.home/'metadata', policies={'tisra': self.policy})
        self.assert_fault('unknown_method', lambda: plain.dispatch({'protocol':PROTOCOL,'app':'tisra',
            'method':'codex.research.capabilities.v1','params':{}}, verified_app='tisra'))

    def test_exact_original_bytes_hash_native_binding_and_completed_result(self):
        seen = []
        original_run = self.text.run
        def capture(args, context):
            seen.append(args['input'].encode()); return original_run(args, context)
        self.text.run = capture
        receipt, args = self.submit(); self.execute(); current = self.status(receipt)
        self.assertEqual(current['state'], 'succeeded'); self.assertEqual(seen, [request()])
        self.assertEqual(current['native'], {'thread_id':'thread-synthetic','turn_id':'turn-synthetic',
            'terminal':'completed','interrupt':'not_requested'})
        ref = current['result_ref']; raw = bytes(self.engine.payload('tisra', ref['payload_id'])['data'])
        result = contract.result_body(raw, args, binding=current, native=current['native'])
        self.assertEqual(result['text'], 'synthetic plan'); self.assertEqual(result['provider_input_sha256'], sha(request()))
        self.assertIsNone(result['model_evidence']['backend_weights_revision']); self.assertEqual(result['usage'], {'tokens':None,'cost':None})
        self.assertEqual(sha(raw), ref['sha256'])
        self.assertEqual(self.rpc('codex.research.submit.v1', args)['job_id'], receipt['job_id'])
        self.assertIsNone(self.runtime.store.claim())

    def test_oversize_invalid_history_and_wrong_descriptor_rejected_before_budget(self):
        before = self.runtime.store.db.execute('SELECT count(*) FROM jobs').fetchone()[0]
        self.assert_fault('codex_input_too_large', lambda: self.upload(b'x'*8193, contract.REQUEST, str(uuid.uuid4())))
        invalid = encode({'schema_version':1,'text':'ok','public_history':[], 'evidence':[], 'migration':None, 'tools':[]})
        self.assert_fault('codex_request_invalid', lambda: self.submit(invalid))
        self.assert_fault('descriptor_mismatch', lambda: self.submit(meta_mutation=lambda m:m.update(evidence=[{'evidenceID':str(uuid.uuid4()),'snapshotDigest':'a'*64}])))
        self.assertEqual(self.runtime.store.db.execute('SELECT count(*) FROM jobs').fetchone()[0], before)
        self.assertEqual(self.runtime.store.db.execute('SELECT count(*) FROM budget').fetchone()[0], 0)
        self.assertEqual(self.runtime.store.db.execute('SELECT count(*) FROM research_native').fetchone()[0], 0)

    def test_full_8k_escaped_request_and_separate_32k_descriptor_preserved(self):
        raw=encode({'schema_version':1,'text':'\\'*3700,'public_history':[], 'evidence':[], 'migration':None})
        raw+=b' '*(8192-len(raw));run=str(uuid.uuid4());meta=encode(descriptor(raw,run))
        meta+=b' '*(32768-len(meta));seen=[];original=self.text.run
        def capture(args,context):
            seen.append(args['input'].encode());return original(args,context)
        self.text.run=capture
        args={'schema_version':1,'run_id':run,'epoch':0,'request':self.upload(raw,contract.REQUEST,run),
            'descriptor':self.upload(meta,contract.DESCRIPTOR,run),'provider':'codex_app_server','model':MODEL,
            'model_fingerprint':self.adapter.model_fingerprints[MODEL],'request_format':contract.FORMATS[0],
            'output_format':contract.FORMATS[1],'history_version':contract.FORMATS[2],
            'max_output_tokens':None,'max_output_bytes':128,'priority':'explicit','deadline_ms':2000}
        receipt=self.rpc('codex.research.submit.v1',args);self.execute()
        self.assertEqual(self.status(receipt)['state'],'succeeded');self.assertEqual(seen,[raw])
        self.assertEqual(len(raw),8192);self.assertEqual(len(meta),32768)

    def test_prestart_cancel_and_generic_task_methods_cannot_reopen_native_run(self):
        receipt, _ = self.submit(); current = self.cancel(receipt)
        self.assertEqual(current['state'],'cancelled'); self.assertEqual(current['external_stop'],'not_started')
        self.assertIsNone(self.runtime.store.claim())
        for method in ('get','cancel','resume'):
            self.assert_fault('typed_research_method_required', lambda:self.rpc(method,{'id':receipt['job_id']}))
        self.assert_fault('typed_research_method_required', lambda:self.rpc('submit',{'tool':NAME,'args':{'run_id':receipt['run_id']},'key':'wrong'}))

    def test_durable_ack_ids_exist_before_returning_from_provider_and_survive_restart(self):
        self.switch_mode('wait_interrupt'); receipt, args = self.submit()
        observed = []
        def stop(event):
            if event['event'] == 'turn_started':
                observed.append(self.engine.native_projection(self.engine.native_row(receipt['job_id'])))
                self.cancel(receipt)
        self.text.observer = stop; self.execute()
        self.assertEqual(observed[0]['turn_id'], 'turn-synthetic')
        current = self.status(receipt); self.assertEqual(current['state'], 'needs_review')
        self.assertEqual(current['native']['interrupt'], 'acknowledged')
        self.assertEqual(current['native']['terminal'], 'interrupted'); self.assertIsNone(current['result_ref'])
        self.runtime.store.close(); self.runtime.store = Store(self.home/'state.sqlite'); self.engine.attach(self.runtime.store)
        self.runtime.store.recover(self.runtime.tools); self.engine.recover()
        self.assertEqual(self.status(receipt)['native'], current['native'])
        self.assertEqual(self.rpc('codex.research.submit.v1', args)['job_id'], receipt['job_id'])
        self.assertIsNone(self.runtime.store.claim())

    def test_interrupt_ack_without_terminal_is_not_external_stop(self):
        self.switch_mode('wait_ack_only'); receipt, _ = self.submit(deadline_ms=300)
        self.text.observer = lambda event: self.cancel(receipt) if event['event']=='turn_started' else None
        self.execute(); current = self.status(receipt)
        self.assertEqual(current['native']['interrupt'], 'acknowledged')
        self.assertEqual(current['native']['terminal'], 'unknown'); self.assertEqual(current['external_stop'], 'unknown')
        self.assertIsNone(current['result_ref'])

    def test_lost_start_ack_is_unknown_never_replayed(self):
        for mode, thread in [('lost_thread_ack',None),('lost_turn_ack','thread-synthetic')]:
            self.switch_mode(mode); receipt, args = self.submit(); self.execute(); current = self.status(receipt)
            self.assertEqual(current['state'],'needs_review'); self.assertEqual(current['native']['thread_id'],thread)
            self.assertIsNone(current['native']['turn_id']); self.assertEqual(current['native']['terminal'],'unknown')
            self.assertEqual(self.rpc('codex.research.submit.v1',args)['job_id'],receipt['job_id'])
            self.assertIsNone(self.runtime.store.claim())

    def test_cancel_and_auth_epoch_drift_discard_matching_late_completed(self):
        for invalidate in ('cancel','epoch'):
            self.switch_mode('late_completed'); receipt, _ = self.submit()
            def drift(event):
                if event['event']=='turn_started':
                    if invalidate=='cancel': self.cancel(receipt)
                    else: self.engine.replace_grant('tisra', replace(self.grant,auth_epoch='new-epoch'))
            self.text.observer=drift; self.execute(); current=self.status(receipt)
            self.assertEqual(current['state'],'needs_review'); self.assertIsNone(current['result_ref'])
            self.assertEqual(current['auth_epoch'],'original-auth-epoch')
            self.assertEqual(current['native']['terminal'],'completed')
            self.assertEqual(current['native']['interrupt'],'acknowledged')

    def test_revoked_grant_retains_owner_bound_status_cancel_cleanup(self):
        receipt,args=self.submit();self.engine.replace_grant('tisra',None)
        self.assertEqual(self.status(receipt)['state'],'cancelled');self.cancel(receipt)
        self.assertEqual(self.rpc('codex.payload.revoke.v1',{'payload_id':args['request']['payload_id']})['revoked'],True)
        self.assert_fault('app_identity_unverified', lambda:self.rpc('codex.research.status.v1',self.binding(receipt),verified=False))
        self.assert_fault('research_not_found', lambda:self.rpc('codex.research.status.v1',self.binding(receipt),owner='other'))

    def test_tools_failed_terminal_and_wrong_turn_fail_closed(self):
        for mode in ('action','failed_turn','mismatch','wait_wrong_terminal'):
            self.switch_mode(mode);receipt,_=self.submit(deadline_ms=250)
            if mode=='wait_wrong_terminal':
                self.text.observer=lambda event:self.cancel(receipt) if event['event']=='turn_started' else None
            self.execute();current=self.status(receipt)
            self.assertEqual(current['state'],'needs_review');self.assertIsNone(current['result_ref'])
            if mode=='failed_turn':self.assertEqual(current['native']['terminal'],'failed')
            if mode=='wait_wrong_terminal':self.assertEqual(current['native']['terminal'],'unknown')

    def test_native_ids_cannot_be_rebound(self):
        receipt,_=self.submit();self.execute()
        self.assert_fault('provider_contract_mismatch',lambda:self.engine.record_native(receipt['job_id'],'native_turn_ack',{'turn_id':'another'}))
        self.assertEqual(self.status(receipt)['native']['turn_id'],'turn-synthetic')

    def test_thread_ack_keeps_admitted_model_evidence_when_registry_changes(self):
        receipt,_=self.submit();original=self.adapter.model_evidence(MODEL)
        replacement=NativeCodexAdapter([MODEL],text_adapter=self.text)
        replacement.control_sha256='0'*64
        replacement.model_fingerprints={MODEL:contract.model_fingerprint(replacement.model_evidence(MODEL))}
        def replace_registry(event):
            if event['event']=='thread_started':self.engine.adapters['codex_app_server']=replacement
        self.text.observer=replace_registry;self.execute()
        native=self.engine.native_row(receipt['job_id'])
        self.assertEqual(json.loads(native['model_evidence']),original)
        self.assertEqual(native['thread_id'],'thread-synthetic');self.assertIsNone(native['turn_id'])
        self.assertIsNone(self.status(receipt)['result_ref'])

    def test_crash_after_external_admission_is_needs_review_without_process_launch(self):
        receipt,args=self.submit();row=self.runtime.store.claim()
        with self.runtime.store.transaction():
            r=self.engine.run(row['id']);self.engine.external_admission(r)
            self.runtime.store.db.execute('UPDATE research_runs SET external_started=1 WHERE job=?',(row['id'],))
        self.runtime.store.close();self.runtime.store=Store(self.home/'state.sqlite');self.engine.attach(self.runtime.store)
        self.runtime.store.recover(self.runtime.tools);self.engine.recover()
        with patch.object(self.text,'run',side_effect=AssertionError('must not launch')):
            self.assertEqual(self.status(receipt)['state'],'needs_review');self.cancel(receipt)
            self.rpc('codex.research.submit.v1',args)
            self.assertIsNone(self.runtime.store.claim())

    def test_native_and_responses_namespaces_share_worker_not_payload_contract(self):
        response_adapter=ResponsesDouble()
        responses=ResearchEngine({'tisra':ResearchGrant('responses_fixture',frozenset({RESPONSE_MODEL}),'r-auth')},
            {'responses_fixture':response_adapter})
        responses.attach(self.runtime.store);self.runtime.research_engines[RESPONSE_NAME]=responses
        self.runtime.tools[RESPONSE_NAME]=responses.tool
        self.runtime.policies['tisra']=replace(self.policy,tools=self.policy.tools|{RESPONSE_NAME},methods=self.policy.methods|RESPONSE_METHODS)
        receipt,args=self.submit();self.execute()
        for pid in (args['request']['payload_id'],self.status(receipt)['result_ref']['payload_id']):
            self.assert_fault('payload_binding_mismatch',lambda:self.rpc('payload.read.v1',{'payload_id':pid,'offset':0,'limit':8192}))
        legacy=self.rpc('payload.begin.v1',{'purpose':RESPONSE_REQUEST,'run_id':str(uuid.uuid4()),'epoch':0,'sha256':sha(b'x'),'byte_count':1})
        self.assert_fault('payload_binding_mismatch',lambda:self.rpc('codex.payload.revoke.v1',{'payload_id':legacy['payload_id']}))

    def test_format_grants_and_status_cancellation_are_independent_in_shared_store(self):
        responses=ResearchEngine({'tisra':ResearchGrant('responses_fixture',frozenset({RESPONSE_MODEL}),'r-auth')},
            {'responses_fixture':ResponsesDouble()})
        responses.attach(self.runtime.store);self.runtime.research_engines[RESPONSE_NAME]=responses
        self.runtime.tools[RESPONSE_NAME]=responses.tool
        self.runtime.policies['tisra']=replace(self.policy,tools=self.policy.tools|{RESPONSE_NAME},methods=self.policy.methods|RESPONSE_METHODS)
        native,_=self.submit();sdk=ResearchClient(DirectClient(self.runtime));raw=responses_body()
        response,_=sdk.submit(raw,responses_metadata(raw,str(uuid.uuid4())),epoch=0,
            provider='responses_fixture',model_fingerprint=RESPONSE_FP,deadline_ms=30000)
        self.assert_fault('research_receipt_mismatch',lambda:self.rpc('research.cancel.v1',self.binding(native)))
        self.assert_fault('research_receipt_mismatch',lambda:self.rpc('codex.research.cancel.v1',self.binding(response)))
        responses.replace_grant('tisra',ResearchGrant('responses_fixture',frozenset({RESPONSE_MODEL}),'r-auth-new'))
        self.assertEqual(self.status(native)['state'],'queued')
        response,_=sdk.submit(raw,responses_metadata(raw,str(uuid.uuid4())),epoch=0,
            provider='responses_fixture',model_fingerprint=RESPONSE_FP,deadline_ms=30000)
        self.engine.replace_grant('tisra',replace(self.grant,auth_epoch='native-auth-new'))
        self.assertEqual(self.rpc('research.status.v1',self.binding(response))['state'],'queued')
        self.assertEqual(self.status(native)['state'],'cancelled')

    def test_real_existing_runtime_worker_and_socket_to_transport_double_only(self):
        self.runtime.store.close()
        with running(self.home/'socket',policies={'tisra':self.policy},codex_research=self.engine,
                identity_verifier=lambda c,a:'tisra' if a=='tisra' else None) as (r,client):
            sdk=CodexResearchClient(client);raw=request();meta=descriptor(raw,str(uuid.uuid4()))
            self.assertEqual(sdk.capabilities()['provider_evidence'],'test_double')
            receipt,args=sdk.submit(raw,meta,epoch=0,provider='codex_app_server',
                model_fingerprint=self.adapter.model_fingerprints[MODEL],deadline_ms=2000)
            record=sdk.durable_record(receipt,args);end=time.monotonic()+3
            while sdk.status(receipt,args)['state'] in {'queued','running'} and time.monotonic()<end:time.sleep(.01)
            self.assertEqual(sdk.status(receipt,args)['state'],'succeeded')
            self.assertEqual(json.loads(sdk.read_response(receipt,args))['text'],'synthetic plan')
            restored=CodexResearchClient(client);accepted,params=restored.restore_submission(record,sha(record))
            self.assertEqual(restored.status(accepted,params)['state'],'succeeded')
            self.assertEqual(restored.cancel(accepted,params)['state'],'needs_review')
            self.assertEqual(r.store.db.execute('SELECT attempts FROM jobs WHERE id=?',(receipt['job_id'],)).fetchone()[0],1)
        self.runtime.store=Store(self.home/'state.sqlite');self.engine.attach(self.runtime.store)
