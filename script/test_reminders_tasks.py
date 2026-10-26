"""Compile the production reminder modules and task host; use synthetic storage only.
No app bundle, signing, launch, EventKit call, system prompt or production data access.
"""
import datetime
import importlib.util
import json
from pathlib import Path
import subprocess
ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT/'build/audit/reminders-task-20261017'

def run(name, argv, timeout=180):
    result = subprocess.run(list(map(str, argv)), cwd=ROOT, capture_output=True, timeout=timeout)
    (OUT/(name+'.log')).write_bytes(result.stdout+result.stderr)
    if result.returncode:
        print(json.dumps({'stage':name,'status':'failed','log':str((OUT/(name+'.log')).relative_to(ROOT))}))
        raise SystemExit(result.returncode)
    return result

def main():
    OUT.mkdir(parents=True, exist_ok=True)
    spec=importlib.util.spec_from_file_location('reminders_build',ROOT/'integrations/reminders_v3/build_static.py')
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    sdk=subprocess.check_output(['/usr/bin/xcrun','--show-sdk-path'],text=True).strip()
    base=['/usr/bin/xcrun','swiftc','-sdk',sdk,'-j','1','-swift-version','6','-target','arm64-apple-macos14.0','-module-cache-path',OUT/'ModuleCache','-I',OUT]
    for name,sources in [('ARLRemindersCore',module.CORE),('ARLRemindersEventKit',module.EVENTKIT)]:
        run(name,base+['-parse-as-library','-whole-module-optimization','-emit-module','-emit-object','-module-name',name,'-emit-module-path',OUT/(name+'.swiftmodule'),*[ROOT/p for p in sources],'-o',OUT/(name+'.o')])
    sources=[ROOT/p for p in module.HOST if not p.endswith('PermissionBrokerMain.swift')]
    sources += [ROOT/'integrations/reminders_v3/FirstSliceFixtureBackend.swift',ROOT/'integrations/reminders_v3/adapter_source/Fixtures/FixtureRepository.swift',ROOT/'tests/RemindersTaskTests.swift',ROOT/'macOS/ARLControl/Services/RemindersNativeClient.swift']
    objects=[OUT/'ARLRemindersCore.o',OUT/'ARLRemindersEventKit.o']
    run('task-compile',base+['-D','REMINDERS_FIRST_SLICE_FIXTURE','-parse-as-library',*sources,*objects,'-o',OUT/'tasks-test'])
    fixture=OUT/('fixture-'+datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%f'))
    result=run('task-results',[OUT/'tasks-test',fixture],30)
    print(result.stdout.decode(),end='')
    history_sources=[p for p in sources if p.name!='RemindersTaskTests.swift']+[ROOT/'tests/RemindersHistoryCompatibilityTests.swift']
    run('history-compile',base+['-D','REMINDERS_FIRST_SLICE_FIXTURE','-parse-as-library',*history_sources,*objects,'-o',OUT/'history-test'])
    history_fixture=OUT/('history-fixture-'+datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%f'))
    history=run('history-results',[OUT/'history-test',history_fixture],30)
    print(history.stdout.decode(),end='')
    production=[ROOT/p for p in module.HOST]
    run('production-helper-compile',base+['-parse-as-library',*production,*objects,'-o',OUT/'production-helper-compile-only'])
    print('production_helper_compile_pass; not_launched')
if __name__=='__main__':main()
