"""Real Store SQLite/Runtime dispatch; consumer and upload authority are doubles.

These tests establish byte/identity/replay gates, not live Tisra authority or
Ledger semantics. The isolated Swift suite exercises the actual Ledger rules.
"""
from __future__ import annotations

import base64
import hashlib
import json
import socket
import tempfile
import threading
import time
import unittest
import uuid
from dataclasses import replace
from pathlib import Path

from arl import PROTOCOL
from arl.contracts import AppPolicy, Fault, encode
from arl.service import Handler, JobContext, Runtime, Server, default_policies
from arl.storage import Store
from arl.tisra_capture_contract import (
    NAME, REQUEST_PURPOSE, CaptureCodec, CommitConfirmation, MAX_REQUEST_BYTES, MAX_RESULT_BYTES,
)
from arl.tisra_capture_runtime import (
    CODEC, SCHEMA_SHA256, METHODS, CaptureRuntime, CaptureCommit, CaptureConsumerPin,
    RegisteredCaptureParticipant, CapturePayloadRequest, UploadedCapturePayload,
)

FIXTURES = Path(__file__).resolve().parents[1] / 'tests/fixtures/capture_transport'


def sha(raw): return hashlib.sha256(raw).hexdigest()
def uid(): return str(uuid.uuid4())


class PayloadDouble:
    def __init__(self): self.uploads = {}; self.calls = 0

    def put(self, owner, capture_id, epoch, raw):
        ref = {'payload_id': uid(), 'sha256': sha(raw), 'byte_count': len(raw)}
        request = CapturePayloadRequest(owner, capture_id, epoch, **ref)
        self.uploads[ref['payload_id']] = UploadedCapturePayload(request, raw, True, time.time()+900)
        return ref

    def resolve(self, request):
        self.calls += 1
        return self.uploads[request.payload_id]


class ConsumerDouble:
    """Synthetic journal only; it never accesses a library or native transport."""
    def __init__(self, pin, raw_result, state='created'):
        self.pin, self.raw_result, self.state = pin, raw_result, state
        self.journal, self.acknowledged, self.outer = {}, set(), {}
        self.writes = self.calls = self.acks = self.lookups = 0
        self.after_write = None
        self.callback_error = self.ack_error = self.no_guard = self.bad_confirmation = False
        self.uncertain = set()

    def metadata(self): return self.pin

    def cached(self, binding, raw_request, authority):
        self.lookups += 1
        if sha(raw_request) != binding.request_sha256 or len(raw_request) != binding.request_bytes:
            raise ValueError('cache needs exact original request bytes')
        if binding.capture_request_id in self.acknowledged:
            return self.journal[binding.capture_request_id]
        return None

    def capture(self, binding, raw_request, authority, guard):
        self.calls += 1
        def write():
            self.writes += 1
            commit = CaptureCommit(binding, authority, self.state, self.raw_result, uid(), uid(),
                                   int(time.time()*1000))
            self.journal[binding.capture_request_id] = commit
            return commit
        commit = write() if self.no_guard else guard.perform(write)
        if self.after_write: self.after_write()
        if self.callback_error: raise OSError('synthetic lost consumer reply')
        return commit

    def confirm(self, commit, raw_outer_receipt, raw_request, authority):
        if sha(raw_request) != commit.binding.request_sha256 or len(raw_request) != commit.binding.request_bytes:
            raise ValueError('confirmation needs exact original request bytes')
        if self.bad_confirmation or self.journal.get(commit.binding.capture_request_id) != commit:
            raise ValueError('not this synthetic journal')
        self.outer.setdefault(commit.binding.capture_request_id, raw_outer_receipt)
        if self.outer[commit.binding.capture_request_id] != raw_outer_receipt:
            raise ValueError('first outer receipt is immutable')
        return CommitConfirmation(commit.binding.library_id, commit.binding.capture_request_id,
                                  commit.transaction_id, sha(raw_outer_receipt))

    def acknowledge(self, commit, raw_outer, authority, guard):
        guard.check()
        self.acks += 1
        if self.outer[commit.binding.capture_request_id] != raw_outer: raise ValueError('changed receipt')
        if self.ack_error: raise OSError('synthetic lost ACK')
        guard.perform(lambda: self.acknowledged.add(commit.binding.capture_request_id))

    def report_uncertain(self, binding, authority):
        self.uncertain.add(binding.capture_request_id)


class CaptureRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='arl-capture-test-')
        self.home = Path(self.temp.name)
        self.raw = (FIXTURES / 'metadata-request.json').read_bytes()
        self.result = (FIXTURES / 'metadata-created.receipt.json').read_bytes()
        self.library, self.instance = uid(), uid()
        self.participant = RegisteredCaptureParticipant('registered-peer-opaque', 'agent', 'native-epoch-7')
        self.pin = CaptureConsumerPin(self.library, self.instance, 'b'*64)
        self.payload = PayloadDouble()
        self.consumer = ConsumerDouble(self.pin, self.result)
        self.registered = self.allowed = True
        self.validation_pairs = {(self.result, self.raw, 'created')}
        self.valid_requests = {self.raw}
        self.observed_request = []; self.observed_result = []
        def request_check(raw):
            if raw not in self.valid_requests: raise ValueError('not a synthetic fixture')
            self.observed_request.append(raw)
        def result_check(raw_result, raw_request, state):
            if (raw_result, raw_request, state) not in self.validation_pairs: raise ValueError('wrong exact pair')
            self.observed_result.append((raw_result, raw_request, state))
        self.codec = CaptureCodec(CODEC, SCHEMA_SHA256, request_check, result_check)
        self.engine = CaptureRuntime(active=True,
            participants={'tisra': self.participant},
            library_grants={('tisra', self.participant.participant_id): frozenset({self.library})},
            method_grants={('tisra', self.participant.participant_id, self.library): METHODS},
            pins={self.library: self.pin}, consumers={self.library: self.consumer},
            codec=self.codec, payload_resolver=self.payload,
            registered_peer=lambda owner, participant: self.registered,
            authorizer=lambda authority, method: self.allowed)
        self.policy = AppPolicy(frozenset({NAME}), methods=METHODS | {'submit', 'get', 'cancel', 'resume'}, max_pending=16)
        self.runtime = Runtime(self.home, policies={'tisra': self.policy, 'other': self.policy},
                               capture=self.engine, identity_verifier=lambda *_: None)
        self.runtime.store = Store(self.home/'state.sqlite')
        self.engine.attach(self.runtime.store); self.runtime.ready.set()

    def tearDown(self):
        self.runtime.store.close(); self.temp.cleanup()

    def rpc(self, method, params=None, *, owner='tisra', verified=True):
        return self.runtime.dispatch({'protocol': PROTOCOL, 'app': owner, 'method': method, 'params': params or {}},
                                     verified_app=owner if verified else None)

    def assert_fault(self, code, callback):
        with self.assertRaises(Fault) as raised: callback()
        self.assertEqual(raised.exception.code, code)

    def submission(self, raw=None, capture_id=None, **changes):
        raw = self.raw if raw is None else raw; capture_id = capture_id or uid()
        request = {'schema_version': 1, 'capture_request_id': capture_id, 'library_id': self.library,
                   'codec': CODEC, 'consumer_schema_sha256': SCHEMA_SHA256,
                   'payload': self.payload.put('tisra', capture_id, self.participant.auth_epoch, raw),
                   'declared_attribution': {'role': 'human', 'display_name': 'Untrusted synthetic display'}}
        request.update(changes)
        return {'key': capture_id, 'request': request}

    def submit(self, **kwargs):
        params = self.submission(**kwargs)
        return self.rpc('capture.submit.v1', params), params

    @staticmethod
    def binding(receipt):
        return {k: receipt['binding'][k] for k in ('capture_request_id', 'admission_sha256')}

    def status(self, receipt): return self.rpc('capture.status.v1', self.binding(receipt))

    def execute(self):
        row = self.runtime.store.claim()
        self.assertIsNotNone(row)
        context = JobContext(self.runtime, row)
        try:
            self.engine.complete(row, self.engine.execute(json.loads(row['args']), context))
        except Exception:
            self.engine.complete(row, error='capture_needs_review')
        return row

    def test_default_disabled_no_route_grants_or_library_discovery(self):
        plain = Runtime(self.home/'plain')
        self.assertNotIn(NAME, plain.tools)
        self.assertTrue(all(NAME not in p.tools and not METHODS.intersection(p.methods) for p in default_policies().values()))
        self.assert_fault('unknown_method', lambda: plain.dispatch({'protocol': PROTOCOL, 'app': 'tisra',
            'method': 'capture.capabilities.v1', 'params': {'library_id': self.library}}, verified_app='tisra'))
        disabled = CaptureRuntime()
        runtime = Runtime(self.home/'disabled', policies={'tisra': self.policy}, capture=disabled,
                          identity_verifier=lambda *_: None)
        runtime.ready.set()
        self.assert_fault('capture_disabled', lambda: runtime.dispatch({'protocol': PROTOCOL, 'app': 'tisra',
            'method': 'capture.capabilities.v1', 'params': {'library_id': self.library}}, verified_app='tisra'))
        self.assertEqual(self.consumer.lookups, 0); self.assertEqual(self.payload.calls, 0)

    def test_authentication_and_independent_grants_are_required_before_resolving(self):
        params = self.submission()
        self.assert_fault('app_identity_unverified', lambda: self.rpc('capture.submit.v1', params, verified=False))
        self.assert_fault('capture_participant_unregistered', lambda: self.rpc('capture.submit.v1', params, owner='other'))
        self.engine.registered_peer = None
        self.assert_fault('capture_host_unconfigured', lambda: self.rpc('capture.submit.v1', params))
        self.engine.registered_peer = lambda *_: True
        self.engine.authorizer = None
        self.assert_fault('capture_host_unconfigured', lambda: self.rpc('capture.submit.v1', params))
        self.engine.authorizer = lambda *_: True
        self.engine.configure(library_grants={})
        self.assert_fault('capture_library_not_authorized', lambda: self.rpc('capture.submit.v1', params))
        self.engine.configure(library_grants={('tisra',self.participant.participant_id):{self.library}}, method_grants={})
        self.assert_fault('capture_method_not_authorized', lambda: self.rpc('capture.submit.v1', params))
        self.assertEqual(self.payload.calls, 0)
        self.assertEqual(self.runtime.store.db.execute('SELECT COUNT(*) FROM jobs').fetchone()[0], 0)

    def test_key_outer_codec_and_payload_capability_binding(self):
        params = self.submission(); params['key'] = uid()
        self.assert_fault('capture_key_mismatch', lambda: self.rpc('capture.submit.v1', params))
        params = self.submission(codec='tisra.unsupported')
        self.assert_fault('capture_codec_unsupported', lambda: self.rpc('capture.submit.v1', params))
        for alteration in ({'owner':'other'}, {'capture_request_id':uid()}, {'auth_epoch':'8'}, {'purpose':'research.request'}):
            params = self.submission(); pid = params['request']['payload']['payload_id']
            uploaded = self.payload.uploads[pid]
            self.payload.uploads[pid] = replace(uploaded, request=replace(uploaded.request, **alteration))
            self.assert_fault('capture_payload_capability_mismatch', lambda: self.rpc('capture.submit.v1', params))
        for alteration in ({'sealed':False}, {'expires_at':time.time()-1}, {'expires_at':float('nan')}):
            params = self.submission(); pid = params['request']['payload']['payload_id']
            self.payload.uploads[pid] = replace(self.payload.uploads[pid], **alteration)
            self.assert_fault('capture_payload_capability_mismatch', lambda: self.rpc('capture.submit.v1', params))
        params = self.submission(); pid = params['request']['payload']['payload_id']
        self.payload.uploads[pid] = replace(self.payload.uploads[pid], raw=self.raw+b' ')
        self.assert_fault('capture_payload_mismatch', lambda: self.rpc('capture.submit.v1', params))
        self.assertEqual(self.consumer.writes, 0)

    def test_exact_synthetic_transport_pairs_complete_and_cache_same_bytes(self):
        states = ['created','deduplicated','created','deduplicated','created','partial','created','deduplicated']
        for index,state in enumerate(states):
            with self.subTest(case=index,state=state):
                raw = encode({'fixture':'opaque synthetic request','case':index})
                result = encode({'fixture':'opaque synthetic result','case':index})
                self.valid_requests.add(raw); self.validation_pairs.add((result, raw, state))
                self.consumer.raw_result, self.consumer.state = result, state
                receipt, params = self.submit(raw=raw); self.execute()
                completed = self.status(receipt)
                self.assertEqual(completed['state'], 'succeeded')
                self.assertEqual(completed['receipt']['state'], state)
                self.assertEqual(completed['binding']['writing_participant']['participant_id'], self.participant.participant_id)
                self.assertEqual(completed['binding']['writing_participant']['actor_kind'], 'agent')
                self.assertEqual(completed['receipt']['result_ref']['sha256'], sha(result))
                before = self.consumer.writes
                cached = self.rpc('capture.submit.v1', params)
                self.assertEqual(encode(cached['receipt']), encode(completed['receipt']))
                self.assertEqual(self.consumer.writes, before)
                read = self.rpc('capture.result.read.v1', dict(self.binding(receipt), offset=0, limit=8192))
                self.assertEqual(base64.b64decode(read['data_base64']), result)
                self.assertTrue(read['eof'])
                self.assertEqual(self.observed_result[-1], (result, raw, state))
        self.assertEqual(self.consumer.calls, 8)
        self.assertIsNone(self.runtime.store.claim())

    def test_idempotency_binds_logical_metadata_exact_bytes_authority_and_new_handle(self):
        receipt, params = self.submit()
        same = self.submission(capture_id=params['key'])
        self.assertEqual(self.rpc('capture.submit.v1', same)['job_id'], receipt['job_id'])
        changed = self.submission(capture_id=params['key'], declared_attribution=None)
        self.assert_fault('capture_idempotency_conflict', lambda:self.rpc('capture.submit.v1', changed))
        changed_raw = self.raw+b' '; self.valid_requests.add(changed_raw)
        changed = self.submission(raw=changed_raw, capture_id=params['key'])
        self.assert_fault('capture_idempotency_conflict', lambda:self.rpc('capture.submit.v1', changed))
        self.engine.configure(participants={'tisra':replace(self.participant,auth_epoch='new-epoch')})
        changed = self.submission(capture_id=params['key'])
        pid = changed['request']['payload']['payload_id']; uploaded=self.payload.uploads[pid]
        self.payload.uploads[pid]=replace(uploaded,request=replace(uploaded.request,auth_epoch='new-epoch'))
        self.assert_fault('capture_idempotency_conflict', lambda:self.rpc('capture.submit.v1', changed))
        self.assertEqual(self.consumer.writes, 0)

    def test_generic_methods_cannot_bypass_typed_admission_or_resume(self):
        receipt, _ = self.submit()
        self.assert_fault('typed_capture_method_required', lambda:self.rpc('submit',
            {'tool':NAME,'args':{'capture_request_id':receipt['binding']['capture_request_id']},'key':'wrong'}))
        for method in ('get','cancel','resume'):
            self.assert_fault('typed_capture_method_required', lambda method=method:self.rpc(method,{'id':receipt['job_id']}))

    def test_caller_cannot_register_callbacks_paths_authority_or_consumer(self):
        for key in ('consumer', 'callback', 'participant_id', 'auth_epoch', 'path', 'url'):
            params=self.submission();params[key]='synthetic caller claim'
            self.assert_fault('capture_invalid_arguments',lambda:self.rpc('capture.submit.v1',params))
        self.assertEqual(self.payload.calls,0);self.assertEqual(self.consumer.calls,0)

    def test_actual_worker_composes_typed_execution_and_confirmed_completion(self):
        receipt,_=self.submit()
        worker=threading.Thread(target=self.runtime.work);worker.start()
        try:
            deadline=time.monotonic()+5
            while self.runtime.store.get('tisra',receipt['job_id'])['state'] not in {'succeeded','needs_review','failed'}:
                if time.monotonic()>deadline:self.fail('capture worker did not finish')
                self.runtime.job_signal.wait(0.01)
            self.assertEqual(self.status(receipt)['state'],'succeeded')
            self.assertEqual(self.consumer.calls,1);self.assertEqual(self.consumer.acks,1)
        finally:
            self.runtime.stopping.set();self.runtime.job_signal.set();worker.join(5)
            self.assertFalse(worker.is_alive())

    def test_fresh_registration_policy_epoch_and_pin_revocation_before_write(self):
        variations = ('registration', 'authorizer', 'policy', 'participant', 'code', 'instance', 'schema', 'methods')
        for variation in variations:
            with self.subTest(variation=variation):
                receipt, _ = self.submit()
                old_participants=dict(self.engine.participants); old_pin=self.consumer.pin
                old_methods=dict(self.engine.method_grants)
                if variation == 'registration': self.registered=False
                if variation == 'authorizer': self.allowed=False
                if variation == 'policy': self.runtime.policies['tisra']=replace(self.policy,tools=frozenset())
                if variation == 'participant': self.engine.configure(participants={'tisra':replace(self.participant,auth_epoch='rotated')})
                if variation == 'code': self.consumer.pin=replace(self.pin,code_sha256='c'*64)
                if variation == 'instance': self.consumer.pin=replace(self.pin,instance_id=uid())
                if variation == 'schema': self.consumer.pin=replace(self.pin,consumer_schema_sha256='d'*64)
                if variation == 'methods': self.engine.configure(method_grants={})
                self.execute()
                self.assertEqual(self.runtime.store.get('tisra',receipt['job_id'])['state'],'needs_review')
                self.assertEqual(self.consumer.writes,0)
                self.registered=self.allowed=True; self.runtime.policies['tisra']=self.policy
                self.engine.configure(participants=old_participants,method_grants=old_methods); self.consumer.pin=old_pin

    def test_revocation_between_record_effects_blocks_next_actual_guarded_write(self):
        receipt, _ = self.submit()
        def capture(binding, raw, authority, guard):
            guard.perform(lambda:setattr(self.consumer,'writes',self.consumer.writes+1))
            self.allowed=False
            guard.perform(lambda:setattr(self.consumer,'writes',self.consumer.writes+1))
        self.consumer.capture=capture
        self.execute()
        self.assertEqual(self.consumer.writes,1)
        self.assertEqual(self.runtime.store.get('tisra',receipt['job_id'])['state'],'needs_review')
        self.assertEqual(self.consumer.acks,0)

    def test_callback_lost_ack_cancel_and_restart_never_auto_replay(self):
        for mode in ('callback','ack','cancel','restart'):
            with self.subTest(mode=mode):
                self.consumer.callback_error=self.consumer.ack_error=False; self.consumer.after_write=None
                receipt, params=self.submit()
                if mode == 'callback': self.consumer.callback_error=True
                if mode == 'ack': self.consumer.ack_error=True
                if mode == 'cancel': self.consumer.after_write=lambda:self.rpc('capture.cancel.v1',self.binding(receipt))
                before=self.consumer.writes
                if mode == 'restart':
                    row=self.runtime.store.claim()
                    self.engine.execute(json.loads(row['args']),JobContext(self.runtime,row))
                    self.runtime.store.close(); self.runtime.store=Store(self.home/'state.sqlite'); self.engine.attach(self.runtime.store)
                    self.runtime.store.recover(self.runtime.tools); self.engine.recover()
                else: self.execute()
                current=self.status(receipt)
                self.assertEqual(current['state'],'needs_review'); self.assertEqual(current['receipt']['state'],'needs_review')
                self.assertIsNone(current['receipt']['result_ref'])
                self.assertEqual(self.rpc('capture.submit.v1',params)['state'],'needs_review')
                self.assertEqual(self.consumer.writes,before+1)
                self.assertIsNone(self.runtime.store.claim())
                self.assertIn(params['key'],self.consumer.uncertain)

    def test_cancel_before_attempt_and_queued_restart_do_not_call_consumer(self):
        receipt,_=self.submit()
        self.assertEqual(self.rpc('capture.cancel.v1',self.binding(receipt))['state'],'cancelled')
        self.assertIsNone(self.runtime.store.claim()); self.assertEqual(self.consumer.calls,0)
        receipt,_=self.submit(); self.engine.recover()
        self.assertEqual(self.status(receipt)['state'],'needs_review')
        self.assertIsNone(self.runtime.store.claim()); self.assertEqual(self.consumer.calls,0)

    def test_result_excess_wrong_classification_confirmation_and_bypass_are_held(self):
        for mode in ('excess','partial_classification','confirmation','guard'):
            with self.subTest(mode=mode):
                self.consumer.raw_result=self.result; self.consumer.state='created'
                self.consumer.bad_confirmation=self.consumer.no_guard=False
                if mode == 'excess': self.consumer.raw_result=b'x'*(MAX_RESULT_BYTES+1)
                if mode == 'partial_classification': self.consumer.state='deduplicated'
                if mode == 'confirmation': self.consumer.bad_confirmation=True
                if mode == 'guard': self.consumer.no_guard=True
                receipt,_=self.submit(); self.execute()
                self.assertEqual(self.status(receipt)['state'],'needs_review')

    def test_cached_receipt_change_or_loss_holds_without_replaying(self):
        receipt,params=self.submit();self.execute(); self.assertEqual(self.status(receipt)['state'],'succeeded')
        old=self.consumer.journal[params['key']]
        self.consumer.journal[params['key']]=replace(old,transaction_id=uid())
        self.assert_fault('capture_needs_review',lambda:self.status(receipt))
        self.assertEqual(self.status(receipt)['state'],'needs_review');self.assertEqual(self.consumer.writes,1)
        receipt,params=self.submit();self.execute();self.consumer.acknowledged.remove(params['key'])
        self.assert_fault('capture_needs_review',lambda:self.status(receipt))
        self.assertEqual(self.consumer.writes,2);self.assertIsNone(self.runtime.store.claim())

    def test_sqlite_delivery_metadata_contains_no_request_result_or_declared_attribution(self):
        receipt,_=self.submit();self.execute()
        row=self.runtime.store.db.execute('SELECT * FROM capture_delivery_v1').fetchone()
        serialized=encode(dict(row))
        self.assertNotIn(b'Untrusted synthetic display',serialized)
        self.assertNotIn(self.raw,serialized);self.assertNotIn(self.result,serialized)
        job=self.runtime.store.row('tisra',receipt['job_id'])
        self.assertIsNone(job['result'])
        self.assertEqual(json.loads(job['args']),{'capture_request_id':receipt['binding']['capture_request_id']})
        self.assertEqual(row['result_sha256'],sha(self.result))

    def test_complete_request_limit_and_complete_result_chunk_read(self):
        raw=self.raw+b' '*(MAX_REQUEST_BYTES-len(self.raw)); self.valid_requests.add(raw)
        self.validation_pairs.add((self.result,raw,'created'))
        receipt,_=self.submit(raw=raw);self.execute()
        self.assertEqual(self.status(receipt)['state'],'succeeded')
        excess=self.submission(raw=raw+b' ')
        self.assert_fault('capture_invalid_arguments',lambda:self.rpc('capture.submit.v1',excess))
        self.consumer.raw_result=self.result+b' '*(MAX_RESULT_BYTES-len(self.result))
        self.validation_pairs.add((self.consumer.raw_result,self.raw,'created'))
        receipt,_=self.submit();self.execute();got=bytearray()
        for offset in range(0,MAX_RESULT_BYTES,8192):
            read=self.rpc('capture.result.read.v1',dict(self.binding(receipt),offset=offset,limit=8192))
            self.assertLessEqual(len(encode({'protocol':PROTOCOL,'ok':True,'result':read}))+1,16384)
            got.extend(base64.b64decode(read['data_base64']))
        self.assertEqual(bytes(got),self.consumer.raw_result)

    def test_handler_uses_verified_kernel_app_and_rejects_duplicate_and_excess_frame(self):
        # Real Unix Handler path; verifier is an explicit synthetic substitute.
        endpoint=self.home/'handler.sock'
        self.runtime.identity_verifier=lambda sock,declared:'tisra'
        server=Server(str(endpoint),Handler);server.runtime=self.runtime
        thread=threading.Thread(target=server.serve_forever);thread.start()
        def request(raw):
            with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as sock:
                sock.connect(str(endpoint));sock.sendall(raw)
                response=bytearray()
                while not response.endswith(b'\n'):
                    data=sock.recv(4096)
                    if not data:break
                    response.extend(data)
                return json.loads(response)
        try:
            envelope={'protocol':PROTOCOL,'app':'tisra','method':'capture.capabilities.v1','params':{'library_id':self.library}}
            self.assertTrue(request(encode(envelope)+b'\n')['ok'])
            envelope['app']='other'
            self.assertEqual(request(encode(envelope)+b'\n')['error']['code'],'app_identity_unverified')
            raw=encode(envelope).replace(b'"app": "other"',b'"app":"tisra","app":"tisra"')+b'\n'
            self.assertEqual(request(raw)['error']['code'],'invalid_payload')
            self.assertEqual(request(b' '+b'x'*16384+b'\n')['error']['code'],'invalid_frame')
        finally:
            server.shutdown();thread.join(5);server.server_close()


if __name__ == '__main__': unittest.main()
