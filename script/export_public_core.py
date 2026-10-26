#!/usr/bin/env python3
"""Build a no-history, allowlisted public core candidate; never publishes Git.
Private compatibility code, native author identities and local state are excluded.
"""
import argparse
import ast
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from script.privacy_audit import scan, audit_candidate
PRIVATE={'arl.private_compat','arl.compat_host'}

def module_path(name):
    base=ROOT/Path(*name.split('.'))
    return base.with_suffix('.py') if base.with_suffix('.py').is_file() else base/'__init__.py'

def closure():
    todo=['arl.host','arl.client','arl.__main__','arl.supervisor'];seen=set();paths=set()
    while todo:
        name=todo.pop()
        if name in seen or name in PRIVATE:continue
        seen.add(name);path=module_path(name)
        if not path.is_file():raise ValueError('unclosed_public_module')
        paths.add(path.relative_to(ROOT))
        parts=name.split('.')
        for count in range(1,len(parts)):
            init=ROOT/Path(*parts[:count])/'__init__.py'
            if init.is_file():paths.add(init.relative_to(ROOT))
        package=name.split('.') if path.name=='__init__.py' else name.split('.')[:-1]
        for node in ast.walk(ast.parse(path.read_text())):
            if isinstance(node,ast.ImportFrom) and node.level:
                prefix=package[:len(package)-node.level+1]
                target='.'.join(prefix+((node.module or '').split('.') if node.module else []))
                candidates=[target] if node.module else ['.'.join(prefix+[a.name]) for a in node.names]
                for candidate in candidates:
                    if candidate.startswith('arl.') and module_path(candidate).is_file() and candidate not in PRIVATE:todo.append(candidate)
    return paths

def package(output,license_file=None):
    output=output.resolve()
    if (ROOT/'build').resolve() not in output.parents or output.exists():raise ValueError('new_build_output_required')
    sources=closure()|{Path('docs/mio-tools.json'),Path('docs/service-connections.json'),Path('pyproject.toml')}
    for path in sources:
        if (ROOT/path).is_symlink():raise ValueError('source_symlink')
        if scan((ROOT/path).read_bytes(), str(path)):raise ValueError('private_reference_in_public_closure:'+str(path))
    output.mkdir(parents=True)
    try:
        for path in sorted(sources):
            destination=output/path;destination.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(ROOT/path,destination)
        if license_file:
            if license_file.is_symlink() or not license_file.is_file():raise ValueError('user_license_required')
            shutil.copyfile(license_file,output/'LICENSE')
        (output/'README.md').write_text('# ARL public core candidate\n\nGeneric identity, app sessions, queue and metadata runtime. Private adapters, personal configuration, native release resources and Git history are excluded. Default host grants no tools or models. Native GUI/source distribution is a separate pending release scope.\n\nRun `python3 -B -m arl.host --isolated-test --home ./state` in an owner-only isolated state directory. Never reuse production state for source checks.\n')
        inventory={str(p.relative_to(output)):hashlib.sha256(p.read_bytes()).hexdigest() for p in output.rglob('*') if p.is_file()}
        report={'schema':1,'profile':'public-core-zero-grants','private_compatibility_included':False,'git_history_included':False,
            'license_selected':license_file is not None,'publish_ready':False,'files':inventory}
        (output/'PUBLIC-MANIFEST.json').write_text(json.dumps(report,indent=2)+'\n')
        if not audit_candidate(output)['release_ready']:
            raise ValueError('private_material_in_public_candidate')
        # Candidate stays local; a license and final independent review are required before publishing.
        return report
    except Exception:
        shutil.rmtree(output);raise

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--output',required=True,type=Path);parser.add_argument('--license-file',type=Path)
    args=parser.parse_args()
    try:
        report=package(args.output,args.license_file);print(json.dumps({k:v for k,v in report.items() if k!='files'}));return 0
    except Exception as e:
        text=str(e) if type(e) is ValueError else 'public_export_failed';print(json.dumps({'error':text,'publish_ready':False}));return 1
if __name__=='__main__':raise SystemExit(main())
