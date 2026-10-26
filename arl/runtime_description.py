"""Immutable boot metadata. No process discovery, grants or private state reads."""
import hashlib
from pathlib import Path
import secrets
from . import PROTOCOL, VERSION
from .contracts import Fault

FEATURES = {"app_sessions": 1, "control_snapshot": 2, "runtime_description": 1}

def source_fingerprint():
    digest = hashlib.sha256()
    root = Path(__file__).parent
    for path in sorted(root.rglob("*.py")):
        if path.is_symlink() or "__pycache__" in path.parts:
            raise Fault("unsafe_runtime_source")
        name = str(path.relative_to(root)).encode()
        raw = path.read_bytes()
        digest.update(len(name).to_bytes(4, "big") + name)
        digest.update(len(raw).to_bytes(8, "big") + raw)
    return digest.hexdigest()

class RuntimeDescription:
    def __init__(self):
        self.boot_id = secrets.token_hex(32)
        self.source_sha256 = source_fingerprint()
    def snapshot(self, ready, *, application_models=False):
        features = dict(FEATURES)
        # Protocol support only. Identity, catalog availability and inference
        # approval remain separate checks on their existing methods.
        if application_models:
            features.update(application_models=1, application_icon=1)
        return {"schema_version": 1, "protocol": PROTOCOL, "version": VERSION,
                "boot_id": self.boot_id, "source_sha256": self.source_sha256,
                "features": features, "ready": bool(ready)}

def validate_description(reply):
    from .app_connections import token
    if (type(reply) is not dict or set(reply) != {"schema_version", "protocol", "version", "boot_id", "source_sha256", "features", "ready"}
        or type(reply["schema_version"]) is not int or reply["schema_version"] != 1
        or reply["protocol"] != PROTOCOL or type(reply["version"]) is not str
        or not token(reply["boot_id"]) or not token(reply["source_sha256"])
        or type(reply["ready"]) is not bool or type(reply["features"]) is not dict
        or any(type(k) is not str or type(v) is not int or v < 1 for k, v in reply["features"].items())):
        raise Fault("invalid_response")
    return reply
