"""Offline host adapter for authorized Library bytes and NAS download receipts.

No network client, MCP registration, authority issuer, NAS mutation, or publisher.
A trusted host must resolve the actual platform file and open its materialized
regular file. A file_id, URL, MCP resource URI or local path alone is not input.
The caller keeps platform identity/version with its FD; no credentials or signed
URLs enter this module. Every effect requires the original owner's verify hook.
"""
from __future__ import annotations

import base64
from dataclasses import dataclass
import hashlib
import json
import math
import os
import re
import stat
import time
import unicodedata
import uuid

CHUNK_BYTES = 32768
MAX_BYTES = 1048576
FRAME_BYTES = 196608
COMMON = {"operation_id", "source_ref", "config_generation", "connection_epoch"}
BINDING = COMMON | {"transfer_ref", "size", "sha256"}
DOWNLOAD_KEYS = COMMON | {"name", "object_ref", "revision", "size"}
BASE = BINDING | {"schema_version", "operation", "downloadable_artifact", "delivery_code"}
MANIFEST_KEYS = BASE | {"name", "object_ref", "revision", "expires_in_seconds", "complete", "direction"}
PAGE_KEYS = BASE | {"offset", "length", "bytes_read", "data_base64", "chunk_sha256", "eof", "next_offset"}


class BridgeFault(ValueError):
    """Finite failure; no automatic retry or unpublished-path fallback."""
    def __init__(self, code):
        self.code = code
        super().__init__(code)


def fail(code="invalid_receipt"):
    raise BridgeFault(code)


def integer(value, low=0, high=MAX_BYTES):
    return type(value) is int and low <= value <= high


def hex64(value):
    return type(value) is str and re.fullmatch("[0-9a-f]{64}", value) is not None


def basename(name):
    try:
        count = len(name.encode("utf-8")) if type(name) is str else 0
    except UnicodeError:
        fail("invalid_name")
    if (type(name) is not str or not 1 <= count <= 255
            or name in {".", ".."} or "/" in name or "\\" in name
            or any(unicodedata.category(c) == "Cc" for c in name)):
        fail("invalid_name")
    return name


def digest(data):
    return hashlib.sha256(data).hexdigest()


def _json(text):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                fail()
            result[key] = value
        return result
    try:
        return json.loads(text, object_pairs_hook=pairs,
                          parse_constant=lambda _: fail())
    except (ValueError, RecursionError, UnicodeError):
        fail()


def mcp_value(result):
    """Admit actual Mio result's two matching representations, with byte cap.

    Pass the tools/call result object, not a transport JSON-RPC envelope.
    Native failure codes propagate, never trigger replay or scope restoration.
    """
    if type(result) is not dict or set(result) != {"content", "structuredContent", "isError"}:
        fail()
    content = result["content"]
    if (type(content) is not list or len(content) != 1 or type(content[0]) is not dict
            or set(content[0]) != {"type", "text"} or content[0]["type"] != "text"
            or type(content[0]["text"]) is not str
            or len(content[0]["text"].encode("utf-8")) > FRAME_BYTES):
        fail()
    text = _json(content[0]["text"])
    value = result["structuredContent"]
    try:
        same = json.dumps(text, sort_keys=True, allow_nan=False) == json.dumps(value, sort_keys=True, allow_nan=False)
    except (TypeError, ValueError, RecursionError):
        fail()
    if type(value) is not dict or not same or type(result["isError"]) is not bool:
        fail()
    if result["isError"]:
        code = value.get("error", {}).get("code") if type(value.get("error")) is dict else None
        if (set(value) != {"schema_version", "operation", "state", "error", "automatic_replay"}
                or type(value["schema_version"]) is not int or value["schema_version"] != 1
                or value["operation"] not in {"download", "transfer_read"} or value["state"] != "failed"
                or value["automatic_replay"] is not False or set(value["error"]) != {"code"}
                or type(code) is not str or re.fullmatch("[A-Za-z][A-Za-z0-9_]{0,95}", code) is None):
            fail()
        fail(code)
    return _json(content[0]["text"])  # independent object, never mutable caller state


def _manifest(value):
    if type(value) is not dict or set(value) != MANIFEST_KEYS:
        fail()
    try:
        canonical_id = str(uuid.UUID(value["operation_id"]))
    except (ValueError, TypeError, AttributeError):
        fail()
    if (value["operation_id"] != canonical_id or type(value["source_ref"]) is not str
            or re.fullmatch("[A-Za-z0-9_-]{1,96}", value["source_ref"]) is None
            or not integer(value["config_generation"], 1, 2**63-1)
            or type(value["connection_epoch"]) is not str
            or re.fullmatch("[0-9a-f]{32}", value["connection_epoch"]) is None
            or not all(hex64(value[k]) for k in ("transfer_ref", "sha256", "object_ref", "revision"))
            or not integer(value["size"]) or type(value["schema_version"]) is not int
            or value["schema_version"] != 1 or value["operation"] != "download"
            or value["downloadable_artifact"] is not False
            or value["delivery_code"] != "platform_file_publisher_required"
            or value["complete"] is not True or value["direction"] != "download"
            or type(value["expires_in_seconds"]) not in (float, int)
            or not math.isfinite(value["expires_in_seconds"]) or not 0 < value["expires_in_seconds"] <= 120):
        fail()
    basename(value["name"])
    return dict(value)


@dataclass(frozen=True)
class VerifiedFile:
    name: str
    data: bytes
    sha256: str

    def check(self, *, max_bytes=MAX_BYTES):
        basename(self.name)
        if type(self.data) is not bytes or len(self.data) > max_bytes or not hex64(self.sha256) or digest(self.data) != self.sha256:
            fail("integrity_failed")


def collect_download(result, *, expected, call, verify, clock=time.monotonic):
    """Validate Mio manifest and every 32KiB result, return bounded verified bytes.

    call(tool, arguments) invokes the existing connection once per chunk and
    returns the actual tools/call result. expected is the original download
    request captured by the host, never reconstructed from the response.
    verify() checks the host's original
    binding; it must raise on revocation. No callback is retried. No file is
    published or marked downloadable here.
    """
    if not callable(call) or not callable(verify):
        fail("owner_required")
    verify()
    manifest = _manifest(mcp_value(result))
    if (type(expected) is not dict or set(expected) != DOWNLOAD_KEYS
            or any(type(manifest[k]) is not type(v) or manifest[k] != v for k, v in expected.items())):
        fail("binding_mismatch")
    instant = clock()
    if type(instant) not in (int, float) or not math.isfinite(instant):
        fail("expired")
    deadline = instant + manifest["expires_in_seconds"]
    previous = instant

    def live():
        nonlocal previous
        now = clock()
        if type(now) not in (int, float) or not math.isfinite(now) or now < previous or now >= deadline:
            fail("expired")
        previous = now
        verify()

    data = bytearray()
    while True:  # empty files still receive a checked EOF page
        live()
        request = {key: manifest[key] for key in BINDING}
        request.update(offset=len(data), length=CHUNK_BYTES)
        page = mcp_value(call("mio_nas_transfer_read", dict(request)))
        live()
        if (set(page) != PAGE_KEYS or any(type(page[k]) is not type(v) or page[k] != v for k, v in request.items())
                or type(page["schema_version"]) is not int or page["schema_version"] != 1
                or page["operation"] != "transfer_read" or page["downloadable_artifact"] is not False
                or page["delivery_code"] != "platform_file_publisher_required"):
            fail()
        count = min(CHUNK_BYTES, manifest["size"] - len(data))
        encoded = page["data_base64"]
        if (not integer(page["bytes_read"]) or page["bytes_read"] != count or type(encoded) is not str
                or len(encoded) > 4*((CHUNK_BYTES+2)//3)):
            fail()
        try:
            raw = base64.b64decode(encoded, validate=True)
        except (ValueError, UnicodeError):
            fail()
        end = len(data) + count
        eof = end == manifest["size"]
        if (len(raw) != count or base64.b64encode(raw).decode("ascii") != encoded
                or page["chunk_sha256"] != digest(raw) or type(page["eof"]) is not bool or page["eof"] != eof
                or (page["next_offset"] is not None if eof else
                    not integer(page["next_offset"]) or page["next_offset"] != end)):
            fail("integrity_failed")
        data.extend(raw)
        if eof:
            break
    live()
    artifact = VerifiedFile(manifest["name"], bytes(data), manifest["sha256"])
    artifact.check()
    return artifact


def _pin(fd):
    if type(fd) is not int or fd < 0:
        fail("invalid_source")
    row = os.fstat(fd)
    if not stat.S_ISREG(row.st_mode) or row.st_nlink != 1 or not integer(row.st_size):
        fail("invalid_source")
    return (row.st_dev, row.st_ino, row.st_size, row.st_mtime_ns, row.st_ctime_ns, row.st_mode, row.st_uid)


def import_materialized(fd, *, transfer, verify):
    """Feed a trusted platform-materialized FD to the existing upload transfer.

    Does not resolve a path/URL, mint a transfer or consume a NAS write permit.
    transfer is the existing FileTransfer supplied by the original owner.
    Materialization must have retained actual platform id and version outside
    this adapter. Expected size/SHA come from the owner's original transfer.
    """
    from homeplane.nas_connection.file_transfer import FileTransfer
    if type(transfer) is not FileTransfer or not callable(verify):
        fail("owner_required")
    if transfer.direction != "upload" or transfer.offset != 0 or transfer.sealed or transfer.claimed:
        fail("invalid_transfer")
    context = dict(ref=transfer.ref, operation_id=transfer.operation_id, fence=transfer.fence)
    verify()
    transfer.check(**context)
    pin = _pin(fd)
    if pin[2] != transfer.size or not hex64(transfer.sha256):
        fail("integrity_failed")
    def live():
        verify()
        transfer.check(**context)
        if _pin(fd) != pin:
            fail("source_changed")
    # Preflight integrity before the first local append.
    check = hashlib.sha256()
    for offset in range(0, transfer.size, CHUNK_BYTES):
        live()
        raw = os.pread(fd, min(CHUNK_BYTES, transfer.size-offset), offset)
        if len(raw) != min(CHUNK_BYTES, transfer.size-offset):
            fail("source_changed")
        check.update(raw)
    live()
    if check.hexdigest() != transfer.sha256:
        fail("integrity_failed")
    try:
        for offset in range(0, transfer.size, CHUNK_BYTES):
            live()
            raw = os.pread(fd, min(CHUNK_BYTES, transfer.size-offset), offset)
            if len(raw) != min(CHUNK_BYTES, transfer.size-offset):
                fail("source_changed")
            transfer.append(**context, offset=offset, data_base64=base64.b64encode(raw).decode("ascii"), sha256=digest(raw))
            live()
        reply = transfer.finish(**context)
        live()
        return reply
    except BaseException:
        transfer.broken = True  # uncertain/changed local transfer cannot be claimed
        raise


def write_exclusive(directory_fd, artifact, *, verify):
    """Create one private local staging file; returns no link or artifact id.

    Publication must use an actual platform publisher separately. Existing
    entries/symlinks are never replaced; partial files remain private on error.
    """
    if type(artifact) is not VerifiedFile or not callable(verify):
        fail("owner_required")
    artifact.check()
    verify()
    row = os.fstat(directory_fd)
    if not stat.S_ISDIR(row.st_mode) or row.st_uid != os.getuid() or row.st_mode & 0o077:
        fail("private_directory_required")
    fd = os.open(artifact.name, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=directory_fd)
    try:
        pin = _pin(fd)
        for offset in range(0, len(artifact.data), CHUNK_BYTES):
            verify()
            raw = artifact.data[offset:offset+CHUNK_BYTES]
            if os.pwrite(fd, raw, offset) != len(raw):
                fail("io_uncertain")
        os.fsync(fd)
        verify()
        named = os.stat(artifact.name, dir_fd=directory_fd, follow_symlinks=False)
        opened = _pin(fd)
        if (opened[:2] != pin[:2] or (named.st_dev, named.st_ino) != pin[:2]
                or opened[2] != len(artifact.data) or digest(os.pread(fd, MAX_BYTES+1, 0)) != artifact.sha256):
            fail("source_changed")
        os.fsync(directory_fd)
        verify()
    finally:
        os.close(fd)
    return {"name": artifact.name, "size": len(artifact.data), "sha256": artifact.sha256,
            "downloadable_artifact": False, "delivery_code": "platform_file_publisher_required"}
