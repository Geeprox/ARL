"""Exactly one authorized real Codex turn, isolated ARL/test peer and synthetic text."""
import hashlib,json,os,tempfile,threading,time,uuid
from datetime import datetime,timezone
from pathlib import Path
from arl.client import Client
from arl.codex_server import CodexTextAdapter,CodexService,NAME
from arl.compat_host import compose_codex_service
from arl.contracts import Fault
from arl.identity import RegisteredPeerVerifier,process_identity
from script.codex_preflight import preflight

OUTPUT=Path(__file__).resolve().parents[1]/'docs/evidence/codex-live-smoke.json'
def main(output=OUTPUT, *, expected_model=None, label='initial-smoke'):
 if output.exists():raise Fault('evidence_already_exists')
 test_id=str(uuid.uuid4())
 proof={'checked_at_utc':datetime.now(timezone.utc).isoformat(),'source_only':True,'synthetic':True,
  'requested_turns':1,'events':[],'installed_runtime_changes':0,'account_switch':False,'model_switch':False,
  'api_fallback':False,'new_credentials':False,'inflight_cancel_tested':False,'test_id':test_id,'label':label}
 start=time.monotonic()
 def record(event):proof['events'].append(dict(event,elapsed_ms=int((time.monotonic()-start)*1000)))
 try:
  inspection=preflight(expected_model=expected_model);proof['preflight']=inspection
  if inspection.get('account_type')!='chatgpt' or not inspection.get('mcp_disabled_verified') or not inspection.get('thread_read_only_verified'):
   raise Fault(inspection.get('error_code','preflight_rejected'))
  model=inspection['model']
  if expected_model is not None and model!=expected_model:raise Fault('provider_model_change_not_authorized')
  adapter=CodexTextAdapter(enabled=True,observer=record)
  proof['binary_sha256']=adapter.pin
  caller='arl-control'
  identity=RegisteredPeerVerifier({caller})
  identity.register(caller,os.getpid(),process_identity(os.getpid())['executable'])
  lease=identity.capture_registration(caller,os.getpid())
  service=CodexService(adapter,caller=caller,model=model,max_calls=1,max_output_bytes=128,
      authorization_current=lambda:True,peer_current=lease.is_current)
  service.preflight()
  proof.update(caller=caller,caller_identity='registered_kernel_development_process',production_signed_caller_verified=False)
  with tempfile.TemporaryDirectory(prefix='arl-codex-live-') as directory:
   runtime=compose_codex_service(directory,service=service,peer_verifier=identity,isolated=True)
   errors=[]
   def serve():
    try:runtime.run()
    except Exception as exc:errors.append(exc)
   thread=threading.Thread(target=serve);thread.start()
   try:
    client=Client(directory,caller);client.connect(timeout=5)
    prompt='Return exactly ARL_CODEX_OK as the text value. Do not call any tools or access files.'
    job=client.submit(NAME,{'model':model,'input':prompt,'max_output_bytes':128},test_id)
    result=client.wait(job['id'],timeout=35)
    proof['job_state']=result['state'];proof['error_code']=result['error']
    proof['caller_receipt']={'job_id':job['id'],'state':result['state'],'progress':result.get('progress')}
    proof['service_status']=Client(directory,'settings').rpc('codex.service.status.v1')
    proof['jobs_total']=sum(runtime.store.state_counts().values())
    proof['persistent_call_count']=runtime.store.db.execute('SELECT calls FROM budget WHERE owner=?',(caller,)).fetchone()[0]
    if result['state']=='succeeded':
     value=result['result']
     proof['response']={k:value[k] for k in ('text','model','format','simulated','request_sha256','output_sha256','token_hard_cap_supported','usage','execution_preferences')}
     proof['expected_response_matched']=value['text']=='ARL_CODEX_OK'
     if not proof['expected_response_matched']:raise Fault('unexpected_smoke_text')
   finally:
    runtime.shutdown();thread.join(35)
    proof['isolated_runtime_closed']=runtime.closed.is_set()
    if errors:raise errors[0]
 except Fault as exc:proof['error_code']=exc.code
 except Exception as exc:proof['error_code']='live_smoke_local_error';proof['error_type']=type(exc).__name__
 proof['elapsed_ms']=int((time.monotonic()-start)*1000)
 with output.open('x') as stream:stream.write(json.dumps(proof,sort_keys=True,indent=2)+'\n')
 print(json.dumps(proof,sort_keys=True))
if __name__=='__main__':main()
