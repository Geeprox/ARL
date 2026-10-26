"""Stage reviewed local-only collector and pinned offline image decoder."""
from pathlib import Path
import hashlib,json,shutil,subprocess,os
ROOT=Path(__file__).resolve().parents[1]
MAGICS={b'\xcf\xfa\xed\xfe',b'\xce\xfa\xed\xfe',b'\xca\xfe\xba\xbe',b'\xca\xfe\xba\xbf'}
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def inputs():
    return ['script/stage_moments_runtime.py','vendor/moments/PILLOW.lock.json',*sorted(str(p.relative_to(ROOT)) for p in (ROOT/'integrations/moments').rglob('*') if p.is_file() and '__pycache__' not in p.parts and p.suffix!='.pyc')]
def preflight():
    pin=json.loads((ROOT/'vendor/moments/PILLOW.lock.json').read_text())
    folder=ROOT/'vendor/moments/pillow'
    actual={str(p.relative_to(folder)):sha(p) for p in folder.rglob('*') if p.is_file()}
    if actual!=pin['files'] or any(p.is_symlink() for p in folder.rglob('*')):raise ValueError('Moments Pillow cache changed')
def stage(app,identity,build_only):
    preflight();dest=app/'Contents/Resources/MomentsRuntime'
    shutil.copytree(ROOT/'integrations/moments',dest,ignore=shutil.ignore_patterns('__pycache__','*.pyc','upstream-manifest.json'))
    shutil.copytree(ROOT/'vendor/moments/pillow',dest/'pillow')
    signed=[]
    if not build_only:
        for p in sorted(dest.rglob('*')):
            if p.is_file() and p.read_bytes()[:4] in MAGICS:
                result=subprocess.run(['/usr/bin/codesign','--force','--options','runtime','--timestamp=none','--sign',identity,str(p)],capture_output=True,timeout=30,env={**os.environ,'PATH':'/usr/bin:/bin'})
                if result.returncode:raise ValueError('Moments decoder signing failed')
                signed.append(str(p.relative_to(dest)))
    rows={str(p.relative_to(dest)):sha(p) for p in dest.rglob('*') if p.is_file()}
    (dest/'inventory.json').write_text(json.dumps({'schema':1,'files':rows,'source_inputs':{r:sha(ROOT/r) for r in inputs()},'native_owner':'local.arl.control','account_protocol_enabled':False,'finder_downloads_enabled':False},sort_keys=True,indent=2)+'\n')
    for p in [dest,*dest.rglob('*')]:p.chmod(p.stat().st_mode & ~0o222)
    return {'files':len(rows),'decoder_native_files_signed':len(signed),'inventory_sha256':sha(dest/'inventory.json')}
