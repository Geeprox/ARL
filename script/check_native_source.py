#!/usr/bin/env python3
"""Compile the complete native source without signing, installing or launching.
No private recipe, resource cache, account, credential store or production state.
"""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import subprocess
import uuid

ROOT=Path(__file__).resolve().parents[1]

def main():
 parser=argparse.ArgumentParser();parser.add_argument('--output',type=Path);args=parser.parse_args()
 output=(args.output or ROOT/'build'/('source-check-'+datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S')+'-'+uuid.uuid4().hex[:8])).absolute()
 if (ROOT/'build').absolute() not in output.parents or output.exists() or any(p.is_symlink() for p in (output,*output.parents)):
  raise ValueError('new_output_under_build_required')
 output.mkdir(parents=True)
 recipe=json.loads((ROOT/'script/release_recipe.json').read_text())
 sdk=subprocess.check_output(['xcrun','--show-sdk-path'],text=True).strip()
 header=ROOT/recipe['compression_header'];module=output/'FlyAICompression';module.mkdir()
 (module/'module.modulemap').write_text('module FlyAICompression { header "'+str(header)+'" export * }\n')
 common=['xcrun','swiftc','-sdk',sdk,'-j','1','-swift-version','6','-enable-testing','-target',recipe['product']['target'],'-module-cache-path',str(output/'ModuleCache')]
 records=[]
 def run(name,argv,sources=()):
  before={p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in sources}
  process=subprocess.run(argv,capture_output=True,timeout=240)
  (output/(name+'.log')).write_bytes(process.stdout+process.stderr)
  stable=all(hashlib.sha256((ROOT/p).read_bytes()).hexdigest()==h for p,h in before.items())
  records.append({'step':name,'exit_code':process.returncode,'inputs_stable':stable,'source_inputs':before})
  (output/'results.json').write_text(json.dumps({'source_compile_only':True,'installed':False,'launched':False,'steps':records},indent=2)+'\n')
  print(name,process.returncode,'stable',stable,flush=True)
  if process.returncode or not stable:
   # CI must expose compiler diagnostics even when its ephemeral workspace is gone.
   diagnostic=(process.stdout+process.stderr).decode('utf-8',errors='replace')
   if len(diagnostic)>12000:diagnostic=diagnostic[:6000]+'\n...\n'+diagnostic[-6000:]
   print(diagnostic,flush=True)
   raise SystemExit(1)
 run('compression',['xcrun','clang','-isysroot',sdk,'-target',recipe['product']['target'],'-c',str(ROOT/recipe['compression_c']),'-I',str(header.parent),'-o',str(output/'FlyAICompression.o')],[recipe['compression_c'],recipe['compression_header']])
 for name in ('ARLCredentialOnboarding','ARLCredentialHostCore'):
  sources=recipe['source_groups'][name]
  run(name,common+['-parse-as-library','-whole-module-optimization','-emit-module','-emit-object','-I',str(output),'-Xcc','-fmodule-map-file='+str(module/'module.modulemap'),'-module-name',name,'-emit-module-path',str(output/(name+'.swiftmodule')),*[str(ROOT/p) for p in sources],'-o',str(output/(name+'.o'))],sources)
 run('archive',['xcrun','ar','rcs',str(output/'libARLCredentialHostCore.a'),*[str(output/(n+'.o')) for n in ('ARLCredentialOnboarding','ARLCredentialHostCore','FlyAICompression')]])
 sources=recipe['source_groups']['Control_complete_link']
 run('Control_complete_link',common+['-I',str(output),'-L',str(output),'-lARLCredentialHostCore','-lz','-Xcc','-fmodule-map-file='+str(module/'module.modulemap'),*[str(ROOT/p) for p in sources],'-o',str(output/'Control-compile-only')],sources)
 print('Native source compilation passed. No application was signed, installed or launched.')
if __name__=='__main__':main()
