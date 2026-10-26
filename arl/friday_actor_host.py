"""One foreground controlled actor; no model or device action on import."""
import json,os,selectors,threading,time
from .contracts import Fault
from .friday_profile import compose_isolated,planning_spec

def execute(candidate,manifest_sha,review_sha,*,adapter=None,on_event=None,cancel=None):
 if adapter is None:raise Fault('friday_planning_disabled')
 spec,req=planning_spec(candidate,manifest_sha,review_sha)
 cancel=cancel or threading.Event();emit=on_event or (lambda _event:None)
 runtime,supervisor=compose_isolated(candidate,manifest_sha,review_sha,adapter=adapter)
 deadline=min(time.monotonic()+30,time.monotonic()+max(0,(req['expires_at_ms']/1000-time.time())))
 errors=[];job_id=None
 def serve():
  try:runtime.run()
  except BaseException:errors.append('planning_host_failed')
 def cancel_owned():
  with runtime.store.lock:
   row=runtime.store.db.execute('SELECT id FROM jobs WHERE owner=? AND key=?',('friday',req['execution_id'])).fetchone()
  if row:runtime.store.cancel('friday',row['id']);runtime.job_signal.set()
 thread=threading.Thread(target=serve);thread.start()
 try:
  if not runtime.ready.wait(3) or errors:raise Fault('planning_host_failed')
  if cancel.is_set():raise Fault('planning_cancelled_or_expired')
  child=supervisor.launch('friday');buffer=bytearray();terminal=None
  with selectors.DefaultSelector() as selector:
   selector.register(child.stdout,selectors.EVENT_READ)
   while terminal is None:
    if cancel.is_set() or time.monotonic()>=deadline:
     cancel_owned();raise Fault('planning_cancelled_or_expired')
    if not selector.select(.05):
     if child.poll() is not None:raise Fault('planning_outcome_unknown')
     continue
    data=os.read(child.stdout.fileno(),4096)
    if not data:raise Fault('planning_outcome_unknown')
    buffer.extend(data)
    if len(buffer)>16384:raise Fault('planning_outcome_unknown')
    while b'\n' in buffer:
     line,_,tail=buffer.partition(b'\n');buffer=bytearray(tail)
     try:event=json.loads(line)
     except ValueError:raise Fault('planning_outcome_unknown') from None
     if set(event)=={'event','job'} and event['event']=='submitted':
      job=event['job']
      if job_id is not None or type(job)!=dict or job.get('tool')!='friday.rule-removal.plan.v1' or type(job.get('id'))!=str:raise Fault('planning_outcome_unknown')
      job_id=job['id'];emit(event)
     elif set(event)=={'status','result'} and event['status']=='advisory_only':
      if not job_id or event['result'].get('job_id')!=job_id or event['result'].get('action_authority') is not False:raise Fault('planning_outcome_unknown')
      terminal=event
     else:raise Fault('planning_outcome_unknown')
  # Cancellation/expiry is checked after receipt too; no late result resurrection.
  if cancel.is_set() or time.monotonic()>=deadline:raise Fault('planning_cancelled_or_expired')
  return terminal
 finally:
  if cancel.is_set() or time.monotonic()>=deadline:cancel_owned()
  supervisor.close()
  for process in supervisor.children.values():
   for pipe in (process.stdin,process.stdout,process.stderr):
    if pipe is not None:pipe.close()
  runtime.shutdown();thread.join(5)
  if thread.is_alive():raise Fault('planning_shutdown_pending')
