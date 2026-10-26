"""Finite host-only admission contracts. Descriptors are never authentication."""
from __future__ import annotations

import hashlib
import json
import math
import re
from dataclasses import dataclass
from enum import Enum
from typing import ClassVar, Protocol

SERVICE = "arl.nas.read-session.v1"


class Failure(str, Enum):
    UNSUPPORTED = "unsupported"
    DISABLED = "disabled"
    CALLER_UNVERIFIED = "caller_unverified"
    SOURCE_CHANGED = "source_changed"
    REFERENCE_MISMATCH = "reference_mismatch"
    CANCELLED = "cancelled"
    REVOKED = "revoked"
    EXPIRED = "expired"
    BUDGET_EXHAUSTED = "budget_exhausted"
    TICKET_INVALID = "ticket_invalid"
    PROVIDER_INVALID = "provider_invalid"
    CREDENTIALS_UNAVAILABLE = "credentials_unavailable"
    CREDENTIAL_INVALID = "credential_invalid"
    BUSY = "busy"
    AUTH_FAILED = "auth_failed"
    ACCESS_DENIED = "access_denied"
    HOST_KEY_MISMATCH = "host_key_mismatch"
    TRANSPORT_TIMEOUT = "transport_timeout"
    TRANSPORT_FAILED = "transport_failed"


TRANSIENT = frozenset({Failure.BUSY, Failure.TRANSPORT_TIMEOUT, Failure.TRANSPORT_FAILED})


class CredentialFault(Exception):
    def __init__(self, code: Failure):
        self.code = code if isinstance(code, Failure) else Failure.PROVIDER_INVALID
        super().__init__(self.code.value)


def _matches(pattern: str, value: str) -> bool:
    return isinstance(value, str) and re.fullmatch(pattern, value) is not None


def digest(value: dict) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":"),
                                    allow_nan=False).encode()).hexdigest()


@dataclass(frozen=True)
class CallerPins:
    """Created only by the registered native host. Verify actual peer each time.

    No Codable/RPC decoder or approved Boolean is provided. Constructing this
    Python descriptor alone grants nothing; HostAuthorizer is mandatory.
    """
    subject: str
    uid: int
    pid: int
    executable_sha256: str
    designated_requirement_sha256: str
    profile_sha256: str
    registration_epoch: int

    def __post_init__(self):
        valid = (_matches(r"[A-Za-z0-9_.-]{1,128}", self.subject)
                 and type(self.uid) is int and 0 <= self.uid <= 2**32 - 1
                 and type(self.pid) is int and 0 < self.pid <= 2**31 - 1
                 and type(self.registration_epoch) is int and 0 < self.registration_epoch <= 2**64 - 1
                 and all(_matches(r"[0-9a-f]{64}", x) for x in
                         (self.executable_sha256, self.designated_requirement_sha256, self.profile_sha256)))
        if not valid:
            raise CredentialFault(Failure.CALLER_UNVERIFIED)


@dataclass(frozen=True)
class NASReadScope:
    service: ClassVar[str] = SERVICE
    source_ref: str
    credential_ref: str
    credential_generation: str
    config_fingerprint: str
    root_descriptor_digest: str
    config_generation: int

    def __post_init__(self):
        valid = (_matches(r"[A-Za-z0-9_-]{1,96}", self.source_ref)
                 and _matches(r"[A-Za-z0-9_-]{1,128}", self.credential_ref)
                 and _matches(r"[0-9a-f]{32}", self.credential_generation)
                 and _matches(r"[0-9a-f]{64}", self.config_fingerprint)
                 and _matches(r"[0-9a-f]{64}", self.root_descriptor_digest)
                 and type(self.config_generation) is int and 0 < self.config_generation <= 2**63 - 1)
        if not valid:
            raise CredentialFault(Failure.SOURCE_CHANGED)

    @classmethod
    def from_config(cls, config, generation: int, credential_generation: str):
        # The bridge passes the source manager's already validated immutable config. This
        # method is not an untrusted config parser. Enabled is checked separately.
        values = config.model_dump(mode="json")
        values.pop("enabled")
        root = {key: values[key] for key in ("transport", "host", "port", "share", "root",
                                             "require_encryption", "host_key_sha256", "sftp_root_confined")}
        return cls(config.source_ref, config.credential_ref, credential_generation,
                   digest(values), digest(root), generation)


@dataclass(frozen=True)
class CurrentSource:
    scope: NASReadScope
    enabled: bool


@dataclass(frozen=True)
class Admission:
    # Supplied by a trusted host after manual setup/admission, never a UI Boolean.
    enabled: bool = False
    ttl_seconds: float = 120
    connection_attempts: int = 1

    def __post_init__(self):
        if (type(self.enabled) is not bool or type(self.connection_attempts) is not int
                or not 1 <= self.connection_attempts <= 8
                or type(self.ttl_seconds) not in {int, float}
                or not math.isfinite(self.ttl_seconds) or not 0 < self.ttl_seconds <= 300):
            raise CredentialFault(Failure.DISABLED)


class HostAuthorizer(Protocol):
    async def verify(self, caller: CallerPins, scope: NASReadScope, stage: str) -> None:
        """Raise unless actual kernel peer/code/profile/current epoch is valid.

        Must use the existing native registered-peer boundary, not strings,
        a model-provided approval flag or OS authorization alone.
        """
        ...


@dataclass(frozen=True)
class CredentialSnapshot:
    schema_version: int
    service: str
    state: str
    failure: str | None
    attempts_used: int
    attempts_remaining: int
    credential_available: bool | None
    # No endpoint, username, password, native handle, ticket or caller pins.
