"""Explicit optional capture composition; installed metadata host is unchanged.

Only trusted host code supplies selected paths, observed process pins and grants.
Nothing here is reachable as an enrollment/configuration RPC or env profile.
"""
from .service import Runtime
from .tisra_capture_runtime import NAME, CaptureAuthority
from .tisra_capture_process import NativeCaptureProcess
from .tisra_capture_uploads import UploadedCaptureRuntime


class CaptureProcessComposition:
    def __init__(self, *, verifier, registrations, native_app, native_pid,
                 expected_executable, expected_sha256, socket_path,
                 selected_ledger, pin, participants=None, library_grants=None,
                 method_grants=None, active=False, registration_guard=None, **upload_limits):
        self.verifier, self.registrations = verifier, registrations
        self.registration_guard = registration_guard
        self._native_config = dict(
            socket_path=socket_path, verifier=verifier, native_app=native_app,
            expected_executable=expected_executable,
            expected_sha256=expected_sha256, selected_ledger=selected_ledger,
            pin=pin, registrations=registrations,
        )
        self.consumer = self._make_consumer(native_pid)
        self.engine = UploadedCaptureRuntime(
            active=active, participants=participants, library_grants=library_grants,
            method_grants=method_grants, pins={pin.library_id: pin},
            consumers={pin.library_id: self.consumer}, codec=self.consumer.codec,
            registered_peer=registrations, authorizer=self._authorize, **upload_limits,
        )

    def _authorize(self, authority, method):
        # Do not call engine._authorize here: it invokes this callback. The
        # engine independently checks current policy and observed consumer pins.
        engine = getattr(self, 'engine', None)
        if engine is None or engine.active is not True or type(authority) is not CaptureAuthority:
            return False
        with engine._configuration_lock:
            participant = engine.participants.get(authority.writer_app)
            pin = engine.pins.get(authority.library_id)
            if participant is None or pin is None:
                return False
            if pin != self.consumer.pin or engine.consumers.get(authority.library_id) is not self.consumer:
                return False
            if engine.codec is not self.consumer.codec:
                return False
            if (participant.participant_id, participant.actor_kind, participant.auth_epoch) != (
                    authority.participant_id, authority.actor_kind, authority.auth_epoch):
                return False
            if authority.instance_id != pin.instance_id or authority.library_id != pin.library_id:
                return False
            if authority.library_id not in engine.library_grants.get(
                    (authority.writer_app, authority.participant_id), frozenset()):
                return False
            if method not in engine.method_grants.get(
                    (authority.writer_app, authority.participant_id, authority.library_id), frozenset()):
                return False
            runtime = engine.runtime
            policy = runtime.policies.get(authority.writer_app) if runtime is not None else None
            if policy is None or NAME not in policy.tools or method not in policy.methods:
                return False
            if self.registrations(authority.writer_app, participant) is not True:
                return False
            if self.registration_guard is not None:
                try:
                    return self.registration_guard(authority.writer_app, participant) is True
                except Exception:
                    return False
            return True

    def _make_consumer(self, native_pid):
        expected = []
        def authorize(authority, method):
            return bool(expected and getattr(self, 'consumer', None) is expected[0]
                        and self._authorize(authority, method))
        consumer = NativeCaptureProcess(native_pid=native_pid, authorize=authorize, **self._native_config)
        expected.append(consumer)
        return consumer

    def replace_native_consumer(self, native_pid):
        """Host-only replacement after separately registering the new process.

        Paths, library/restore/code/schema pins remain the selected composition.
        The old adapter's authorization closure cannot serve the new mapping.
        Neither journal nor task is replayed by replacing a process binding.
        """
        consumer = self._make_consumer(native_pid)
        with self.engine._configuration_lock:
            previous = self.consumer
            self.consumer = consumer
            self.engine.configure(consumers={consumer.pin.library_id: consumer},
                                  pins={consumer.pin.library_id: consumer.pin})
            self.engine.codec = consumer.codec
        previous.close()
        return consumer

    def close(self):
        """Release the selected Ledger descriptor after stopping this runtime."""
        self.consumer.close()

    def make_runtime(self, home, *, policies, **runtime_options):
        if any(key in runtime_options for key in ('identity_verifier', 'capture', 'local_enabled')):
            raise ValueError('capture_composition_owns_identity_and_engine')
        return Runtime(home, policies=policies, identity_verifier=self.verifier,
                       capture=self.engine, local_enabled=False, **runtime_options)
