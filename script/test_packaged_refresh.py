"""Real packaged metadata refresh; no production state/account/tool effects.
Starts only the bundled Core in a short private test home, calls the actual
modules consumer across cache expiry, then verifies no bundle file/mode drift.
"""
import argparse,hashlib,json,os,sys
from pathlib import Path
import plistlib,socket,subprocess,tempfile,time
from finalize_build import staged_release
ROOT=Path(__file__).resolve().parents[1]
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def inventory(app):
 return {str(p.relative_to(app)):{'sha256':sha(p),'mode':p.stat().st_mode&0o777} for p in app.rglob('*') if p.is_file()}
def rpc(home,method):
 with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as s:
  s.settimeout(3);s.connect(str(home/'runtime.sock'));s.sendall((json.dumps({'protocol':'arl/1','app':'settings','method':method,'params':{}})+'\n').encode())
  with s.makefile('rb') as f:raw=f.readline(131073)
 d=json.loads(raw);assert d['ok'],d.get('error',{}).get('code','metadata_rpc_failed');return d['result']
def verify(package):
 package=package.absolute();app=package/'ARL.app';manifest=json.loads((package/'manifest.json').read_text());before=inventory(app);assert before==manifest['bundle_files']
 mio=app/'Contents/Library/LoginItems/ARLMioAppleBridge.app'
 sys.path.insert(0,str(ROOT/'script'))
 from stage_mio_runtime import verify_runtime
 mio_resources=verify_runtime(mio/'Contents/Resources/MioRuntime')
 check=subprocess.run([str(mio/'Contents/MacOS/ARLMioAppleBridge'),'--runtime-check'],capture_output=True,timeout=10)
 assert check.returncode==0,'packaged_mio_runtime_check_failed'
 mio_check=json.loads(check.stdout);assert mio_check['status']=='PASS' and mio_check['catalog_tools']==20 and mio_check['credentials_read'] is False and mio_check['prompts_requested'] is False and mio_check['network_requests']==0
 info=plistlib.loads((app/'Contents/Info.plist').read_bytes());root=app/'Contents/Resources/CoreRuntime';python=app/'Contents/Resources/NASRuntime/python/bin/python3.12'
 report={'build':info['CFBundleVersion'],'version':info['CFBundleShortVersionString'],'production_state_written':False,'credential_or_business_requests':False,'mio_sealed_modes':mio_resources,'actual_packaged_mio_check':mio_check}
 (ROOT/'build/audit').mkdir(parents=True,exist_ok=True)
 with tempfile.TemporaryDirectory(prefix='rpc-',dir=ROOT/'build/audit') as folder:
  home=Path(folder);home.chmod(0o700)
  process=subprocess.Popen([str(python),'-I','-B',str(root/'entry.py'),'--parent-pid',str(os.getpid()),'--isolated-test','--home',str(home)],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
  try:
   deadline=time.monotonic()+8
   while time.monotonic()<deadline:
    try:
     description=rpc(home,'runtime.describe');break
    except (OSError,AssertionError):time.sleep(.05)
   else:raise AssertionError('packaged_start_failed')
   assert description['ready'] and description['version']==info['CFBundleShortVersionString'] and description['source_sha256']==info['ARLCoreRuntimeSourceSHA256']
   overview=rpc(home,'overview');assert overview['policy']['local_inference_enabled'] is False
   assert sum(overview['queue']['counts'].values())==0
   stamps=[]
   for i in range(3):
    if i:time.sleep(5.1)
    value=rpc(home,'settings.modules_snapshot');stamps.append(value['modules'][0]['checked_at_ms'])
   assert len(set(stamps))==3,'worker cache did not expire'
   report.update(actual_packaged_start=True,actual_module_worker_refreshes=3,zero_grants=True,source_matches_signed_info=True)
  finally:
   process.terminate();process.wait(timeout=8)
 after=inventory(app);report['file_set_and_modes_unchanged']=after==before;report['added_files']=len(set(after)-set(before));report['signature_verified']=subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict',str(app)],capture_output=True).returncode==0
 path=ROOT/f'build/audit/packaged-refresh-build{info["CFBundleVersion"]}.json';path.write_text(json.dumps(report,indent=2)+'\n');path.chmod(0o600)
 print(json.dumps(report,indent=2));assert report['file_set_and_modes_unchanged'] and report['signature_verified']
 return 0
def main():
 parser=argparse.ArgumentParser();parser.add_argument('--package',required=True,type=Path);args=parser.parse_args()
 with staged_release(args.package.absolute().parent):return verify(args.package)
if __name__=='__main__':raise SystemExit(main())
