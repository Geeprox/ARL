"""Resolve content-addressed media offloaded by the native NAS owner.

No network API, mounting, credentials or retry lives here. Missing NAS files do
not trigger downloads. Only exact hash-named files in the committed receipt are
eligible; all other requests remain within the local archive.
"""
import hashlib
import json
from pathlib import Path
import re

PATTERN = re.compile(r'media/([a-f0-9]{64})\.(jpg|jpeg|png|gif|webp|mp4)\Z')
_verified = {}


def _confined(root, target):
    if not target.is_relative_to(root):return False
    cursor = root
    if root.is_symlink():return False
    for part in target.relative_to(root).parts:
        cursor = cursor / part
        if cursor.is_symlink():return False
    return True


def receipt(output):
    path = Path(output) / 'private/nas-storage.json'
    if not _confined(Path(output), path):return {}
    try:
        if path.stat().st_size > 8 * 1024 * 1024:return {}
        value = json.loads(path.read_text())
        if value.get('schema') != 1 or not isinstance(value.get('files'), dict):return {}
        if not isinstance(value.get('media_root'), str) or not Path(value['media_root']).is_absolute():return {}
        return value
    except (OSError, ValueError, TypeError):return {}


def remote_media(output, relative):
    match = PATTERN.fullmatch(str(relative))
    if not match:return None
    binding = receipt(output); row = binding.get('files', {}).get(relative)
    if not isinstance(row, dict) or row.get('sha256') != match[1] or type(row.get('bytes')) is not int:return None
    root = Path(binding['media_root']); target = root / Path(relative).name
    if not _confined(root, target):return None
    try:
        stat = target.stat()
        if not target.is_file() or stat.st_size != row['bytes']:return None
        identity = (stat.st_dev, stat.st_ino, stat.st_size, stat.st_mtime_ns, stat.st_ctime_ns)
        key = str(target)
        if _verified.get(key) != identity:
            sha = hashlib.sha256()
            with target.open('rb') as stream:
                for block in iter(lambda: stream.read(1024 * 1024), b''):sha.update(block)
            if sha.hexdigest() != row['sha256']:return None
            if len(_verified) > 10000:_verified.clear()
            _verified[key] = identity
        return target
    except OSError:return None


def media_file(output, relative):
    output = Path(output)
    path = Path(relative)
    if path.is_absolute() or not path.parts or '..' in path.parts:return None
    target = output / relative
    if _confined(output, target) and target.is_file():return target
    return remote_media(output, relative)


def retained_reference(output, relative, expected_sha=None, expected_bytes=None, *, binding=None):
    """Reuse a prior native readback receipt for metadata projection only.

    This does not assert current file availability/integrity. Serving, migration
    reclamation and explicit audits still read and validate the actual blob.
    Collection must also work while the NAS is temporarily disconnected.
    """
    match=PATTERN.fullmatch(str(relative))
    if not match:return False
    if (Path(output)/str(relative)).exists():return False
    binding=receipt(output) if binding is None else binding
    if binding.get('schema')!=1 or not re.fullmatch('[a-f0-9]{64}',str(binding.get('snapshot',''))):return False
    row=binding.get('files',{}).get(str(relative),{})
    if row.get('sha256')!=match[1] or type(row.get('bytes')) is not int or row['bytes']<0:return False
    if expected_sha is None or expected_sha!=row['sha256']:return False
    if expected_bytes is not None and (type(expected_bytes) is not int or expected_bytes!=row['bytes']):return False
    return True
