"""One-shot approved Calendar host. No persistent agent or general enrollment/API."""
from __future__ import annotations
import hashlib,json,os,selectors,stat,subprocess,sys,threading,time
from pathlib import Path
from .calendar_write import CalendarWriteAdapter,CalendarWriteTransport,NAME,checked
from .contracts import AppPolicy,Fault,encode
from .host import account_home
from .identity import RegisteredPeerVerifier,process_identity
from .service import Runtime
from .providers import MockProvider
from .supervisor import SignedPeerVerifier
APP='calendar_review'
class NoExternalTools:
    transport=None
    def tools(self):return []

class ReviewGate:
    def __init__(self,args,expires_at_ms,*,clock=None):
        checked(args);self.args=json.loads(encode(args));self.sha256=hashlib.sha256(encode(args)).hexdigest()
        self.clock=clock or (lambda:int(time.time()*1000))
        if type(expires_at_ms)!=int or not self.clock()<expires_at_ms<=self.clock()+600000:raise Fault('review_expired')
        self.expires=expires_at_ms
    def admit(self,owner,name,args):
        if owner!=APP or name!=NAME or hashlib.sha256(encode(args)).hexdigest()!=self.sha256:raise Fault('review_not_authorized')
        if self.clock()>=self.expires:raise Fault('review_expired')

def private_json(path,limit=16384):
    fd=os.open(str(path),os.O_RDONLY|os.O_NOFOLLOW)
    try:
        s=os.fstat(fd)
        if not stat.S_ISREG(s.st_mode) or s.st_uid!=os.geteuid() or s.st_mode&0o077:raise Fault('unsafe_review_file')
        raw=os.read(fd,limit+1)
    finally:os.close(fd)
    if len(raw)>limit:raise Fault('invalid_review_file')
    try:return json.loads(raw)
    except ValueError:raise Fault('invalid_review_file') from None

class CalendarPackage:
    def __init__(self,bundle,manifest):self.bundle=Path(bundle);self.manifest=manifest;self.validate()
    def validate(self):
        if self.bundle.is_symlink() or self.manifest.get('bundle_id')!='local.arl.calendarbridge':raise Fault('calendar_package_changed')
        files={}
        for p in self.bundle.rglob('*'):
            s=p.lstat()
            if stat.S_ISLNK(s.st_mode) or s.st_uid!=os.geteuid() or s.st_mode&0o022:raise Fault('calendar_package_changed')
            if p.is_file():files[str(p.relative_to(self.bundle))]=hashlib.sha256(p.read_bytes()).hexdigest()
        if files!=self.manifest['files']:raise Fault('calendar_package_changed')
        if self.manifest['requirement']!='cdhash H"'+self.manifest['cdhash']+'"':raise Fault('calendar_package_changed')
        p=subprocess.run(['/usr/bin/codesign','--verify','--strict',str(self.bundle)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=3)
        if p.returncode:raise Fault('calendar_signature_invalid')
    @property
    def executable(self):return self.bundle/'Contents/MacOS/ARLCalendarBridge'
    @property
    def verifier(self):return self.bundle/'Contents/Helpers/PeerSignatureHelper'

def run_review(package,gate,*,home=None,transport=None):
    """home/transport injection only for isolated source tests; production CLI fixes both."""
    package.validate()
    if transport is None:
        # Generic subprocess stdin was an effect-boundary bypass. Only the
        # native broker-owned channel can perform an actual effect now.
        raise Fault('native_broker_required')
    home=home or account_home()/'Library/Application Support/ARL/calendar-once'
    gate.admit(APP,NAME,gate.args)
    registered=RegisteredPeerVerifier({APP});signed=SignedPeerVerifier(package.verifier,{APP:package.manifest['requirement']})
    child=None;runtime=None
    def verify(connection,app):
        try:package.validate()
        except (Fault,OSError):return None
        return app if registered(connection,app)==app and signed(connection,app)==app else None
    policies={'settings':AppPolicy(frozenset(),frozenset(),0,0,0,methods=frozenset({'health','ready'}),public_metadata=True),
        APP:AppPolicy(frozenset({NAME}),frozenset(),0,1,1,methods=frozenset({'health','ready','submit','get','cancel'}))}
    runtime=Runtime(home,policies=policies,extra_tools=[CalendarWriteAdapter(transport).tool()],identity_verifier=verify,admission=gate.admit,apple=NoExternalTools(),travel=NoExternalTools(),providers={"mock":MockProvider()})
    errors=[]
    def serve():
        try:runtime.run()
        except Exception:errors.append('review_runtime_failed')
    thread=threading.Thread(target=serve);thread.start()
    try:
        end=time.monotonic()+5
        while not runtime.ready.is_set() and time.monotonic()<end and not errors:time.sleep(.01)
        if not runtime.ready.is_set():raise Fault('review_runtime_failed')
        flag='--isolated-review-client' if home!=account_home()/'Library/Application Support/ARL/calendar-once' else '--review-client'
        child=subprocess.Popen([str(package.executable),flag],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,env={'PATH':'/usr/bin:/bin:/usr/sbin:/sbin'})
        selector=selectors.DefaultSelector();selector.register(child.stdout,selectors.EVENT_READ)
        try:
            if not selector.select(3) or child.stdout.readline(33)!=b'prepared\n':raise Fault('review_handshake_failed')
        finally:selector.close()
        package.validate();registered.register(APP,child.pid,package.executable)
        out,_=child.communicate(encode({'home':str(home),'args':gate.args}),timeout=25)
        if child.returncode or len(out)>8192:raise Fault('review_client_unavailable')
        try:receipt=json.loads(out)
        except ValueError:raise Fault('review_client_unavailable') from None
        if type(receipt) is not dict or receipt.get('state') not in {'succeeded','failed','cancelled','needs_review'}:raise Fault('review_client_unavailable')
        return receipt
    except subprocess.TimeoutExpired:raise Fault('review_outcome_unknown') from None
    finally:
        if child:
            registered.revoke(child.pid)
            if child.poll() is None:child.terminate();child.wait(3)
        runtime.shutdown();thread.join(12)
        if thread.is_alive():raise Fault('review_shutdown_pending')

# No auto-start or permissive serve command; explicit approved request digest is required.
def main():
    import argparse
    parser=argparse.ArgumentParser();parser.add_argument('--approved-sha256',required=True);parser.add_argument('--native-broker',action='store_true');args=parser.parse_args()
    base=account_home()/'Library/Application Support/ARL/calendar-once'
    review=private_json(base/'review.json');manifest=private_json(base/'calendar-package.json')
    if type(review) is not dict or set(review)!={'args','expires_at_ms'}:raise Fault('invalid_review_file')
    gate=ReviewGate(review['args'],review['expires_at_ms'])
    if args.approved_sha256!=gate.sha256:raise Fault('review_not_authorized')
    package=CalendarPackage(account_home()/'Applications/ARLCalendarBridge.app',manifest)
    # This is not a shared-interpreter identity. The exact reviewed native broker
    # creates this host process and owns both anonymous pipes. No socket/FD RPC
    # enrollment or caller-selected parent/launcher is provided.
    parent=process_identity(os.getppid())
    if (not args.native_broker or not parent or parent['uid']!=os.geteuid() or parent['executable']!=str(package.executable)
            or any(not stat.S_ISFIFO(os.fstat(fd).st_mode) for fd in (0,1))):
        raise Fault('native_broker_required')
    from .calendar_write import CalendarNativeChannel
    receipt=run_review(package,gate,transport=CalendarNativeChannel())
    print(json.dumps({'broker_receipt':receipt}),flush=True);return 0
if __name__=='__main__':
    try:raise SystemExit(main())
    except Fault as exc:print(json.dumps({'ok':False,'error':{'code':exc.code}}));raise SystemExit(1)
