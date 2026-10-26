"""Small host-private manual settings controller. No secret-entry/store API."""
from __future__ import annotations

import asyncio
import time
from dataclasses import dataclass
from enum import Enum
from typing import Callable, Protocol

from homeplane.nas_connection import NASConnectionConfig, NASConnectionError
from .contracts import NASReadScope
from .scope_bridge import ScopedNASConnection


class Action(str, Enum):
    SAVE_CONFIGURATION = "save_configuration"
    SAVE_CREDENTIAL = "save_credential"
    TEST_CONNECTION = "test_connection"
    TEST_READ = "test_read"
    TEST_WRITE = "test_write"
    RECONNECT = "reconnect"
    STOP = "stop"


@dataclass(frozen=True)
class SetupRequest:
    action: Action
    configuration: NASConnectionConfig
    expected_snapshot_revision: int
    read_scope: NASReadScope | None = None


class _ManualIntent:
    __slots__ = ("_owner", "_request", "_deadline", "_used")

    def __init__(self, owner, request, deadline):
        self._owner, self._request, self._deadline, self._used = owner, request, deadline, False

    def consume(self, owner, request, now):
        valid = (not self._used and self._owner is owner and self._request == request and now < self._deadline)
        self._used = True
        return valid


class HostComposer(Protocol):
    async def compose(self, configuration: NASConnectionConfig, target_generation: int,
                      request: SetupRequest) -> ScopedNASConnection:
        """Trusted owner uses actual peer/native purpose/current-generation gates.

        Not an RPC enrollment or grant hook. Must return a paired source-bound
        manager on the same private state path, without starting it. Default absent.
        """
        ...


class NASSetupController:
    def __init__(self, connection: ScopedNASConnection, *, composer: HostComposer | None = None,
                 clock=time.monotonic):
        self.connection, self._composer, self._clock = connection, composer, clock
        self._revision, self._cancel_epoch = 0, 0
        self._manual_owner = object()
        self._lock = asyncio.Lock()

    def snapshot(self):
        # Existing manager.status() and broker.snapshot() are cache/clock reads.
        snapshot = self.connection.snapshot()
        snapshot["snapshot_revision"] = self._revision
        snapshot["configuration"] = (self.connection.manager.config.model_dump(mode="json")
                                      if self.connection.manager.config else None)
        snapshot["action_availability"] = {
            "save_configuration": "allowed", "save_credential": "unsupported",
            "test_connection": "manual_host_required" if self._composer else "unsupported",
            "test_read": "manual_host_required" if self._composer else "unsupported",
            "test_write": "unsupported", "reconnect": "manual_host_required" if self._composer else "unsupported",
            "stop": "allowed"}
        return snapshot

    def capture_click(self, request: SetupRequest):
        """Called synchronously by the trusted UI click handler, never RPC-decoded.

        Indicates exact user intent only; grants no native/source/content access.
        """
        return _ManualIntent(self._manual_owner, request, self._clock() + 30)

    def _reply(self, request, outcome, fault=None):
        return {"schema_version": 1, "action": request.action.value, "outcome": outcome,
                "failure": fault, "snapshot": self.snapshot()}

    async def perform(self, request: SetupRequest, intent=None, *,
                      _after_stop_admission: Callable[[], str | None] | None = None):
        if (not isinstance(request, SetupRequest) or not isinstance(request.action, Action)
                or not isinstance(request.configuration, NASConnectionConfig)
                or type(request.expected_snapshot_revision) is not int):
            # An untyped request never gets reflected into public error text.
            return {"schema_version": 1, "outcome": "failed", "failure": "invalid_configuration"}
        if type(intent) is not _ManualIntent or not intent.consume(self._manual_owner, request, self._clock()):
            return self._reply(request, "held", "manual_intent_required")
        if request.expected_snapshot_revision != self._revision:
            return self._reply(request, "held", "stale_generation")
        if request.action == Action.STOP:
            # A host-private synchronous commit runs only after this exact
            # controller consumed the real one-use intent and checked revision.
            # No await separates that admission, the bridge's final binding
            # checks/cancellation, and this controller's Stop mutations. The
            # callback is never carried in a request, cache, or channel DTO.
            if _after_stop_admission is not None:
                try:
                    fault = _after_stop_admission()
                except Exception:
                    return self._reply(request, "held", "manual_intent_required")
                if fault is not None:
                    allowed = {"binding_mismatch", "stale_generation", "configuration_changed",
                               "configuration_not_saved", "invalid_configuration",
                               "protocol_unsupported", "write_unsupported"}
                    return self._reply(request, "held", fault if type(fault) is str and fault in allowed
                                       else "manual_intent_required")
            # Cancel before waiting for occupied native I/O to finish; no public
            # permission-cancel RPC or claim that a busy native call returned.
            self._cancel_epoch += 1
            self.connection.credentials.cancel()
            manager = self.connection.manager
            if manager.config:
                try:
                    await manager.disable(expected_generation=manager.generation)
                except NASConnectionError:
                    await manager.close()
            else:
                await manager.close()
            self._revision += 1
            return self._reply(request, "applied")
        if self._lock.locked():
            return self._reply(request, "held", "operation_in_progress")
        if request.action in {Action.TEST_WRITE, Action.SAVE_CREDENTIAL}:
            return self._reply(request, "unsupported", "write_unsupported" if request.action == Action.TEST_WRITE
                               else "native_nas_purpose_unavailable")
        async with self._lock:
            epoch, manager = self._cancel_epoch, self.connection.manager
            if request.action == Action.SAVE_CONFIGURATION:
                fault = None
                try:
                    # Revalidate even Pydantic model_copy updates. Saving forces
                    # disabled; metadata persistence cannot connect or resolve.
                    values = request.configuration.model_dump(mode="json")
                    values["enabled"] = False
                    config = NASConnectionConfig.model_validate(values)
                    await manager.configure(config, expected_generation=manager.generation)
                except Exception:
                    fault = "invalid_configuration"
                self._revision += 1
                return self._reply(request, "failed" if fault else "applied", fault)
            if self._composer is None:
                return self._reply(request, "unsupported", "native_nas_purpose_unavailable")
            if manager.config is None:
                return self._reply(request, "held", "configuration_not_saved")
            requested = request.configuration.model_dump(mode="json")
            requested["enabled"] = manager.config.enabled
            if requested != manager.config.model_dump(mode="json"):
                return self._reply(request, "held", "configuration_changed")
            if request.action == Action.TEST_READ:
                if (request.read_scope != self.connection.credentials.scope or not manager.status().readable
                        or manager.generation != request.read_scope.config_generation):
                    return self._reply(request, "held", "binding_mismatch")
                fault = None
                try:
                    # Narrow directory enumeration evidence only, one entry;
                    # does not return content or confer a steward extraction grant.
                    await manager.list_page(manager.config.source_ref, limit=1)
                except NASConnectionError:
                    fault = "read_denied"
                except asyncio.CancelledError:
                    self.connection.credentials.cancel()
                    await manager.close()
                    raise
                if self._cancel_epoch != epoch:
                    fault = "user_cancelled"
                self._revision += 1
                return self._reply(request, "failed" if fault else "applied", fault)
            # Deliberate new connection/reconnect is a new finite admission.
            generation = manager.generation
            config = manager.config.model_copy(update={"enabled": True})
            old_path = manager.store.path
            await manager.close()
            replacement, fault = None, None
            try:
                replacement = await self._composer.compose(config, generation + 1, request)
                if (type(replacement) is not ScopedNASConnection or replacement.manager.store.path != old_path
                        or replacement.manager.generation != generation
                        or replacement.credentials.scope != NASReadScope.from_config(
                            config, generation + 1, replacement.credentials.scope.credential_generation)):
                    fault = "binding_mismatch"
                elif self._cancel_epoch != epoch:
                    fault = "user_cancelled"
                else:
                    self.connection = replacement
                    await replacement.manager.configure(config, expected_generation=generation)
                    async with asyncio.timeout(config.connect_timeout_seconds + .1):
                        while replacement.manager.status().state not in {"online", "paused"}:
                            if self._cancel_epoch != epoch:
                                fault = "user_cancelled"
                                break
                            await asyncio.sleep(.005)
                    if replacement.manager.status().state != "online":
                        fault = "connection_failed"
            except asyncio.CancelledError:
                if isinstance(replacement, ScopedNASConnection):
                    replacement.credentials.cancel()
                    await replacement.manager.close()
                raise
            except Exception:
                fault = "connection_failed"
            if self._cancel_epoch != epoch:
                fault = "user_cancelled"
            if fault and isinstance(replacement, ScopedNASConnection):
                if replacement.credentials._failure is None:
                    replacement.credentials.cancel()
                await replacement.manager.close()
            self._revision += 1
            return self._reply(request, "failed" if fault else "applied", fault)
