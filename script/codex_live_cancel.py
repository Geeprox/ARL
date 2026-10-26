"""One authorized real cancellation turn. No automatic replay or result publication."""
import hashlib,json,os,tempfile,threading,time,uuid
from datetime import datetime,timezone
from pathlib import Path
from arl.client import Client
from arl.codex_server import CodexTextAdapter,CodexService,NAME
from arl.compat_host import compose_codex_service
from arl.contracts import Fault
from arl.identity import RegisteredPeerVerifier,process_identity
from script.codex_preflight import preflight

OUTPUT=Path(__file__).resolve().parents[1]/'docs/evidence/codex-live-cancel-1.json'
def main(output=OUTPUT, *, expected_model=None):
 if output.exists():raise Fault('evidence_already_exists')
 proof={'checked_at_utc':datetime.now(timezone.utc).isoformat(),'test_id':str(uuid.uuid4()),
    'requested_turns':1,'source_only':True,'synthetic':True,'events':[],'installed_runtime_changes':0,
    'api_fallback':False,'model_switch':False,'account_switch':False,'new_credentials':False,
    'cancel_requested_after_start_ack':False,'inflight_cancel_terminal_verified':False,
    'quota_refund':'not_claimed','immediate_upstream_stop':'not_claimed'}
 start=time.monotonic();client=None;job=None
 def record(event):
  proof['events'].append(dict(event,elapsed_ms=int((time.monotonic()-start)*1000)))
  if event['event']=='turn_started' and event.get('source')=='response' and event.get('status')=='inProgress' and not proof['cancel_requested_after_start_ack']:
   if client is None or job is None:raise Fault('cancel_test_not_prepared')
   current=client.rpc('get',{'id':job['id']})
   if current['state']!='running':raise Fault('cancel_test_no_longer_active')
   receipt=client.rpc('cancel',{'id':job['id']})
   proof['cancel_requested_after_start_ack']=True
   proof['cancel_rpc_state']=receipt['state']
   proof['events'].append({'event':'local_cancel_requested','turn_start_status':'inProgress','job_state':current['state'],'elapsed_ms':int((time.monotonic()-start)*1000)})
 try:
  inspection=preflight(expected_model=expected_model);proof['preflight']=inspection
  if inspection.get('account_type')!='chatgpt' or not inspection.get('mcp_disabled_verified') or not inspection.get('thread_read_only_verified'):
   raise Fault(inspection.get('error_code','preflight_rejected'))
  adapter=CodexTextAdapter(enabled=True,observer=record);proof['binary_sha256']=adapter.pin
  caller='arl-control'
  identity=RegisteredPeerVerifier({caller})
  identity.register(caller,os.getpid(),process_identity(os.getpid())['executable'])
  lease=identity.capture_registration(caller,os.getpid())
  service=CodexService(adapter,caller=caller,model=inspection['model'],max_calls=1,
      authorization_current=lambda:True,peer_current=lease.is_current)
  service.preflight()
  proof.update(caller=caller,caller_identity='registered_kernel_development_process',production_signed_caller_verified=False)
  with tempfile.TemporaryDirectory(prefix='arl-codex-cancel-') as home:
   runtime=compose_codex_service(home,service=service,peer_verifier=identity,isolated=True)
   errors=[]
   def serve():
    try:runtime.run()
    except Exception as exc:errors.append(exc)
   thread=threading.Thread(target=serve);thread.start()
   try:
    client=Client(home,caller);client.connect(timeout=5)
    prompt='Return a text value listing every integer from 1 through 2000 in order, separated by spaces. This is synthetic test data. Do not use tools or access files.'
    job=client.submit(NAME,{'model':inspection['model'],'input':prompt,'max_output_bytes':32768},proof['test_id'])
    receipt=client.wait(job['id'],timeout=35)
    proof['job_state']=receipt['state'];proof['error_code']=receipt['error']
    proof['generated_text_published']=bool((receipt['result'] or {}).get('text'))
    proof['receipt_metadata_returned']=receipt['result'] is not None
    proof['caller_receipt']={'job_id':job['id'],'state':receipt['state'],'progress':receipt.get('progress'),'result':receipt['result']}
    proof['jobs_total']=sum(runtime.store.state_counts().values())
    proof['persistent_call_count']=runtime.store.db.execute('SELECT calls FROM budget WHERE owner=?',(caller,)).fetchone()[0]
    proof['interrupt_ack_received']=any(e['event']=='interrupt_ack' for e in proof['events'])
    proof['inflight_cancel_terminal_verified']=any(e['event']=='cancel_terminal' and e.get('status')=='interrupted' and e.get('matches_turn') is True for e in proof['events'])
   finally:
    runtime.shutdown();thread.join(35);proof['isolated_runtime_closed']=runtime.closed.is_set()
    if errors:raise errors[0]
 except Fault as exc:proof['error_code']=exc.code
 except Exception as exc:proof['error_code']='cancel_smoke_local_error';proof['error_type']=type(exc).__name__
 proof['elapsed_ms']=int((time.monotonic()-start)*1000)
 with output.open('x') as stream:stream.write(json.dumps(proof,sort_keys=True,indent=2)+'\n')
 print(json.dumps(proof,sort_keys=True))
if __name__=='__main__':main()
