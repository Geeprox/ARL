"""Focused, offline checks of migrated source. Outputs stay in this repository."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT/'build/source-migration-20261011'
ENV = {'PATH':'/usr/bin:/bin','TMPDIR':str(OUT/'tmp'),'HOME':str(OUT/'home'),
       'LANG':'C','LC_ALL':'C','PYTHONDONTWRITEBYTECODE':'1'}
def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def run(name, argv, seconds, cwd=ROOT):
    start = time.monotonic()
    process = subprocess.Popen([str(x) for x in argv], cwd=cwd, env=ENV,
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        start_new_session=True)
    timed_out = False
    try:
        stdout, stderr = process.communicate(timeout=seconds)
    except subprocess.TimeoutExpired:
        timed_out = True
        os.killpg(process.pid, signal.SIGTERM)
        try:
            stdout, stderr = process.communicate(timeout=2)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            stdout, stderr = process.communicate()
    for suffix, data in [('stdout',stdout),('stderr',stderr)]:
        (OUT/(name+'.'+suffix)).write_bytes(data[-65536:])
    try:
        os.killpg(process.pid, 0)
        absent = False
    except ProcessLookupError:
        absent = True
    row = {'name':name,'argv':[str(x) for x in argv], 'returncode':process.returncode,
           'seconds':round(time.monotonic()-start,3), 'timeout':timed_out,
           'direct_child_reaped':process.poll() is not None, 'process_group_absent':absent}
    try:
        row['result'] = json.loads(stdout)
    except (ValueError, UnicodeDecodeError):
        row['stdout_summary'] = stdout.decode(errors='replace')[-1500:]
    if process.returncode:
        row['stderr_summary'] = stderr.decode(errors='replace')[-2000:]
    return row

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument('--native',action='store_true')
    modes.add_argument('--build-checks',action='store_true')
    args = parser.parse_args()
    for name in ('tmp','home','fixture-cwd/build/host-contract-v2'):
        (OUT/name).mkdir(parents=True,exist_ok=True)
    results = []
    pins = {}
    with (ROOT/'build/release.lock').open('a') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        if args.native:
            plan = json.loads((ROOT/'script/source_migration_checks.json').read_text())
            cache = ROOT/'build/cache/ModuleCache'
            cache.mkdir(parents=True,exist_ok=True)
            swift = '/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc'
            sdk = '/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk'
            common = [swift,'-sdk',sdk,'-j','1','-swift-version','6',
                      '-target','arm64-apple-macos14.0','-module-cache-path',cache,'-parse-as-library']
            for item in plan:
                for relative in item.get('sources',[]):
                    pins[relative] = digest(ROOT/relative)
            (OUT/'NATIVE-INPUTS.json').write_text(json.dumps(pins,indent=2)+'\n')
            steps = []
            for item in plan:
                if 'sources' in item:
                    argv = common + item.get('flags',[]) + [ROOT/p for p in item['sources']]
                    if item.get('binary'):
                        argv += ['-o',OUT/item['binary']]
                    steps.append((item['name'],argv,item['seconds'],ROOT))
                else:
                    steps.append((item['name'],[OUT/item['binary']]+[ROOT/p for p in item.get('arguments',[])],
                                  item['seconds'],OUT/'fixture-cwd'))
        else:
            runtime = ROOT/'vendor/release/ARL.resources/Contents/Resources/ServiceRuntime'
            steps = [
                ('array-combined-r2',[runtime/'Runtime/node',ROOT/'tests/NetEaseAppendArrayTests.cjs',
                    ROOT/'integrations/service_runtime/netease_bridge.cjs',runtime],45,ROOT),
                ('build-focused',['/usr/bin/python3','-B','-m','unittest',
                    'tests.test_build_release.ReleaseTests.test_output_rejects_external_directory',
                    'tests.test_build_release.ReleaseTests.test_plan_does_not_run_native',
                    'tests.test_build_release.ReleaseTests.test_real_offline_resources_are_rebound_without_changing_helper_or_vendor'],30,ROOT),
                ('build-check',['/bin/bash',ROOT/'build.sh','--check','--build-only'],30,ROOT)]
        if args.build_checks:
            steps = [step for step in steps if step[0] != 'array-combined-r2']
        try:
            for name,argv,seconds,cwd in steps:
                row = run(name,argv,seconds,cwd)
                results.append(row)
                print(json.dumps({'step':name,'returncode':row['returncode'],'seconds':row['seconds']}),flush=True)
                if row['returncode'] != 0 or row['timeout'] or not row['process_group_absent']:
                    break
        finally:
            stable = all(digest(ROOT/p)==pin for p,pin in pins.items())
            result = {'status':'PASS' if len(results)==len(steps) and all(
                x['returncode']==0 and not x['timeout'] and x['process_group_absent'] for x in results) and stable else 'FAIL',
                'input_hashes_stable':stable,'steps':results,'real_provider_calls':0,
                'real_credential_reads':0,'signed':False,'installed':False}
            (OUT/('NATIVE-RESULT.json' if args.native else 'BUILD-RESULT-r3.json' if args.build_checks else 'LIGHT-RESULT-r2.json')).write_text(
                json.dumps(result,ensure_ascii=False,indent=2)+'\n')
            print(result['status'],flush=True)
    return 0 if result['status']=='PASS' else 1

if __name__=='__main__':
    raise SystemExit(main())
