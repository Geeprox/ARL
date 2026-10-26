"""Fixed ARL host composition for the reviewed NAS consumer, with no registration RPC."""
import fcntl,hashlib,json,os,signal,stat,subprocess,sys,threading,time
from pathlib import Path
ROOT=Path(__file__).resolve().parent
sys.path.insert(0,str(ROOT/'core'))
from arl.compat_host import CodexCallerPeer,compose_codex_service
from arl.codex_server import CodexTextAdapter
from arl.codex_service_v2 import CodexServiceV2
from arl.identity import RegisteredPeerVerifier
from arl.supervisor import SignedPeerVerifier

def main():
    config=json.loads((ROOT/'config.json').read_text());manifest=json.loads((ROOT/'manifest.json').read_text())
    def closure_current():
        try:
            members=list(ROOT.rglob('*'))
            if any(p.is_symlink() for p in members):return False
            if {str(p.relative_to(ROOT)) for p in members if p.is_file() and p.name!='manifest.json'} != set(manifest):return False
            return all(not (ROOT/p).is_symlink() and stat.S_ISREG((ROOT/p).stat().st_mode) and (ROOT/p).stat().st_uid==os.getuid() and not ((ROOT/p).stat().st_mode & 0o022) and hashlib.sha256((ROOT/p).read_bytes()).hexdigest()==h for p,h in manifest.items())
        except OSError:return False
    if not closure_current():raise RuntimeError('source_manifest_changed')
    home=Path(config['state_home']);home.mkdir(mode=0o700,parents=True,exist_ok=True);os.chmod(home,0o700)
    lock=(home/'adapter.lock').open('a');fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    child=subprocess.Popen([config['python'],'-I','-S','-B',str(ROOT/'worker.py')],cwd=ROOT,env={'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','HOME':str(Path.home())},stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True)
    if child.stdout.readline()!='prepared\n':raise RuntimeError('caller_not_prepared')
    registered=RegisteredPeerVerifier({config['caller']});registered.register(config['caller'],child.pid,config['peer_executable']);lease=registered.capture_registration(config['caller'],child.pid)
    signed=SignedPeerVerifier(ROOT/'PeerSignatureHelper',{config['caller']:config['signature_requirement']})
    adapter=CodexTextAdapter(binary=config['codex_binary'],enabled=True,max_wall_seconds=180)
    if adapter.pin!=config['codex_sha256']:raise RuntimeError('provider_binary_changed')
    service=CodexServiceV2(adapter,package_home=Path.home()/"Library/Application Support/ARL/CodexPackages",caller=config['caller'],model=config['model'],max_calls=None,max_output_bytes=32768,reasoning_effort=config['reasoning_effort'],service_tier='default',scope_generation=config['scope_generation'],authorization_current=closure_current,peer_current=lambda: child.poll() is None and lease.is_current())
    runtime=None;stop=threading.Event()
    def shutdown(*_):stop.set()
    signal.signal(signal.SIGTERM,shutdown);signal.signal(signal.SIGINT,shutdown)
    try:
        service.preflight()
        runtime=compose_codex_service(home,service=service,peer_verifier=CodexCallerPeer(config['caller'],registered,signed))
        errors=[]
        def serve():
            try:runtime.run()
            except BaseException as e:errors.append(type(e).__name__)
        thread=threading.Thread(target=serve);thread.start()
        if not runtime.ready.wait(10):raise RuntimeError('runtime_not_ready')
        runtime.codex_v2.initialize()
        child.stdin.write('go\n');child.stdin.flush()
        last_status=0
        while not stop.wait(1):
            if child.poll() is not None or errors or not closure_current():break
            status=service.status()
            if time.monotonic()-last_status>15:
                temporary=home/'status.tmp';temporary.write_text(json.dumps(status));temporary.chmod(0o600);os.replace(temporary,home/'status.json');last_status=time.monotonic()
            if time.monotonic()-(service.checked_mono or 0)>60:
                try:service.preflight()
                except Exception:pass
    finally:
        if child.poll() is None:child.terminate()
        try:child.wait(3)
        except subprocess.TimeoutExpired:child.kill();child.wait()
        registered.revoke(child.pid)
        if runtime is not None:runtime.shutdown();thread.join(35)

if __name__=='__main__':main()
