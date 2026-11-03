"""Bounded read-only callback timings, never protocol objects or credentials."""
import json
import os
from pathlib import Path
import pwd
import stat
import time
import uuid

FILENAME = 'authorization-timings.json'
STAGES = frozenset({'reserve','lease','connect','connect_effect','reply','provider_reply',
                    'request','request_reply','inventory_metadata'})
OUTCOMES = frozenset({'ok','reply_timeout','cancelled','wire_error'})
MAX_COUNT = 4096
MAX_US = 120_000_000
MAX_RECENT = 16
MAX_RECORD = 16384

def readonly_operation(frame):
    """Read only selectors; original wire/request admission remains authoritative."""
    if type(frame) is not dict:return None
    kind=frame.get('kind')
    if kind=='connect':return 'connect'
    if kind=='list':return 'list'
    if kind=='files':
        request=frame.get('request')
        if type(request) is dict and request.get('operation')=='list':return 'list'
    return None


class ReadonlyAuthorizationTimings:
    """One worker's finite aggregate; root/clock are constructor-only fixtures."""
    def __init__(self, *, root=None, clock=time.time):
        self.root=root;self.clock=clock;self.active=False;self.rows={}
        self.count=0;self.truncated=False;self.dirty=False

    def begin(self, operation):
        self.active=operation in {'connect','list'}

    def add(self, stage, elapsed_ns, outcome):
        if (not self.active or stage not in STAGES or outcome not in OUTCOMES
                or type(elapsed_ns) is not int or elapsed_ns < 0):return
        if self.count>=MAX_COUNT:self.truncated=True;self.dirty=True;return
        value=min(elapsed_ns//1000,MAX_US)
        if elapsed_ns//1000>MAX_US:self.truncated=True
        row=self.rows.setdefault(stage,dict(stage=stage,count=0,total_microseconds=0,
            min_microseconds=value,max_microseconds=value,recent_microseconds=[],
            outcomes={name:0 for name in sorted(OUTCOMES)}))
        row['count']+=1;row['total_microseconds']+=value
        row['min_microseconds']=min(row['min_microseconds'],value)
        row['max_microseconds']=max(row['max_microseconds'],value)
        row['recent_microseconds']=(row['recent_microseconds']+[value])[-MAX_RECENT:]
        row['outcomes'][outcome]+=1;self.count+=1;self.dirty=True

    def finish(self):
        was_active=self.active;self.active=False
        if not was_active or not self.dirty:return False
        try:
            value=dict(schema_version=1,operation='nas_native_authorization_timings',at=int(self.clock()),
                measurement='authorize_entry_to_validated_reply',context='read_only_connect_list',
                truncated=self.truncated,stages=[self.rows[name] for name in sorted(self.rows)])
            raw=json.dumps(value,sort_keys=True,separators=(',',':'),allow_nan=False).encode()
            if len(raw)>MAX_RECORD:return False
            root=(Path(pwd.getpwuid(os.getuid()).pw_dir)/'Library/Application Support/ARL/nas'
                  if self.root is None else Path(self.root))
            # Never create a diagnostics directory or follow an alternate path.
            if any(path.is_symlink() for path in (root,*root.parents)):return False
            directory=os.open(root,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW|os.O_CLOEXEC)
            try:
                info=os.fstat(directory)
                if info.st_uid!=os.getuid() or stat.S_IMODE(info.st_mode)!=0o700:return False
                try:old=os.stat(FILENAME,dir_fd=directory,follow_symlinks=False)
                except FileNotFoundError:old=None
                if old is not None and (not stat.S_ISREG(old.st_mode) or old.st_uid!=os.getuid()
                        or old.st_nlink!=1 or stat.S_IMODE(old.st_mode)!=0o600):return False
                temporary='.authorization-timings-'+uuid.uuid4().hex
                fd=os.open(temporary,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW|os.O_CLOEXEC,0o600,dir_fd=directory)
                try:
                    view=memoryview(raw)
                    while view:
                        count=os.write(fd,view)
                        if count<=0:return False
                        view=view[count:]
                    os.fsync(fd)
                    try:current=os.stat(FILENAME,dir_fd=directory,follow_symlinks=False)
                    except FileNotFoundError:current=None
                    if ((old is None)!=(current is None) or old is not None
                            and (old.st_dev,old.st_ino)!=(current.st_dev,current.st_ino)):return False
                    os.rename(temporary,FILENAME,src_dir_fd=directory,dst_dir_fd=directory)
                    os.fsync(directory);self.dirty=False;return True
                finally:
                    os.close(fd)
                    try:os.unlink(temporary,dir_fd=directory)
                    except FileNotFoundError:pass
            finally:os.close(directory)
        except Exception:return False
