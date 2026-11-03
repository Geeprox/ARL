#!/usr/bin/env python3
"""Review and upgrade fixed ARL journal anchors without changing any records.

Ordinary application reads never repair an anchor. This maintenance operation
requires an exact fresh plan and stopped native owners, preserves the legacy
anchor, and refuses directory/inode changes or unsafe record files.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import stat
import subprocess
import uuid

LAYOUTS = {
    'notes': ('', 'apple-direct-once-v1', ('apple-direct-once-v1',)),
    'messages': ('', 'messages-direct-once-v1', ('messages-direct-once-v1',)),
    'calendar': ('', 'calendar-business-once-v1', ('calendar-business-once-v1',)),
    'reminders': ('reminders-v3', 'product-v1', ('product-v1', 'product-v1/tasks')),
}


class UpgradeError(ValueError):
    pass


def digest(data):
    return hashlib.sha256(data).hexdigest()


def checked(path, directory=False):
    path = Path(path)
    for parent in (path, *path.parents):
        if parent.is_symlink():
            raise UpgradeError('symlink_refused')
    info = path.lstat()
    if (info.st_uid != os.geteuid() or info.st_mode & 0o077
            or not (stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode))
            or directory and stat.S_IMODE(info.st_mode) != 0o700
            or not directory and info.st_nlink != 1):
        raise UpgradeError('unsafe_journal')
    return info


def read_private(path, limit=32 * 1024 * 1024):
    before = checked(path)
    if not 0 <= before.st_size <= limit:
        raise UpgradeError('journal_file_budget')
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        current = os.fstat(fd)
        if (current.st_dev, current.st_ino, current.st_size) != (before.st_dev, before.st_ino, before.st_size):
            raise UpgradeError('journal_changed')
        data = bytearray()
        while len(data) <= limit:
            part = os.read(fd, min(65536, limit + 1 - len(data)))
            if not part:
                break
            data.extend(part)
        after = os.fstat(fd)
        if len(data) != before.st_size or (after.st_size, after.st_mtime_ns) != (before.st_size, before.st_mtime_ns):
            raise UpgradeError('journal_changed')
        return bytes(data)
    finally:
        os.close(fd)


def volume_uuid(path):
    # diskutil accepts a disk identifier or mount point, not an arbitrary
    # directory. Match the filesystem's device number using device metadata;
    # never open or read a raw disk.
    device = Path(path).stat().st_dev
    nodes = [node for node in Path('/dev').glob('disk*')
             if stat.S_ISBLK(node.lstat().st_mode) and node.lstat().st_rdev == device]
    if len(nodes) != 1:
        raise UpgradeError('volume_identity_unavailable')
    result = subprocess.run(['/usr/sbin/diskutil', 'info', '-plist', str(nodes[0])],
                            capture_output=True, check=True, timeout=10)
    return str(uuid.UUID(plistlib.loads(result.stdout)['VolumeUUID']))


def inventory(root):
    records = {}
    def unavailable(error):
        raise UpgradeError('journal_inventory_unavailable') from error
    for current, directories, files in os.walk(root, followlinks=False, onerror=unavailable):
        checked(current, directory=True)
        for name in directories:
            checked(Path(current) / name, directory=True)
        for name in files:
            path = Path(current) / name
            records[str(path.relative_to(root))] = digest(read_private(path))
            if len(records) > 10000:
                raise UpgradeError('journal_inventory_budget')
    return digest(json.dumps(records, sort_keys=True, separators=(',', ':')).encode()), len(records)


def plan(home, *, volume=volume_uuid):
    home = Path(home)
    checked(home, directory=True)
    entries = []
    for kind, (relative, stem, directories) in LAYOUTS.items():
        parent = home / relative
        if relative:
            try:
                checked(parent, directory=True)
            except FileNotFoundError:
                continue
        root, anchor = parent / stem, parent / (stem + '.anchor')
        if root.is_symlink() or anchor.is_symlink():
            raise UpgradeError('symlink_refused')
        if not root.exists() and not anchor.exists():
            continue
        if not root.exists() or not anchor.exists():
            raise UpgradeError('journal_missing_or_replaced')
        checked(parent, directory=True)
        infos, volumes = [], []
        for name in directories:
            path = parent / name
            info = checked(path, directory=True)
            identity = str(uuid.UUID(volume(path))).lower()
            after = checked(path, directory=True)
            if (info.st_dev, info.st_ino) != (after.st_dev, after.st_ino):
                raise UpgradeError('journal_changed')
            infos.append((int(info.st_dev), int(info.st_ino)))
            volumes.append(identity)
        if len(set(volumes)) != 1:
            raise UpgradeError('journal_volume_changed')
        expected = 'v2\n' + ''.join(v + '\n' + str(i[1]) + '\n' for v, i in zip(volumes, infos))
        raw = read_private(anchor, 512)
        fields = raw.decode('ascii').splitlines()
        if raw == expected.encode():
            state = 'current'
        elif fields[:1] == ['v1'] and len(fields) == 1 + len(infos) * 2:
            try:
                old = [(int(fields[i]), int(fields[i + 1])) for i in range(1, len(fields), 2)]
            except ValueError as exc:
                raise UpgradeError('invalid_anchor') from exc
            canonical = ('v1\n' + ''.join(str(device) + '\n' + str(inode) + '\n' for device, inode in old)).encode()
            if raw != canonical:
                raise UpgradeError('invalid_anchor')
            if any(a[1] != b[1] for a, b in zip(old, infos)) or len({a[0] for a in old}) != 1:
                raise UpgradeError('journal_missing_or_replaced')
            state = 'legacy_current' if old == infos else 'legacy_device_changed'
        else:
            raise UpgradeError('journal_missing_or_replaced')
        tree, count = inventory(root)
        entries.append({'kind': kind, 'parent': relative, 'stem': stem, 'state': state,
                        'anchor_sha256': digest(raw), 'directories': infos,
                        'volume_uuid': volumes[0], 'new_anchor': expected,
                        'records_sha256': tree, 'record_files': count})
    report = {'schema_version': 1, 'records_modified': False, 'entries': entries}
    report['plan_sha256'] = digest(json.dumps(report, sort_keys=True, separators=(',', ':')).encode())
    return report


def write_new(path, data):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    try:
        view = memoryview(data)
        while view:
            count = os.write(fd, view)
            if count <= 0:
                raise UpgradeError('anchor_write_uncertain')
            view = view[count:]
        os.fsync(fd)
    finally:
        os.close(fd)


def apply(home, expected, *, owners_stopped=False, volume=volume_uuid):
    if owners_stopped is not True:
        raise UpgradeError('stop_native_owners_first')
    reviewed = plan(home, volume=volume)
    if reviewed['plan_sha256'] != expected:
        raise UpgradeError('reviewed_plan_changed')
    for entry in reviewed['entries']:
        if entry['state'] == 'current':
            continue
        parent = Path(home) / entry['parent']
        anchor = parent / (entry['stem'] + '.anchor')
        original = read_private(anchor, 512)
        if digest(original) != entry['anchor_sha256'] or inventory(parent / entry['stem'])[0] != entry['records_sha256']:
            raise UpgradeError('journal_changed')
        backup = parent / (entry['stem'] + '.anchor.legacy-' + digest(original))
        if backup.exists():
            if read_private(backup, 512) != original:
                raise UpgradeError('anchor_backup_changed')
        else:
            write_new(backup, original)
        temporary = parent / (entry['stem'] + '.anchor.new-' + uuid.uuid4().hex)
        write_new(temporary, entry['new_anchor'].encode())
        if read_private(anchor, 512) != original:
            raise UpgradeError('journal_changed')
        os.replace(temporary, anchor)
        fd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
        if inventory(parent / entry['stem'])[0] != entry['records_sha256']:
            raise UpgradeError('journal_changed')
    final = plan(home, volume=volume)
    return {'schema_version': 1, 'status': 'upgraded', 'records_modified': False,
            'legacy_anchors_preserved': True, 'reviewed_plan_sha256': expected,
            'entries': [{'kind': e['kind'], 'state': e['state'], 'record_files': e['record_files'],
                         'records_sha256': e['records_sha256']} for e in final['entries']]}


def native_owners_stopped():
    result = subprocess.run(['/bin/ps', '-A', '-o', 'comm='], capture_output=True, check=True, text=True, timeout=10)
    return not any(Path(line.strip()).name in {'ARL', 'ARLControl', 'ARLRemindersBridge'} for line in result.stdout.splitlines())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply-plan-sha256')
    args = parser.parse_args()
    home = Path.home() / 'Library/Application Support/ARL'
    try:
        result = (apply(home, args.apply_plan_sha256, owners_stopped=native_owners_stopped())
                  if args.apply_plan_sha256 else plan(home))
        print(json.dumps(result, ensure_ascii=False, sort_keys=True, indent=2))
    except (UpgradeError, OSError, ValueError, subprocess.SubprocessError) as exc:
        print(json.dumps({'status': 'blocked', 'code': str(exc) if isinstance(exc, UpgradeError) else type(exc).__name__, 'records_modified': False}))
        return 2
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
