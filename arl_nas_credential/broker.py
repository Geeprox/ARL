"""Private ephemeral credential use; no store, public resolver or logging."""
from __future__ import annotations

import asyncio
import math
import secrets
import time
from dataclasses import dataclass
from typing import Awaitable, Callable, Protocol

from .contracts import (Admission, CallerPins, CredentialFault, CredentialSnapshot,
                        CurrentSource, Failure, HostAuthorizer, NASReadScope, SERVICE, TRANSIENT)


class PrivateCredential:
    """Owned ephemeral bytes, usable only inside the controlled transport callback.

    Strings/libraries may make immutable copies. Clearing is best effort, not a
    claim of complete memory zeroization. Never put this object on an RPC/log.
    """
    __slots__ = ("scope", "expires_at", "_username", "_password", "_cleared")

    def __init__(self, scope: NASReadScope, expires_at: float, username: bytes, password: bytes):
        if (not isinstance(scope, NASReadScope) or type(expires_at) not in {int, float}
                or not math.isfinite(expires_at) or not isinstance(username, bytes)
                or not isinstance(password, bytes) or not 1 <= len(username) <= 1024
                or not 1 <= len(password) <= 32768):
            raise CredentialFault(Failure.CREDENTIAL_INVALID)
        self.scope, self.expires_at = scope, expires_at
        self._username, self._password = bytearray(username), bytearray(password)
        self._cleared = False

    def __repr__(self):
        return "<PrivateCredential redacted>"

    def __reduce_ex__(self, protocol):
        raise TypeError("private_credential_not_serializable")

    def _pair(self):
        invalid, pair = False, None
        try:
            if self._cleared:
                invalid = True
            else:
                username, password = self._username.decode("utf-8"), self._password.decode("utf-8")
                if (not username or not password or len(username) > 256 or len(password) > 8192
                        or any(ord(c) < 32 for c in username)):
                    invalid = True
                else:
                    pair = (username, password)
        except UnicodeError:
            invalid = True
        if invalid:
            raise CredentialFault(Failure.CREDENTIAL_INVALID)
        return pair

    def clear(self):
        for value in (self._username, self._password):
            value[:] = b"\0" * len(value)
            value.clear()
        self._cleared = True


class PrivateProvider(Protocol):
    async def use(self, scope: NASReadScope, caller: CallerPins,
                  consume: Callable[[PrivateCredential], Awaitable[None]]) -> None:
        """Native owner leases its purpose-bound entry, calls once, clears finally.

        No return-secret API and no fallback. Missing NAS purpose is unsupported.
        Must verify item identity/generation and native login/peer gates internally.
        """
        ...


@dataclass(frozen=True)
class _Ticket:
    identifier: str


class CredentialBroker:
    def __init__(self, *, scope: NASReadScope, caller: CallerPins, admission: Admission = Admission(),
                 authorizer: HostAuthorizer | None = None, provider: PrivateProvider | None = None,
                 current_source: Callable[[], CurrentSource | None] | None = None,
                 clock: Callable[[], float] = time.monotonic):
        self.scope, self.caller, self.admission = scope, caller, admission
        self._authorizer, self._provider, self._current_source, self._clock = authorizer, provider, current_source, clock
        self.deadline = clock() + admission.ttl_seconds
        self._lock = asyncio.Lock()
        self._pending = None
        self._used = 0
        self._failure = None
        self._last_failure = None
        self._state = "not_checked"
        self._available = None

    def snapshot(self) -> CredentialSnapshot:
        # Passive, does not verify identity/source, lease, prompt or contact NAS.
        state, failure, available = self._state, self._failure or self._last_failure, self._available
        if self._provider is None:
            state = "unsupported"
        elif not self.admission.enabled:
            state = "disabled"
        elif self._failure is None and self._clock() >= self.deadline:
            state, failure, available = "failed", Failure.EXPIRED, None
        return CredentialSnapshot(1, SERVICE, state, failure.value if failure else None,
                                  self._used, max(0, self.admission.connection_attempts - self._used), available)

    def revoke(self):
        self._failure, self._state, self._pending = Failure.REVOKED, "revoked", None
        self._available = None

    def cancel(self):
        self._failure, self._state, self._pending = Failure.CANCELLED, "cancelled", None
        self._available = None

    def _reject(self, code: Failure):
        self._last_failure = code
        if code not in TRANSIENT:
            self._failure, self._pending = code, None
            self._state = code.value if code in {Failure.CANCELLED, Failure.REVOKED} else "failed"
            if code not in {Failure.CREDENTIAL_INVALID, Failure.CREDENTIALS_UNAVAILABLE}:
                self._available = None
        raise CredentialFault(code)

    def _source_ok(self):
        valid = False
        try:
            source = self._current_source() if self._current_source else None
            valid = (isinstance(source, CurrentSource) and source.enabled is True and source.scope == self.scope)
        except Exception:
            pass
        if not valid:
            self._reject(Failure.SOURCE_CHANGED)

    def _check_current(self):
        # No await between this renewed local boundary and the caller's effect.
        # A current-source hook may itself block, so renew lifetime/cancel after it.
        if self._failure:
            self._reject(self._failure)
        if self._clock() >= self.deadline:
            self._reject(Failure.EXPIRED)
        self._source_ok()
        if self._failure:
            self._reject(self._failure)
        if self._clock() >= self.deadline:
            self._reject(Failure.EXPIRED)

    def _check_private_lease(self, lease):
        self._check_current()
        if (not isinstance(lease, PrivateCredential) or lease.scope != self.scope
                or lease._cleared or type(lease.expires_at) not in {int, float}
                or not math.isfinite(lease.expires_at) or lease.expires_at > self.deadline):
            self._reject(Failure.CREDENTIAL_INVALID)
        if self._clock() >= lease.expires_at:
            self._reject(Failure.EXPIRED)

    async def check(self, stage: str):
        if self._failure:
            self._reject(self._failure)
        if self._provider is None:
            self._reject(Failure.UNSUPPORTED)
        if not self.admission.enabled:
            self._reject(Failure.DISABLED)
        self._check_current()
        if self._authorizer is None:
            self._reject(Failure.CALLER_UNVERIFIED)
        verified = False
        try:
            await self._authorizer.verify(self.caller, self.scope, stage)
            verified = True
        except Exception:
            pass
        # Renew cancellation, lifetime and source after potentially blocking code
        # verification. Host verification must itself renew peer/epoch checks.
        self._check_current()
        if not verified:
            self._reject(Failure.CALLER_UNVERIFIED)

    async def reserve(self, reference: str) -> _Ticket:
        async with self._lock:
            await self.check("reserve")
            if reference != self.scope.credential_ref:
                self._reject(Failure.REFERENCE_MISMATCH)
            if self._pending is not None:
                self._reject(Failure.BUSY)
            if self._used >= self.admission.connection_attempts:
                self._reject(Failure.BUDGET_EXHAUSTED)
            self._used += 1  # Finite attempt consumed before resolution/effect.
            ticket = _Ticket(secrets.token_hex(16))
            self._pending = ticket
            return ticket

    async def use(self, ticket: _Ticket, consume: Callable[[PrivateCredential], Awaitable[dict]]) -> dict:
        async with self._lock:
            await self.check("lease")
            if type(ticket) is not _Ticket or ticket is not self._pending:
                self._reject(Failure.TICKET_INVALID)
            self._pending = None  # Single use even on cancellation/uncertain return.
            self._state = "resolving"
            calls, result, fault = 0, None, None

            async def controlled(lease):
                nonlocal calls, result
                calls += 1
                if calls != 1 or not isinstance(lease, PrivateCredential):
                    self._reject(Failure.PROVIDER_INVALID)
                try:
                    await self.check("connect")
                    self._check_private_lease(lease)
                    result = await consume(lease)
                    await self.check("reply")
                finally:
                    lease.clear()

            try:
                await self._provider.use(self.scope, self.caller, controlled)
                if calls != 1 or result is None:
                    fault = Failure.CREDENTIALS_UNAVAILABLE
            except CredentialFault as exc:
                fault = exc.code
            except asyncio.CancelledError:
                self.cancel()
                raise
            except Exception:
                fault = Failure.PROVIDER_INVALID
            # Raise outside exception handlers so private provider errors are not
            # attached as exception contexts or copied into a public message.
            if fault:
                # Network/auth errors cannot prove a native item is missing or
                # a stored secret is invalid. Local lease absence/shape can.
                self._available = False if fault in {Failure.CREDENTIALS_UNAVAILABLE, Failure.CREDENTIAL_INVALID} else None
                self._state = "failed"
                self._reject(fault)
            await self.check("provider_reply")
            self._state, self._available, self._last_failure = "resolved", True, None
            return result
