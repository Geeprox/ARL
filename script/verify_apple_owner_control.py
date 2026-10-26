"""Same-source SDK/Control compilation and isolated local journal/lifecycle QA."""
import datetime,json,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/audit/apple-reminders-e2e-20261019.noindex'
records=[]
def run(name,argv,seconds=240):
    p=subprocess.run(list(map(str,argv)),cwd=ROOT,capture_output=True,timeout=seconds)
    (OUT/(name+'.log')).write_bytes(p.stdout+p.stderr)
    records.append(dict(name=name,argv=list(map(str,argv)),exit_code=p.returncode,log=name+'.log'))
    (OUT/'control-verification.json').write_text(json.dumps(records,indent=2)+'\n')
    print(name,p.returncode,flush=True)
    if p.returncode:print((p.stdout+p.stderr).decode()[-14000:]);raise SystemExit(p.returncode)
    if p.stdout:print(p.stdout.decode(),end='',flush=True)
def main():
    OUT.mkdir(parents=True,exist_ok=True);sdkout=OUT/'sdk.noindex';sdkout.mkdir(exist_ok=True)
    recipe=json.loads((ROOT/'script/release_recipe.json').read_text());groups=recipe['source_groups']
    sdk=subprocess.check_output(['/usr/bin/xcrun','--show-sdk-path'],text=True).strip()
    mod=sdkout/'FlyAICompression';mod.mkdir(exist_ok=True)
    (mod/'module.modulemap').write_text('module FlyAICompression { header "'+str(ROOT/recipe['compression_header'])+'" export * }\n')
    modulemap='-fmodule-map-file='+str(mod/'module.modulemap')
    base=['/usr/bin/xcrun','swiftc','-sdk',sdk,'-j','1','-swift-version','6','-target','arm64-apple-macos14.0','-module-cache-path',OUT/'ModuleCache']
    run('current-compression-compile',['/usr/bin/xcrun','clang','-isysroot',sdk,'-target','arm64-apple-macos14.0','-c',ROOT/recipe['compression_c'],'-I',(ROOT/recipe['compression_header']).parent,'-o',sdkout/'FlyAICompression.o'])
    for name in ['ARLCredentialOnboarding','ARLCredentialHostCore']:
        run('current-'+name+'-compile',base+['-parse-as-library','-whole-module-optimization','-emit-module','-emit-object','-I',sdkout,'-Xcc',modulemap,'-module-name',name,'-emit-module-path',sdkout/(name+'.swiftmodule'),*[ROOT/p for p in groups[name]],'-o',sdkout/(name+'.o')])
    run('current-sdk-archive',['/usr/bin/xcrun','ar','rcs',sdkout/'libARLCredentialHostCore.a',*[sdkout/(n+'.o') for n in ['ARLCredentialOnboarding','ARLCredentialHostCore','FlyAICompression']]])
    link=base+['-I',sdkout,'-L',sdkout,'-lARLCredentialHostCore','-lz','-Xcc',modulemap]
    run('same-source-production-Control-compile',link+['-parse-as-library',*[ROOT/p for p in groups['Control_complete_link']],'-o',OUT/'production-Control-compile-only'])
    run('journal-test-compile',link+['-parse-as-library',ROOT/'tests/AppleBusinessJournalTests.swift','-o',OUT/'apple-journal-tests'])
    fixture=OUT/('journal-fixture-'+datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%f'))
    run('journal-test-results',[OUT/'apple-journal-tests',fixture],30)
    # Reuse the already reviewed actual RuntimeStore lifecycle consumer test.
    source=(ROOT/'build/audit/apple-automatic-refresh-r2-20261019.noindex/RuntimeStoreAppleExitTests.swift').read_text()
    source=source.replace('build/audit/apple-nas-20261016/checks.noindex','build/audit/apple-reminders-e2e-20261019.noindex/lifecycle-fixtures.noindex')
    test=OUT/'RuntimeStoreAppleExitTests.swift';test.write_text(source)
    control=[ROOT/p for p in groups['Control_complete_link'] if not p.endswith('/ARLControlApp.swift')]
    run('same-source-Control-lifecycle-compile',link+['-D','ARL_LIFECYCLE_TEST','-parse-as-library',*control,test,'-o',OUT/'apple-lifecycle-tests'])
    run('same-source-Control-lifecycle-results',[OUT/'apple-lifecycle-tests',ROOT/'build/releases.noindex/ARL-0.1.2-88/package/ARL.authority.candidate.json'],45)
    print('current_production_control_compile_pass; not_launched; no_sign_install',flush=True)
if __name__=='__main__':main()
