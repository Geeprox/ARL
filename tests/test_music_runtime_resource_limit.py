"""Exercise the production packager with sealed, synthetic runtime inventories.

The pinned official node and CLI files are copied as inert public fixture bytes.
No process, credential, provider, or installed application is invoked. Swift's
limit is read for policy agreement; this does not execute the native client.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import shutil
import stat
import tempfile

NATIVE = 'integrations/credentials_login/Module/Sources/ARLCredentialOnboarding/MusicRuntimeClient.swift'
PACKAGER = 'integrations/service_runtime/package_resources.py'


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--runtime', type=Path, required=True)
    parser.add_argument('--fixture-parent', type=Path, required=True)
    parser.add_argument('--baseline-source', type=Path)
    args = parser.parse_args()
    packager = load(args.source/PACKAGER, 'candidate_packager')
    baseline = load(args.baseline_source/PACKAGER, 'baseline_packager') if args.baseline_source else None
    match = re.search(r'\("Bridge/netease_bridge\.cjs",([0-9]+(?:\*[0-9]+)?)\)',
                      (args.source/NATIVE).read_text())
    assert match, 'native_limit_not_found'
    native_limit = 1
    for term in match[1].split('*'):
        native_limit *= int(term)
    assert native_limit == 131072
    reports = []
    root = Path(tempfile.mkdtemp(prefix='resource-limit-', dir=args.fixture_parent))
    try:
        for name in ['Runtime/node', 'NetEase/dist/index.js']:
            target = root/name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(args.runtime/name, target)
            target.chmod(0o555 if name == 'Runtime/node' else 0o444)
        (root/'Bridge').mkdir()
        public_bridge = (args.runtime/'Bridge/netease_bridge.cjs').read_bytes()
        assert len(public_bridge) == 69008

        def fixture(raw, invalid_provenance=False):
            root.chmod(0o755)
            for item in root.rglob('*'):
                if item.is_dir():
                    item.chmod(0o755)
            for name in ['Bridge/netease_bridge.cjs', 'inventory.json', 'provenance.json']:
                path = root/name
                if path.exists():
                    path.chmod(0o644)
            (root/'Bridge/netease_bridge.cjs').write_bytes(raw)
            bridge_sha = sha(root/'Bridge/netease_bridge.cjs')
            # Synthetic provenance exercises the verifier, not dependency execution.
            provenance = dict(bridge_sha256='0'*64 if invalid_provenance else bridge_sha,
                              dependencies={'synthetic-'+str(i):{} for i in range(56)},
                              every_dependency_archive_verified_against_lock_SRI=True)
            (root/'provenance.json').write_text(json.dumps(provenance))
            inventory = {}
            for item in root.rglob('*'):
                if item.is_file() and item.name != 'inventory.json':
                    if item != root/'Runtime/node':
                        item.chmod(0o444)
                    inventory[str(item.relative_to(root))] = dict(
                        sha256=sha(item), bytes=item.stat().st_size,
                        mode=stat.S_IMODE(item.stat().st_mode))
            (root/'inventory.json').write_text(json.dumps(inventory, sort_keys=True))
            (root/'inventory.json').chmod(0o444)
            for item in root.rglob('*'):
                if item.is_dir():
                    item.chmod(0o555)
            root.chmod(0o555)
            return sha(root/'inventory.json')

        def observe(module, pin):
            try:
                module.verified_inventory(root, pin)
                return 'accepted'
            except ValueError as error:
                return str(error)

        for name, raw, expected in [
            ('empty', b'', 'bridge_missing_or_oversize'),
            ('old_limit', b' '*65536, 'accepted'),
            ('old_limit_plus_one', b' '*65537, 'accepted'),
            ('actual_ARL16_bridge', public_bridge, 'accepted'),
            ('new_limit', b' '*131072, 'accepted'),
            ('new_limit_plus_one', b' '*131073, 'bridge_missing_or_oversize'),
        ]:
            pin = fixture(raw)
            actual = observe(packager, pin)
            assert actual == expected, name
            assert (actual == 'accepted') == (0 < len(raw) <= native_limit), 'native_limit_policy_disagrees'
            report = dict(case=name, bytes=len(raw), actual=actual, expected=expected,
                          agrees_with_native_source_limit=True)
            if baseline:
                old = observe(baseline, pin)
                old_expected = 'accepted' if len(raw) <= 65536 else 'bridge_missing_or_oversize'
                assert old == old_expected
                report['baseline_observed'] = old
            reports.append(report)
        pin = fixture(public_bridge)
        actual = observe(packager, '0'*64)
        assert actual == 'runtime_inventory_pin_mismatch'
        reports.append(dict(case='wrong_inventory_pin', actual=actual))
        pin = fixture(public_bridge, invalid_provenance=True)
        actual = observe(packager, pin)
        assert actual == 'bridge_provenance_mismatch'
        reports.append(dict(case='wrong_bridge_provenance', actual=actual))
    finally:
        root.chmod(0o755)
        for item in root.rglob('*'):
            if item.is_dir():
                item.chmod(0o755)
        shutil.rmtree(root)
    print(json.dumps(dict(status='PASS', cases=reports,
                          production_packager_executed=True,
                          native_client_executed=False, native_limit_from_source=native_limit,
                          provider_calls=0, credential_access=0,
                          installed_writes=0, child_processes_started=0)))


if __name__ == '__main__':
    main()
