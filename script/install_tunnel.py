#!/usr/bin/env python3
"""Verified official client install + user-owned loopback MCP profile.
Default checks only; never creates accounts, tunnels, grants or launch agents.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shlex
import sys
import shutil
import tempfile
import urllib.parse
import urllib.request
import zipfile

ROOT=Path(__file__).resolve().parents[1]
RELEASE_API='https://api.github.com/repos/openai/tunnel-client/releases/latest'
PREFIX=ROOT/'build/dependencies/tunnel-client'
LIMIT=180*1024*1024

def fetch(url,limit=LIMIT):
    parsed=urllib.parse.urlsplit(url)
    if parsed.scheme!='https' or parsed.username or parsed.password or parsed.hostname not in {'api.github.com','github.com','raw.githubusercontent.com'}:
        raise ValueError('official_source_required')
    request=urllib.request.Request(url,headers={'User-Agent':'ARL-dependency-check','Accept':'application/vnd.github+json'})
    with urllib.request.urlopen(request,timeout=30) as response:
        raw=response.read(limit+1)
    if len(raw)>limit:raise ValueError('download_limit')
    return raw

def release():
    data=json.loads(fetch(RELEASE_API,2*1024*1024))
    tag=data['tag_name'];system={'Darwin':'darwin','Linux':'linux','Windows':'windows'}.get(platform.system())
    arch={'arm64':'arm64','aarch64':'arm64','x86_64':'amd64','AMD64':'amd64'}.get(platform.machine())
    if not re.fullmatch(r'v[0-9]+(?:\.[0-9]+){2}',tag) or not system or not arch:raise ValueError('unsupported_platform')
    name='tunnel-client-'+tag+'-'+system+'-'+arch+'.zip'
    assets={a['name']:a for a in data['assets']}
    if name not in assets or 'SHA256SUMS.txt' not in assets:raise ValueError('release_assets_missing')
    checksums=fetch(assets['SHA256SUMS.txt']['browser_download_url'],2*1024*1024).decode()
    matches=[line.split()[0] for line in checksums.splitlines() if len(line.split())==2 and line.split()[1].lstrip('*')==name]
    if len(matches)!=1 or not re.fullmatch('[a-f0-9]{64}',matches[0]):raise ValueError('checksum_missing')
    return {'version':tag,'name':name,'url':assets[name]['browser_download_url'],'sha256':matches[0]}

def safe_extract(archive,destination):
    with zipfile.ZipFile(archive) as z:
        if len(z.infolist())>2000 or sum(i.file_size for i in z.infolist())>LIMIT:raise ValueError('archive_limit')
        names=set()
        for item in z.infolist():
            path=Path(item.filename);mode=(item.external_attr>>16)&0xffff
            if path.is_absolute() or '..' in path.parts or '\\' in item.filename or item.filename in names or mode&0o170000==0o120000:raise ValueError('unsafe_archive')
            names.add(item.filename)
        z.extractall(destination)

def installed():
    for path in (PREFIX, *PREFIX.parents):
        if path.is_symlink():raise ValueError("unsafe_destination")
    record=PREFIX/'installation.json'
    if record.is_symlink() or not record.is_file():return None
    value=json.loads(record.read_text())
    if not re.fullmatch(r'v[0-9]+(?:\.[0-9]+){2}',value.get('version','')):raise ValueError('invalid_install_record')
    binary=PREFIX/value['version']/'tunnel-client'
    for path in (binary,*binary.parents):
        if path.is_symlink():raise ValueError('unsafe_destination')
    if binary.is_symlink() or not binary.is_file() or hashlib.sha256(binary.read_bytes()).hexdigest()!=value['binary_sha256']:
        raise ValueError('installed_client_changed')
    return binary,value

def install(info):
    for p in (PREFIX,*PREFIX.parents):
        if p.is_symlink():raise ValueError('unsafe_destination')
    old=installed()
    if old and old[1]['archive_sha256']==info['sha256']:return old[0]
    PREFIX.mkdir(parents=True,exist_ok=True,mode=0o700)
    destination=PREFIX/info['version']
    if destination.exists():
        saved=destination/'.arl-installation.json'
        if not saved.is_file() or saved.is_symlink():raise ValueError('unverified_existing_version')
        receipt=json.loads(saved.read_text());binary=destination/'tunnel-client'
        if receipt.get('archive_sha256')!=info['sha256'] or not binary.is_file() or binary.is_symlink() or hashlib.sha256(binary.read_bytes()).hexdigest()!=receipt.get('binary_sha256'):
            raise ValueError('unverified_existing_version')
        record=PREFIX/'installation.json';record.write_text(json.dumps(receipt)+'\n');record.chmod(0o600)
        return binary
    with tempfile.TemporaryDirectory(prefix='stage-',dir=PREFIX) as folder:
        stage=Path(folder);archive=stage/'client.zip';raw=fetch(info['url'])
        if hashlib.sha256(raw).hexdigest()!=info['sha256']:raise ValueError('download_hash_mismatch')
        archive.write_bytes(raw);safe_extract(archive,stage/'contents')
        matches=list((stage/'contents').rglob('tunnel-client'))
        if len(matches)!=1 or not matches[0].is_file():raise ValueError('client_binary_missing')
        source=matches[0].parent
        binary=source/'tunnel-client';binary.chmod(0o700)
        receipt={'version':info['version'],'archive_sha256':info['sha256'],'binary_sha256':hashlib.sha256(binary.read_bytes()).hexdigest()}
        (source/'.arl-installation.json').write_text(json.dumps(receipt)+'\n')
        source.rename(destination)
        binary=destination/'tunnel-client'
        record=PREFIX/'installation.json';temporary=PREFIX/'installation.json.new'
        temporary.write_text(json.dumps(receipt)+'\n');temporary.chmod(0o600);temporary.replace(record)
    return binary

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--check',action='store_true');parser.add_argument('--online',action='store_true');parser.add_argument('--install',action='store_true')
    args=parser.parse_args()
    try:
        current=installed();report={'dependency_ready':current is not None,'account_or_grants_changed':False,'existing_mio_modified':False,'runtime_started':False}
        if args.online or args.install:
            info=release();report['available_version']=info['version']
            if args.install:install(info);report.update(dependency_ready=True,download_verified=True)
        print(json.dumps(report));return 0
    except Exception as e:
        code=str(e) if type(e) is ValueError and re.fullmatch('[a-z_]+',str(e)) else 'tunnel_dependency_prepare_failed'
        print(json.dumps({'error':code,'existing_mio_modified':False,'runtime_started':False}));return 1
if __name__=='__main__':raise SystemExit(main())
