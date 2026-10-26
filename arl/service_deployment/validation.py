"""Strict bounded parsing only. Paths, images and credentials are never resolved."""
from __future__ import annotations

import json
import re
from urllib.parse import urlsplit

from ..contracts import Fault, encode
from ..control import bounded_text, identifier
from .models import (Backend, Configuration, CredentialRequirement, Dependency,
                     EndpointSpec, EvidenceSource, HealthSpec, Manifest, Mount,
                     MountBinding, Parameter, Port, PortBinding, ReservedPort,
                     RuntimeSpec, TargetInventory)

MAX_INPUT_BYTES = 65536
MAX_DEPTH = 16
MAX_SERVICES = 32
MAX_TIME_MS = 1000000000000000
SERVICE_ID = r"service\.[a-z][a-z0-9-]{0,47}"
KEY = r"[A-Z][A-Z0-9_]{0,63}"
RESERVED_PARAMETER = re.compile(r"(?:^|_)(SECRET|TOKEN|PASSWORD|CREDENTIAL|API_KEY|PRIVATE_KEY)(?:$|_)")


class ValidationFault(Fault):
    def __init__(self, code: str, field: str):
        self.field = field
        super().__init__(code)


def fail(code, field):
    raise ValidationFault(code, field)


def strict_json(raw: bytes | str) -> dict:
    if type(raw) not in (bytes, str):
        fail("invalid_json", "input")
    try:
        raw = raw.encode("utf-8") if type(raw) is str else raw
        if len(raw) > MAX_INPUT_BYTES:
            fail("input_too_large", "input")

        def pairs(items):
            result = {}
            for key, value in items:
                if key in result:
                    fail("duplicate_field", "input")
                result[key] = value
            return result

        def constant(_):
            fail("invalid_json", "input")

        value = json.loads(raw.decode("utf-8"), object_pairs_hook=pairs, parse_constant=constant)
        check_document(value)
        return value
    except (UnicodeError, ValueError, RecursionError, OverflowError):
        fail("invalid_json", "input")


def check_document(value):
    if type(value) is not dict:
        fail("invalid_object", "input")

    def depth(v, n):
        if n > MAX_DEPTH:
            fail("input_too_deep", "input")
        if type(v) is dict:
            if any(type(k) is not str for k in v):
                fail("invalid_field", "input")
            for item in v.values():
                depth(item, n + 1)
        elif type(v) is list:
            for item in v:
                depth(item, n + 1)
        elif type(v) not in (str, int, bool, type(None)):
            fail("invalid_type", "input")

    depth(value, 0)
    try:
        if len(encode(value)) > MAX_INPUT_BYTES:
            fail("input_too_large", "input")
    except (ValueError, UnicodeError, RecursionError, OverflowError):
        fail("invalid_json", "input")


def obj(v, keys, field):
    if type(v) is not dict or set(v) != set(keys):
        fail("unknown_or_missing_field", field)
    return v


def arr(v, field, limit=32):
    if type(v) is not list or len(v) > limit:
        fail("invalid_array", field)
    return v


def text_value(v, field, limit=200):
    if not bounded_text(v, limit) or any(ord(c) == 127 for c in v):
        fail("invalid_text", field)
    return v


def ident(v, field, limit=64):
    if not identifier(v, limit):
        fail("invalid_identifier", field)
    return v


def service_id(v, field):
    if type(v) is not str or re.fullmatch(SERVICE_ID, v) is None:
        fail("invalid_service_id", field)
    return v


def integer(v, field, low=0, high=MAX_TIME_MS):
    if type(v) is not int or not low <= v <= high:
        fail("invalid_integer", field)
    return v


def boolean(v, field):
    if type(v) is not bool:
        fail("invalid_boolean", field)
    return v


def choice(v, values, field):
    if type(v) is not str or v not in values:
        fail("unsupported_value", field)
    return v


def unique(items, key, field):
    if len({key(item) for item in items}) != len(items):
        fail("duplicate_entry", field)
    return tuple(sorted(items, key=key))


def digest(v, field, sizes=(64,)):
    if type(v) is not str or len(v) not in sizes or re.fullmatch(r"[a-f0-9]+", v) is None:
        fail("invalid_digest", field)
    return v


def https_url(v, field):
    text_value(v, field, 2048)
    try:
        p = urlsplit(v)
        if (p.scheme != "https" or not p.hostname or p.username is not None or
                p.password is not None or p.port not in (None, 443) or p.query or p.fragment or
                re.fullmatch(r"[A-Za-z0-9.-]+", p.hostname) is None or
                any(s in v for s in ("\\", "%", " ", "\t")) or
                ".." in p.path.split("/")):
            fail("invalid_https_url", field)
    except ValueError:
        fail("invalid_https_url", field)
    return v


def path(v, field, *, root_allowed=False):
    text_value(v, field, 1024)
    if (not v.startswith("/") or v.startswith("//") or "\\" in v or
            any(part in (".", "..") for part in v.split("/")) or
            "//" in v or (v != "/" and v.endswith("/")) or
            (not root_allowed and v == "/")):
        fail("invalid_absolute_path", field)
    return v


def endpoint(v, field):
    obj(v, {"scheme", "port", "path"}, field)
    p = path(v["path"], field + ".path", root_allowed=True)
    if len(p) > 256 or re.fullmatch(r"/[A-Za-z0-9/_~.-]*", p) is None:
        fail("invalid_endpoint_path", field + ".path")
    return EndpointSpec(choice(v["scheme"], {"http", "https"}, field + ".scheme"),
                        ident(v["port"], field + ".port"), p)


def parse_manifest(value) -> Manifest:
    check_document(value)
    keys = {"schema_version", "service_id", "name", "version", "icon_ref", "repository_url",
            "revision", "license_spdx", "runtimes", "ports", "mounts", "parameters",
            "credential_requirements", "dependencies", "portal", "health"}
    v = obj(value, keys, "manifest")
    integer(v["schema_version"], "schema_version", 1, 1)
    runtimes = []
    for r in arr(v["runtimes"], "runtimes", 3):
        if type(r) is not dict:
            fail("invalid_object", "runtimes")
        backend = Backend(choice(r.get("backend"), {b.value for b in Backend}, "runtimes.backend"))
        if backend == Backend.MAC_NATIVE:
            obj(r, {"backend", "artifact_url", "artifact_sha256", "bundle_id"}, "runtimes")
            bundle = ident(r["bundle_id"], "runtimes.bundle_id", 80)
            if "." not in bundle or ".." in bundle:
                fail("invalid_bundle_id", "runtimes.bundle_id")
            runtimes.append(RuntimeSpec(backend, artifact_url=https_url(r["artifact_url"], "runtimes.artifact_url"),
                            artifact_sha256=digest(r["artifact_sha256"], "runtimes.artifact_sha256"), bundle_id=bundle))
        else:
            obj(r, {"backend", "image"}, "runtimes")
            image = text_value(r["image"], "runtimes.image", 300)
            if re.fullmatch(r"[a-z0-9][a-z0-9._/-]{1,190}@sha256:[a-f0-9]{64}", image) is None or "/" not in image.split("@")[0] or ".." in image:
                fail("unpinned_image", "runtimes.image")
            runtimes.append(RuntimeSpec(backend, image=image))
    if not runtimes:
        fail("runtime_required", "runtimes")
    runtimes = unique(runtimes, lambda r: r.backend, "runtimes")
    ports = []
    for p in arr(v["ports"], "ports", 16):
        obj(p, {"name", "service_port", "protocol", "required"}, "ports")
        ports.append(Port(ident(p["name"], "ports.name"), integer(p["service_port"], "ports.service_port", 1, 65535),
                          choice(p["protocol"], {"tcp", "udp"}, "ports.protocol"), boolean(p["required"], "ports.required")))
    ports = unique(ports, lambda p: p.name, "ports")
    unique(ports, lambda p: (p.protocol, p.service_port), "ports")
    mounts = []
    for m in arr(v["mounts"], "mounts", 16):
        obj(m, {"name", "destination", "access", "kind", "required"}, "mounts")
        mounts.append(Mount(ident(m["name"], "mounts.name"), path(m["destination"], "mounts.destination"),
                            choice(m["access"], {"ro", "rw"}, "mounts.access"),
                            choice(m["kind"], {"file", "directory"}, "mounts.kind"), boolean(m["required"], "mounts.required")))
    mounts = unique(mounts, lambda m: m.name, "mounts")
    unique(mounts, lambda m: m.destination, "mounts")
    parameters = []
    for p in arr(v["parameters"], "parameters"):
        if type(p) is not dict:
            fail("invalid_object", "parameters")
        kind = choice(p.get("kind"), {"boolean", "integer", "enum"}, "parameters.kind")
        keys = {"key", "kind", "required"} | ({"choices"} if kind == "enum" else {"minimum", "maximum"} if kind == "integer" else set())
        obj(p, keys, "parameters")
        key = text_value(p["key"], "parameters.key", 64)
        if re.fullmatch(KEY, key) is None or RESERVED_PARAMETER.search(key):
            fail("sensitive_or_invalid_parameter", "parameters.key")
        values, low, high = (), None, None
        if kind == "enum":
            values = tuple(text_value(item, "parameters.choices", 80) for item in arr(p["choices"], "parameters.choices", 16))
            if not values or len(set(values)) != len(values):
                fail("invalid_choices", "parameters.choices")
        elif kind == "integer":
            low = integer(p["minimum"], "parameters.minimum", -1000000000, 1000000000)
            high = integer(p["maximum"], "parameters.maximum", low, 1000000000)
        parameters.append(Parameter(key, kind, boolean(p["required"], "parameters.required"), values, low, high))
    parameters = unique(parameters, lambda p: p.key, "parameters")
    credentials = []
    for c in arr(v["credential_requirements"], "credential_requirements", 16):
        obj(c, {"key", "purpose", "required"}, "credential_requirements")
        key = text_value(c["key"], "credential_requirements.key", 64)
        if re.fullmatch(KEY, key) is None:
            fail("invalid_identifier", "credential_requirements.key")
        credentials.append(CredentialRequirement(key, text_value(c["purpose"], "credential_requirements.purpose"), boolean(c["required"], "credential_requirements.required")))
    credentials = unique(credentials, lambda c: c.key, "credential_requirements")
    if {p.key for p in parameters} & {c.key for c in credentials}:
        fail("duplicate_configuration_key", "credential_requirements")
    dependencies = []
    for d in arr(v["dependencies"], "dependencies", 16):
        obj(d, {"service_id", "version", "required"}, "dependencies")
        dependencies.append(Dependency(service_id(d["service_id"], "dependencies.service_id"), ident(d["version"], "dependencies.version", 80), boolean(d["required"], "dependencies.required")))
    dependencies = unique(dependencies, lambda d: d.service_id, "dependencies")
    portal = endpoint(v["portal"], "portal")
    h = obj(v["health"], {"endpoint", "expected_status", "timeout_ms", "interval_ms", "stale_after_ms"}, "health")
    interval = integer(h["interval_ms"], "health.interval_ms", 1000, 300000)
    timeout = integer(h["timeout_ms"], "health.timeout_ms", 100, 5000)
    if timeout > interval:
        fail("invalid_health_timing", "health.timeout_ms")
    health = HealthSpec(endpoint(h["endpoint"], "health.endpoint"), integer(h["expected_status"], "health.expected_status", 200, 299),
                        timeout, interval, integer(h["stale_after_ms"], "health.stale_after_ms", interval, 900000))
    by_port = {p.name: p for p in ports}
    for ep in (portal, health.endpoint):
        if ep.port not in by_port or by_port[ep.port].protocol != "tcp":
            fail("invalid_endpoint_port", "portal_or_health.port")
    manifest = Manifest(service_id(v["service_id"], "service_id"), text_value(v["name"], "name"),
                        ident(v["version"], "version", 80), text_value(v["icon_ref"], "icon_ref", 80),
                        https_url(v["repository_url"], "repository_url"), digest(v["revision"], "revision", (40, 64)),
                        ident(v["license_spdx"], "license_spdx", 80), runtimes, ports, mounts, parameters,
                        credentials, dependencies, portal, health)
    try:
        manifest.descriptor.validate()
    except Fault:
        fail("invalid_app_descriptor", "descriptor")
    if manifest.service_id in {d.service_id for d in dependencies}:
        fail("self_dependency", "dependencies")
    return manifest


def parse_configuration(value, manifest: Manifest) -> Configuration:
    check_document(value)
    v = obj(value, {"schema_version", "service_id", "deployment_id", "target_id", "backend", "port_bindings",
                    "mount_bindings", "parameters", "credential_refs"}, "configuration")
    integer(v["schema_version"], "schema_version", 1, 1)
    if service_id(v["service_id"], "service_id") != manifest.service_id:
        fail("service_mismatch", "service_id")
    backend = Backend(choice(v["backend"], {r.backend.value for r in manifest.runtimes}, "backend"))
    ports = []
    for p in arr(v["port_bindings"], "port_bindings", 16):
        obj(p, {"name", "host_port", "exposure"}, "port_bindings")
        name = choice(p["name"], {p.name for p in manifest.ports}, "port_bindings.name")
        ports.append(PortBinding(name, integer(p["host_port"], "port_bindings.host_port", 1, 65535),
                                 choice(p["exposure"], {"target_loopback"}, "port_bindings.exposure")))
    ports = unique(ports, lambda p: p.name, "port_bindings")
    if backend == Backend.MAC_NATIVE:
        for p in ports:
            if p.host_port != next(item.service_port for item in manifest.ports if item.name == p.name):
                fail("native_port_remap_unsupported", "port_bindings.host_port")
    mounts = []
    for m in arr(v["mount_bindings"], "mount_bindings", 16):
        obj(m, {"name", "source"}, "mount_bindings")
        mounts.append(MountBinding(choice(m["name"], {m.name for m in manifest.mounts}, "mount_bindings.name"),
                                   path(m["source"], "mount_bindings.source")))
    mounts = unique(mounts, lambda m: m.name, "mount_bindings")
    parameters = v["parameters"]
    if type(parameters) is not dict or set(parameters) - {p.key for p in manifest.parameters}:
        fail("unknown_configuration_key", "parameters")
    for p in manifest.parameters:
        if p.key not in parameters:
            continue
        item = parameters[p.key]
        if p.kind == "boolean":
            boolean(item, "parameters." + p.key)
        elif p.kind == "integer":
            integer(item, "parameters." + p.key, p.minimum, p.maximum)
        else:
            choice(item, p.choices, "parameters." + p.key)
    credentials = v["credential_refs"]
    if type(credentials) is not dict or set(credentials) - {c.key for c in manifest.credential_requirements}:
        fail("unknown_configuration_key", "credential_refs")
    for ref in credentials.values():
        ident(ref, "credential_refs.reference_id")
    return Configuration(manifest.service_id, ident(v["deployment_id"], "deployment_id"), ident(v["target_id"], "target_id"),
                         backend, ports, mounts, tuple(sorted(parameters.items())), tuple(sorted(credentials.items())))


def parse_inventory(value) -> TargetInventory:
    """Only synthetic inventory is deserializable. Real facts require host injection."""
    check_document(value)
    v = obj(value, {"schema_version", "target_id", "supported_backends", "occupied_ports", "source", "observed_at_ms"}, "inventory")
    integer(v["schema_version"], "schema_version", 1, 1)
    choice(v["source"], {"synthetic"}, "source")
    backends = unique([Backend(choice(b, {b.value for b in Backend}, "supported_backends")) for b in arr(v["supported_backends"], "supported_backends", 3)], lambda b: b, "supported_backends")
    ports = []
    for p in arr(v["occupied_ports"], "occupied_ports", 64):
        obj(p, {"protocol", "port"}, "occupied_ports")
        ports.append(ReservedPort(choice(p["protocol"], {"tcp", "udp"}, "occupied_ports.protocol"), integer(p["port"], "occupied_ports.port", 1, 65535)))
    return TargetInventory(ident(v["target_id"], "target_id"), backends, unique(ports, lambda p: (p.protocol, p.port), "occupied_ports"),
                           EvidenceSource.SYNTHETIC, integer(v["observed_at_ms"], "observed_at_ms"))


def validate_inventory(value):
    if (type(value) is not TargetInventory or type(value.source) is not EvidenceSource or
            type(value.supported_backends) is not tuple or len(value.supported_backends) > 3 or
            any(type(b) is not Backend for b in value.supported_backends) or
            len(set(value.supported_backends)) != len(value.supported_backends) or
            type(value.occupied_ports) is not tuple or len(value.occupied_ports) > 64):
        fail("invalid_service_inventory", "inventory")
    ident(value.target_id, "inventory.target_id")
    integer(value.observed_at_ms, "inventory.observed_at_ms")
    for port in value.occupied_ports:
        if type(port) is not ReservedPort:
            fail("invalid_service_inventory", "inventory.occupied_ports")
        choice(port.protocol, {"tcp", "udp"}, "inventory.occupied_ports.protocol")
        integer(port.port, "inventory.occupied_ports.port", 1, 65535)
    unique(value.occupied_ports, lambda p: (p.protocol, p.port), "inventory.occupied_ports")
