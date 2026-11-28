"""Production metadata host with optional reviewed local compatibility composition."""
import argparse
from pathlib import Path
import signal
import threading

from .contracts import Fault
from .extension_contracts import compatibility, metadata_policies
from .identity import PeerComposition
# Frozen Apple review overlays import account_home from this entry module.
from .lifecycle import account_home, state_home
from .service import Runtime


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
