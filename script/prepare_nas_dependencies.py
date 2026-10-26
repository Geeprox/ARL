#!/usr/bin/env python3
"""Prepare locked public NAS dependencies without pip/npm or credentials.
Default checks; --install downloads only checksum-pinned official artifacts.
"""
import argparse
import hashlib
import os
import stat
import json
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import tempfile
import urllib.parse
import urllib.request
import zipfile
if __package__:
    from .stage_nas_runtime import inventory
else:
    from stage_nas_runtime import inventory

ROOT=Path(__file__).resolve().parents[1]
CACHE=ROOT/'vendor/nas'
LIMIT=800*1024*1024

def download(row,target):
    url=row.get('url',row.get('source'));p=urllib.parse.urlsplit(url)
    if p.scheme!='https' or p.hostname not in {'github.com','files.pythonhosted.org'} or p.username or p.password:
        raise ValueError('official_dependency_source_required')
    request=urllib.request.Request(url,headers={'User-Agent':'ARL-dependencies'})
    digest=hashlib.sha256();count=0
    with urllib.request.urlopen(request,timeout=30) as response,target.open('xb') as stream:
        while True:
            raw=response.read(1024*1024)
            if not raw:break
            count+=len(raw)
            if count>LIMIT:raise ValueError('dependency_download_limit')
            digest.update(raw);stream.write(raw)
    if digest.hexdigest()!=row['sha256'] or row.get('bytes',count)!=count:raise ValueError('dependency_hash_mismatch')

def unpack_tar(path,target):
    target.mkdir(parents=True,exist_ok=True)
    with tarfile.open(path) as archive:
        members=archive.getmembers();names=set()
        if len(members)>100000 or sum(max(0,m.size) for m in members)>LIMIT:raise ValueError('archive_limit')
        for member in members:
            name=Path(member.name)
            if (name.is_absolute() or '..' in name.parts or "\\" in member.name or member.name in names
                or not (member.isfile() or member.isdir() or member.issym())):raise ValueError('unsafe_archive')
            names.add(member.name)
        # Links are created last so no archived regular file can traverse them.
        for member in [m for m in members if not m.issym()]:
            archive.extract(member,target)
        for member in [m for m in members if m.issym()]:
            destination=target/member.name;link=Path(member.linkname)
            if link.is_absolute() or "\\" in member.linkname:raise ValueError('unsafe_archive_link')
            resolved=(destination.parent/link).resolve()
            if not resolved.is_relative_to(target.resolve()):raise ValueError('unsafe_archive_link')
            for parent in destination.parents:
                if parent == target.parent:break
                if parent.is_symlink():raise ValueError('unsafe_archive_link')
            destination.symlink_to(member.linkname)
        inventory(target,links=True)

def unpack_wheel(path,target):
    with zipfile.ZipFile(path) as archive:
        members=archive.infolist();names=set()
        if len(members)>100000 or sum(m.file_size for m in members)>LIMIT:raise ValueError('wheel_limit')
        for member in members:
            name=Path(member.filename);mode=(member.external_attr>>16)&0xffff
            if (name.is_absolute() or '..' in name.parts or "\\" in member.filename or mode&0o170000==0o120000
                or member.filename in names):raise ValueError('unsafe_wheel')
            names.add(member.filename)
            if name.parts and '.data' in name.parts[0]:raise ValueError('unsupported_wheel_layout')
        archive.extractall(target)

def recovery():
    journal=CACHE/'PREPARE-RECOVERY.json'
    if not journal.exists():return False
    if journal.is_symlink():raise ValueError('unsafe_recovery_record')
    receipt=json.loads(journal.read_text())
    if set(receipt)!={'schema','python','licenses'} or receipt['schema']!=1:raise ValueError('invalid_recovery_record')
    paths=[(CACHE/'python',receipt['python']), (CACHE/'license-source/python/licenses',receipt['licenses'])]
    existing=[]
    for path,expected in paths:
        if path.exists():
            if path.is_symlink() or inventory(path,links=True)!=expected:raise ValueError('partial_cache_changed')
            existing.append(path)
    if len(existing)==2:
        temporary=CACHE/'CACHE.json.new';temporary.write_text(json.dumps(receipt,sort_keys=True,indent=2)+'\n');temporary.replace(CACHE/'CACHE.json');journal.unlink();return True
    for path in existing:
        # Only the just-prepared, inventory-proven partial is removed. Unknown
        # existing caches are kept for review; no user data lives in this tree.
        shutil.rmtree(path)
    license_root=CACHE/'license-source'
    if license_root.exists():
        for folder in [license_root/'python',license_root]:
            if folder.exists():folder.rmdir()
    journal.unlink();return False

def check():
    try:
        data=json.loads((CACHE/'CACHE.json').read_text())
        ready=data['python']==inventory(CACHE/'python',links=True) and data['licenses']==inventory(CACHE/'license-source/python/licenses')
    except Exception:ready=False
    return {'nas_cache_ready':ready,'downloads_performed':False,'credentials_read':False}

def prepare():
    if platform.system()!='Darwin' or platform.machine()!='arm64':raise ValueError('locked_runtime_requires_macos_arm64')
    if check()['nas_cache_ready']:return check()
    if recovery():return check()
    if (CACHE/'python').exists() or (CACHE/'license-source').exists():raise ValueError('existing_cache_needs_review')
    decompressor=shutil.which('zstd')
    if decompressor is None:raise ValueError('zstd_required_for_locked_license_archive')
    lock=json.loads((CACHE/'DEPENDENCIES.lock.json').read_text())
    for p in (CACHE,*CACHE.parents):
        if p.is_symlink():raise ValueError('dependency_destination_symlink')
    CACHE.mkdir(parents=True,exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='prepare-',dir=CACHE) as folder:
        stage=Path(folder);python=stage/'python.tar.gz';download(lock['python'],python);unpack_tar(python,stage/'runtime')
        licenses=stage/'licenses.tar.zst';download(lock['python_license_archive'],licenses)
        subprocess.run([decompressor,'-d','-q',str(licenses),'-o',str(stage/'licenses.tar')],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=90)
        unpack_tar(stage/'licenses.tar',stage/'license-source')
        site=stage/'runtime/python/lib/python3.12/site-packages'
        for row in lock['wheels']:
            archive=stage/row['filename'];download(row,archive);unpack_wheel(archive,site)
        python=stage/'runtime/python';license_source=stage/'license-source/python/licenses'
        if not python.is_dir() or not license_source.is_dir():raise ValueError('locked_archive_layout_changed')
        # Only this newly prepared version is moved; existing installations are never overwritten.
        receipt={'schema':1,'python':inventory(python,links=True),'licenses':inventory(license_source)}
        journal=CACHE/'PREPARE-RECOVERY.json'
        journal.write_text(json.dumps(receipt,sort_keys=True,indent=2)+'\n')
        python.rename(CACHE/'python');(stage/'license-source').rename(CACHE/'license-source')
        temporary=CACHE/'CACHE.json.new';temporary.write_text(json.dumps(receipt,sort_keys=True,indent=2)+'\n');temporary.replace(CACHE/'CACHE.json');journal.unlink()
    return {'nas_cache_ready':True,'downloads_performed':True,'credentials_read':False,'cache_sha256':hashlib.sha256((CACHE/'CACHE.json').read_bytes()).hexdigest()}

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--check',action='store_true');parser.add_argument('--install',action='store_true');args=parser.parse_args()
    try:
        result=prepare() if args.install else check();print(json.dumps(result));return 0 if result['nas_cache_ready'] else 2
    except Exception as e:
        code=str(e) if type(e) is ValueError else 'nas_dependency_prepare_failed'
        print(json.dumps({'error':code,'credentials_read':False,'retry':'Keep existing cache; correct the missing input and rerun.'}));return 1
if __name__=='__main__':raise SystemExit(main())
