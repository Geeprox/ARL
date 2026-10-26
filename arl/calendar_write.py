"""Opt-in one-event write. Never included in the metadata-only host by default."""
from __future__ import annotations
import datetime,hashlib,json,os,re,selectors,stat,subprocess,sys,time
from pathlib import Path
from .contracts import Fault,Tool,object_schema,string,validate,encode
NAME='apple.calendar.create.v1'
SCHEMA=object_schema({'operation_id':dict(string(36),pattern=r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'),
    'title':string(300),'start':string(40),'end':string(40)},['operation_id','title','start','end'])
DATE_RE=re.compile(r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,6})?(?:Z|[+-]\d\d:\d\d)')
def checked(args):
    validate(args,SCHEMA)
    if not args['title'].strip() or any(ord(c)<32 or 0x7f<=ord(c)<=0x9f or 0xd800<=ord(c)<=0xdfff for c in args['title']):raise Fault('invalid_arguments')
    try:
        dates=[]
        for key in ('start','end'):
            if not DATE_RE.fullmatch(args[key]):raise ValueError()
            dates.append(datetime.datetime.fromisoformat(args[key].replace('Z','+00:00')))
        span=(dates[1]-dates[0]).total_seconds()
        if not 0<span<=86400:raise ValueError()
    except ValueError:raise Fault('invalid_arguments') from None
    return args

class CalendarWriteTransport:
    def __init__(self,executable,*,runner=subprocess.run):
        self.executable=Path(executable).resolve(strict=True);self.runner=runner
        self.pin=self.verify()
    def verify(self):
        st=self.executable.lstat()
        if not stat.S_ISREG(st.st_mode) or st.st_uid!=os.geteuid() or st.st_mode&0o022:raise Fault('unsafe_calendar_helper')
        return hashlib.sha256(self.executable.read_bytes()).hexdigest()
    def __call__(self,args):
        if self.verify()!=self.pin:raise Fault('calendar_helper_changed')
        try:
            p=self.runner([str(self.executable)],input=encode({'tool':NAME,'args':checked(args)}),
                stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=8,
                env={'PATH':'/usr/bin:/bin:/usr/sbin:/sbin'})
            if p.returncode or len(p.stdout)>4096:raise ValueError()
            d=json.loads(p.stdout)
            if type(d) is not dict or d.get('status') not in {'saved_local','needs_permission','no_default_calendar','invalid_arguments','outcome_unknown'}:raise ValueError()
            if d['status']!='saved_local':raise Fault(d['status'])
            if set(d)!={'status','operation_id'} or d['operation_id']!=args['operation_id']:raise ValueError()
            return {'schema_version':1,'operation_id':args['operation_id'],'persistence':'saved_local','cloud_sync':'not_checked'}
        except (subprocess.TimeoutExpired,OSError,ValueError):raise Fault('outcome_unknown') from None

class CalendarNativeChannel:
    """Private pipes to the native parent; constructed only by the sealed host.

    The native parent revalidates the proposal/expiry/one-use marker independently
    of Python. It accepts effects only from its own fixed isolated child.
    """
    def __call__(self,args):
        request=encode({'native_effect':{'tool':NAME,'args':checked(args)}})+b'\n'
        sys.stdout.buffer.write(request);sys.stdout.buffer.flush()
        selector=selectors.DefaultSelector();selector.register(0,selectors.EVENT_READ)
        raw=bytearray();deadline=time.monotonic()+8
        try:
            while b'\n' not in raw:
                left=deadline-time.monotonic()
                if left<=0 or not selector.select(left):raise Fault('outcome_unknown')
                part=os.read(0,4097-len(raw))
                if not part or len(raw)+len(part)>4096:raise Fault('outcome_unknown')
                raw.extend(part)
            if raw.count(b'\n')!=1 or not raw.endswith(b'\n'):raise Fault('outcome_unknown')
            result=json.loads(raw)
        except (OSError,ValueError):raise Fault('outcome_unknown') from None
        finally:selector.close()
        if type(result) is not dict:raise Fault('outcome_unknown')
        status=result.get('status')
        if status!='saved_local':
            allowed={'needs_permission','no_default_calendar','review_not_authorized','review_expired','operation_consumed','unsafe_review_file','outcome_unknown'}
            raise Fault(status if status in allowed else 'outcome_unknown')
        if set(result)!={'status','operation_id'} or result['operation_id']!=args['operation_id']:raise Fault('outcome_unknown')
        return {'schema_version':1,'operation_id':args['operation_id'],'persistence':'saved_local','cloud_sync':'not_checked'}


class CalendarWriteAdapter:
    def __init__(self,transport=None):self.transport=transport
    def run(self,args,context):
        checked(args);context.check_cancelled()
        if context.row['key']!=args['operation_id']:raise Fault('operation_key_mismatch')
        if self.transport is None:raise Fault('calendar_write_not_enabled')
        # No post-effect cancellation exception: save may already have committed.
        return self.transport(args)
    def tool(self):
        return Tool(NAME,SCHEMA,self.run,idempotent=False,permissions=('calendar_write_only','reviewed_single_event'),
            availability='adapter' if self.transport else 'not_implemented',
            description='One reviewed event in the system default calendar; explicit offset times; no reads, invitations, recurrence or implicit permission prompt.')
