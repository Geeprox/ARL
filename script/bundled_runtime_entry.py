"""Fixed ARL.app core entry. No installation, grants or launchd mutations."""
import sys
# Check before importing the packaged service or opening state. -I ignores
# Python environment controls, so -B is required explicitly at every root.
if __name__ == "__main__" and (not sys.flags.isolated or not sys.flags.dont_write_bytecode):
    sys.stderr.write("bundled_python_launch_flags_required\n")
    raise SystemExit(1)
import hashlib
import json
import os
from pathlib import Path
import stat
import threading
import time
import signal
import pwd
import uuid


def verify(root):
    root = Path(root).absolute()
    for path in (root, *root.parents):
        if path.is_symlink(): raise ValueError("runtime_symlink")
    raw = (root / "manifest.json").read_bytes()
    if len(raw) > 1024*1024: raise ValueError("runtime_manifest_limit")
    manifest = json.loads(raw)
    if (manifest.get("schema") != 1 or manifest.get("protocol") != "arl/1"
        or manifest.get("store_version") != 4 or manifest.get("profile") not in {"public-core-zero-grants", "local-compatibility"}):
        raise ValueError("unsupported_runtime_package")
    files = manifest.get("files")
    if type(files) is not dict or not 1 <= len(files) <= 4096: raise ValueError("invalid_runtime_inventory")
    actual = set()
    for p in root.rglob("*"):
        info = p.lstat()
        if not (stat.S_ISREG(info.st_mode) or stat.S_ISDIR(info.st_mode)) or info.st_uid != os.geteuid() or info.st_mode & 0o022:
            raise ValueError("unsafe_runtime_resource")
        if p.is_file(): actual.add(str(p.relative_to(root)))
    if actual != set(files) | {"manifest.json"}: raise ValueError("unlisted_runtime_resource")
    for name, digest in files.items():
        rel = Path(name)
        if rel.is_absolute() or ".." in rel.parts or str(rel) == ".": raise ValueError("invalid_runtime_path")
        if not isinstance(digest, str) or len(digest) != 64 or hashlib.sha256((root/rel).read_bytes()).hexdigest() != digest:
            raise ValueError("runtime_hash_mismatch")
    return manifest


def startup_failure(error, phase):
    """Persist only fixed startup phase/type/errno; no stderr or config text."""
    home=Path(pwd.getpwuid(os.geteuid()).pw_dir)/'Library/Application Support/ARL'
    args=sys.argv[1:]
    if '--isolated-test' in args:
        i=args.index('--isolated-test')
        if args[i:i+2]!=['--isolated-test','--home'] or len(args)!=i+3:return
        home=Path(args[i+2]).absolute()
    record={'schema_version':1,'phase':phase,'code':'bundled_runtime_start_failed',
            'type':type(error).__name__,'pid':os.getpid(),'parent_pid':os.getppid(),'at':int(time.time())}
    if isinstance(error,OSError) and type(error.errno) is int:record['errno']=error.errno
    temporary=home/('.runtime-startup-'+uuid.uuid4().hex)
    try:
        for p in (home,*home.parents):
            if p.is_symlink():return
        info=home.stat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid!=os.geteuid() or info.st_mode&0o077:return
        fd=os.open(temporary,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
        with os.fdopen(fd,'wb') as stream:
            stream.write((json.dumps(record,sort_keys=True)+'\n').encode());stream.flush();os.fsync(stream.fileno())
        os.replace(temporary,home/'runtime-startup-failure.json')
    except OSError:pass
    finally:
        if temporary.exists():temporary.unlink()

def watch_parent(parent):
    if parent<=1 or os.getppid()!=parent:raise ValueError('invalid_parent_owner')
    def monitor():
        while os.getppid()==parent:time.sleep(.1)
        os.kill(os.getpid(),signal.SIGTERM)
    threading.Thread(target=monitor,daemon=True).start()

def main():
    root = Path(__file__).absolute().parent
    phase='verify_package'
    try:
        manifest = verify(root)
        parent=None
        if len(sys.argv) >= 3 and sys.argv[1] == "--parent-pid":
            parent = int(sys.argv[2])
            if parent <= 1 or os.getppid() != parent: raise ValueError("invalid_parent_owner")
            sys.argv = sys.argv[:1] + sys.argv[3:]
            watch_parent(parent)
        if len(sys.argv) >= 3 and sys.argv[1] == "--manage":
            sys.dont_write_bytecode = True
            sys.path.insert(0, str(root/"code"))
            from arl.install_cli import main as manage
            from arl.install_transaction import InstallFault
            def parent_exit(_signal,_frame):raise InstallFault("install_parent_exited")
            if parent is not None:signal.signal(signal.SIGTERM,parent_exit)
            return manage(sys.argv[2:], root.parents[2],parent_pid=parent)
        if sys.argv[1:] == ["--attachment-inspect"]:
            # Only the existing signed Mio parent starts this ephemeral mode.
            # Request bytes stay on private stdin; no state home or task runtime
            # is opened, and stdout contains a finite metadata receipt only.
            if parent is None: raise ValueError("invalid_parent_owner")
            sys.dont_write_bytecode = True
            sys.path.insert(0, str(root/"code"))
            from arl.attachment_inspection import run as inspect_attachment
            return inspect_attachment(sys.stdin.buffer, sys.stdout.buffer, parent)
        if sys.argv[1:] == ["--check"]:
            print(json.dumps({"status":"PASS", "source_sha256":manifest["source_sha256"], "profile":manifest["profile"], "grants_changed":False}))
            return 0
        if sys.argv[1:] and not (len(sys.argv) == 4 and sys.argv[1:3] == ["--isolated-test", "--home"]):
            raise ValueError("invalid_runtime_arguments")
        phase='import_runtime'
        os.environ.clear()
        os.environ.update(PATH="/usr/bin:/bin:/usr/sbin:/sbin", PYTHONDONTWRITEBYTECODE="1")
        sys.dont_write_bytecode = True
        sys.path.insert(0, str(root/"code"))
        from arl.runtime_description import source_fingerprint
        if source_fingerprint() != manifest["source_sha256"]: raise ValueError("runtime_fingerprint_mismatch")
        from arl.host import main as host_main, run, state_home
        phase='check_maintenance'
        maintenance = state_home()/"install-maintenance.json"
        if maintenance.exists():
            info = maintenance.lstat()
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
                raise ValueError("unsafe_maintenance_marker")
            # No opt-in composition, task replay, account/model preflight or
            # tool grants while validating a staged installation.
            if json.loads(maintenance.read_bytes()) != {"schema_version":1,"enabled":1}:raise ValueError("invalid_maintenance_marker")
            phase='start_maintenance';return run(state_home())
        phase='start_runtime';return host_main()
    except Exception as error:
        startup_failure(error,phase)
        # Exception messages may contain paths/configuration; only a fixed code leaves this boundary.
        sys.stderr.write("bundled_runtime_start_failed\n")
        return 1

if __name__ == "__main__": raise SystemExit(main())
