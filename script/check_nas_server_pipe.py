"""Finite offline Swift→Python production pipe test. No user credentials/network."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess

ROOT=Path(__file__).resolve().parents[1]

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--output',required=True)
    parser.add_argument('--runtime-template',required=True)
    parser.add_argument('--compression-sdk',required=True)
    args=parser.parse_args()
    out=Path(args.output).resolve();support=Path(args.compression_sdk).resolve()
    assert out.is_relative_to(ROOT/'build') and not out.exists()
    out.mkdir(mode=0o700)
    sdk=subprocess.check_output(['/usr/bin/xcrun','--sdk','macosx','--show-sdk-path'],text=True).strip()
    compiler=subprocess.check_output(['/usr/bin/xcrun','--find','swiftc'],text=True).strip()
    recipe=json.loads((ROOT/'script/release_recipe.json').read_text())
    exe=out/'checks'
    command=[compiler,'-sdk',sdk,'-swift-version','6','-j','1','-suppress-warnings','-target','arm64-apple-macos14.0','-module-cache-path',str(out/'ModuleCache'),'-parse-as-library','-I',str(support),'-Xcc','-fmodule-map-file='+str(support/'FlyAICompression/module.modulemap')]
    command += [str(ROOT/x) for x in recipe['source_groups']['ARLCredentialOnboarding']]
    command += [str(ROOT/'tests/NASServerPipeTests.swift'),str(support/'FlyAICompression.o'),'-lz','-o',str(exe)]
    result=subprocess.run(command,capture_output=True,text=True,timeout=150)
    (out/'compile.log').write_text(result.stdout+result.stderr)
    if result.returncode:print(result.stdout+result.stderr);raise SystemExit(result.returncode)
    app=out/'Fixture.app';resources=app/'Contents/Resources/NASRuntime';(app/'Contents/MacOS').mkdir(parents=True)
    shutil.copy2(exe,app/'Contents/MacOS/checks')
    shutil.copytree(Path(args.runtime_template),resources)
    runtime=resources/'Runtime'
    for file in (ROOT/'integrations/nas/runtime').rglob('*'):
        if file.is_file() and '__pycache__' not in file.parts:
            target=runtime/file.relative_to(ROOT/'integrations/nas/runtime');target.parent.mkdir(parents=True,exist_ok=True)
            if target.exists():target.chmod(0o644)
            shutil.copyfile(file,target)
    shutil.copyfile(ROOT/'integrations/nas/runtime/nas_host.py',runtime/'nas_production_host.py')
    (runtime/'nas_host.py').chmod(0o644)
    shutil.copyfile(ROOT/'tests/fixtures/nas_server_pipe_host.py',runtime/'nas_host.py')
    inventory={}
    for file in resources.rglob('*'):
        if file.is_file() and file.name!='inventory.json':
            assert not file.is_symlink()
            inventory[str(file.relative_to(resources))]={'sha256':hashlib.sha256(file.read_bytes()).hexdigest(),'bytes':file.stat().st_size,'mode':stat.S_IMODE(file.stat().st_mode)}
    manifest=resources/'inventory.json';manifest.chmod(0o644);manifest.write_text(json.dumps(inventory,sort_keys=True))
    info={'CFBundleIdentifier':'local.arl.fixture.nas.server','CFBundleExecutable':'checks','CFBundlePackageType':'APPL','ARLNASRuntimeInventorySHA256':hashlib.sha256(manifest.read_bytes()).hexdigest()}
    (app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    result=subprocess.run([str(exe),str(app)],capture_output=True,text=True,timeout=45)
    (out/'run.log').write_text(result.stdout+result.stderr)
    print(result.stdout+result.stderr)
    (out/'result.json').write_text(json.dumps({'status':'PASS' if result.returncode==0 else 'FAILED','network':False,'keychain':False,'synthetic_smb_only':True,'returncode':result.returncode})+'\n')
    raise SystemExit(result.returncode)

if __name__=='__main__':main()
