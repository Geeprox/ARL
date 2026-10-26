import json
import hashlib
import copy
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]

class ResearchSDKSwiftTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp=tempfile.TemporaryDirectory(prefix='arl-research-sdk-swift-')
        cls.binary=Path(cls.temp.name)/'fixture'
        sources=['examples/ARLClient.swift','integrations/tisra/ARLResearchClient.swift','integrations/tisra/ResearchClientFixture.swift']
        p=subprocess.run(['xcrun','swiftc','-swift-version','6','-D','RESEARCH_CLIENT_FIXTURE','-module-cache-path',cls.temp.name+'/cache',*[str(ROOT/s) for s in sources],'-o',str(cls.binary)],capture_output=True,text=True,timeout=90)
        if p.returncode: raise AssertionError(p.stderr)
    @classmethod
    def tearDownClass(cls): cls.temp.cleanup()
    def call(self,name):
        p=subprocess.run([str(self.binary),name],capture_output=True,text=True,check=True,timeout=5)
        r=json.loads(p.stdout);self.assertEqual(r['provider_calls'],0);return r
    def test_success_and_durable_callback(self):
        r=self.call('success');self.assertEqual((r['status'],r['recorded'],r['submits'],r['revokes']),('ok',2,1,0))
    def test_auth_revision_rejected_on_status_cancel_and_final_read(self):
        for name in ('status_drift','cancel_drift','read_drift'):
            with self.subTest(name=name):self.assertEqual(self.call(name)['status'],'research_receipt_mismatch')
    def test_noncanonical_and_state_receipt_combinations(self):
        for name in ('uppercase_uuid','empty_auth','success_null','queued_result'):
            r=self.call(name);self.assertEqual((r['status'],r['revokes']),('research_receipt_mismatch',2))
    def test_cancelled_submit_task_uses_uncancelled_cleanup(self):
        for name in ('cancel_begin','cancel_write','cancel_seal'):
            r=self.call(name)
            self.assertEqual((r['status'],r['revokes'],r['submits'],r['revoke_task_cancelled']),('cancelled',1,0,False))
        self.assertEqual(self.call('cancel_begin')['writes'],0)
        self.assertEqual(self.call('cancel_write')['writes'],1)
    def test_second_upload_and_persistence_failure(self):
        for name,code,count in [('second_begin_bad','invalid_response',2),('persist_failure','fixture_persist_failed',1)]:
            r=self.call(name);self.assertEqual((r['status'],r['revokes'],r['submits']),(code,count,0))
        self.assertEqual(self.call('persist_failure')['writes'],0)
    def test_cleanup_pending_and_reconnect_recovery(self):
        r=self.call('cleanup_pending');self.assertEqual((r['status'],r['revokes'],r['submits']),('payload_cleanup_pending',3,0))
    def test_lost_submit_same_run_and_lost_begin_no_retry(self):
        r=self.call('lost_submit');self.assertEqual((r['status'],r['submits'],r['revokes']),('disconnected',2,2))
        r=self.call('lost_begin');self.assertEqual((r['status'],r['begins'],r['revokes']),('disconnected',1,0))

    def saved_record(self):
        path=Path(self.temp.name)/'synthetic-accepted-submission.json'
        p=subprocess.run([str(self.binary),'save_record',str(path)],capture_output=True,text=True,check=True,timeout=5)
        self.assertEqual(json.loads(p.stdout)['submits'],1)
        data=path.read_bytes()
        return path,data,hashlib.sha256(data).hexdigest()

    def restore(self,scenario,path,digest):
        # A new executable process: no surviving submission object or actor pins.
        p=subprocess.run([str(self.binary),scenario,str(path),digest],capture_output=True,text=True,check=True,timeout=5)
        r=json.loads(p.stdout)
        self.assertEqual((r['begins'],r['writes'],r['submits'],r['provider_calls']),(0,0,0,0))
        return r

    def test_restart_restores_status_cancel_and_response_without_submission_replay(self):
        path,data,digest=self.saved_record()
        record=json.loads(data)
        self.assertEqual(record['receipt']['auth_epoch'],'revision-1')
        self.assertIsNone(record['receipt']['result_ref'])
        self.assertIsNone(record['receipt']['error_code'])
        for scenario,count in [('restore_status',1),('restore_cancel',1),('restore_read',2)]:
            with self.subTest(scenario=scenario):
                r=self.restore(scenario,path,digest)
                self.assertEqual(r['status'],'ok')
                self.assertEqual(r['cancels'] if scenario=='restore_cancel' else r['statuses'],count)

    def test_restored_original_auth_epoch_rejects_rpc_and_second_restore_drift(self):
        path,_,digest=self.saved_record()
        for scenario in ['restore_status_drift','restore_cancel_drift','restore_pin_conflict','restore_wrong_owner']:
            with self.subTest(scenario=scenario):
                self.assertEqual(self.restore(scenario,path,digest)['status'],'research_receipt_mismatch')

    def test_durable_scope_tampering_rejected_before_rpc(self):
        path,data,digest=self.saved_record(); original=json.loads(data)
        for field in ['owner','run_id','job_id','epoch','auth_epoch','provider','model','model_fingerprint','request_sha256']:
            record=copy.deepcopy(original)
            record['receipt'][field]=1 if field=='epoch' else 'changed'
            path.write_text(json.dumps(record))
            with self.subTest(field=field):
                r=self.restore('restore_only',path,digest)
                self.assertEqual((r['status'],r['statuses'],r['cancels']),('research_restore_mismatch',0,0))
        record=copy.deepcopy(original);record['params']['descriptor']['payload_id']='cccccccc-cccc-4ccc-8ccc-cccccccccccc'
        path.write_text(json.dumps(record))
        self.assertEqual(self.restore('restore_only',path,digest)['status'],'research_restore_mismatch')

    def test_malformed_durable_record_rejected_even_with_matching_digest(self):
        path,data,_=self.saved_record(); original=json.loads(data)
        invalid=[b'not-json',b'[]',b'{}',b'x'*65_301,
                 data[:-1]+b',"schema_version":1}', b' '+data]
        mutations=[lambda r:r.update(schema_version=2), lambda r:r.update(extra=True),
                   lambda r:r['receipt'].pop('error_code'), lambda r:r['params'].update(extra=True),
                   lambda r:r['params'].update(epoch=-1),lambda r:r['params'].update(max_output_tokens=4097),
                   lambda r:r['params'].update(deadline_ms=600001),lambda r:r['params'].update(priority=''),
                   lambda r:r['params'].update(request_format='wrong'),
                   lambda r:r['params']['request'].update(payload_id='NOT-A-UUID'),
                   lambda r:r['params']['descriptor'].update(byte_count=32769),
                   lambda r:r['params'].update(model='changed')]
        for mutate in mutations:
            r=copy.deepcopy(original);mutate(r)
            invalid.append(json.dumps(r,sort_keys=True,separators=(',',':')).encode())
        for index,raw in enumerate(invalid):
            with self.subTest(index=index):
                path.write_bytes(raw)
                r=self.restore('restore_only',path,hashlib.sha256(raw).hexdigest())
                self.assertIn(r['status'],['research_restore_mismatch','research_receipt_mismatch'])
                self.assertEqual((r['statuses'],r['cancels']),(0,0))
        path.write_bytes(data)
        for digest in ['', 'G'*64, '0'*64]:
            self.assertEqual(self.restore('restore_only',path,digest)['status'],'research_restore_mismatch')

if __name__=='__main__':unittest.main()
