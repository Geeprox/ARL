"""Source SDK regressions: private temp store, no listener/provider execution."""
import copy
import unittest
from arl.contracts import Fault
from arl.research import REQUEST, sha
from arl.research_client import PayloadCleanupPending, ResearchClient
from tests import test_research as fixtures
from arl.contracts import AppPolicy
from arl.research import ResearchEngine, ResearchGrant, NAME, METHODS
from arl.service import Runtime
from arl.storage import Store
body, metadata, FINGERPRINT = fixtures.body, fixtures.metadata, fixtures.FINGERPRINT
from tests.test_runtime import RuntimeCase
import uuid
import threading


class Proxy:
    app = 'tisra'
    def __init__(self, client):
        self.client = client; self.calls = []; self.before = None; self.after = None
    def rpc(self, method, params=None):
        self.calls.append((method, copy.deepcopy(params)))
        if self.before: self.before(method, params)
        result = self.client.rpc(method, params)
        return self.after(method, params, result) if self.after else result


class ResearchClientTests(RuntimeCase):
    def setUp(self):
        super().setUp(); self.adapter = fixtures.Adapter()
        grant = ResearchGrant('responses_fixture', frozenset({fixtures.MODEL}), 'grant-epoch-1')
        self.engine = ResearchEngine({'tisra': grant}, {'responses_fixture': self.adapter})
        self.policy = AppPolicy(frozenset({NAME}), methods=METHODS, max_pending=4)
        self.runtime = Runtime(self.home, policies={'tisra':self.policy}, research=self.engine, identity_verifier=lambda c,a:None)
        self.runtime.store = Store(self.home/'state.sqlite'); self.engine.attach(self.runtime.store); self.runtime.ready.set()
        self.client = fixtures.DirectClient(self.runtime); self.sdk = ResearchClient(self.client)
    def tearDown(self):
        self.runtime.store.close(); super().tearDown()
    def submit(self):
        raw=body();run=str(uuid.uuid4())
        return self.sdk.submit(raw,metadata(raw,run),epoch=0,provider='responses_fixture',model_fingerprint=FINGERPRINT)

    def proxy(self):
        p = Proxy(self.client); self.sdk = ResearchClient(p); return p

    def revoked(self, count):
        rows = self.runtime.store.db.execute('SELECT state,length(data) FROM research_payloads').fetchall()
        self.assertEqual([tuple(r) for r in rows], [('revoked', 0)] * count)
        self.assertEqual(self.adapter.calls, [])

    def test_first_auth_revision_pinned_for_status_cancel_and_baseline_mutation(self):
        p = self.proxy(); receipt, args = self.submit()
        p.after = lambda m,a,r: dict(r,auth_epoch='different') if m.startswith('research.') else r
        self.assert_fault('research_receipt_mismatch', lambda:self.sdk.status(receipt,args))
        self.assert_fault('research_receipt_mismatch', lambda:self.sdk.cancel(receipt,args))
        restored=ResearchClient(p)
        self.assert_fault('research_receipt_mismatch',lambda:restored.status(receipt,args))
        altered=dict(receipt,auth_epoch='different')
        self.assert_fault('research_receipt_mismatch',lambda:self.sdk.status(altered,args))

    def test_noncanonical_and_inconsistent_receipts_rejected(self):
        receipt,args=self.submit()
        result={'payload_id':str(uuid.uuid4()),'sha256':sha(b'{}'),'byte_count':2}
        patches=[{'job_id':receipt['job_id'].upper()}, {'epoch':True}, {'auth_epoch':''},
                 {'state':'succeeded','result_ref':None}, {'result_ref':result},
                 {'state':'succeeded','result_ref':result,'cancel_requested':True},
                 {'state':'succeeded','result_ref':dict(result,byte_count=True)},
                 {'state':'succeeded','result_ref':dict(result,payload_id=result['payload_id'].upper())},
                 {'error_code':'unknown while queued'}, {'external_stop':'unknown'}]
        for patch in patches:
            with self.subTest(patch=patch):
                self.assert_fault('research_receipt_mismatch',lambda:self.sdk.check(dict(receipt,**patch),args))

    def test_cancel_after_begin_persists_known_id_before_zero_writes(self):
        p=self.proxy(); flag=[False]; saved=[]
        def persist(record): saved.append(record); flag[0]=True
        raw=body();run=str(uuid.uuid4())
        self.assert_fault('cancelled',lambda:self.sdk.submit(raw,metadata(raw,run),epoch=0,provider='responses_fixture',model_fingerprint=FINGERPRINT,cancelled=lambda:flag[0],on_payload_created=persist))
        self.revoked(1)
        self.assertEqual(len(saved),1);self.assertEqual(saved[0]['sha256'],sha(raw));self.assertEqual(saved[0]['owner'],'tisra')
        self.assertFalse(any(m=='payload.write.v1' for m,_ in p.calls))

    def test_concurrent_first_receipts_cannot_pin_two_auth_revisions(self):
        receipt,args=self.submit();fresh=ResearchClient(self.client)
        barrier=threading.Barrier(2);accepted=[];rejected=[]
        def check(epoch):
            barrier.wait()
            try:fresh.check(dict(receipt,auth_epoch=epoch),args);accepted.append(epoch)
            except Fault as error:rejected.append(error.code)
        threads=[threading.Thread(target=check,args=(epoch,)) for epoch in ('one','two')]
        for thread in threads:thread.start()
        for thread in threads:thread.join(2);self.assertFalse(thread.is_alive())
        self.assertEqual(len(accepted),1);self.assertEqual(rejected,['research_receipt_mismatch'])

    def test_cancel_during_write_does_not_retry_and_revokes(self):
        p=self.proxy(); flag=[False]
        def after(m,a,r):
            if m=='payload.write.v1': flag[0]=True;raise Fault('disconnected')
            return r
        p.after=after;raw=body();run=str(uuid.uuid4())
        self.assert_fault('cancelled',lambda:self.sdk.upload(raw,REQUEST,run,0,cancelled=lambda:flag[0]))
        self.revoked(1);self.assertEqual(sum(m=='payload.write.v1' for m,_ in p.calls),1)

    def test_second_upload_failure_revokes_both_and_does_not_submit(self):
        p=self.proxy(); begins=[0]
        def after(m,a,r):
            if m=='payload.begin.v1':
                begins[0]+=1
                if begins[0]==2:return dict(r,chunk_bytes=1)
            return r
        p.after=after
        self.assert_fault('invalid_response',lambda:self.submit())
        self.revoked(2);self.assertFalse(any(m=='research.submit.v1' for m,_ in p.calls))

    def test_observer_failure_revokes_before_any_write(self):
        p=self.proxy();raw=body();run=str(uuid.uuid4())
        def fail(_):raise RuntimeError('fixture persistence failure')
        with self.assertRaises(RuntimeError):self.sdk.upload(raw,REQUEST,run,0,on_payload_created=fail)
        self.revoked(1);self.assertFalse(any(m=='payload.write.v1' for m,_ in p.calls))

    def test_lost_submit_receipts_revoke_inputs_and_invalidate_same_run(self):
        p=self.proxy()
        def after(m,a,r):
            if m=='research.submit.v1':raise Fault('disconnected')
            return r
        p.after=after
        self.assert_fault('disconnected',lambda:self.submit())
        self.assertEqual(sum(m=='research.submit.v1' for m,_ in p.calls),2)
        row=self.runtime.store.db.execute('SELECT invalidated FROM research_runs').fetchone()
        self.assertEqual(row[0],1);self.assertIsNone(self.runtime.store.claim());self.assertEqual(self.adapter.calls,[])
        self.assertEqual(self.runtime.store.db.execute("SELECT COUNT(*) FROM research_payloads WHERE purpose!='tisra.research.response.v1' AND state='revoked'").fetchone()[0],2)

    def test_cleanup_failure_preserves_pending_ids_and_explicit_recovery(self):
        p=self.proxy(); ids=[]
        def after(m,a,r):
            if m=='payload.begin.v1':ids.append(r['payload_id'])
            if m=='payload.seal.v1' and len(ids)==2:raise Fault('disconnected')
            return r
        def before(m,a):
            if m=='payload.revoke.v1' and a['payload_id']==ids[0]:raise Fault('disconnected')
        p.after=after;p.before=before
        with self.assertRaises(PayloadCleanupPending) as caught:self.submit()
        self.assertEqual(caught.exception.payload_ids,(ids[0],))
        self.assertEqual(sum(m=='payload.revoke.v1' for m,_ in p.calls),2)
        p.before=None;p.after=None;self.sdk.cleanup_payloads(caught.exception.payload_ids)
        self.revoked(2)

    def test_lost_begin_ack_has_no_known_id_and_no_unsafe_begin_retry(self):
        p=self.proxy()
        def after(m,a,r):
            if m=='payload.begin.v1':raise Fault('disconnected')
            return r
        p.after=after
        self.assert_fault('disconnected',lambda:self.sdk.upload(body(),REQUEST,str(uuid.uuid4()),0))
        self.assertEqual(sum(m=='payload.begin.v1' for m,_ in p.calls),1)
        self.assertFalse(any(m=='payload.revoke.v1' for m,_ in p.calls))


if __name__=='__main__': unittest.main()
