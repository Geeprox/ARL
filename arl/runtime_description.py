"""Immutable boot metadata. No process discovery, grants or private state reads."""
from pathlib import Path
import secrets
from . import PROTOCOL, VERSION
from .contracts import Fault
from .source_fingerprint import UnsafeRuntimeSource, source_fingerprint as fingerprint_tree

FEATURES = {"app_sessions": 1, "control_snapshot": 2, "runtime_description": 1}

def source_fingerprint():
    try:
        return fingerprint_tree(Path(__file__).parent)
    except UnsafeRuntimeSource:
        raise Fault("unsafe_runtime_source") from None

class RuntimeDescription:
    def __init__(self):
        self.boot_id = secrets.token_hex(32)
        self.source_sha256 = source_fingerprint()
    def snapshot(self, ready, *, application_models=False, application_platform=False):
        features = dict(FEATURES)
        # Protocol support only. Identity, catalog availability and inference
        # approval remain separate checks on their existing methods.
        if application_models:
            features.update(application_models=1, application_icon=1)
        if application_platform:
            features.update(application_registration=1, application_tasks=1, model_scheduler=1)
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
