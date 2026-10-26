"""Copied native Python actor + real isolated ARL queue; synthetic provider only."""
import asyncio,copy,hashlib,importlib.util,json,queue,subprocess,tempfile,threading,time,unittest,uuid,zipfile
from pathlib import Path
from types import SimpleNamespace
from arl.contracts import Fault
from arl.friday_binding import FridayReviewBinding,digest
from arl.friday_actor_client import ReviewedActorFactory
from arl.friday_actor_host import execute
from arl.friday_planning_client import plan_removal
from arl.friday_profile import planning_spec,MODEL
from integrations.friday.prepare_planning_candidate import stage_controlled
from tests.test_friday_planning import request,provider
from unittest.mock import patch
ROOT=Path(__file__).resolve().parents[1]
def owner_review(req):
 boot=str(uuid.uuid4())
 from arl.friday_planning_client import ReviewedRemoval
 return dict(id=req['execution_id'],boot_id=boot,context={'backend':'simulator','fingerprint':req['context_fingerprint']},
  approval_digest=digest([boot,'simulator',ReviewedRemoval(req,MODEL).digest,MODEL]),request=req,model=MODEL,
  provider='codex_app_server',model_inference_attempted=False,real_write_attempted=False)
class ThreadSession:
 def __init__(self,runner):
  self.runner=runner;self.events=queue.Queue();self.cancelled=threading.Event();self.cancels=0
  def run():
   try:self.events.put(execute(*runner.args,adapter=runner.adapter,on_event=self.events.put,cancel=self.cancelled))
   except Exception as e:self.events.put({'status':'rejected','code':getattr(e,'code','planning_outcome_unknown')})
  self.thread=threading.Thread(target=run);self.thread.start()
 def next(self,timeout):
  try:return self.events.get(timeout=timeout)
  except queue.Empty:return None
 def cancel(self):self.cancels+=1;self.cancelled.set()
 def finished(self):self.thread.join(5)
class ThreadRunner:
 def __init__(self,args,adapter):self.args=args;self.adapter=adapter;self.started=0;self.sessions=[]
 def start(self):
  self.started+=1;session=ThreadSession(self);self.sessions.append(session);return session
 def close(self):
  for s in self.sessions:
   if s.thread.is_alive():s.cancel()
   s.thread.join(8)
   if s.thread.is_alive():raise AssertionError('isolated host did not stop')
class FridayActorTests(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory(prefix='friday-closed-',dir='/tmp');self.candidate=Path(self.tmp.name).resolve()/'actor'
  self.manifest=stage_controlled(self.candidate);self.mh=hashlib.sha256((self.candidate/'source-manifest.json').read_bytes()).hexdigest()
  self.req=request();self.review=owner_review(self.req);self.binding=FridayReviewBinding.from_review(self.review)
  file=self.candidate/'reviewed-request.json';file.write_text(self.binding.raw);file.chmod(0o600);self.rh=hashlib.sha256(file.read_bytes()).hexdigest();self.runners=[]
 def tearDown(self):
  for runner in self.runners:runner.close()
  self.tmp.cleanup()
 def factory(self,p=None):
  runner=ThreadRunner((self.candidate,self.mh,self.rh),p or provider(self.req));self.runners.append(runner)
  return ReviewedActorFactory(self.candidate,self.mh,self.rh,runner=runner),runner
 def runtime(self,factory):
  spec=importlib.util.spec_from_file_location('friday_product_sdk',self.candidate/'product/homeplane/arl.py');module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
  parent=module.ARLRuntime(lambda:self.candidate/'public-status-home');self.parent_runtime=parent
  return factory.bind_runtime(parent)
 def call(self,factory):return asyncio.run(plan_removal(self.runtime(factory),self.binding.action,deadline=time.monotonic()+20,current_context=lambda:self.req['context_fingerprint']))
 def test_exact_owner_review_binding_not_a_grant_and_mutations_rejected(self):
  for field,value in [('id',str(uuid.uuid4())),('boot_id',str(uuid.uuid4())),('approval_digest','0'*64),('model','other')]:
   changed=copy.deepcopy(self.review);changed[field]=value;self.assertFalse(self.binding.matches(changed))
  changed=copy.deepcopy(self.review);changed['request']['text']='different';self.assertFalse(self.binding.matches(changed))
  changed=copy.deepcopy(self.review);changed['context']['backend']='home_core';self.assertFalse(self.binding.matches(changed))
  self.assertTrue(self.binding.matches(copy.deepcopy(self.review)));self.review['request']['text']='mutable later';self.assertNotEqual(self.binding.action.request['text'],self.review['request']['text'])
  with self.assertRaises(Fault):FridayReviewBinding('{"model":1,"model":2}')
  value=self.binding.value;value['owner_review']['review_id']=str(uuid.uuid4())
  with self.assertRaisesRegex(Fault,'friday_review_identity_mismatch'):FridayReviewBinding(json.dumps(value))
 def test_default_disabled_has_no_state_actor_provider_or_model(self):
  f=ReviewedActorFactory(self.candidate,self.mh,self.rh);self.assertFalse(f.authorizes(self.review))
  with self.assertRaisesRegex(Fault,'friday_planning_disabled'):f.client_factory(self.candidate/'state').connect()
  self.assertFalse((self.candidate/'state').exists())
  out=subprocess.run([str(self.candidate/self.manifest['python_executable']),'-I','-S','-B',str(self.candidate/'planning_host.py')],capture_output=True,timeout=5)
  self.assertEqual(json.loads(out.stdout)['status'],'disabled');self.assertFalse((self.candidate/'state').exists())
 def test_actual_closed_runtime_validate_only_repeat_clean_and_drift_rejection(self):
  # Complete immutable package can move to the approved target without edits,
  # regenerated identity or a rewritten absolute interpreter path.
  moved=self.candidate.parent/'relocated';self.candidate.rename(moved);self.candidate=moved
  self.assertEqual(hashlib.sha256((moved/'source-manifest.json').read_bytes()).hexdigest(),self.mh)
  cwd=Path(self.tmp.name)/'shadow';cwd.mkdir();(cwd/'arl.py').write_text('raise RuntimeError("shadow")')
  argv=[str(self.candidate/self.manifest['python_executable']),'-I','-S','-B',str(self.candidate/'planning_host.py'),'--validate-only','--manifest-sha256',self.mh,'--approved-review-sha256',self.rh]
  for _ in range(2):
   p=subprocess.run(argv,cwd=cwd,capture_output=True,timeout=8);self.assertEqual(p.returncode,0,p.stderr);self.assertEqual(json.loads(p.stdout)['calls_started'],0)
  self.assertFalse(list(self.candidate.rglob('*.pyc')));self.assertFalse((self.candidate/'state').exists())
  file=self.candidate/'runtime/lib/python3.12/abc.py';file.write_bytes(file.read_bytes()+b'\n# isolated drift\n')
  with self.assertRaisesRegex(Fault,'launch_source_changed'):planning_spec(self.candidate,self.mh,self.rh)
 def test_product_sdk_relay_actual_registered_actor_receipt_and_one_attempt(self):
  f,runner=self.factory();self.assertTrue(f.authorizes(self.review));result=self.call(f)
  self.assertEqual(result['owner'],'friday');self.assertFalse(result['action_authority']);self.assertEqual(result['execution_id'],self.req['execution_id']);self.assertEqual(runner.adapter.run.call_count,1)
  self.assertEqual(runner.sessions[0].cancels,0)
  self.assertEqual(self.parent_runtime.home(),self.candidate/'public-status-home')
  with self.assertRaises(Exception):self.call(f)
  self.assertEqual(runner.started,1);self.assertEqual(runner.adapter.run.call_count,1)
  from arl.client import Client
  with self.assertRaises(Fault):Client(self.candidate/'state','friday').rpc('capabilities')
 def test_owner_can_load_sealed_sdk_without_replacing_live_arl(self):
  import sys
  from integrations.friday.load_sdk import load_client_module
  old=sys.modules['arl'];module=load_client_module(self.candidate,self.mh)
  runner=ThreadRunner((self.candidate,self.mh,self.rh),provider(self.req));self.runners.append(runner)
  f=module.ReviewedActorFactory(self.candidate,self.mh,self.rh,runner=runner)
  self.assertTrue(f.authorizes(self.review));result=self.call(f)
  self.assertEqual(result['owner'],'friday');self.assertIs(sys.modules['arl'],old);self.assertEqual(runner.started,1)
 def test_arbitrary_request_and_owner_key_rejected_before_process(self):
  f,runner=self.factory();c=f.client_factory(self.candidate/'state');c.connect()
  params={'tool':'runtime.ping','args':{},'key':'other'}
  with self.assertRaisesRegex(Fault,'planning_review_not_authorized'):c.rpc('submit',params)
  self.assertEqual(runner.started,0);self.assertFalse((self.candidate/'state').exists())
  runner.args=(self.candidate,self.mh,'0'*64)
  with self.assertRaisesRegex(Fault,'planning_profile_changed'):ReviewedActorFactory(self.candidate,self.mh,self.rh,runner=runner)
 def test_lost_ack_is_durable_no_replay_and_owned_cancel(self):
  f,runner=self.factory();original=runner.start
  def start():
   session=original();original_next=session.next
   def lost(timeout):original_next(timeout);return None
   session.next=lost;return session
  runner.start=start
  with self.assertRaises(Exception):self.call(f)
  self.assertTrue((self.candidate/'state/relay_admission.json').exists());self.assertGreaterEqual(runner.sessions[0].cancels,1)
  with self.assertRaises(Exception):self.call(f)
  self.assertEqual(runner.started,1)
 def test_inflight_cancel_and_review_drift_still_cancel_owned_session(self):
  p=provider(self.req);entered=threading.Event()
  def wait(args,context):
   entered.set()
   while True:context.check_cancelled();time.sleep(.01)
  p.run.side_effect=wait;f,runner=self.factory(p)
  async def run():
   task=asyncio.create_task(plan_removal(self.runtime(f),self.binding.action,deadline=time.monotonic()+20,current_context=lambda:self.req['context_fingerprint']))
   for _ in range(200):
    if entered.is_set():break
    await asyncio.sleep(.02)
   self.assertTrue(entered.is_set());self.assertTrue(self.parent_runtime._busy.locked());task.cancel()
   with self.assertRaises(asyncio.CancelledError):await task
   for _ in range(200):
    if runner.sessions[0].cancelled.is_set():break
    await asyncio.sleep(.02)
   self.assertTrue(runner.sessions[0].cancelled.is_set())
  asyncio.run(run());runner.close();self.assertEqual(p.run.call_count,1)
  # Local cancel remains usable after immutable review drift/expiry.
  c=f.client_factory(self.candidate/'state');c.session=runner.sessions[0];c.job={'id':'known-local-job'}
  (self.candidate/'reviewed-request.json').write_text('changed')
  self.assertEqual(c.rpc('cancel',{'id':'known-local-job'})['id'],'known-local-job')
 def test_changed_receipt_no_candidate_or_extra_attempt(self):
  p=provider(self.req);old=p.run.side_effect;p.run.side_effect=lambda a,c:dict(old(a,c),model='wrong')
  f,runner=self.factory(p)
  with self.assertRaises(Exception):self.call(f)
  with self.assertRaises(Exception):self.call(f)
  self.assertEqual(runner.started,1);self.assertEqual(p.run.call_count,1)

 def injected_zip(self):
  canary=Path(self.tmp.name)/'UNMANIFESTED_IMPORT_EXECUTED'
  original=self.candidate/'runtime/lib/python3.12/json/__init__.py'
  code='open('+repr(str(canary))+',"w").write("synthetic import canary")\n__path__=['+repr(str(original.parent))+']\n__package__="json"\nexec(compile(open('+repr(str(original))+').read(),'+repr(str(original))+',"exec"),globals())\n'
  zip_path=self.candidate/'runtime/lib/python312.zip'
  with zipfile.ZipFile(zip_path,'w') as archive:archive.writestr('json.py',code)
  zip_path.chmod(0o600)
  return zip_path,canary

 def test_prepare_then_zip_mutation_rejected_before_spawn_enrollment_or_rpc(self):
  from arl.supervisor import ControlledSupervisor
  from arl.identity import RegisteredPeerVerifier
  spec,_=planning_spec(self.candidate,self.mh,self.rh)
  _,canary=self.injected_zip()
  with self.assertRaisesRegex(Fault,'planning_profile_changed'):planning_spec(self.candidate,self.mh,self.rh)
  with self.assertRaisesRegex(Fault,'launch_closure_changed'):spec.validate()
  verifier=RegisteredPeerVerifier({'friday'});supervisor=ControlledSupervisor([spec],verifier)
  with patch('arl.supervisor.subprocess.Popen') as spawn:
   with self.assertRaisesRegex(Fault,'launch_closure_changed'):supervisor.launch('friday')
   spawn.assert_not_called()
  self.assertFalse(canary.exists());self.assertFalse(verifier.registry)
  self.assertFalse(supervisor.children);self.assertFalse((self.candidate/'state').exists())

 def test_added_zip_never_imported_in_actor_or_disabled_host(self):
  _,canary=self.injected_zip();exe=str(self.candidate/self.manifest['python_executable'])
  actor=subprocess.run([exe,'-I','-S','-B',str(self.candidate/'planning_consumer.py')],input='stop\n',capture_output=True,text=True,timeout=5)
  self.assertEqual(actor.stdout,'prepared\n');self.assertNotEqual(actor.returncode,0)
  host=subprocess.run([exe,'-I','-S','-B',str(self.candidate/'planning_host.py')],capture_output=True,text=True,timeout=5)
  self.assertEqual(json.loads(host.stdout)['status'],'disabled')
  self.assertFalse(canary.exists());self.assertFalse((self.candidate/'state').exists())

 def test_mutation_after_prepared_rejected_before_register_go(self):
  from arl.supervisor import ControlledSupervisor
  from arl.identity import RegisteredPeerVerifier
  spec,_=planning_spec(self.candidate,self.mh,self.rh)
  verifier=RegisteredPeerVerifier({'friday'});supervisor=ControlledSupervisor([spec],verifier)
  original=subprocess.Popen;canary=Path(self.tmp.name)/'UNMANIFESTED_IMPORT_EXECUTED'
  def mutate_after_spawn(*args,**kwargs):
   process=original(*args,**kwargs);self.injected_zip();return process
  with patch('arl.supervisor.subprocess.Popen',side_effect=mutate_after_spawn),patch.object(verifier,'register',wraps=verifier.register) as enroll:
   with self.assertRaisesRegex(Fault,'launch_closure_changed'):supervisor.launch('friday')
   enroll.assert_not_called()
  self.assertFalse(canary.exists());self.assertFalse(verifier.registry);self.assertFalse(supervisor.children)

 def test_closure_checks_dirs_links_modes_and_only_top_level_state(self):
  spec,_=planning_spec(self.candidate,self.mh,self.rh)
  empty=self.candidate/'runtime/lib/unmanifested';empty.mkdir()
  with self.assertRaisesRegex(Fault,'launch_closure_changed'):spec.validate()
  empty.rmdir()
  link=self.candidate/'runtime/lib/alias';link.symlink_to(self.candidate/'runtime/lib/python3.12')
  with self.assertRaisesRegex(Fault,'unsafe_launch_closure'):spec.validate()
  link.unlink()
  folder=self.candidate/'runtime/lib/python3.12';mode=folder.stat().st_mode&0o777;folder.chmod(0o777)
  with self.assertRaisesRegex(Fault,'unsafe_launch_closure'):spec.validate()
  folder.chmod(mode)
  state=self.candidate/'state';state.mkdir(mode=0o700);marker=state/'owned_marker';marker.write_text('synthetic state');marker.chmod(0o600);spec.validate()
  inner=self.candidate/'runtime/lib/python3.12/state';inner.mkdir();(inner/'unmanifested.py').write_text('pass')
  with self.assertRaisesRegex(Fault,'launch_closure_changed'):spec.validate()
  with self.assertRaisesRegex(Fault,'planning_profile_changed'):planning_spec(self.candidate,self.mh,self.rh)

 def test_enrolled_actor_closure_drift_revokes_peer_and_metadata(self):
  from arl.friday_profile import compose_isolated
  p=provider(self.req);entered=threading.Event();stop=threading.Event()
  old=p.run.side_effect
  def wait(args,context):
   entered.set()
   while not stop.is_set():context.check_cancelled();time.sleep(.01)
   return old(args,context)
  p.run.side_effect=wait
  runtime,supervisor=compose_isolated(self.candidate,self.mh,self.rh,adapter=p)
  thread=threading.Thread(target=runtime.run);thread.start()
  try:
   self.assertTrue(runtime.ready.wait(3));child=supervisor.launch('friday');self.assertTrue(entered.wait(5))
   self.assertTrue(supervisor.verifier.is_registered('friday',child.pid))
   zip_path,canary=self.injected_zip()
   self.assertIsNone(supervisor.peer_verifier(None,'friday'));self.assertFalse(supervisor.verifier.is_registered('friday',child.pid))
   zip_path.unlink();supervisor.specs['friday'].validate()
   # Restore only the still-owned clean child for the independent metadata
   # guard check. It imported no injected module; no new call is submitted.
   supervisor.verifier.register('friday',child.pid,supervisor.specs['friday'].executable)
   self.injected_zip()
   self.assertFalse(supervisor.metadata_active('friday',supervisor.specs['friday'],child))
   self.assertFalse(supervisor.verifier.is_registered('friday',child.pid));self.assertFalse(canary.exists())
   self.assertEqual(p.run.call_count,1) # one synthetic provider double only
  finally:
   stop.set();supervisor.close()
   for child in supervisor.children.values():
    for pipe in (child.stdin,child.stdout,child.stderr):
     if pipe is not None:pipe.close()
   runtime.shutdown();thread.join(5);self.assertFalse(thread.is_alive())
