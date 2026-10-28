from __future__ import annotations

import json
import hashlib
import math
import re
from dataclasses import dataclass
from typing import Any, Callable, Protocol


class Fault(Exception):
    def __init__(self, code: str, message: str = ""):
        self.code = code
        super().__init__(message or code)


class Cancelled(Fault):
    def __init__(self):
        super().__init__("cancelled")


class Context(Protocol):
    def check_cancelled(self) -> None: ...


@dataclass(frozen=True)
class Tool:
    name: str
    schema: dict
    handler: Callable[[dict, Context], Any]
    idempotent: bool = True
    permissions: tuple = ()
    availability: str = "ready"
    description: str = ""
    version: int = 1
    completion_fence: Callable | None = None

    def __post_init__(self):
        if self.completion_fence is not None and (
                not callable(self.completion_fence) or self.idempotent is not False or not self.permissions):
            raise Fault('invalid_tool_completion_fence')

    @property
    def requires_identity(self):
        return bool(self.permissions) or (self.name.startswith("mio_") and self.name != "mio_tunnel_ping")

    def contract_digest(self):
        contract = {"name": self.name, "version": self.version,
            "schema": self.schema, "permissions": self.permissions,
            "requires_identity": self.requires_identity, "idempotent": self.idempotent}
        # Preserve every pre-existing tool digest and completion behavior unless
        # the trusted host explicitly selects this new non-idempotent mechanism.
        if self.completion_fence is not None:
            contract['completion_fence'] = 'store.transaction.v1'
        return hashlib.sha256(encode(contract)).hexdigest()

    def descriptor(self) -> dict:
        return {"name": self.name, "version": self.version, "inputSchema": self.schema,
                "idempotent": self.idempotent, "permissions": self.permissions,
                "availability": self.availability, "description": self.description}


def object_schema(props=None, required=()):
    return {"type": "object", "properties": props or {},
            "required": list(required), "additionalProperties": False}


def string(limit=4096):
    return {"type": "string", "minLength": 1, "maxLength": limit}


def validate(value, schema):
    """Strict bounded schema subset used by ARL and the existing Mio tools."""
    kind = schema["type"]
    good = {"object": type(value) is dict, "string": type(value) is str,
            "integer": type(value) is int, "number": type(value) in (int, float),
            "boolean": type(value) is bool, "array": type(value) is list}.get(kind, False)
    if not good:
        raise Fault("invalid_arguments", "Wrong argument type")
    if kind == "object":
        props = schema.get("properties", {})
        if set(value) - set(props) or set(schema.get("required", [])) - set(value):
            raise Fault("invalid_arguments", "Unknown or missing argument")
        for key, item in value.items():
            validate(item, props[key])
    elif kind == "array":
        if len(value) < schema.get("minItems", 0) or ("maxItems" in schema and len(value) > schema["maxItems"]):
            raise Fault("invalid_arguments", "Array exceeds bounds")
        for item in value:
            validate(item, schema["items"])
    elif kind == "string":
        if not schema.get("minLength", 0) <= len(value) <= schema.get("maxLength", 4096):
            raise Fault("invalid_arguments", "String exceeds bounds")
        if "pattern" in schema and not re.fullmatch(schema["pattern"], value):
            raise Fault("invalid_arguments", "Pattern mismatch")
    elif kind in ("number", "integer"):
        if not math.isfinite(value) or not schema.get("minimum", -1e12) <= value <= schema.get("maximum", 1e12):
            raise Fault("invalid_arguments", "Number exceeds bounds")
    if "enum" in schema and value not in schema["enum"]:
        raise Fault("invalid_arguments", "Unsupported value")


def encode(data) -> bytes:
    return json.dumps(data, ensure_ascii=False, sort_keys=True, allow_nan=False).encode()


@dataclass(frozen=True)
class AppPolicy:
    tools: frozenset
    providers: frozenset = frozenset({"mock"})
    max_tokens: int = 256
    max_pending: int = 64
    max_calls: int | None = 1000
    methods: frozenset = frozenset({"health", "ready", "capabilities", "providers",
        "submit", "get", "cancel", "resume", "wake", "poll_wakes", "stop", "heartbeat"})
    public_metadata: bool = False
    priority_bands: frozenset = frozenset({"explicit"})
    default_priority: str = "explicit"
    max_deadline_ms: int = 60000


class Provider(Protocol):
    name: str
    paid: bool
    def discover(self) -> dict: ...
    def complete(self, args: dict, context: Context) -> dict: ...
