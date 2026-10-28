#!/usr/bin/env python3
"""Audit publishable source/index/history or an explicit release candidate.

Never prints matched values, reads ignored runtime state, or changes Git history.
"""
import argparse
import collections
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PATTERNS = {
    'private_platform_file_identifier': re.compile(rb'\blibfile_[a-z0-9]{24,}\b'),
    'personal_path': re.compile(rb'/(?:Users|home)/[A-Za-z0-9_.-]+/'),
    'private_app_reference': re.compile(rb'(?i)(?<![A-Za-z])(?:tisra|friday)(?![A-Za-z])'),
    'organization_or_tunnel_identifier': re.compile(rb'(?:org-[A-Za-z0-9]{12,}|tunnel_[a-f0-9]{24,}|plugin_asdk_app_[a-f0-9]{24,})'),
    'email_address': re.compile(rb'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'),
    'private_key_material': re.compile(rb'-----BEGIN (?:RSA |EC |DSA |OPENSSH |ENCRYPTED )?PRIVATE KEY-----'),
    'credential_candidate': re.compile(rb'(?:sk-(?:(?:proj|svcacct)-)?[A-Za-z0-9_-]{24,}|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{22,}|Bearer [A-Za-z0-9._~+/-]{24,}|(?:AKIA|ASIA)[A-Z0-9]{16}|AIza[A-Za-z0-9_-]{35}|xox[baprs]-[A-Za-z0-9-]{20,})'),
    'secret_assignment_review': re.compile(rb'''(?im)\b(?:api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|password)\s*["']?\s*[:=]\s*["']([^"'\r\n]{10,})["']'''),
    'credential_url': re.compile(rb'(?i)\b[a-z][a-z0-9+.-]*://[^\s/:@]+:[^\s/@]+@'),
    'private_network_address': re.compile(rb'\b(?:10\.\d{1,3}\.\d{1,3}\.\d{1,3}|192\.168\.\d{1,3}\.\d{1,3}|172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3})\b'),
    'local_hostname': re.compile(rb'(?i)\b[a-z0-9][a-z0-9-]*\.local\b'),
}
FIXTURE_LABEL_HASHES = {'tests/MusicProviderFailureDiagnosticsTests.cjs': ['87f6e67528b9110c1258f8e0c2c7744d0e9f4bdf5fa9d1565d097426ca4b7b7e'], 'tests/test_priority_r2.py': ['9d29a33f1bfd4446561e1a726867ccd0e3df769cdca9de19b198873ab26fe048']}
MAX_BLOB = 64 * 1024 * 1024
SCOPES = ('tracked', 'untracked', 'index', 'history', 'history_metadata', 'candidate')
SENSITIVE_NAME = re.compile(r'(?i)(?:^|/)(?:\.env(?:\..*)?|id_rsa|id_ed25519|auth\.json|.*\.(?:p12|pfx|key|pem))$')


def scan(raw, path=''):
    found = set()
    # Names can leak identity or carry a private key even with empty contents.
    combined = raw + b'\n' + path.encode('utf-8', errors='replace')
    for name, pattern in PATTERNS.items():
        for match in pattern.finditer(combined):
            if name == 'credential_candidate' and hashlib.sha256(match.group()).hexdigest() in FIXTURE_LABEL_HASHES.get(path, ()):
                continue
            if name == 'email_address':
                domain = match.group().lower().rsplit(b'@', 1)[-1]
                if domain in {b'example.com', b'example.org', b'example.net', b'example.test'} or domain.endswith((b'.invalid', b'.example')):
                    continue
            if name == 'secret_assignment_review' and match.group(1).startswith((b'env:', b'${')):
                continue
            found.add(name)
            break
    if SENSITIVE_NAME.search(path):
        found.add('credential_file_review')
    if b'\0' in raw[:8192]:
        found.add('binary_review')
    return sorted(found)


def git(*args):
    return subprocess.check_output(['git', '-C', str(ROOT), *args], stderr=subprocess.DEVNULL)


def file_types(path, name):
    # Never follow a link into an ignored directory or outside the checkout.
    if any(p.is_symlink() for p in (path, *path.parents)):
        return ['symlink_review']
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode):
        return ['special_file_review']
    return scan(path.read_bytes(), name) if info.st_size <= MAX_BLOB else ['oversize_review']


def objects(rows):
    """Read exact index/history objects, including commit and annotated-tag text."""
    with subprocess.Popen(['git', '-C', str(ROOT), 'cat-file', '--batch'], stdin=subprocess.PIPE,
                          stdout=subprocess.PIPE, stderr=subprocess.DEVNULL) as process:
        try:
            for identity, name, mode in rows:
                process.stdin.write(identity + b'\n')
                process.stdin.flush()
                header = process.stdout.readline().split()
                if len(header) != 3:
                    raise RuntimeError('git_object_unavailable')
                size, kind = int(header[2]), header[1]
                if size <= MAX_BLOB:
                    raw = process.stdout.read(size)
                    if len(raw) != size:
                        raise RuntimeError('git_object_truncated')
                    types = scan(raw, name) if kind in {b'blob', b'commit', b'tag'} else []
                else:
                    left = size
                    while left:
                        chunk = process.stdout.read(min(left, 1024 * 1024))
                        if not chunk:
                            raise RuntimeError('git_object_truncated')
                        left -= len(chunk)
                    types = ['oversize_review'] if kind in {b'blob', b'commit', b'tag'} else []
                if process.stdout.read(1) != b'\n':
                    raise RuntimeError('git_object_truncated')
                if mode == b'120000':
                    types = sorted(set(types) | {'symlink_review'})
                if mode == b'160000':
                    types = sorted(set(types) | {'submodule_review'})
                yield identity, name, kind, types
        finally:
            process.stdin.close()
            process.stdout.close()
            process.wait(timeout=10)
            if process.returncode:
                raise RuntimeError('git_object_reader_failed')


def report(findings, **coverage):
    counts = collections.Counter((f['scope'], t) for f in findings for t in f['types'])
    return {'schema': 2, **coverage, 'release_ready': not findings,
            'limits': ['Pattern scan is not proof of absence; candidates and binaries need private review.',
                       'Ignored local state, external credentials and unreachable Git objects are excluded.',
                       'A clean report does not establish license, build or distribution readiness.'],
            'counts': {scope: {t: n for (s, t), n in sorted(counts.items()) if s == scope} for scope in SCOPES},
            'findings': findings}


def audit(history=False):
    findings, coverage = [], collections.Counter()
    index = []
    tracked = set()
    for row in git('ls-files', '--stage', '-z').split(b'\0'):
        if not row:
            continue
        metadata, name = row.split(b'\t', 1)
        mode, identity, _ = metadata.split()
        name = name.decode('utf-8', errors='surrogateescape')
        tracked.add(name)
        index.append((identity, name, mode))
    others = {n.decode('utf-8', errors='surrogateescape') for n in git('ls-files', '--others', '--exclude-standard', '-z').split(b'\0') if n}
    for name in sorted(tracked | others):
        path = ROOT / name
        scope = 'tracked' if name in tracked else 'untracked'
        if not path.exists() and not path.is_symlink():
            continue
        coverage[scope] += 1
        types = file_types(path, name)
        if types:
            findings.append({'scope': scope, 'path': name, 'types': types})
    for identity, name, kind, types in objects(index):
        coverage['index'] += 1
        if types:
            findings.append({'scope': 'index', 'path': name, 'types': types, 'object': identity.decode()})
    blobs = 0
    if history:
        rows = []
        for line in git('-c', 'core.quotePath=false', 'rev-list', '--objects', '--all').splitlines():
            identity, _, name = line.partition(b' ')
            rows.append((identity, name.decode('utf-8', errors='replace'), None))
        for identity, name, kind, types in objects(rows):
            if kind == b'blob':
                blobs += 1
            scope = 'history_metadata' if kind in {b'commit', b'tag'} else 'history'
            coverage[scope] += 1
            if types:
                findings.append({'scope': scope, 'path': name or '(git metadata)', 'types': types,
                                 'object': identity.decode()})
    return report(findings, history_scanned=history, history_blobs=blobs, files_scanned=dict(coverage))


def audit_candidate(path):
    path = Path(path).absolute()
    if any(p.is_symlink() for p in (path, *path.parents)) or not path.is_dir():
        raise ValueError('candidate_directory_required')
    findings, count = [], 0
    for entry in sorted(path.rglob('*')):
        if entry.is_dir() and not entry.is_symlink():
            continue
        count += 1
        name = str(entry.relative_to(path))
        types = file_types(entry, name)
        if types:
            findings.append({'scope': 'candidate', 'path': name, 'types': types})
    if not count:
        findings.append({'scope': 'candidate', 'path': '(empty)', 'types': ['empty_candidate']})
    return report(findings, history_scanned=False, history_blobs=0, files_scanned={'candidate': count})


def write_report(path, result):
    path = Path(path).absolute()
    if (ROOT / 'build').absolute() not in path.parents or any(p.is_symlink() for p in (path, *path.parents)):
        raise ValueError('report_must_stay_in_ignored_build')
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix='.privacy-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            os.fchmod(stream.fileno(), 0o600)
            stream.write(json.dumps(result, ensure_ascii=True, indent=2) + '\n')
            stream.flush(); os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary): os.unlink(temporary)



def main():
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--history', action='store_true')
    mode.add_argument('--candidate', type=Path, help='Scan every file of an explicit unpacked release candidate.')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    try:
        result = audit_candidate(args.candidate) if args.candidate else audit(args.history)
        if args.output:
            write_report(args.output, result)
        print(json.dumps({k: v for k, v in result.items() if k != 'findings'}))
        return 0 if result['release_ready'] else 2
    except Exception:
        print(json.dumps({'error': 'privacy_audit_failed', 'release_ready': False}))
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
