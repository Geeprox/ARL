"""Versioned direct NAS reader contracts. No public filesystem paths or secrets."""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

MAX_RANGE = 1024 * 1024
MAX_PAGE = 128
ERRORS = frozenset({
    "nas_not_configured", "nas_disabled", "nas_unavailable", "nas_busy", "nas_source_changed",
    "nas_object_unknown", "nas_cursor_expired", "nas_missing", "nas_revision_changed",
    "nas_invalid_request", "nas_budget_exceeded", "nas_auth_failed", "nas_access_denied",
    "nas_host_key_mismatch", "nas_dependency_missing", "nas_timeout", "nas_transport_failed",
})


class NASConnectionError(Exception):
    """Only a fixed code crosses the transport boundary; exception text is discarded."""

    def __init__(self, code: str):
        self.code = code if code in ERRORS else "nas_transport_failed"
        super().__init__(self.code)


def relative_path(value: str, *, allow_root: bool = False) -> str:
    # SMB/SFTP use literal names, never URL-decode them. Percent is a normal character.
    if allow_root and value == "":
        return value
    if (not isinstance(value, str) or not value or len(value.encode()) > 1024
            or any(ord(c) < 32 for c in value) or any(c in value for c in "\\:")
            or any(part in {"", ".", ".."} or len(part.encode()) > 255 for part in value.split("/"))):
        raise NASConnectionError("nas_invalid_request")
    return value


class Contract(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)


class NASConnectionConfig(Contract):
    schema_version: Literal[1] = 1
    source_ref: str = Field(pattern=r"^[A-Za-z0-9_-]{1,96}$")
    transport: Literal["smb", "sftp"]
    host: str = Field(min_length=1, max_length=253)
    port: int | None = Field(default=None, ge=1, le=65535)
    share: str | None = Field(default=None, max_length=255)
    root: str = Field(default="", max_length=1024)
    credential_ref: str = Field(pattern=r"^[A-Za-z0-9_-]{1,128}$")
    enabled: bool = False
    require_encryption: bool = True
    host_key_sha256: str | None = Field(default=None, pattern=r"^SHA256:[A-Za-z0-9+/]{43}$")
    # SFTP v3 has no atomic open-beneath. Reads require a server-enforced account root.
    sftp_root_confined: bool = False
    connect_timeout_seconds: float = Field(default=8, ge=0.05, le=30, allow_inf_nan=False)
    operation_timeout_seconds: float = Field(default=5, ge=0.05, le=30, allow_inf_nan=False)
    health_interval_seconds: float = Field(default=30, ge=0.05, le=300, allow_inf_nan=False)
    backoff_initial_seconds: float = Field(default=1, ge=0.05, le=60, allow_inf_nan=False)
    backoff_max_seconds: float = Field(default=60, ge=0.05, le=300, allow_inf_nan=False)

    @field_validator("host")
    @classmethod
    def host_only(cls, value):
        # IPv4, IPv6 or DNS only: no URL/userinfo/UNC/query/port interpretation.
        import ipaddress

        try:
            ipaddress.ip_address(value)
        except ValueError:
            labels = value.rstrip(".").split(".")
            if not all(re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?", x) for x in labels):
                raise ValueError("nas_invalid_host") from None
        return value

    @model_validator(mode="after")
    def endpoint(self):
        if self.backoff_max_seconds < self.backoff_initial_seconds:
            raise ValueError("nas_invalid_backoff")
        if self.transport == "smb":
            if not self.share or "/" in self.share:
                raise ValueError("nas_share_required")
            try:
                relative_path(self.share)
                relative_path(self.root, allow_root=True)
            except NASConnectionError:
                raise ValueError("nas_invalid_request") from None
            if self.host_key_sha256 or self.sftp_root_confined or ":" in self.host:
                raise ValueError("nas_invalid_smb_config")
        elif self.share or not self.host_key_sha256 or self.root != "/" or not self.sftp_root_confined:
            raise ValueError("nas_sftp_requires_pinned_server_confined_root")
        return self

    @property
    def effective_port(self):
        return self.port or (445 if self.transport == "smb" else 22)


@dataclass(frozen=True)
class NASCredentials:
    """Ephemeral resolver result. Never persisted or included in repr/status/schema."""

    username: str = field(repr=False)
    password: str = field(repr=False)

    def payload(self):
        if (not self.username or not self.password or len(self.username) > 256 or len(self.password) > 8192
                or any(ord(c) < 32 for c in self.username)):
            raise NASConnectionError("nas_auth_failed")
        return {"username": self.username, "password": self.password}


class NASConnectionStatus(Contract):
    schema_version: Literal[1] = 1
    source_ref: str | None = None
    config_generation: int = Field(ge=0)
    connection_epoch: str | None = None
    configured: bool = False
    enabled: bool = False
    state: Literal["not_configured", "disabled", "connecting", "online", "backoff", "paused", "stopped"]
    reachable: bool | None = None
    authenticated: bool | None = None
    readable: bool | None = None
    failure: str | None = None
    retry_in_seconds: float | None = None
    checked_at: datetime | None = None


class NASConnectionSettings(Contract):
    """Owner-local saved config and cached status; never resolves a credential."""

    config: NASConnectionConfig | None
    status: NASConnectionStatus
    credential_reference_saved: bool
    credential_availability: Literal["not_checked"] = "not_checked"


class NASConnectionEntry(Contract):
    object_ref: str = Field(pattern=r"^[0-9a-f]{64}$")
    kind: Literal["file", "directory"]
    revision: str = Field(pattern=r"^[0-9a-f]{64}$")
    size: int = Field(ge=0)
    modified_ns: int | None = None
    media_kind: Literal["image", "video", "audio", "other"] = "other"
    closed: None = None
    revision_basis: Literal["metadata"] = "metadata"


class NASConnectionPage(Contract):
    schema_version: Literal[1] = 1
    source_ref: str
    config_generation: int = Field(ge=1)
    connection_epoch: str
    entries: list[NASConnectionEntry] = Field(max_length=MAX_PAGE)
    next_cursor: str | None = None
    enumeration_complete: bool = False
    completed_scan_token: str | None = None
    snapshot_consistent: Literal[False] = False


class NASConnectionEdit(Contract):
    expected_generation: int = Field(ge=0)
    config: NASConnectionConfig


class NASConnectionCommand(Contract):
    expected_generation: int = Field(ge=0)


# File consumers are distinct from the historical opaque metadata inventory.
FILE_PAGE = 32
FILE_READ = 128 * 1024
FILE_SESSION_BYTES = 1024 * 1024
FILE_OUTPUT = 192 * 1024


def file_request(value):
    """Strict private command DTO; no endpoint, credential or caller selectors."""
    if type(value) is not dict:
        raise NASConnectionError("nas_invalid_request")
    operation = value.get("operation")
    if type(operation) is not str:
        raise NASConnectionError("nas_invalid_request")
    if operation in {"list", "search"}:
        allowed = {"operation", "directory_ref", "cursor", "limit"}
        if operation == "search": allowed.add("keyword")
        if not set(value) <= allowed or (operation == "search" and "keyword" not in value):
            raise NASConnectionError("nas_invalid_request")
        for key, size in (("directory_ref", 64), ("cursor", 32)):
            item = value.get(key)
            if key in value and (type(item) is not str or re.fullmatch("[0-9a-f]{%d}" % size, item) is None):
                raise NASConnectionError("nas_invalid_request")
        limit = value.get("limit", 16)
        if type(limit) is not int or not 1 <= limit <= FILE_PAGE:
            raise NASConnectionError("nas_invalid_request")
        keyword = value.get("keyword")
        if operation == "search" and (type(keyword) is not str or not 1 <= len(keyword.encode()) <= 256
                or any(ord(c) < 32 or ord(c) == 127 for c in keyword)):
            raise NASConnectionError("nas_invalid_request")
        return dict(value, limit=limit)
    keys = {"operation", "source_ref", "config_generation", "connection_epoch", "object_ref", "revision", "offset", "length"}
    if operation != "read" or set(value) != keys:
        raise NASConnectionError("nas_invalid_request")
    for key, pattern in (("source_ref", r"[A-Za-z0-9_-]{1,96}"), ("connection_epoch", r"[0-9a-f]{32}"),
                         ("object_ref", r"[0-9a-f]{64}"), ("revision", r"[0-9a-f]{64}")):
        if type(value[key]) is not str or re.fullmatch(pattern, value[key]) is None:
            raise NASConnectionError("nas_invalid_request")
    if (type(value["config_generation"]) is not int or not 1 <= value["config_generation"] <= 2**63-1
            or type(value["offset"]) is not int or not 0 <= value["offset"] <= 2**63-1
            or type(value["length"]) is not int or not 1 <= value["length"] <= FILE_READ):
        raise NASConnectionError("nas_invalid_request")
    return dict(value)
