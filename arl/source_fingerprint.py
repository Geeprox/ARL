"""Content identity of a packaged or in-place ARL Python source tree."""
import hashlib
from pathlib import Path


class UnsafeRuntimeSource(ValueError):
    pass


def source_fingerprint(root):
    digest = hashlib.sha256()
    root = Path(root)
    for path in sorted(root.rglob("*.py")):
        if path.is_symlink() or "__pycache__" in path.parts:
            raise UnsafeRuntimeSource("unsafe_runtime_source")
        name = str(path.relative_to(root)).encode()
        raw = path.read_bytes()
        digest.update(len(name).to_bytes(4, "big") + name)
        digest.update(len(raw).to_bytes(8, "big") + raw)
    return digest.hexdigest()
