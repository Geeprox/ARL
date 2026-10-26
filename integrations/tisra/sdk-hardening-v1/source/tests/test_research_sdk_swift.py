import json
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

if __name__=='__main__':unittest.main()
