"""Production metadata host with optional reviewed local compatibility composition."""
import argparse
import fcntl
import json
import re
import stat
import time
from . import VERSION
import os
from pathlib import Path
import pwd
import signal
import threading
from .contracts import Fault
from .extension_contracts import compatibility, metadata_policies
from .service import Runtime

def account_home():return Path(pwd.getpwuid(os.geteuid()).pw_dir)
def state_home():return account_home()/'Library/Application Support/ARL'

class PeerComposition:
    def __init__(self,verifiers=()):self.verifiers=tuple(verifiers)
    def __call__(self,connection,app):
        if app == 'settings': return None
        for verifier in self.verifiers:
            try:
                if verifier(connection,app)==app:return app
            except Exception:continue
        return None
    def session_binding(self,connection,app):
        for verifier in self.verifiers:
            if verifier(connection,app)==app and hasattr(verifier,'session_binding'):
                return verifier.session_binding(connection,app)
        raise Fault('app_identity_unverified')


class MetadataLog:
    """Bounded 64 KiB private log, fixed machine fields, no exception messages."""
    def __init__(self, home):
        self.path = home/"host.log"

    def event(self, event, code=None):
        if event not in {"starting", "ready", "stopped", "disabled", "error"}:
            raise ValueError("unknown_log_event")
        record = {"at": int(time.time()), "event": event, "version": VERSION}
        if code and re.fullmatch(r"[a-z_]{1,80}", code):
            record["code"] = code
        raw = (json.dumps(record, sort_keys=True)+"\n").encode()
        fd = os.open(str(self.path), os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
                raise Fault("unsafe_log")
            fcntl.flock(fd, fcntl.LOCK_EX)
            if os.fstat(fd).st_size + len(raw) > 65536:
                os.ftruncate(fd, 0)
            os.lseek(fd, 0, os.SEEK_END)
            os.write(fd, raw)
        finally:
            os.close(fd)


def make_runtime(home,**bindings):
    if compatibility:
        from .compat_host import make_runtime as compose
        return compose(home,**bindings)
    if bindings:raise Fault('host_extension_unavailable')
    return Runtime(home,policies=metadata_policies(),local_enabled=False,identity_verifier=PeerComposition(),execute_jobs=False)

def run(home,**bindings):
    if compatibility:
        from .compat_host import run as legacy
        return legacy(home,**bindings)
    runtime=make_runtime(home,**bindings)
    def stop(_signal,_frame):threading.Thread(target=runtime.shutdown,daemon=True).start()
    signal.signal(signal.SIGTERM,stop);signal.signal(signal.SIGINT,stop)
    try:runtime.run();return 0
    except Fault as error:return 0 if error.code in {'user_disabled','already_running'} else 1
    except Exception:return 1

def main():
    if compatibility:
        from .compat_host import main as legacy
        return legacy()
    parser=argparse.ArgumentParser();parser.add_argument('--isolated-test',action='store_true');parser.add_argument('--home',type=Path)
    args=parser.parse_args()
    if args.home is not None and not args.isolated_test:parser.error('home override requires isolated test')
    return run(args.home if args.home is not None else state_home())
if __name__=='__main__':raise SystemExit(main())
