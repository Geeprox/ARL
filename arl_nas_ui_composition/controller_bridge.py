"""Typed UI configuration -> existing NASSetupController, in a trusted host.

No JSON/RPC dispatch or credential input. NativeCache is passive owner evidence,
not authentication. The existing composer/broker/provider retain actual checks.
"""
from __future__ import annotations

import asyncio
from dataclasses import dataclass
import time

from homeplane.nas_connection import NASConnectionConfig
from arl_nas_credential import CallerPins, NASReadScope
from arl_nas_credential.settings import Action, NASSetupController, SetupRequest

# The parent reported an identity/lease-expiry bug in the frozen 0.1.0.
# Reference 0.1.1 now has exact owner pins, but independent lease review and
# native composition are pending. No injected cache/composer can publish live
# readiness here; there is no per-instance enable flag.
LIVE_DEPENDENCY_REVIEW_PENDING = True

class SetupFault(Exception):
    def __init__(self, code):
        self.code = code
        super().__init__(code)


@dataclass(frozen=True)
class Configuration:
    address: str
    port: int
    transport: str
    share: str
    root: str
    application_scope: str = 'read_only'
    connection_timeout_seconds: int = 8
    automatic_read_retries: int = 0
    maximum_concurrent_reads: int = 1
    require_encryption: bool = True


@dataclass(frozen=True)
class Request:
    action: Action
    configuration: Configuration
    expected_snapshot_revision: int
    expected_configuration_generation: int
    read_scope: NASReadScope | None = None


@dataclass(frozen=True)
class NativeCache:
    # Supplied only by the native owner from its cache. No UI decoder exists.
    state: str = 'unsupported'
    fault: str = 'native_nas_purpose_unavailable'
    caller: CallerPins | None = None

    def __post_init__(self):
        if self.state not in {'unsupported', 'held', 'ready'}:
            raise SetupFault('provider_invalid')
        if self.state == 'ready' and type(self.caller) is not CallerPins:
            raise SetupFault('caller_unverified')


@dataclass(frozen=True)
class Fact:
    state: str
    fault: str | None = None


@dataclass(frozen=True)
class Admission:
    state: str
    fault: str | None = None


@dataclass(frozen=True)
class Snapshot:
    revision: int
    configuration: Configuration | None
    current_configuration_generation: int
    read_scope: NASReadScope
    observed_caller: CallerPins | None  # private projection, never in action DTO
    connection_epoch: str | None
    provider: str
    availability: tuple[tuple[Action, Admission], ...]
    configuration_saved: Fact
    credential_reference_saved: Fact
    credential_available: Fact
    connected: Fact
    readable: Fact
    writable: Fact = Fact('unsupported', 'write_unsupported')

    def admission(self, action):
        return dict(self.availability)[action]


@dataclass(frozen=True)
class Reply:
    request: Request
    outcome: str
    failure: str | None
    snapshot: Snapshot


class _CapturedClick:
    __slots__ = ('owner', 'request', 'setup', 'intent', 'deadline', 'used', 'native',
                 'connection', 'manager', 'credentials', 'epoch', 'stop_target')
    def __init__(self, owner, request, setup, intent, deadline, native, connection, epoch, stop_target):
        self.owner, self.request, self.setup, self.intent = owner, request, setup, intent
        self.deadline, self.used, self.native = deadline, False, native
        self.connection, self.epoch, self.stop_target = connection, epoch, stop_target
        self.manager, self.credentials = connection.manager, connection.credentials
    def __repr__(self): return '<CapturedNASSettingsClick: in-process>'
    def __reduce_ex__(self, protocol): raise TypeError('manual_click_not_serializable')


class _OwnedSave:
    # Private controller operation identity, never a wire token or DTO field.
    def __init__(self, click, origin, manager, epoch):
        self.connection, self.manager, self.origin = click.connection, manager, origin
        self.credentials = click.credentials
        self.original_config = manager.config.model_copy(deep=True) if manager.config is not None else None
        self.target_config = click.setup.configuration
        self.task, self.epoch, self.deadline = asyncio.current_task(), epoch, click.deadline
        self.state, self.stopped = 'running', False


class SettingsControllerBridge:
    """One owner-held controller; no second manager/store or background refresh.

    seed is the host's complete validated policy/config template, including its
    source/ref and hidden timeout/security fields. UI fields never replace it.
    Native readiness is unavailable by default even if a composer is present.
    """
    def __init__(self, controller: NASSetupController, *, seed: NASConnectionConfig,
                 native: NativeCache = NativeCache(), clock=time.monotonic):
        if type(controller) is not NASSetupController or type(seed) is not NASConnectionConfig:
            raise SetupFault('host_not_configured')
        try:
            self.seed = NASConnectionConfig.model_validate(seed.model_dump(mode='json'))
        except Exception:
            raise SetupFault('invalid_configuration') from None
        scope = controller.connection.credentials.scope
        if (seed.source_ref, seed.credential_ref) != (scope.source_ref, scope.credential_ref):
            raise SetupFault('binding_mismatch')
        self.controller, self.native, self.clock = controller, native, clock
        self._owner, self._active = object(), 0
        self._run_epoch, self._active_save, self._last_save = 0, None, None

    @staticmethod
    def _identity(scope):
        return (scope.service, scope.source_ref, scope.credential_ref, scope.credential_generation,
                scope.config_fingerprint, scope.root_descriptor_digest)

    @staticmethod
    def _projection(config):
        if config is None: return None
        if config.transport != 'smb': raise SetupFault('protocol_unsupported')
        timeout = config.connect_timeout_seconds
        if not timeout.is_integer() or not 1 <= timeout <= 30:
            raise SetupFault('invalid_configuration')
        return Configuration(config.host, config.effective_port, config.transport, config.share,
                             config.root, connection_timeout_seconds=int(timeout))

    def _map(self, ui: Configuration):
        if type(ui) is not Configuration: raise SetupFault('invalid_configuration')
        if ui.transport != 'smb': raise SetupFault('protocol_unsupported')
        if ui.application_scope != 'read_only': raise SetupFault('write_unsupported')
        if (type(ui.port) is not int or not 1 <= ui.port <= 65535 or
                type(ui.connection_timeout_seconds) is not int or not 1 <= ui.connection_timeout_seconds <= 30 or
                type(ui.automatic_read_retries) is not int or ui.automatic_read_retries != 0 or
                type(ui.maximum_concurrent_reads) is not int or ui.maximum_concurrent_reads != 1 or
                ui.require_encryption is not True):
            raise SetupFault('invalid_configuration')
        base = self.controller.connection.manager.config or self.seed
        if base.transport != 'smb': raise SetupFault('protocol_unsupported')
        values = base.model_dump(mode='json')
        # Preserve None vs effective 445: they are distinct exact fingerprint
        # inputs even though the UI shows the same effective port.
        port = base.port if ui.port == base.effective_port else ui.port
        values.update(host=ui.address, port=port, transport='smb', share=ui.share,
                      root=ui.root, connect_timeout_seconds=float(ui.connection_timeout_seconds),
                      enabled=False, require_encryption=True)
        try: return NASConnectionConfig.model_validate(values)
        except Exception: raise SetupFault('invalid_configuration') from None

    def cached_snapshot(self):
        raw = self.controller.snapshot()  # cached manager/broker/clock only
        connection = self.controller.connection
        config, scope = connection.manager.config, connection.credentials.scope
        status, credential = raw['connection'], raw['credential']
        try:
            projection = self._projection(config)
            configuration_saved = Fact('verified' if projection else 'unknown')
        except SetupFault as exc:
            projection, configuration_saved = None, Fact('unsupported', exc.code)
        same_config = False
        if config:
            expected = NASReadScope.from_config(config, max(1, connection.manager.generation), scope.credential_generation)
            same_config = self._identity(scope) == self._identity(expected)
        current = same_config and scope.config_generation == status['config_generation']
        ready = self.native.state == 'ready' and self.native.caller == connection.credentials.caller
        composer_ready = raw['action_availability']['test_connection'] == 'manual_host_required'
        fault = ('native_resolver_unavailable' if LIVE_DEPENDENCY_REVIEW_PENDING else
                 self.native.fault if self.native.state != 'ready' else
                 'caller_unverified' if not ready else
                 'native_resolver_unavailable' if not composer_ready else
                 'source_changed' if config and not same_config else None)
        live_admission = Admission('allowed') if fault is None else Admission(
            'unsupported' if LIVE_DEPENDENCY_REVIEW_PENDING or self.native.state == 'unsupported' or not composer_ready else 'held', fault)
        # Configuration saving is possible independently of native credentials.
        metadata_admission = Admission('allowed') if (config or self.seed).transport == 'smb' else Admission('unsupported', 'protocol_unsupported')
        availability = tuple((action,
            metadata_admission if action == Action.SAVE_CONFIGURATION else
            Admission('allowed') if action == Action.STOP and config else
            Admission('held', 'configuration_not_saved') if action == Action.STOP else
            Admission('unsupported', 'native_nas_purpose_unavailable') if action == Action.SAVE_CREDENTIAL else
            Admission('unsupported', 'write_unsupported') if action == Action.TEST_WRITE else live_admission)
            for action in Action)
        if fault:
            access = Fact(live_admission.state, fault)
            credential_fact = access
            connected = readable = access
        else:
            failure = credential['failure']
            credential_fact = (Fact('verified') if current and credential['state'] == 'resolved' and credential['credential_available'] is True else
                               Fact('failed', failure) if failure else Fact('unknown'))
            online = (current and status['state'] == 'online' and status['enabled'] is True and
                      status['source_ref'] == scope.source_ref and status['connection_epoch'] is not None and
                      status['reachable'] is True and status['authenticated'] is True)
            reason = status['failure']
            idle = Fact('failed', reason) if reason else Fact('held', 'disabled') if not status['enabled'] else Fact('unknown')
            connected = Fact('verified') if online else idle
            readable = Fact('verified') if online and status['readable'] is True else idle
        return Snapshot(raw['snapshot_revision'], projection, status['config_generation'], scope,
            self.native.caller if ready else None, status['connection_epoch'] if current and fault is None else None,
            'available' if fault is None else live_admission.state, availability,
            configuration_saved, Fact('verified' if raw['credential_reference_saved'] else 'unknown'),
            credential_fact, connected, readable)

    def _owned_stop(self, request, snapshot, target):
        """Only this bridge's exact Save predecessor can cancel that Save.

        The manager may be at the predecessor or its one disabled save result.
        A completed/new operation, replaced connection, changed scope, enabled
        config, unrelated metadata edit or stale target has no cancellation right.
        """
        if (target is not self._last_save or target.epoch != self._run_epoch or
                target.state not in {'running', 'cancelled'} or
                self.controller.connection is not target.connection or
                target.connection.manager is not target.manager or
                target.connection.credentials is not target.credentials):
            raise SetupFault('stale_generation')
        origin = target.origin
        if (request.expected_snapshot_revision != origin.revision or
                request.expected_configuration_generation != origin.current_configuration_generation or
                snapshot.revision != origin.revision):
            raise SetupFault('stale_generation')
        if origin.configuration is None or request.configuration != origin.configuration:
            raise SetupFault('configuration_changed')
        if (type(request.read_scope) is not NASReadScope or request.read_scope != origin.read_scope or
                snapshot.read_scope != origin.read_scope):
            raise SetupFault('binding_mismatch')
        manager = target.manager
        before = (manager.generation == origin.current_configuration_generation and
                  manager.config == target.original_config)
        saved = (manager.generation == origin.current_configuration_generation + 1 and
                 manager.config == target.target_config)
        if not (before or saved) or manager.config is None or manager.config.enabled:
            raise SetupFault('stale_generation')

    def _prepare(self, request, *, captured=None):
        if type(request) is not Request or type(request.action) is not Action:
            raise SetupFault('invalid_configuration')
        config = self._map(request.configuration)
        snapshot = self.cached_snapshot()
        for n in (request.expected_snapshot_revision, request.expected_configuration_generation):
            if type(n) is not int or not 0 <= n <= 2**63 - 1: raise SetupFault('stale_generation')
        target = None
        if request.action == Action.STOP:
            if captured is not None:
                target = captured.stop_target
            elif self._active_save is not None:
                target = self._active_save
            elif (self._last_save is not None and self._last_save.state == 'cancelled' and
                    self.clock() < self._last_save.deadline):
                # A UI Task may finish cancellation just before the Stop click.
                # Its same bounded predecessor still owns cleanup, until replaced.
                target = self._last_save
        if target is not None:
            self._owned_stop(request, snapshot, target)
        elif (request.expected_snapshot_revision != snapshot.revision or
                request.expected_configuration_generation != snapshot.current_configuration_generation):
            raise SetupFault('stale_generation')
        if request.action != Action.STOP and self._active_save is not None:
            raise SetupFault('operation_in_progress')
        if request.action != Action.SAVE_CONFIGURATION:
            if snapshot.configuration is None: raise SetupFault('configuration_not_saved')
            if target is None and snapshot.configuration != request.configuration:
                raise SetupFault('configuration_changed')
            if type(request.read_scope) is not NASReadScope: raise SetupFault('binding_mismatch')
            if request.action in {Action.TEST_READ, Action.STOP}:
                if request.read_scope != snapshot.read_scope: raise SetupFault('binding_mismatch')
            elif self._identity(request.read_scope) != self._identity(snapshot.read_scope):
                raise SetupFault('binding_mismatch')
        admission = snapshot.admission(request.action)
        if admission.state != 'allowed': raise SetupFault(admission.fault)
        return (SetupRequest(request.action, config,
            snapshot.revision if target is not None else request.expected_snapshot_revision, request.read_scope),
            target, snapshot)

    def capture_after_click(self, request):
        """Trusted synchronous click call; not an RPC/token decoder or grant."""
        setup, target, _ = self._prepare(request)
        intent = self.controller.capture_click(setup)
        return _CapturedClick(self._owner, request, setup, intent, self.clock() + 30, self.native,
                              self.controller.connection, self._run_epoch, target)

    async def perform_captured(self, click):
        if type(click) is not _CapturedClick or click.owner is not self._owner or click.used:
            raise SetupFault('manual_intent_required')
        click.used = True
        if self.clock() >= click.deadline: raise SetupFault('manual_intent_expired')
        if click.connection is not self.controller.connection: raise SetupFault('binding_mismatch')
        if (click.manager is not click.connection.manager or
                click.credentials is not click.connection.credentials):
            raise SetupFault('binding_mismatch')
        if click.epoch != self._run_epoch: raise SetupFault('stale_generation')
        # Recheck all UI freshness/mapping immediately before the actual
        # controller. Native changes cannot reuse a captured live attempt.
        prepared, target, origin = self._prepare(click.request, captured=click)
        if prepared != click.setup: raise SetupFault('stale_generation')
        if click.request.action not in {Action.SAVE_CONFIGURATION, Action.STOP} and self.native != click.native:
            raise SetupFault('caller_unverified')
        # Outer validation is a fast rejection, not the real intent authority.
        # Stop commits only inside the controller's post-consumption synchronous
        # boundary. Its earlier clock sample cannot authorize cancellation.
        owned = None
        if click.request.action == Action.SAVE_CONFIGURATION:
            self._run_epoch += 1
            owned = _OwnedSave(click, origin, click.connection.manager, self._run_epoch)
            self._active_save = self._last_save = owned
        elif click.request.action != Action.STOP:
            self._run_epoch += 1

        def commit_stop():
            # Called by the actual controller only after the exact intent and
            # revision were accepted, before any Stop effect or await.
            try:
                if (click.connection is not self.controller.connection or
                        click.manager is not click.connection.manager or
                        click.credentials is not click.connection.credentials):
                    raise SetupFault('binding_mismatch')
                if click.epoch != self._run_epoch:
                    raise SetupFault('stale_generation')
                current_setup, current_target, _ = self._prepare(click.request, captured=click)
                if current_setup != click.setup or current_target is not target:
                    raise SetupFault('stale_generation')
            except SetupFault as exc:
                return exc.code
            self._run_epoch += 1
            if target is not None:
                target.stopped = True
                if target.task is not asyncio.current_task() and not target.task.done():
                    target.task.cancel()
            return None

        self._active += 1
        try:
            if click.request.action == Action.STOP:
                raw = await self.controller.perform(click.setup, click.intent,
                                                    _after_stop_admission=commit_stop)
            else:
                raw = await self.controller.perform(click.setup, click.intent)
            if owned is not None and owned.stopped:
                return Reply(click.request, 'held', 'user_cancelled', self.cached_snapshot())
            if owned is not None: owned.state = 'done'
            return Reply(click.request, raw['outcome'], raw['failure'], self.cached_snapshot())
        except asyncio.CancelledError:
            if owned is not None:
                owned.state = 'cancelled'
                if owned.stopped:
                    return Reply(click.request, 'held', 'user_cancelled', self.cached_snapshot())
            raise
        finally:
            if owned is not None and self._active_save is owned: self._active_save = None
            self._active -= 1
