"""Opt-in one-item Reminders adapter. Never registered by the installed host."""
from __future__ import annotations
import json,os,selectors,sys,time,uuid
from .contracts import Fault,Tool,object_schema,string,validate,encode

NAME='apple.reminders.create.v1'
SCHEMA=object_schema({
    'operation_id':dict(string(36),pattern=r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'),
    'title':string(300),
    'target_policy':dict(string(40),enum=['system_default_at_confirmation'])
},['operation_id','title','target_policy'])

def checked(args):
    validate(args,SCHEMA)
    try:
        if str(uuid.UUID(args['operation_id']))!=args['operation_id']:raise ValueError()
    except ValueError:raise Fault('invalid_arguments') from None
    title=args['title']
    if not title.strip() or any(ord(c)<32 or 0x7f<=ord(c)<=0x9f or 0xd800<=ord(c)<=0xdfff for c in title):
        raise Fault('invalid_arguments')
    return args

class RemindersNativeChannel:
    """Only the sealed host's anonymous pipes to its fixed native parent."""
    def __call__(self,args,context):
        sys.stdout.buffer.write(encode({'native_effect':{'tool':NAME,'args':checked(args)}})+b'\n')
        sys.stdout.buffer.flush()
        selector=selectors.DefaultSelector();selector.register(0,selectors.EVENT_READ)
        raw=bytearray();deadline=time.monotonic()+25;commit_sent=False;commit_allowed=False
        try:
            while True:
                while b'\n' not in raw:
                    left=deadline-time.monotonic()
                    if left<=0 or not selector.select(left):raise Fault('outcome_unknown')
                    part=os.read(0,4097-len(raw))
                    if not part or len(raw)+len(part)>4096:raise Fault('outcome_unknown')
                    raw.extend(part)
                if raw.count(b'\n')!=1 or not raw.endswith(b'\n'):raise Fault('outcome_unknown')
                result=json.loads(raw);raw.clear()
                if type(result) is dict and result.get('status')=='awaiting_commit':
                    if commit_sent or set(result)!={'status','operation_id'} or result['operation_id']!=args['operation_id']:
                        raise Fault('outcome_unknown')
                    allowed=True
                    try:context.check_cancelled()
                    except Fault:allowed=False
                    if time.monotonic()>=deadline:allowed=False
                    sys.stdout.buffer.write(encode({'native_commit':allowed,'operation_id':args['operation_id']})+b'\n')
                    sys.stdout.buffer.flush();commit_sent=True;commit_allowed=allowed
                    continue
                break
        except (OSError,ValueError):raise Fault('outcome_unknown') from None
        finally:selector.close()
        if type(result) is not dict:raise Fault('outcome_unknown')
        if result.get('status')!='saved_local':
            allowed={'needs_permission','needs_unlock','lock_state_unknown','no_default_list','target_changed',
                'user_cancelled','review_expired','review_not_authorized','operation_consumed',
                'unsafe_review_file','outcome_unknown'}
            raise Fault(result.get('status') if result.get('status') in allowed else 'outcome_unknown')
        if not commit_sent or not commit_allowed:raise Fault('outcome_unknown')
        if (set(result)!={'status','operation_id','target_identifier_sha256'} or
                result['operation_id']!=args['operation_id'] or
                type(result['target_identifier_sha256']) is not str or
                len(result['target_identifier_sha256'])!=64 or
                any(c not in '0123456789abcdef' for c in result['target_identifier_sha256'])):
            raise Fault('outcome_unknown')
        return {'schema_version':1,'operation_id':args['operation_id'],
            'target_selection':'system_default_confirmed','target_identifier_sha256':result['target_identifier_sha256'],
            'persistence':'saved_local','cloud_sync':'not_checked'}

class RemindersWriteAdapter:
    def __init__(self,transport=None):self.transport=transport
    def run(self,args,context):
        checked(args);context.check_cancelled()
        if context.row['key']!=args['operation_id']:raise Fault('operation_key_mismatch')
        if self.transport is None:raise Fault('reminders_write_not_enabled')
        # A synchronous native save cannot be undone by a late cancellation.
        return self.transport(args,context)
    def tool(self):
        return Tool(NAME,SCHEMA,self.run,idempotent=False,
            permissions=('reminders_full_access','reviewed_single_reminder'),
            availability='adapter' if self.transport else 'not_implemented',
            description='One native-confirmed item in the current default Reminders list; no due date, alarms, recurrence, content reads or implicit TCC prompt.')
