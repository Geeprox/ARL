import json,subprocess,tempfile,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
class NativeSetupFlowTests(unittest.TestCase):
 @classmethod
 def setUpClass(cls):
  cls.tmp=tempfile.TemporaryDirectory(prefix='calendar-native-setup-test-',dir='/tmp');b=Path(cls.tmp.name);cls.binary=b/'test'
  subprocess.run(['/usr/bin/xcrun','swiftc','-parse-as-library','-swift-version','6','-module-cache-path',str(b/'cache'),str(ROOT/'tests/Fixture.swift'),str(ROOT/'source/SetupFlow.swift'),str(ROOT/'source/NativeSetupReview.swift'),'-framework','AppKit','-o',str(cls.binary)],check=True,capture_output=True,timeout=35)
 @classmethod
 def tearDownClass(cls):cls.tmp.cleanup()
 def run_case(self,s):return json.loads(subprocess.run([str(self.binary),s],check=True,capture_output=True,timeout=5).stdout)
 def refusal(self,s,code,TCC=None):
  v=self.run_case(s);self.assertEqual(v['code'],code);self.assertEqual(v['grants'],0)
  if TCC is not None:self.assertEqual(v['TCC_requests'],TCC)
  return v
 def test_unknown_can_complete_only_after_two_native_review_doubles_without_becoming_unlocked(self):
  v=self.run_case('success');self.assertEqual(v['grants'],1);self.assertEqual(v['observation'],'unknown');self.assertEqual(v['reviews'],2);self.assertEqual(v['TCC_requests'],1);self.assertEqual(v['expires_at_ms'],4600000)
 def test_known_locked_refuses_before_UI_TCC(self):
  self.assertEqual(self.refusal('locked','needs_unlock',0)['reviews'],0)
 def test_existing_consumed_refuses_before_UI_TCC(self):self.assertEqual(self.refusal('consumed','session_already_consumed',0)['reviews'],0)
 def test_cancel_or_expire_first_review_requests_no_permission(self):
  for s,c in [('cancel_disclosure','user_cancelled'),('expire_review','user_cancelled_or_expired'),('stale_review','native_interaction_expired')]:
   with self.subTest(s=s):self.refusal(s,c,0)
 def test_lock_after_first_review_requests_no_permission(self):self.refusal('lock_after_disclosure','needs_unlock',0)
 def test_permission_denial_emits_no_session(self):self.refusal('deny_permission','needs_permission',1)
 def test_existing_write_only_skips_TCC_and_still_requires_native_reviews(self):
  v=self.run_case('preauthorized');self.assertEqual(v['TCC_requests'],0);self.assertEqual(v['reviews'],2);self.assertEqual(v['grants'],1)
 def test_revocation_while_permission_request_is_active_no_session(self):self.refusal('revoke_during_permission','caller_unverified',1)
 def test_revocation_in_status_read_cannot_request_TCC(self):self.refusal('revoke_during_status','caller_unverified',0)
 def test_revocation_in_final_status_read_cannot_emit_session(self):self.refusal('revoke_during_final_status','caller_unverified',1)
 def test_task_cancellation_while_permission_request_is_active_no_session(self):self.refusal('cancel_during_permission','user_cancelled',1)
 def test_whole_deadline_while_permission_request_is_active_no_session(self):self.refusal('deadline_during_permission','native_setup_deadline',1)
 def test_target_cancel_or_changed_default_no_session(self):
  self.refusal('cancel_target','user_cancelled');self.refusal('changed_target','target_changed')
 def test_final_confirmation_revocation_no_session(self):self.refusal('revoked_after_confirmation','caller_unverified')
 def test_revocation_or_expiry_during_final_target_read_no_session(self):
  self.refusal('revoke_during_final_target','caller_unverified');self.refusal('expire_during_final_target','native_interaction_expired')
 def test_native_button_accepts_only_fresh_foreground_matching_window_input(self):
  v=self.run_case('event_guard');self.assertTrue(v.pop('fresh'));self.assertFalse(any(v.values()))
 def test_held_return_cannot_accept_next_dialog_or_unpaired_key_up(self):
  v=self.run_case('held_return');self.assertTrue(v['first_fresh_press']);self.assertTrue(v['mouse_confirmation']);self.assertFalse(v['repeat_in_next_dialog']);self.assertFalse(v['unpaired_key_up']);self.assertFalse(v['old_press_carried'])
if __name__=='__main__':unittest.main()
