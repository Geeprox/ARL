#!/usr/bin/env python3
"""Clean-clone dependency checks and isolated metadata smoke; no account setup."""
import argparse
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile
import threading

ROOT=Path(__file__).resolve().parents[1]

def checks(native=False):
    required={'python_3_9':sys.version_info>=(3,9),'source':(ROOT/'arl/service.py').is_file()}
    optional={'codex_cli':shutil.which('codex') is not None}
    if native:
        required.update(macos_14=platform.system()=='Darwin' and int(platform.mac_ver()[0].split('.')[0])>=14,
                        arm64=platform.machine()=='arm64',xcode=shutil.which('xcrun') is not None,
                        release_resources=(ROOT/'vendor/release/cache.json').is_file(),
                        nas_runtime=(ROOT/'vendor/nas/python').is_dir())
        if required['xcode']:
            result=subprocess.run(['xcrun','swiftc','--version'],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=10)
            required['swift_6']=result.returncode==0 and b'Swift version 6.' in result.stdout
        # A toolchain and two cache directories do not prove that the current
        # recipe's helper templates, source pins and offline inputs are usable.
        if all(required.values()):
            result=subprocess.run([sys.executable,'-B',str(ROOT/'script/build_release.py'),
                                   '--check','--build-only'], stdout=subprocess.DEVNULL,
                                  stderr=subprocess.DEVNULL, timeout=60)
            required['native_build_inputs']=result.returncode==0
    return {'required':required,'optional':optional,'ready':all(required.values()),
            'native_public_release_assets':'not_published','accounts':'user_interaction_required','mio':'optional_separate_setup'}

def prepare():
    path=ROOT/'build/dev-state'
    if any(p.is_symlink() for p in (path,*path.parents)) or path.exists() and (not path.is_dir() or path.stat().st_uid!=os.geteuid() or path.stat().st_mode&0o077):
        raise ValueError('unsafe_dev_state')
    path.mkdir(parents=True,exist_ok=True,mode=0o700)
    return 'isolated_state_prepared'

def smoke():
    # Explicit zero-grant profile avoids all product, credentials and real provider setup.
    from arl.contracts import AppPolicy
    from arl.service import Runtime
    from arl.client import Client
    policy={'settings':AppPolicy(frozenset(),frozenset(),0,0,0,methods=frozenset({'ready','settings.snapshot'}),public_metadata=True)}
    with tempfile.TemporaryDirectory(prefix='arl-check-') as directory:
        runtime=Runtime(Path(directory),policies=policy,execute_jobs=False,identity_verifier=lambda c,a:None,providers={})
        thread=threading.Thread(target=runtime.run);thread.start()
        try:
            client=Client(Path(directory),'settings');client.connect(timeout=5)
            state=client.rpc('settings.snapshot')
            if state['runtime']['task_execution_enabled'] or any(a['connection']=='connected' for a in state['apps']):
                raise ValueError('unexpected_authority')
            return 'isolated_metadata_rpc_pass'
        finally:
            runtime.shutdown();thread.join(10)
            if thread.is_alive():raise ValueError('cleanup_pending')

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--check',action='store_true');parser.add_argument('--native',action='store_true')
    parser.add_argument('--prepare',action='store_true');parser.add_argument('--smoke',action='store_true');args=parser.parse_args()
    sys.path.insert(0,str(ROOT))
    try:
        report=checks(args.native)
        if not report['ready']:print(json.dumps(report));return 2
        if args.prepare:report['prepare']=prepare()
        if args.smoke:report['smoke']=smoke()
        print(json.dumps(report));return 0
    except Exception:
        print(json.dumps({'ready':False,'error':'bootstrap_check_failed','retry':'Fix missing inputs, rerun the same command; no installed state was changed.'}));return 1
if __name__=='__main__':raise SystemExit(main())
