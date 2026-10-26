"""Verify and seal offline service runtime into a new unsigned Control candidate.

Call before outer app signing. No compilation, signing, launch, network or repair.
The reviewed inventory digest is mandatory; verifying a self-described inventory
without an independent caller pin would not authenticate the resource inputs.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import stat

NODE_SHA = 'e4b5a3af0e05c75de2eae013904145f40fe7fc2a6e6f17510128bf45cca4e79b'
CLI_SHA = '0d586c070cbe90a60132056a42ae8fd565b73294353faf4842cd10f9e634bb88'
PUBLICATION_BUDGET = {'manifest_bytes': 1024*1024, 'resource_bytes': 256*1024*1024, 'files': 3000}
CONTROL_IDS = {'local.arl.control', 'local.arl.control.future.oct3'}


def require(value, reason):
    if not value:
        raise ValueError(reason)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def no_links(path):
    for item in (path, *path.parents):
        require(not item.is_symlink(), 'symlink_boundary')


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, 'duplicate_json_key')
        result[key] = value
    return result


def verified_inventory(stage, expected_sha256):
    stage = Path(stage).absolute()
    no_links(stage)
    require(stage.is_dir(), 'missing_runtime')
    require(len(expected_sha256) == 64 and all(c in '0123456789abcdef' for c in expected_sha256), 'invalid_inventory_pin')
    manifest = stage/'inventory.json'
    no_links(manifest)
    require(manifest.is_file() and 0 < manifest.stat().st_size <= PUBLICATION_BUDGET['manifest_bytes'], 'manifest_boundary')
    require(digest(manifest) == expected_sha256, 'runtime_inventory_pin_mismatch')
    inventory = json.loads(manifest.read_bytes(), object_pairs_hook=unique_object)
    require(isinstance(inventory, dict) and 3 <= len(inventory) <= PUBLICATION_BUDGET['files'], 'inventory_boundary')
    for name, row in inventory.items():
        require(isinstance(name, str) and not name.startswith('/') and all(p not in ('', '.', '..') for p in name.split('/')), 'invalid_resource_path')
        require(isinstance(row, dict) and set(row) == {'sha256', 'bytes', 'mode'}, 'invalid_resource_entry')
        require(type(row['bytes']) is int and row['bytes'] >= 0 and type(row['mode']) is int and 0 <= row['mode'] <= 0o777 and not row['mode'] & 0o222, 'invalid_resource_size_mode')
        require(isinstance(row['sha256'], str) and len(row['sha256']) == 64 and all(c in '0123456789abcdef' for c in row['sha256']), 'invalid_resource_hash')
    require(sum(row['bytes'] for row in inventory.values()) <= PUBLICATION_BUDGET['resource_bytes'], 'publication_resource_budget')
    actual = {}
    for path in sorted(stage.rglob('*')):
        info = path.lstat()
        require(stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode), 'runtime_entry_boundary')
        require(not info.st_mode & 0o222, 'runtime_writable')
        if stat.S_ISREG(info.st_mode):
            require(info.st_size <= PUBLICATION_BUDGET['resource_bytes'], 'runtime_file_limit')
            actual[str(path.relative_to(stage))] = dict(sha256=digest(path),bytes=info.st_size,mode=stat.S_IMODE(info.st_mode))
    require(not stage.stat().st_mode & 0o222, 'runtime_root_writable')
    actual.pop('inventory.json')
    require(actual == inventory, 'runtime_inventory_mismatch')
    for name, pin in [('Runtime/node', NODE_SHA), ('NetEase/dist/index.js', CLI_SHA)]:
        require(inventory.get(name, {}).get('sha256') == pin, 'official_runtime_image_changed')
    require(inventory['Runtime/node']['mode'] == 0o555, 'runtime_executable_mode')
    require('Bridge/netease_bridge.cjs' in inventory and inventory['Bridge/netease_bridge.cjs']['bytes'] > 0, 'bridge_missing_or_empty')
    provenance = json.loads((stage/'provenance.json').read_bytes(), object_pairs_hook=unique_object)
    require(provenance.get('bridge_sha256') == inventory['Bridge/netease_bridge.cjs']['sha256'], 'bridge_provenance_mismatch')
    require(len(provenance.get('dependencies', {})) == 56 and provenance.get('every_dependency_archive_verified_against_lock_SRI') is True, 'dependency_provenance_mismatch')
    return inventory


def populate(stage, app, expected_inventory_sha256):
    stage, app = Path(stage).absolute(), Path(app).absolute()
    no_links(app)
    require(app.suffix == '.app' and app.is_dir(), 'candidate_bundle_required')
    require(not any(p.name == 'Applications' for p in app.parents), 'installed_bundle_not_a_packaging_target')
    require(not (app/'Contents/_CodeSignature').exists(), 'signed_bundle_not_a_packaging_target')
    info_path = app/'Contents/Info.plist'
    no_links(info_path)
    info = plistlib.loads(info_path.read_bytes())
    require(info.get('CFBundleIdentifier') in CONTROL_IDS, 'wrong_control_bundle')
    inventory = verified_inventory(stage, expected_inventory_sha256)
    target = app/'Contents/Resources/ServiceRuntime'
    no_links(target)
    require(not target.exists(), 'existing_resource_stage')
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(stage, target, copy_function=shutil.copy2)
    require(verified_inventory(target, expected_inventory_sha256) == inventory, 'runtime_copy_mismatch')
    manifest_bytes = (target/'inventory.json').stat().st_size
    info['ARLServiceRuntimeManifestSHA256'] = expected_inventory_sha256
    info['ARLServiceRuntimeManifestBytes'] = manifest_bytes
    info_path.write_bytes(plistlib.dumps(info))
    return dict(runtime_inventory_sha256=expected_inventory_sha256, runtime_inventory_bytes=manifest_bytes, resource_files=len(inventory)+1,
                publication_budget=PUBLICATION_BUDGET, publication_resource_bytes=sum(row['bytes'] for row in inventory.values()),
                publication_headroom_bytes=PUBLICATION_BUDGET['resource_bytes']-sum(row['bytes'] for row in inventory.values()),
                bridge_sha256=inventory['Bridge/netease_bridge.cjs']['sha256'],
                nested_node_image_unchanged=True,outer_signing_still_required=True,
                native_compiles=0,launched=False,installed=False,full_product_acceptance=False)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime', type=Path, required=True)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--inventory-sha256', required=True)
    args = parser.parse_args()
    print(json.dumps(populate(args.runtime, args.app, args.inventory_sha256)))
