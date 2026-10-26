"""Stage a read-only Control status profile for a separately reviewed signed helper.

This emits a candidate JSON only. It does not install, run, or authorize the helper.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

EXPECTED_BUNDLE_ID = 'local.arl.mioapplebridge'
EXPECTED_REQUIREMENT = 'identifier "local.arl.mioapplebridge" and certificate root = H"859332b7fffbbbb33b80c7b78d30c27d2d81583f"'


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(argv: list[str]) -> str:
    result = subprocess.run(argv, env={'PATH': '/usr/bin:/bin', 'LANG': 'C', 'LC_ALL': 'C'},
                            capture_output=True, text=True, timeout=10)
    if result.returncode:
        raise ValueError('signed_helper_unverified')
    return result.stdout + result.stderr


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--signed-app', type=Path, required=True)
    parser.add_argument('--expected-executable-sha256', required=True)
    parser.add_argument('--expected-cdhash', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    assert re.fullmatch(r'[a-f0-9]{64}', args.expected_executable_sha256)
    assert re.fullmatch(r'[a-f0-9]{40}', args.expected_cdhash)
    assert args.signed_app.is_dir() and not args.signed_app.is_symlink()
    assert not args.output.exists(), 'candidate_exists_stop'
    executable = args.signed_app / 'Contents/MacOS/ARLMioAppleBridge'
    assert executable.is_file() and not executable.is_symlink()
    assert sha(executable) == args.expected_executable_sha256
    run(['/usr/bin/codesign', '--verify', '--strict', '--deep', str(args.signed_app)])
    detail = run(['/usr/bin/codesign', '-dv', '--verbose=4', str(args.signed_app)])
    fields = dict(row.split('=', 1) for row in detail.splitlines() if '=' in row)
    assert fields.get('Identifier') == EXPECTED_BUNDLE_ID
    assert fields.get('CDHash') == args.expected_cdhash
    run(['/usr/bin/codesign', '--verify', '--strict',
         '--test-requirement', '=' + EXPECTED_REQUIREMENT, str(args.signed_app)])
    profile = {'schema_version': 1, 'enabled': 1,
               'helper_bundle_id': EXPECTED_BUNDLE_ID,
               'helper_cdhash': args.expected_cdhash,
               'helper_requirement': EXPECTED_REQUIREMENT,
               'helper_executable_sha256': args.expected_executable_sha256}
    args.output.write_bytes(json.dumps(profile, sort_keys=True, separators=(',', ':')).encode())
    print(json.dumps({'profile_sha256': sha(args.output), 'installed': False,
                      'helper_run': False, 'tcc_called': False, 'event_data_accessed': False}))


if __name__ == '__main__':
    main()
