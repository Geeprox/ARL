"""Compile exact production consumers; execute only isolated synthetic storage."""
import datetime, importlib.util, json, subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/audit/apple-reminders-e2e-20261019.noindex'
records=[]
def run(name,argv,seconds=180):
    p=subprocess.run(list(map(str,argv)),cwd=ROOT,capture_output=True,timeout=seconds)
    (OUT/(name+'.log')).write_bytes(p.stdout+p.stderr)
    records.append(dict(name=name,argv=list(map(str,argv)),exit_code=p.returncode,log=name+'.log'))
    (OUT/'execution-verification.json').write_text(json.dumps(records,indent=2)+'\n')
    print(name,p.returncode,flush=True)
    if p.returncode:print((p.stdout+p.stderr).decode()[-12000:]);raise SystemExit(p.returncode)
    if p.stdout:print(p.stdout.decode(),end='',flush=True)
def main():
    OUT.mkdir(parents=True,exist_ok=True)
    spec=importlib.util.spec_from_file_location('reminders_build',ROOT/'integrations/reminders_v3/build_static.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
    sdk=subprocess.check_output(['/usr/bin/xcrun','--show-sdk-path'],text=True).strip()
    base=['/usr/bin/xcrun','swiftc','-sdk',sdk,'-j','1','-swift-version','6','-target','arm64-apple-macos14.0','-module-cache-path',OUT/'ModuleCache','-I',OUT]
    for name,sources in [('ARLRemindersCore',m.CORE),('ARLRemindersEventKit',m.EVENTKIT)]:
        run(name,base+['-parse-as-library','-whole-module-optimization','-emit-module','-emit-object','-module-name',name,'-emit-module-path',OUT/(name+'.swiftmodule'),*[ROOT/p for p in sources],'-o',OUT/(name+'.o')])
    host=[ROOT/p for p in m.HOST if not p.endswith('PermissionBrokerMain.swift')]
    native=[ROOT/'integrations/reminders_v3/FirstSliceFixtureBackend.swift',ROOT/'integrations/reminders_v3/adapter_source/Fixtures/FixtureRepository.swift',ROOT/'macOS/ARLControl/Services/RemindersNativeClient.swift']
    mio=[ROOT/x['path'] for x in json.loads((ROOT/'script/mio_native_recipe.json').read_text())['sources'] if not x['path'].endswith('/main.swift')]
    objects=[OUT/'ARLRemindersCore.o',OUT/'ARLRemindersEventKit.o']
    run('owner-execution-compile',base+['-D','REMINDERS_FIRST_SLICE_FIXTURE','-parse-as-library',*host,*native,*mio,ROOT/'macOS/ARLControl/Services/AppleOwnerExecutor.swift',ROOT/'tests/AppleOwnerExecutionTests.swift',*objects,'-o',OUT/'apple-owner-tests'])
    fixture=OUT/('fixture-'+datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%f'))
    run('owner-execution-results',[OUT/'apple-owner-tests',fixture],30)
    run('music-output-preservation-compile',base+['-parse-as-library',*mio,ROOT/'tests/MioMusicWriteFailureOutputTests.swift','-o',OUT/'music-output-tests'])
    run('music-output-preservation-results',[OUT/'music-output-tests'],30)
    run('production-helper-compile',base+['-parse-as-library',*[ROOT/p for p in m.HOST],*objects,'-o',OUT/'production-helper-compile-only'])
    print('production_helper_compile_pass; not_launched',flush=True)
if __name__=='__main__':main()
