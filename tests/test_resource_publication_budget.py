"""Owned synthetic packaging only: no official runtime, signing or execution."""
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import sys


def main():
    root = Path(sys.argv[1]).resolve(strict=True)
    module_path = Path(__file__).resolve().parents[1] / 'integrations/service_runtime/package_resources.py'
    spec = importlib.util.spec_from_file_location('synthetic_packager', module_path)
    package = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(package)
    digest = lambda data: hashlib.sha256(data).hexdigest()
    stage = root / 'stage'
    stage.mkdir()
    # Override official pins solely in this isolated imported test module.
    node, cli, bridge = b'inert synthetic node', b'inert synthetic CLI', b'A' * (140 * 1024)
    package.NODE_SHA, package.CLI_SHA = digest(node), digest(cli)
    provenance = json.dumps({'bridge_sha256': digest(bridge), 'dependencies': {str(n): 'synthetic' for n in range(56)},
                             'every_dependency_archive_verified_against_lock_SRI': True}).encode()
    inventory = {}
    for name, data, mode in [('Runtime/node', node, 0o555), ('NetEase/dist/index.js', cli, 0o444),
                             ('Bridge/netease_bridge.cjs', bridge, 0o444), ('provenance.json', provenance, 0o444)]:
        path = stage / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        path.chmod(mode)
        inventory[name] = dict(bytes=len(data), sha256=digest(data), mode=mode)
    raw = json.dumps(inventory, sort_keys=True).encode()
    manifest = stage / 'inventory.json'
    manifest.write_bytes(raw)
    manifest.chmod(0o444)
    for path in sorted(stage.rglob('*'), reverse=True):
        if path.is_dir(): path.chmod(0o555)
    stage.chmod(0o555)
    assert package.verified_inventory(stage, digest(raw)) == inventory
    app = root / 'Synthetic.app'
    (app / 'Contents').mkdir(parents=True)
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'local.arl.control'}))
    result = package.populate(stage, app, digest(raw))
    sealed = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    assert sealed['ARLServiceRuntimeManifestBytes'] == len(raw)
    assert sealed['ARLServiceRuntimeManifestSHA256'] == digest(raw)
    assert result['publication_headroom_bytes'] > 0 and result['outer_signing_still_required']

    def reject(data, reason):
        manifest.chmod(0o644)
        manifest.write_bytes(data)
        manifest.chmod(0o444)
        try:
            package.verified_inventory(stage, digest(data))
        except ValueError as error:
            assert str(error) == reason, str(error)
        else:
            raise AssertionError(reason)
    malformed = json.loads(raw)
    malformed['Runtime/node']['bytes'] = True
    reject(json.dumps(malformed).encode(), 'invalid_resource_size_mode')
    malformed = json.loads(raw)
    malformed['Runtime/node']['bytes'] = package.PUBLICATION_BUDGET['resource_bytes'] + 1
    reject(json.dumps(malformed).encode(), 'publication_resource_budget')
    reject(b'{"x":{},"x":{}}', 'duplicate_json_key')
    manifest.chmod(0o644)
    manifest.write_bytes(raw)
    manifest.chmod(0o444)
    print(json.dumps({'status': 'PASS', 'groups': ['R01_publication_seal_and_budget'],
                      'bridge_bytes': len(bridge), 'actual_resources_executed': 0, 'signed_or_installed': 0}))


if __name__ == '__main__':
    main()
