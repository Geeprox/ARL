import hashlib,json,time
from pathlib import Path
from unittest.mock import Mock
from arl.calendar_review import CalendarPackage,ReviewGate,run_review,APP,private_json
from arl.calendar_write import NAME
from arl.contracts import Fault
from tests.test_runtime import RuntimeCase
from tests.test_calendar_write import ARGS
ROOT=Path(__file__).resolve().parents[1]/'integrations/apple_calendar'
class CalendarReviewTests(RuntimeCase):
 def package(self):return CalendarPackage(ROOT/'dist/ARLCalendarBridge.app',json.loads((ROOT/'calendar-package.json').read_text()))
 def test_review_binding_expiry_owner_action_no_caller_approval_flag(self):
  now=[1000];g=ReviewGate(ARGS,5000,clock=lambda:now[0]);g.admit(APP,NAME,ARGS)
  for owner,name,args in [('settings',NAME,ARGS),(APP,'shell',ARGS),(APP,NAME,dict(ARGS,title='changed')),(APP,NAME,dict(ARGS,approved=True))]:
   self.assert_fault('review_not_authorized',lambda:g.admit(owner,name,args))
  now[0]=5000;self.assert_fault('review_expired',lambda:g.admit(APP,NAME,ARGS))
 def test_review_file_owner_private_no_symlink_bounded(self):
  p=self.home/'review';p.write_text('{}');p.chmod(0o600);self.assertEqual(private_json(p),{})
  p.chmod(0o644);self.assert_fault('unsafe_review_file',lambda:private_json(p));p.chmod(0o600)
  p.write_text('x'*17000);self.assert_fault('invalid_review_file',lambda:private_json(p))
 def test_actual_signed_native_client_to_real_source_runtime_double_effect(self):
  package=self.package();g=ReviewGate(ARGS,int(time.time()*1000)+120000)
  save=Mock(return_value={'schema_version':1,'operation_id':ARGS['operation_id'],'persistence':'saved_local','cloud_sync':'not_checked'})
  receipt=run_review(package,g,home=self.home,transport=save)
  self.assertEqual(receipt['state'],'succeeded');self.assertEqual(save.call_count,1)
  again=run_review(package,g,home=self.home,transport=save);self.assertEqual(receipt['id'],again['id']);self.assertEqual(save.call_count,1)
 def test_uncertain_real_signed_client_write_no_restart_replay(self):
  package=self.package();g=ReviewGate(ARGS,int(time.time()*1000)+120000);save=Mock(side_effect=Fault('outcome_unknown'))
  receipt=run_review(package,g,home=self.home,transport=save);self.assertEqual(receipt['state'],'needs_review')
  again=run_review(package,g,home=self.home,transport=save);self.assertEqual(again['id'],receipt['id']);self.assertEqual(save.call_count,1)
 def test_unbrokered_host_rejected_before_permission_or_job(self):
  self.assert_fault('native_broker_required',lambda:run_review(self.package(),ReviewGate(ARGS,int(time.time()*1000)+120000),home=self.home))
  self.assertFalse((self.home/'state.sqlite').exists())

 def test_same_signed_binary_without_host_registration_is_rejected(self):
  import subprocess,threading
  from arl.contracts import AppPolicy,encode
  from arl.identity import RegisteredPeerVerifier
  from arl.supervisor import SignedPeerVerifier
  from arl.service import Runtime
  package=self.package();registered=RegisteredPeerVerifier({APP});signed=SignedPeerVerifier(package.verifier,{APP:package.manifest['requirement']})
  def verify(c,a):return a if registered(c,a)==a and signed(c,a)==a else None
  r=Runtime(self.home,policies={APP:AppPolicy(frozenset({NAME}))},identity_verifier=verify,execute_jobs=False)
  thread=threading.Thread(target=r.run);thread.start()
  try:
   end=time.monotonic()+3
   while not r.ready.is_set() and time.monotonic()<end:time.sleep(.01)
   p=subprocess.Popen([str(package.executable),'--isolated-review-client'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL)
   self.assertEqual(p.stdout.readline(),b'prepared\n')
   out,_=p.communicate(encode({'home':str(self.home),'args':ARGS}),timeout=5)
   self.assertEqual(json.loads(out)['code'],'app_identity_unverified');self.assertEqual(sum(r.store.state_counts().values()),0)
  finally:r.shutdown();thread.join(5)
