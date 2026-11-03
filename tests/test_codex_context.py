"""Real local sockets/stdio, synthetic provider; never accesses an account."""
import datetime,hashlib,json,sys,tempfile,time,unittest
from pathlib import Path
from arl.codex_context import context_rows,TRANSPORT_FRAME_BYTES
from arl.codex_server import CodexTextAdapter,NAME
from arl.client import Client
from arl.contracts import AppPolicy,Fault
from tests.test_runtime import RuntimeCase,running
FIXTURE=Path(__file__).parent/'fixtures/CodexContextServer.py'
class Context:
 def check_cancelled(self):pass
 def remaining(self,maximum=30):return maximum
def adapter(mode='ok'):return CodexTextAdapter(enabled=True,test_command=[sys.executable,'-I','-B',str(FIXTURE),mode])
class ContextTests(RuntimeCase):
 def test_large_multibyte_input_round_trips_without_truncation_and_records_provider_tokens(self):
  text=('中"\nabc'*80000)+' END_SENTINEL'
  result=adapter().run({'model':'synthetic','input':text,'max_output_bytes':128},Context())
  self.assertEqual(result['text'],'CONTEXT_OK');self.assertEqual(result['request_sha256'],hashlib.sha256(text.encode()).hexdigest())
  self.assertEqual(result['context_receipt']['model_context_window_tokens'],500000)
  self.assertEqual(result['context_receipt']['last']['inputTokens'],len(text)//4)
 def test_background_refresh_preserves_valid_proof_and_scope_checks(self):
  from arl.codex_server import CodexService
  import threading
  a=adapter();s=CodexService(a,caller='tester',model='synthetic',reasoning_effort='low',authorization_current=lambda:True,peer_current=lambda:True,allow_test_command=True)
  s.checked_mono=time.monotonic();entered=threading.Event();release=threading.Event();errors=[]
  def preflight(*args,**kwargs):entered.set();release.wait(3);return {}
  a.preflight_model=preflight
  def refresh():
   try:s.preflight()
   except Exception as e:errors.append(e)
  thread=threading.Thread(target=refresh);thread.start();self.assertTrue(entered.wait(2))
  args={'model':'synthetic','input':'original','max_output_bytes':128}
  try:
   s.admit('tester',s.name,args)
   s.checked_mono=None
   self.assert_fault('codex_preflight_required',lambda:s.admit('tester',s.name,args))
   s.check_running('tester',s.name,args)
   self.assert_fault('codex_scope_unavailable',lambda:s.check_running('other',s.name,args))
   a.verify=lambda:(_ for _ in ()).throw(Fault('provider_binary_changed'))
   self.assert_fault('provider_binary_changed',lambda:s.check_running('tester',s.name,args))
  finally:release.set();thread.join(4)
  self.assertFalse(thread.is_alive());self.assertEqual(errors,[])

 def test_binary_update_is_deferred_while_a_turn_is_running(self):
  binary=self.home/'provider';binary.write_bytes(b'old')
  a=CodexTextAdapter(binary=binary,enabled=True);old=a.pin
  a.verify_official_binary=lambda:None
  binary.write_bytes(b'official-update')
  self.assert_fault('provider_binary_changed',lambda:a.refresh_official_binary(allow_update=False))
  self.assertEqual(a.pin,old)
  a.refresh_official_binary(allow_update=True)
  self.assertEqual(a.pin,hashlib.sha256(binary.read_bytes()).hexdigest())

 def test_provider_context_overflow_is_typed_and_not_silently_truncated(self):
  with self.assertRaises(Fault) as error:adapter('context_exceeded').run({'model':'synthetic','input':'original whole input','max_output_bytes':128},Context())
  self.assertEqual(error.exception.code,'model_context_window_exceeded')
 def test_context_metadata_is_model_specific_and_stale_unknown_remain_unknown(self):
  path=self.home/'models.json';now=datetime.datetime.now(datetime.timezone.utc)
  value={'fetched_at':now.isoformat(),'models':[{'slug':'a','context_window':500000,'max_context_window':872000,'effective_context_window_percent':95},{'slug':'b','context_window':272000,'effective_context_window_percent':95}]}
  path.write_text(json.dumps(value));rows=context_rows([{'model':'a'},{'model':'b'},{'model':'unknown'}],path)
  self.assertEqual(rows['a']['effective_context_window_tokens'],475000);self.assertEqual(rows['b']['effective_context_window_tokens'],258400);self.assertNotIn('unknown',rows)
  value['fetched_at']=(now-datetime.timedelta(days=2)).isoformat();path.write_text(json.dumps(value));self.assertEqual(context_rows([{'model':'a'}],path),{})
 def test_large_frame_requires_explicit_model_transport_and_default_runtime_stays_bounded(self):
  policies={'tisra':AppPolicy(frozenset({NAME}),frozenset(),0,1,2)}
  args={'model':'synthetic','input':'original long input '*10000,'max_output_bytes':128}
  with running(self.home,policies=policies,extra_tools=[adapter().tool()],identity_verifier=lambda c,a:'tisra' if a=='tisra' else None) as (runtime,small):
   self.assert_fault('invalid_frame',lambda:small.submit(NAME,args,'large'))
   large=Client(self.home,'tisra',max_frame_bytes=TRANSPORT_FRAME_BYTES)
   with self.assertRaises(Fault) as rejected:large.submit(NAME,args,'large')
   self.assertIn(rejected.exception.code,{'invalid_frame','disconnected'})
   self.assertEqual(runtime.store.db.execute('SELECT count(*) FROM jobs').fetchone()[0],0)
   runtime.max_request_frame_bytes=TRANSPORT_FRAME_BYTES
   job=large.submit(NAME,args,'large');result=large.wait(job['id'])
   self.assertEqual(result['state'],'succeeded',result);self.assertEqual(result['result']['request_sha256'],hashlib.sha256(args['input'].encode()).hexdigest())
if __name__=='__main__':unittest.main()
