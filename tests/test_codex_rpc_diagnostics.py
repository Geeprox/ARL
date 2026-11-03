import json,sys,tempfile,unittest
from pathlib import Path
from arl.codex_server import Session,CodexTextAdapter
from arl.codex_diagnostics import rpc_error
from arl.contracts import Fault,Cancelled
FIXTURE=Path(__file__).parent/'fixtures/CodexRPCServer.py'
class Context:
 def __init__(self):self.calls=0;self.cancelled=False
 def check_cancelled(self):
  self.calls+=1
  if self.cancelled:raise Cancelled()
 def remaining(self,maximum=30):return maximum
class RPCDiagnosticsTests(unittest.TestCase):
 def session(self,mode,context=None,observer=None):
  temp=tempfile.TemporaryDirectory();self.addCleanup(temp.cleanup)
  session=Session(Path('/unused'),temp.name,test_command=[sys.executable,'-I','-B',str(FIXTURE),mode],context=context,observer=observer)
  self.addCleanup(session.close);session.initialize();return session
 def test_transient_explicit_read_rejection_recovers_in_same_session(self):
  events=[];s=self.session('recover',observer=lambda event,**fields:events.append({'event':event,**fields}))
  result=s.response(s.send('account/read',{'refreshToken':False}))
  self.assertEqual(result['requests'],2);self.assertEqual(sum(e['event']=='rpc_read_retry' for e in events),1)
  self.assertNotIn('secret',json.dumps(events));self.assertNotIn('sk-synthetic',json.dumps(events))
 def test_read_retry_is_bounded_and_carries_only_finite_diagnostic(self):
  events=[];s=self.session('exhausted',observer=lambda event,**fields:events.append({'event':event,**fields}))
  with self.assertRaises(Fault) as error:s.response(s.send('account/read',{'refreshToken':False}))
  self.assertEqual(sum(e['event']=='rpc_read_retry' for e in events),2)
  self.assertEqual(error.exception.provider_error,{'method':'account/read','jsonrpc_code':-32603,'category':'temporary_unavailable','safe_read_retry':True})
 def test_authentication_errors_do_not_retry(self):
  events=[];s=self.session('auth',observer=lambda event,**fields:events.append(event))
  with self.assertRaises(Fault) as error:s.response(s.send('account/read',{'refreshToken':False}))
  self.assertEqual(error.exception.provider_error['category'],'authentication_required');self.assertNotIn('rpc_read_retry',events)
 def test_thread_creation_is_not_retried_even_after_explicit_overload(self):
  events=[];s=self.session('thread_rejected',observer=lambda event,**fields:events.append(event))
  with self.assertRaises(Fault):s.response(s.send('thread/start',{'model':'synthetic'}))
  self.assertNotIn('rpc_read_retry',events)
 def test_turn_creation_is_never_retried(self):
  events=[];s=self.session('recover',observer=lambda event,**fields:events.append(event))
  with self.assertRaises(Fault):s.response(s.send('turn/start',{'threadId':'synthetic','input':[]}))
  self.assertNotIn('rpc_read_retry',events)
 def test_buffered_frames_share_one_full_integrity_check_per_read_batch(self):
  context=Context();events=[];s=self.session('recover',context=context,observer=lambda event,**fields:events.append(event));context.calls=0;events.clear()
  result=s.response(s.send('burst',{}));self.assertEqual(result['requests'],1)
  self.assertLess(context.calls,20);self.assertLess(events.count('pipe_read'),20)
 def test_cancellation_is_checked_before_next_pipe_read(self):
  context=Context();s=self.session('recover',context=context);context.cancelled=True
  with self.assertRaises(Cancelled):s.response(s.send('account/read',{'refreshToken':False}))
 def test_buffered_terminal_never_publishes_after_revocation(self):
  context=Context()
  def native(event,**fields):
   if event=='native_terminal':context.cancelled=True
  context.native_observer=native
  adapter=CodexTextAdapter(enabled=True,test_command=[sys.executable,'-I','-B',str(FIXTURE),'cancel_on_output'])
  with self.assertRaises(Cancelled):adapter.run({'model':'synthetic','input':'public synthetic','max_output_bytes':128},context)
 def test_unknown_error_text_is_not_logged_or_treated_as_retryable(self):
  value=rpc_error('untrusted/method',{'code':-99999,'message':'secret sk-value private content'})
  self.assertEqual(value['method'],'unknown');self.assertFalse(value['safe_read_retry']);self.assertNotIn('secret',json.dumps(value))
if __name__=='__main__':unittest.main()
