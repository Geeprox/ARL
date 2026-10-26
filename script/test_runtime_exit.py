"""Focused actual RuntimeStore/management wiring test using an existing SDK.
No app install, UI automation, production state writes or credential admission.
"""
import argparse
import json
from pathlib import Path
import subprocess
import sys
ROOT=Path(__file__).resolve().parents[1]
def main():
    parser=argparse.ArgumentParser();parser.add_argument('--base',required=True,type=Path)
    args=parser.parse_args();base=args.base.absolute()
    if not base.is_relative_to(ROOT/'build'):raise ValueError('base must be a repo build')
    recipe_path=ROOT/'build/local-config/release_recipe.json'
    if not recipe_path.exists():recipe_path=ROOT/'script/release_recipe.json'
    recipe=json.loads(recipe_path.read_text());sdk=base/'work/sdk';output=ROOT/'build/audit/runtime-store-exit-tests'
    output.parent.mkdir(parents=True,exist_ok=True)
    argv=['/usr/bin/xcrun','swiftc','-j','1','-swift-version','6','-suppress-warnings','-D','ARL_LIFECYCLE_TEST','-parse-as-library','-I',str(sdk),'-L',str(sdk),'-lARLCredentialHostCore','-lz','-Xcc','-fmodule-map-file='+str(sdk/'FlyAICompression/module.modulemap'),'-module-cache-path',str(ROOT/'build/cache/ModuleCache')]
    argv += [str(ROOT/r) for r in recipe['source_groups']['Control_complete_link'] if r!='macOS/ARLControl/App/ARLControlApp.swift']+[str(ROOT/'tests/RuntimeStoreExitTests.swift'),'-o',str(output)]
    built=subprocess.run(argv,capture_output=True,text=True,timeout=180)
    (ROOT/'build/audit/runtime-store-exit-compile.log').write_text(built.stdout+built.stderr)
    if built.returncode:print('runtime_store_test_compile_failed',file=sys.stderr);return built.returncode
    tested=subprocess.run([str(output),str(base/'package/ARL.authority.candidate.json')],capture_output=True,text=True,timeout=25)
    (ROOT/'build/audit/runtime-store-exit-tests.log').write_text(tested.stdout+tested.stderr)
    print(tested.stdout,end='');return tested.returncode
if __name__=='__main__':raise SystemExit(main())
