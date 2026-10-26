"""Reusable native/Mio permit mechanics; all effects injected, keys ephemeral."""
import json,subprocess,tempfile,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1];SOURCE=ROOT/'integrations/apple_review'
class ReusableAppleReviewTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp=tempfile.TemporaryDirectory(prefix='apple-gate-build-',dir='/tmp');cls.build=Path(cls.tmp.name)
        main=cls.build/'main.swift';cls.binary=cls.build/'gate'
        main.write_text('''import Foundation
let result:[String:Any]
do{result=try scenario(CommandLine.arguments[1],home:CommandLine.arguments[2])}
catch{result=["status":"fixture_failure"]}
FileHandle.standardOutput.write(try! JSONSerialization.data(withJSONObject:result,options:.sortedKeys))
''')
        sources=[SOURCE/name for name in ('Proposal.swift','PeerAuthentication.swift','ConsumptionJournal.swift','ApprovalEngine.swift','Fixture.swift')]
        subprocess.run(['/usr/bin/xcrun','swiftc','-D','APPLE_REVIEW_FIXTURE','-swift-version','6','-module-cache-path',str(SOURCE/'dist/module-cache'),str(main),*[str(p) for p in sources],'-framework','Security','-o',str(cls.binary)],check=True,capture_output=True,timeout=60)
        subprocess.run(['/usr/bin/codesign','--force','--sign','-','--identifier','local.arl.applereview.fixture',str(cls.binary)],check=True,capture_output=True,timeout=5)
    @classmethod
    def tearDownClass(cls):cls.tmp.cleanup()
    def run_case(self,name,home=None):
        if home is None:
            with tempfile.TemporaryDirectory(prefix='apple-gate-',dir='/tmp') as folder:return self.run_case(name,str(Path(folder).resolve()))
        p=subprocess.run([str(self.binary),name,home],check=True,capture_output=True,timeout=5)
        return json.loads(p.stdout)
    def test_untrusted_or_bad_payload_permit_rejected_before_data_access(self):
        for name,status in {'disabled':'capability_not_granted','forged_caller':'caller_unverified','approved_flag':'invalid_arguments','duplicate_key':'duplicate_key','bad_signature':'permit_unverified','tamper':'permit_binding_mismatch','target_mismatch':'permit_binding_mismatch','expired':'permit_expired','cancel_before':'cancelled_before_effect','invalid_date':'invalid_time','wrong_offset':'time_zone_offset_mismatch'}.items():
            with self.subTest(name=name):
                r=self.run_case(name);self.assertEqual(r['status'],status,r)
                self.assertEqual(r['save_calls'],0);self.assertEqual(r['metadata_reads'],0);self.assertEqual(r['authorization_checks'],0)
    def test_same_compiled_gate_accepts_distinct_user_calendar_and_reminder_proposals(self):
        r=self.run_case('dynamic_native');self.assertEqual(r['status'],'ok',r);self.assertEqual(r['save_calls'],2);self.assertEqual(r['native_prompts'],2)
        self.assertIn('Synthetic event',r['displays'][0]);self.assertIn('2026-10-02T10:05:00+08:00',r['displays'][0])
        self.assertIn('Another request',r['displays'][1]);self.assertIn('Synthetic default_reminders',r['displays'][1])
    def test_workflow_has_no_local_ui_dependency_and_locked_requires_explicit_qualification(self):
        r=self.run_case('locked_workflow');self.assertEqual(r['status'],'ok',r);self.assertEqual(r['save_calls'],1);self.assertEqual(r['native_prompts'],0)
        for name,status in [('locked_unqualified','needs_unlock'),('unknown_lock','lock_state_unknown')]:
            r=self.run_case(name);self.assertEqual(r['status'],status,r);self.assertEqual(r['save_calls'],0);self.assertEqual(r['metadata_reads'],0)
    def test_native_cancel_late_click_cancellation_and_revocation_before_save(self):
        for name,status in [('native_cancel','user_cancelled'),('late_native','approval_expired'),('cancel_after_review','cancelled_before_effect'),('revoked','caller_unverified'),('issuer_revoked','permit_unverified')]:
            with self.subTest(name=name):
                r=self.run_case(name);self.assertEqual(r['status'],status,r);self.assertEqual(r['save_calls'],0)
    def test_budget_replay_uncertainty_and_late_cancel(self):
        for name,status in [('budget','effect_budget_exceeded'),('replay','operation_consumed'),('uncertain','outcome_unknown'),('late_cancel','ok')]:
            r=self.run_case(name);self.assertEqual(r['status'],status,r);self.assertEqual(r['save_calls'],1)
    def test_restart_and_concurrent_processes_cannot_repeat_same_operation(self):
        with tempfile.TemporaryDirectory(prefix='apple-gate-race-',dir='/tmp') as folder:
            home=str(Path(folder).resolve());children=[subprocess.Popen([str(self.binary),'success',home],stdout=subprocess.PIPE,stderr=subprocess.PIPE) for _ in range(2)]
            results=[json.loads(p.communicate(timeout=5)[0]) for p in children]
            self.assertCountEqual([r['status'] for r in results],['ok','operation_consumed']);self.assertEqual(sum(r['save_calls'] for r in results),1)
            self.assertEqual(self.run_case('success',home)['status'],'operation_consumed')
    def test_actual_kernel_peer_signature_and_registration_revoke(self):
        r=self.run_case('kernel_peer');self.assertEqual(r['status'],'ok',r);self.assertTrue(r['verified']);self.assertTrue(r['revoked']);self.assertTrue(r['old_generation_rejected'])
