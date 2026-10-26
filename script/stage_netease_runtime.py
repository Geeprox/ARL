"""Stage pinned official runtime inputs; never npm-install or fetch at app startup.

This build step covers NetEase dependencies. The final product also requires the
reviewed native credential broker, provider consumers and shared service catalog.
"""
import argparse
import base64
import hashlib
import io
import json
import os
from pathlib import Path
import stat
import tarfile

NODE_VERSION = 'v24.21.0'
NODE_ARCHIVE_SHA = 'bed7eea5325e1108f32ce5228ddd6a5f0f08a499ee42aa7442aea583702f6057'
NODE_IMAGE_SHA = 'e4b5a3af0e05c75de2eae013904145f40fe7fc2a6e6f17510128bf45cca4e79b'
CLI_IMAGE_SHA = '0d586c070cbe90a60132056a42ae8fd565b73294353faf4842cd10f9e634bb88'
LOCK_SHA = '98433f64aef77cde3321536f1331a544f1699b8491260e2f392f1a37cdecd191'
CLI_ARCHIVE_SHA = 'd9679fa2a2271ad025f2dd5a1110d1d5ea65c9c4b36b5ad70a755be75fe05bb9'
# Build/run are development tools published as runtime dependencies; neither is
# exposed by the bounded account/read capability set. Media binaries are not
# included: ARL exposes no playback, upload, conversion or arbitrary CLI command.
ROOT_DEPENDENCIES = ('@clack/prompts','commander','dotenv','ffprobe-static','fluent-ffmpeg',
                     'image-size','json-bigint','node-fetch','qrcode-terminal','semver','winston','zod')


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def check(value, reason):
    if not value:
        raise ValueError(reason)


def regular(path):
    for part in [path, *path.parents]:
        check(not part.is_symlink(), 'symlink input')
    info = path.stat()
    check(stat.S_ISREG(info.st_mode) and info.st_size <= 160*1024*1024, 'invalid input file')


def resolve_package(root, parent, name):
    check(not name.startswith(('.', '/')) and '..' not in name.split('/'), 'invalid dependency name')
    current = parent
    while current == root or root in current.parents:
        candidate = current/'node_modules'/name
        if (candidate/'package.json').is_file():
            return candidate
        if current == root:
            break
        current = current.parent
    raise ValueError('unresolved locked dependency: '+name)


def verified_tar_files(raw):
    result = {}
    with tarfile.open(fileobj=io.BytesIO(raw)) as archive:
        for member in archive:
            path = Path(member.name)
            check(not path.is_absolute() and '..' not in path.parts, 'unsafe package archive path')
            check(member.isdir() or member.isfile(), 'package archive link or device')
            if member.isdir():
                continue
            check(len(path.parts) > 1 and member.size <= 160*1024*1024, 'package archive boundary')
            relative = str(Path(*path.parts[1:]))
            check(relative not in result, 'duplicate archive member')
            result[relative] = archive.extractfile(member).read()
    return result


def stage(node_archive, cli_archive, cli_root, npm_cache, output, bridge=None):
    bridge = bridge or Path(__file__).resolve().parents[1]/'integrations/service_runtime/netease_bridge.cjs'
    regular(bridge)
    bridge_bytes = bridge.read_bytes()
    check(0 < len(bridge_bytes) <= 65536, 'bridge input boundary')
    regular(node_archive)
    regular(cli_archive)
    for directory in (cli_root, npm_cache, output.parent):
        for part in [directory, *directory.parents]:
            check(not part.is_symlink(), 'symlink directory input')
    node_archive, cli_root, output = node_archive.resolve(), cli_root.resolve(), output.absolute()
    check(digest(node_archive) == NODE_ARCHIVE_SHA, 'official Node archive mismatch')
    check(digest(cli_archive) == CLI_ARCHIVE_SHA, 'official CLI archive mismatch')
    official_files = verified_tar_files(cli_archive.read_bytes())
    for relative, content in official_files.items():
        regular(cli_root/relative)
        check((cli_root/relative).read_bytes() == content, 'official CLI file differs from archive')
    for rel in ['dist/index.js','package.json','package-lock.json']:
        regular(cli_root/rel)
    check(digest(cli_root/'dist/index.js') == CLI_IMAGE_SHA, 'official CLI mismatch')
    check(digest(cli_root/'package-lock.json') == LOCK_SHA, 'dependency lock mismatch')
    package = json.loads((cli_root/'package.json').read_bytes())
    check(package['name'] == '@music163/ncm-cli' and package['version'] == '0.1.7', 'official package identity')
    lock = json.loads((cli_root/'package-lock.json').read_bytes())['packages']
    selected = {}
    verified = {}
    pending = [resolve_package(cli_root, cli_root, name) for name in ROOT_DEPENDENCIES]
    while pending:
        directory = pending.pop()
        relative = str(directory.relative_to(cli_root))
        if relative in selected:
            continue
        regular(directory/'package.json')
        metadata = json.loads((directory/'package.json').read_bytes())
        entry = lock[relative]
        check(metadata['version'] == entry['version'] and entry.get('integrity','').startswith('sha512-'), 'locked dependency mismatch')
        expected = base64.b64decode(entry['integrity'].split('-',1)[1],validate=True)
        check(len(expected) == 64, 'invalid dependency SRI')
        hex_digest = expected.hex()
        blob = npm_cache/'_cacache/content-v2/sha512'/hex_digest[:2]/hex_digest[2:4]/hex_digest[4:]
        regular(blob)
        raw = blob.read_bytes()
        check(hashlib.sha512(raw).digest() == expected, 'dependency archive integrity mismatch')
        archive_files = verified_tar_files(raw)
        check(json.loads(archive_files['package.json'])['version'] == metadata['version'], 'archive version mismatch')
        check(archive_files['package.json'] == (directory/'package.json').read_bytes(), 'dependency metadata differs from verified archive')
        verified[relative] = archive_files
        selected[relative] = dict(name=metadata['name'],version=metadata['version'],integrity=entry['integrity'],license=metadata.get('license'))
        for name in metadata.get('dependencies', {}):
            pending.append(resolve_package(cli_root,directory,name))
    check(not output.exists(), 'preserve existing stage')
    output.mkdir(parents=True)

    def write(relative, content, executable=False):
        target = output/relative
        check(not target.exists(), 'duplicate output')
        target.parent.mkdir(parents=True,exist_ok=True)
        target.write_bytes(content)
        target.chmod(0o555 if executable else 0o444)

    with tarfile.open(node_archive) as archive:
        prefix = 'node-'+NODE_VERSION+'-darwin-arm64/'
        for original, target in [('bin/node','Runtime/node'),('LICENSE','Notices/Node-LICENSE')]:
            member = archive.getmember(prefix+original)
            check(member.isfile() and member.size <= 160*1024*1024, 'unexpected Node artifact')
            write(target,archive.extractfile(member).read(),original == 'bin/node')
    check(digest(output/'Runtime/node') == NODE_IMAGE_SHA, 'Node image mismatch')
    excluded = []
    write('Bridge/netease_bridge.cjs', bridge_bytes)

    for rel, content in sorted(official_files.items()):
        write('NetEase/'+rel,content)
    write('NetEase/package-lock.json',(cli_root/'package-lock.json').read_bytes())
    for relative in sorted(selected):
        for rel, content in sorted(verified[relative].items()):
            path = Path(rel)
            if selected[relative]['name'] == 'ffprobe-static' and path.parts[0] == 'bin':
                excluded.append(relative+'/'+rel)
                continue
            check(path.suffix not in {'.node','.pyc'}, 'unreviewed native or generated resource')
            write('NetEase/'+relative+'/'+rel,content)
    provenance = dict(schema_version=2,bridge_sha256=hashlib.sha256(bridge_bytes).hexdigest(),
                      bridge_protocol=1,credential_bridge_integrated=True,platform='darwin-arm64',node_version=NODE_VERSION,
                      node_archive_sha256=NODE_ARCHIVE_SHA,node_image_sha256=NODE_IMAGE_SHA,
                      cli_package='@music163/ncm-cli',cli_version='0.1.7',cli_image_sha256=CLI_IMAGE_SHA,
                      dependency_lock_sha256=LOCK_SHA,dependencies=selected,excluded_media_binaries=excluded,
                      every_dependency_archive_verified_against_lock_SRI=True,
                      excluded_top_level_build_tools=['build','run'],
                      user_npm_install_required=False,user_Homebrew_required=False,
                      supported_scope='Dependencies for bounded ARL account and read consumers; no general CLI, playback or upload.',
                      credential_consumer_integrated=True,credential_consumer_native_verified=False,
                      credential_consumer_evidence='source integrated; native chain not yet verified',full_product_acceptance=False)
    write('provenance.json',(json.dumps(provenance,indent=2,sort_keys=True)+'\n').encode())
    inventory = {str(p.relative_to(output)):dict(sha256=digest(p),bytes=p.stat().st_size,mode=stat.S_IMODE(p.stat().st_mode))
                 for p in sorted(output.rglob('*')) if p.is_file()}
    write('inventory.json',(json.dumps(inventory,indent=2,sort_keys=True)+'\n').encode())
    for p in sorted(output.rglob('*'),reverse=True):
        if p.is_dir():
            p.chmod(0o555)
    output.chmod(0o555)
    return dict(output=str(output),files=len(inventory)+1,dependency_packages=len(selected),inventory_sha256=digest(output/'inventory.json'),
                full_product_acceptance=False)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--node-archive',type=Path,required=True)
    parser.add_argument('--official-cli-root',type=Path,required=True)
    parser.add_argument('--cli-archive',type=Path,required=True)
    parser.add_argument('--npm-cache',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--bridge',type=Path,help='Reviewed source bridge; default is the adjacent source tree')
    args = parser.parse_args()
    print(json.dumps(stage(args.node_archive,args.cli_archive,args.official_cli_root,args.npm_cache,args.output,args.bridge)))
