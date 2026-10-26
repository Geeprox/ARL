"""Tool-only ChatGPT fileParams importer, intentionally not registered.

Accept only the documented file object on the existing authenticated MCP call.
The owner must verify its original caller/request/scope before every IO phase;
file_id, this schema and a CDN URL do not mint an owner permit. No cookies,
API keys, proxy credentials, NAS credentials, upload/move/mkdir, or new service.

Narrow first profile supports only https://files.oaiusercontent.com on port 443.
The docs do not guarantee an exhaustive CDN list. A different platform origin
is rejected, not guessed or followed; Library materialization is a separate host
workflow. Signed URLs live only in this request and never appear in receipts.
"""
from __future__ import annotations
import base64
from dataclasses import dataclass, field
import http.client
import hashlib
import ipaddress
import math
import re
import socket
import ssl
import time
from urllib.parse import urlsplit
import uuid

from integrations.nas.attachment_bridge import (
    BridgeFault, VerifiedFile, CHUNK_BYTES, MAX_BYTES, digest, basename, integer,
)

TOOL_NAME = "mio_nas_import_attachment"
FILE_HOST = "files.oaiusercontent.com"
MAX_URL_BYTES = 16384
DOWNLOAD_SECONDS = 20.0


def fail(code):
    raise BridgeFault(code)


@dataclass(frozen=True)
class FileParam:
    file_id: str
    download_url: str = field(repr=False)
    mime_type: str | None = None
    file_name: str | None = None


def file_param(value):
    """Shape/finite-origin check only. Authorization remains with MCP/native."""
    if (type(value) is not dict or not {"download_url", "file_id"} <= set(value)
            or not set(value) <= {"download_url", "file_id", "mime_type", "file_name"}):
        fail("attachment_reference_required")
    file_id, url = value["file_id"], value["download_url"]
    if (type(file_id) is not str or re.fullmatch(r"file[-_][A-Za-z0-9_-]{1,128}", file_id) is None
            or type(url) is not str):
        fail("attachment_reference_required")
    try:
        valid_size = 1 <= len(url.encode("ascii")) <= MAX_URL_BYTES
        parsed = urlsplit(url)
        port = parsed.port
    except (UnicodeError, ValueError):
        fail("attachment_origin_unsupported")
    if (not valid_size or parsed.scheme != "https" or parsed.netloc != FILE_HOST
            or parsed.hostname != FILE_HOST or port is not None or parsed.fragment
            or not parsed.path.startswith("/") or "\\" in url
            or any(ord(c) <= 32 or ord(c) == 127 for c in url)):
        fail("attachment_origin_unsupported")
    name, mime = value.get("file_name"), value.get("mime_type")
    if "file_name" in value:
        basename(name)
    if "mime_type" in value and (type(mime) is not str or
            re.fullmatch(r"[A-Za-z0-9!#$&^_.+-]+/[A-Za-z0-9!#$&^_.+-]+", mime) is None
            or len(mime) > 255):
        fail("attachment_metadata_invalid")
    return FileParam(file_id, url, mime, name)


def request(value):
    """Original operation/fence plus top-level 'file'; no paths or URL fallback."""
    keys = {"operation_id", "source_ref", "config_generation", "connection_epoch", "name", "file"}
    if type(value) is not dict or set(value) != keys:
        fail("invalid_import_request")
    try:
        canonical = str(uuid.UUID(value["operation_id"]))
    except (ValueError, AttributeError, TypeError):
        fail("invalid_import_request")
    if (canonical != value["operation_id"] or type(value["source_ref"]) is not str
            or re.fullmatch("[A-Za-z0-9_-]{1,96}", value["source_ref"]) is None
            or not integer(value["config_generation"], 1, 2**63-1)
            or type(value["connection_epoch"]) is not str
            or re.fullmatch("[0-9a-f]{32}", value["connection_epoch"]) is None):
        fail("invalid_import_request")
    # Keep the existing upload target grammar; source display name may be Unicode.
    from homeplane.nas_connection.file_operations import file_name
    from arl_nas_upload_new.contracts import UploadFault
    try:
        file_name(value["name"])
    except UploadFault:
        fail("invalid_import_request")
    source = file_param(value["file"])
    captured = {key: value[key] for key in keys - {"file"}}
    return captured, source


def descriptor():
    """Concrete reviewed candidate; coordinator alone registers/publishes it."""
    props = {
        "operation_id": {"type": "string", "format": "uuid", "pattern": "^[0-9a-f-]{36}$"},
        "source_ref": {"type": "string", "pattern": "^[A-Za-z0-9_-]{1,96}$"},
        "config_generation": {"type": "integer", "minimum": 1, "maximum": 2**63-1},
        "connection_epoch": {"type": "string", "pattern": "^[0-9a-f]{32}$"},
        "name": {"type": "string", "minLength": 1, "maxLength": 255,
                 "description": "Portable basename for the original owner staging plan; no path."},
        "file": {"type": "object", "additionalProperties": False,
                 "properties": {"download_url": {"type": "string", "maxLength": MAX_URL_BYTES},
                                "file_id": {"type": "string", "maxLength": 134},
                                "mime_type": {"type": "string", "maxLength": 255},
                                "file_name": {"type": "string", "maxLength": 255}},
                 "required": ["download_url", "file_id"]}}
    output = {
        "schema_version": {"type": "integer", "const": 1},
        "operation": {"type": "string", "const": "import_attachment"},
        "state": {"type": "string", "const": "staged"},
        **{k: props[k] for k in ("operation_id", "source_ref", "config_generation", "connection_epoch", "name")},
        "file_id": {"type": "string"}, "transfer_ref": {"type": "string", "pattern": "^[0-9a-f]{64}$"},
        "size": {"type": "integer", "minimum": 0, "maximum": MAX_BYTES},
        "sha256": {"type": "string", "pattern": "^[0-9a-f]{64}$"},
        "expires_in_seconds": {"type": "number", "exclusiveMinimum": 0, "maximum": 120},
        "complete": {"type": "boolean", "const": True},
        "direction": {"type": "string", "const": "upload"},
        "nas_write_performed": {"type": "boolean", "const": False},
        "write_approval_required": {"type": "boolean", "const": True},
        "downloadable_artifact": {"type": "boolean", "const": False},
        "automatic_replay": {"type": "boolean", "const": False}}
    return {"name": TOOL_NAME, "title": "Import selected attachment to ARL staging",
            "description": "Use this when the user explicitly selects a ChatGPT attachment for the original ARL/NAS operation. Receives the platform file object via fileParams. Downloads at most 1MiB, seals 32KiB chunks in the original owner transfer, and returns only staging metadata. No NAS write is performed; a separate exact native write approval remains required. Do not construct a URL or local path. No automatic retry.",
            "inputSchema": {"type": "object", "additionalProperties": False,
                            "properties": props, "required": sorted(props)},
            "outputSchema": {"type": "object", "additionalProperties": False,
                             "properties": output, "required": sorted(output)},
            "annotations": {"readOnlyHint": True, "destructiveHint": False,
                            "openWorldHint": False, "idempotentHint": False},
            "_meta": {"openai/fileParams": ["file"], "arl/capability": "mio_nas_attachment",
                      "arl/version": 1, "arl/requiresConfirmation": False}}


def inspection_descriptor():
    """Smallest production smoke entry: standard files, no NAS scope or store."""
    original = descriptor()
    props = {key: original["inputSchema"]["properties"][key] for key in ("operation_id", "file")}
    output = {"schema_version": {"type": "integer", "const": 1},
              "operation": {"type": "string", "const": "inspect_attachment"},
              "operation_id": props["operation_id"],
              "state": {"type": "string", "const": "verified"},
              "file_id": {"type": "string"},
              "size": {"type": "integer", "minimum": 0, "maximum": 9007199254740991},
              "sha256": {"type": "string", "pattern": "^[0-9a-f]{64}$"},
              "nas_write_performed": {"type": "boolean", "const": False},
              "stored": {"type": "boolean", "const": False},
              "automatic_replay": {"type": "boolean", "const": False}}
    return dict(name="mio_attachment_inspect", title="Verify selected attachment input",
                description="Use this when the user selects a ChatGPT attachment to verify ARL can receive it. Reads at most 1MiB through platform fileParams and returns only size/SHA256. No file is retained or written to NAS. This call does not need or create a NAS scope; do not construct a URL.",
                inputSchema={"type": "object", "additionalProperties": False,
                             "properties": props, "required": sorted(props)},
                outputSchema={"type": "object", "additionalProperties": False,
                              "properties": output, "required": sorted(output)},
                annotations={"readOnlyHint": True, "destructiveHint": False,
                             "openWorldHint": False, "idempotentHint": True},
                _meta={"openai/fileParams": ["file"], "arl/capability": "mio_attachment",
                       "arl/version": 1, "arl/requiresConfirmation": False})


def inspect_attachment(value, *, verify, clock=time.monotonic):
    """Receive actual standard fileParams independently of NAS availability.

    Existing authenticated caller admission is still mandatory. A successful
    digest receipt proves only byte reception, not NAS upload or retention.
    """
    if not callable(verify):
        fail("verified_caller_required")
    if type(value) is not dict or set(value) != {"operation_id", "file"}:
        fail("invalid_import_request")
    try:
        canonical = str(uuid.UUID(value["operation_id"]))
    except (ValueError, TypeError, AttributeError):
        fail("invalid_import_request")
    if canonical != value["operation_id"]:
        fail("invalid_import_request")
    source = file_param(value["file"])
    verify()
    size, sha = fetch(source, verify=verify, clock=clock, receipt_only=True)
    verify()
    return dict(schema_version=1, operation="inspect_attachment", operation_id=canonical,
                state="verified", file_id=source.file_id, size=size, sha256=sha,
                nas_write_performed=False, stored=False, automatic_replay=False)


class _PinnedHTTPS(http.client.HTTPSConnection):
    """Fixed public IP, original SNI/hostname validation, no env proxies."""
    def __init__(self, host, ip, timeout):
        super().__init__(host, port=443, timeout=timeout, context=ssl.create_default_context())
        self._ip = ip
    def connect(self):
        raw = socket.create_connection((self._ip, 443), timeout=self.timeout)
        try:
            self.sock = self._context.wrap_socket(raw, server_hostname=self.host)
        except BaseException:
            raw.close()
            raise


def _addresses(host):
    rows = socket.getaddrinfo(host, 443, type=socket.SOCK_STREAM)
    if not rows or len(rows) > 32:
        fail("attachment_dns_rejected")
    ips = []
    for family, socktype, proto, canonname, address in rows:
        try:
            ip = ipaddress.ip_address(address[0])
        except ValueError:
            fail("attachment_dns_rejected")
        if (family not in (socket.AF_INET, socket.AF_INET6) or socktype != socket.SOCK_STREAM
                or not ip.is_global or getattr(ip, "ipv4_mapped", None) is not None):
            fail("attachment_dns_rejected")
        if str(ip) not in ips:
            ips.append(str(ip))
    return ips


def fetch(source, *, verify, clock=time.monotonic, receipt_only=False):
    """One HTTPS GET, no redirects/retries/auth forwarding or decompression.

    verify is the original native caller/request verifier; no default grants.
    The native outer request deadline must also bound OS DNS resolution.
    Socket operations and body consumption have a 20s remaining-time budget.
    No payload is returned before a complete bounded response and owner recheck.
    """
    if type(source) is not FileParam or not callable(verify):
        fail("verified_caller_required")
    source = file_param({k: v for k, v in {
        "file_id": source.file_id, "download_url": source.download_url,
        "file_name": source.file_name, "mime_type": source.mime_type}.items() if v is not None})
    start = clock()
    if type(start) not in (int, float) or not math.isfinite(start):
        fail("attachment_expired")
    previous = start
    def live():
        nonlocal previous
        now = clock()
        if type(now) not in (int, float) or not math.isfinite(now) or now < previous or now >= start+DOWNLOAD_SECONDS:
            fail("attachment_expired")
        previous = now
        verify()
        return start+DOWNLOAD_SECONDS-now
    live()
    try:
        ips = _addresses(FILE_HOST)
    except BridgeFault:
        raise
    except (OSError, ValueError):
        fail("attachment_dns_rejected")
    remaining = live()
    connection = _PinnedHTTPS(FILE_HOST, ips[0], remaining)  # never retry another address
    response = None
    try:
        parsed = urlsplit(source.download_url)
        target = parsed.path + ("?"+parsed.query if parsed.query else "")
        connection.request("GET", target, headers={"Accept-Encoding": "identity", "Connection": "close"})
        remaining = live()
        if connection.sock is not None:
            connection.sock.settimeout(remaining)
        body_socket = connection.sock
        response = connection.getresponse()
        live()
        if response.status != 200:
            fail("attachment_unavailable")  # includes redirects and expired signed URLs
        headers = response.getheaders()
        def values(name):
            return [v.strip() for k, v in headers if k.lower() == name]
        lengths, encodings, transfers = values("content-length"), values("content-encoding"), values("transfer-encoding")
        if (len(lengths) > 1 or len(encodings) > 1 or len(transfers) > 1
                or encodings and encodings != ["identity"]
                or transfers and [v.lower() for v in transfers] != ["chunked"]
                or lengths and transfers):
            fail("attachment_response_invalid")
        expected = None
        if lengths:
            if re.fullmatch("[0-9]{1,10}", lengths[0]) is None:
                fail("attachment_response_invalid")
            expected = int(lengths[0])
            if not receipt_only and expected > MAX_BYTES:
                fail("attachment_too_large")
        data = bytearray(); received = 0; hasher = hashlib.sha256()
        while True:
            remaining = live()
            if body_socket is not None and not response.isclosed():
                body_socket.settimeout(remaining)
            raw = response.read(CHUNK_BYTES if receipt_only else min(CHUNK_BYTES, MAX_BYTES+1-len(data)))
            live()
            if type(raw) is not bytes:
                fail("attachment_response_invalid")
            if not raw:
                break
            received += len(raw); hasher.update(raw)
            if not receipt_only:data.extend(raw)
            if not receipt_only and len(data) > MAX_BYTES:
                fail("attachment_too_large")
        if expected is not None and received != expected:
            fail("attachment_truncated")
        live()
        if receipt_only:return received, hasher.hexdigest()
        artifact = VerifiedFile(source.file_name or "attachment.bin", bytes(data), digest(data))
        artifact.check()
        return artifact
    except BridgeFault:
        raise
    except (OSError, ValueError, http.client.HTTPException):
        fail("attachment_fetch_failed")  # never leak URL/header/server text in errors
    finally:
        if response is not None:
            response.close()
        connection.close()


def import_attachment(value, *, verify, create_transfer, clock=time.monotonic):
    """Fetch documented fileParams then seal an original owner FileTransfer.

    verify() must recheck the original authenticated MCP call, selected file and
    saved scope/epoch; metadata is not authorization. create_transfer is the
    original owner's factory, not an MCP argument. It must return the exact
    operation/fence/name/size/SHA requested here and retain successful transfers.
    Failed created transfers are closed; no native mutation permit is consumed.
    """
    if not callable(verify) or not callable(create_transfer):
        fail("verified_caller_required")
    captured, source = request(value)
    verify()
    artifact = fetch(source, verify=verify, clock=clock)
    verify()
    from homeplane.nas_connection.file_transfer import FileTransfer
    from homeplane.nas_connection.file_operations import ScopeFence
    fence = ScopeFence(captured["source_ref"], captured["config_generation"], captured["connection_epoch"])
    transfer = create_transfer(operation_id=captured["operation_id"], fence=fence,
                               name=captured["name"], size=len(artifact.data), sha256=artifact.sha256)
    if type(transfer) is not FileTransfer:
        fail("owner_transfer_required")
    context = dict(ref=transfer.ref, operation_id=captured["operation_id"], fence=fence)
    if (transfer.operation_id != captured["operation_id"] or transfer.fence != fence
            or transfer.name != captured["name"] or transfer.size != len(artifact.data)
            or transfer.sha256 != artifact.sha256 or transfer.direction != "upload"
            or transfer.offset != 0 or transfer.sealed or transfer.claimed):
        fail("binding_mismatch")  # do not close a different owner's returned transfer
    try:
        for offset in range(0, len(artifact.data), CHUNK_BYTES):
            verify()
            raw = artifact.data[offset:offset+CHUNK_BYTES]
            transfer.append(**context, offset=offset, data_base64=base64.b64encode(raw).decode("ascii"), sha256=digest(raw))
            verify()
        verify()
        sealed = transfer.finish(**context)
        verify()
        return dict(sealed, operation="import_attachment", state="staged", file_id=source.file_id,
                    nas_write_performed=False, write_approval_required=True, automatic_replay=False)
    except BaseException:
        transfer.broken = True
        transfer.close()
        raise
