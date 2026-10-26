"""Friday's existing SDK client_factory over one pinned foreground actor.

The Console is not enrolled. Default runner=None starts nothing. No HTTP/model
enable flag, arbitrary command/path/provider or direct household interface.
"""
import hashlib,json,os,selectors,signal,stat,subprocess,time
from pathlib import Path
from types import SimpleNamespace
from .contracts import Fault
from .friday_binding import FridayReviewBinding
from .friday_planning import NAME,FridayRemovalPlanner
from .friday_profile import planning_spec

class ProcessSession:
 def __init__(self,candidate,manifest_sha,review_sha):
  spec,_=planning_spec(candidate,manifest_sha,review_sha)
  self.process=subprocess.Popen([str(spec.executable),'-I','-S','-B',str(Path(candidate)/'planning_host.py'),
   '--manifest-sha256',manifest_sha,'--approved-review-sha256',review_sha],cwd=candidate,
   env={'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','HOME':str(Path.home())},
   stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,start_new_session=True)
  os.set_blocking(self.process.stdout.fileno(),False);self.buffer=bytearray();self.events=0;self.interrupted=False
 def next(self,timeout):
  end=time.monotonic()+timeout
  with selectors.DefaultSelector() as select:
   select.register(self.process.stdout,selectors.EVENT_READ)
   while True:
    if b'\n' in self.buffer:
     line,_,tail=self.buffer.partition(b'\n');self.buffer=bytearray(tail);self.events+=1
     if len(line)>16384 or self.events>3:raise Fault('planning_outcome_unknown')
     try:return json.loads(line)
     except ValueError:raise Fault('planning_outcome_unknown') from None
    if time.monotonic()>=end:return None
    if not select.select(max(0,end-time.monotonic())):return None
    chunk=os.read(self.process.stdout.fileno(),4096)
    if not chunk:raise Fault('planning_outcome_unknown')
    self.buffer.extend(chunk)
    if len(self.buffer)>16384:raise Fault('planning_outcome_unknown')
 def cancel(self):
  if self.process.poll() is None and not self.interrupted:
   self.interrupted=True;self.process.send_signal(signal.SIGINT)
 def finished(self):
  try:self.process.wait(timeout=2)
  except subprocess.TimeoutExpired:raise Fault('planning_shutdown_pending') from None
  finally:self.process.stdout.close()
  if self.process.returncode:raise Fault('planning_outcome_unknown')

class ProcessRunner:
 """Only reviewed internal composition may supply this; not an RPC parameter."""
 def __init__(self,candidate,manifest_sha,review_sha):self.args=(Path(candidate).resolve(strict=True),manifest_sha,review_sha)
 def start(self):return ProcessSession(*self.args)

class ReviewedActorFactory:
 def __init__(self,candidate,manifest_sha,review_sha,*,runner=None):
  self.candidate=Path(candidate).resolve(strict=True);self.manifest_sha=manifest_sha;self.review_sha=review_sha
  self.runner=runner;self.binding=FridayReviewBinding((self.candidate/'reviewed-request.json').read_text())
  if runner is not None and hasattr(runner,'args') and runner.args!=(self.candidate,manifest_sha,review_sha):raise Fault('planning_profile_changed')
  self.verify()
 def verify(self):planning_spec(self.candidate,self.manifest_sha,self.review_sha)
 def authorizes(self,review):
  if self.runner is None or not self.binding.matches(review):return False
  try:self.verify();return True
  except (Fault,OSError,ValueError):return False
 def client_factory(self,home,start=False):
  if start or Path(home)!=self.candidate/'state':raise Fault('planning_profile_changed')
  return ActorRelayClient(self)
 def bind_runtime(self,owner_runtime):
  # Keep Friday's existing single-flight gate and public status home intact.
  if not callable(getattr(owner_runtime,'_bounded',None)):raise Fault('friday_runtime_required')
  return SimpleNamespace(home=lambda:self.candidate/'state',client_factory=self.client_factory,_bounded=owner_runtime._bounded)
 def claim(self):
  home=self.candidate/'state';home.mkdir(mode=0o700,exist_ok=True)
  st=home.lstat()
  if not stat.S_ISDIR(st.st_mode) or st.st_uid!=os.geteuid() or st.st_mode&0o077:raise Fault('unsafe_planning_profile')
  try:fd=os.open(str(home/'relay_admission.json'),os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
  except FileExistsError:raise Fault('planning_previous_attempt_not_replayed') from None
  try:
   raw=json.dumps({'review_sha256':self.review_sha,'execution_id':self.binding.action.execution_id}).encode()
   if os.write(fd,raw)!=len(raw):raise Fault('planning_admission_uncertain')
   os.fsync(fd)
  finally:os.close(fd)
  fd=os.open(home,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
  try:os.fsync(fd)
  finally:os.close(fd)

class ActorRelayClient:
 def __init__(self,factory):self.factory=factory;self.session=None;self.job=None;self.complete=False
 def connect(self,timeout=2):
  self.factory.verify()
  if self.factory.runner is None:raise Fault('friday_planning_disabled')
 def rpc(self,method,params=None):
  # Expired/drifted review must not prevent cancellation of our already-owned
  # process. No source reload, new task or arbitrary PID is authorized here.
  if method=='cancel':
   if not self.job or params!={'id':self.job['id']}:raise Fault('job_not_found')
   if not self.complete:self.session.cancel()
   return self.job
  self.factory.verify();binding=self.factory.binding;action=binding.action
  if method=='capabilities':
   descriptor=FridayRemovalPlanner(object()).tool().descriptor()
   return {'protocol':'arl/1','version':1,'tools':[descriptor]}
  if method=='submit':
   if params!={'tool':NAME,'args':action.args(),'key':action.execution_id} or self.session is not None:raise Fault('planning_review_not_authorized')
   if self.factory.runner is None:raise Fault('friday_planning_disabled')
   self.factory.claim() # durable before launch; never clear on lost acknowledgement
   try:
    self.session=self.factory.runner.start();event=self.session.next(3)
    if type(event)!=dict or set(event)!={'event','job'} or event['event']!='submitted':raise Fault('planning_outcome_unknown')
    self.job=event['job']
    if type(self.job)!=dict or self.job.get('tool')!=NAME or type(self.job.get('id'))!=str:raise Fault('planning_outcome_unknown')
    if self.job.get('state')=='succeeded':return self.rpc('get',{'id':self.job['id']})
    return self.job
   except BaseException:
    if self.session:self.session.cancel()
    raise
  if method=='get':
   if not self.job or params!={'id':self.job['id']}:raise Fault('job_not_found')
   if self.complete:return self.job
   event=self.session.next(.05)
   if event is None:return self.job
   if type(event)!=dict or set(event)!={'status','result'} or event['status']!='advisory_only':raise Fault('planning_outcome_unknown')
   result=event['result']
   if type(result)!=dict or result.get('job_id')!=self.job['id']:raise Fault('planning_receipt_mismatch')
   self.session.finished();self.complete=True
   self.job={'id':self.job['id'],'tool':NAME,'state':'succeeded','result':result};return self.job
  raise Fault('method_not_allowed')
