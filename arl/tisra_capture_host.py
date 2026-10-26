"""Finite trusted host attachment; no JSON/env/CLI enrollment or default grants."""
from dataclasses import dataclass
import threading
from typing import Callable

from .contracts import AppPolicy, Fault
from .identity import RegisteredPeerVerifier
from .service import Runtime
from .supervisor import ControlledSupervisor, LaunchSpec
from .tisra_capture_composition import CaptureProcessComposition
from .tisra_capture_process import CaptureProcessRegistrations
from .tisra_capture_runtime import NAME, CaptureConsumerPin, RegisteredCaptureParticipant
from .tisra_capture_uploads import METHODS


@dataclass(frozen=True)
class NativeCaptureSelection:
    """Explicit host-selected live consumer/library, never decoded from RPC."""
    pid: int
    executable: str
    sha256: str
    socket_path: str
    selected_ledger: str
    pin: CaptureConsumerPin


@dataclass(frozen=True)
class CaptureHostConfig:
    # One reviewed controlled source and one selected native library per host.
    source: LaunchSpec
    source_executable_sha256: str
    participant: RegisteredCaptureParticipant
    native_app: str
    select_native: Callable
    library_granted: bool = False
    methods: frozenset = frozenset()


class CaptureHostAttachment:
    def __init__(self, config=None, *, enabled=False):
        if type(enabled) is not bool:
            raise Fault('capture_host_unconfigured')
        self.config, self.enabled = config, enabled
        self.runtime = self.composition = self.supervisor = self.registrations = None
        self.verifier = None
        self._lock = threading.RLock()
        self._started = self._stopping = self._closed = False

    def make_runtime(self, home):
        from .host import metadata_policies, PeerComposition
        with self._lock:
            if self.runtime is not None or self._closed:
                raise Fault('capture_host_unconfigured')
            policies = metadata_policies()
            granted = False
            if self.enabled:
                cfg = self.config
                if (type(cfg) is not CaptureHostConfig or type(cfg.source) is not LaunchSpec or
                        cfg.source.app not in {'tisra', 'friday', 'mio'} or
                        type(cfg.participant) is not RegisteredCaptureParticipant or
                        type(cfg.library_granted) is not bool or type(cfg.methods) is not frozenset or
                        not cfg.methods <= METHODS or not callable(cfg.select_native) or
                        type(cfg.native_app) is not str or not cfg.native_app or
                        cfg.native_app in {'settings', cfg.source.app}):
                    raise Fault('capture_host_unconfigured')
                granted = cfg.library_granted and bool(cfg.methods)
                policies[cfg.source.app] = AppPolicy(
                    frozenset({NAME}) if granted else frozenset(), frozenset(),
                    max_tokens=0, max_pending=8 if granted else 0,
                    max_calls=64 if granted else 0,
                    methods=cfg.methods if granted else frozenset())
            self.runtime = Runtime(home, policies=policies, local_enabled=False,
                                   identity_verifier=self._verify if self.enabled else PeerComposition(),
                                   execute_jobs=granted, host_attachment=self)
            return self.runtime

    def _registered(self, app, participant):
        supervisor = self.supervisor
        if supervisor is None or self._stopping or app != self.config.source.app or participant != self.config.participant:
            return False
        process = supervisor.children.get(app)
        if process is None or not supervisor.metadata_active(app, self.config.source, process):
            self.registrations.revoke(app)
            return False
        try:
            return self.registrations.identity(app, participant).pid == process.pid
        except Fault:
            return False

    def _verify(self, connection, app):
        if not self._registered(app, self.config.participant):
            return None
        return self.supervisor.peer_verifier(connection, app)

    def start(self, runtime):
        with self._lock:
            if runtime is not self.runtime or self._started or self._stopping or self._closed:
                raise Fault('capture_host_unconfigured')
            self._started = True
            if not self.enabled:
                return
            cfg = self.config
            self.verifier = RegisteredPeerVerifier({cfg.source.app, cfg.native_app})
            self.registrations = CaptureProcessRegistrations(self.verifier)
            self.supervisor = ControlledSupervisor((cfg.source,), self.verifier)

            def attach(process):
                identity = self.registrations.register(cfg.source.app, process.pid,
                    cfg.source.executable, cfg.source_executable_sha256, cfg.participant)
                # This callback is trusted host code selecting an existing native
                # owner. Only the test callback launches a disposable fixture.
                selected = cfg.select_native(identity)
                if type(selected) is not NativeCaptureSelection:
                    raise Fault('capture_host_unconfigured')
                self.verifier.register(cfg.native_app, selected.pid, selected.executable)
                library = selected.pin.library_id
                grants = frozenset({library}) if cfg.library_granted else frozenset()
                self.composition = CaptureProcessComposition(
                    verifier=self.verifier, registrations=self.registrations,
                    native_app=cfg.native_app, native_pid=selected.pid,
                    expected_executable=selected.executable, expected_sha256=selected.sha256,
                    socket_path=selected.socket_path, selected_ledger=selected.selected_ledger,
                    pin=selected.pin, participants={cfg.source.app: cfg.participant},
                    library_grants={(cfg.source.app, cfg.participant.participant_id): grants},
                    method_grants={(cfg.source.app, cfg.participant.participant_id, library): cfg.methods},
                    active=True, registration_guard=self._registered)
                runtime.capture = self.composition.engine
                runtime.capture.bind_runtime(runtime)
                runtime.tools[runtime.capture.name] = runtime.capture.tool

            self.supervisor.launch(cfg.source.app, on_registered=attach)

    def begin_shutdown(self):
        with self._lock:
            if self._stopping:
                return
            self._stopping = True
            if self.registrations is not None:
                self.registrations.revoke(self.config.source.app)
            if self.supervisor is not None:
                self.supervisor.close()

    def close(self, *, runtime_finished=None):
        with self._lock:
            if self._closed:
                return
            if (self.runtime is not None and self.runtime.instance is not None and
                    not self.runtime.closed.is_set() and runtime_finished is not self.runtime):
                raise Fault('capture_host_still_running')
            self.begin_shutdown()
            # Runtime calls this only after worker/handlers stop, or host startup
            # never acquired the lifetime lock. Never close an in-use Ledger fd.
            if self.composition is not None:
                self.composition.close()
            self._closed = True
