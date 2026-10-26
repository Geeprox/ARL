"""Acceptance only: real Tisra .app + actual arl.host.run, synthetic stores.

Reuses the reviewed gated source, native adapter, Store and receipt contracts.
No installed runtime or production profile is changed by this controller.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
import time
import uuid

from arl.host import run
from arl.providers import Router
from arl.service import Runtime
from arl.supervisor import LaunchSpec, pin_sources
from arl.tisra_capture_host import CaptureHostConfig, NativeCaptureSelection
from arl.tisra_capture_profiles import CaptureSourceProfile, attachment_for_profiles, production_profiles
from arl.tisra_capture_runtime import CaptureConsumerPin
from arl.tisra_capture_uploads import METHODS
from tests.test_capture_process_end_to_end import ROOT, PARTICIPANT, process_pin, read_line, sha


def emit(value):
    print(json.dumps(value, sort_keys=True), flush=True)


class NativeApplication:
    def __init__(self, root, bundle, startup):
        self.root, self.bundle = Path(root), Path(bundle)
        self.native_root = self.root / 'native'
        self.native_root.mkdir(mode=0o700, exist_ok=True)
        self.fifo = self.root / ('control-' + str(uuid.uuid4()))
        os.mkfifo(self.fifo, 0o600)
        self.control = os.open(self.fifo, os.O_RDWR | os.O_NONBLOCK)
        token = str(uuid.uuid4())
        self.output = self.root / (token + '.native.stdout')
        self.error = self.root / (token + '.native.stderr')
        self.open_error = self.root / (token + '.open.stderr')
        for path in (self.output, self.error, self.open_error):
            path.touch(mode=0o600)
        self.offset = 0
        self.pid = None
        with self.open_error.open('wb') as errors:
            self.launcher = subprocess.Popen(['/usr/bin/open', '-n', '-W', '--stdin', str(self.fifo),
                '--stdout', str(self.output), '--stderr', str(self.error), str(self.bundle),
                '--args', '--isolated-capture-application', str(self.native_root)],
                stdout=subprocess.DEVNULL, stderr=errors,
                env={'PATH': '/usr/bin:/bin:/usr/sbin:/sbin'})
        try:
            self.command(startup)
            self.metadata = self.read()
        except BaseException:
            # Closing this task's writer releases the inherited reader with EOF.
            # Never guess a native PID or signal another installed application.
            os.close(self.control); self.fifo.unlink(missing_ok=True)
            try: self.launcher.wait(10)
            except subprocess.TimeoutExpired:
                self.launcher.terminate(); self.launcher.wait(5)
            raise
        self.pid = self.metadata['pid']
        # Readiness is a hint; trusted host observation is the authority.
        identity = process_pin(self.pid)
        expected = str((self.bundle / 'Contents/MacOS/Tisra').resolve(strict=True))
        if identity['executable'] != expected or identity['sha256'] != sha(Path(expected).read_bytes()):
            raise AssertionError('Tisra application image observation mismatch')
        if not self.metadata['workspace_ready'] or self.metadata['bundle_id'] != 'app.tisra.capture.isolated':
            raise AssertionError('Real Tisra workspace/bundle did not become ready')
        self.identity = identity

    def command(self, value):
        raw = (json.dumps(value) + '\n').encode()
        if len(raw) > 32768 or os.write(self.control, raw) != len(raw):
            raise AssertionError('Incomplete inherited host control frame')

    def read(self, timeout=40):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            with self.output.open('rb') as stream:
                stream.seek(self.offset)
                raw = stream.readline(32769)
            if raw.endswith(b'\n'):
                self.offset += len(raw)
                return json.loads(raw)
            if self.launcher.poll() is not None:
                raise AssertionError(json.dumps(self.failure('launcher exited')))
            threading.Event().wait(0.03)
        raise AssertionError(json.dumps(self.failure('application ready timeout')))

    def failure(self, reason):
        return dict(reason=reason, launcher_exit=self.launcher.poll(),
                    native_stderr=self.error.read_text()[-4096:], open_stderr=self.open_error.read_text()[-4096:])

    def stop(self):
        if hasattr(self, '_stop_evidence'):
            return self._stop_evidence
        forced = False
        if self.launcher.poll() is None:
            self.command({'command': 'stop'})
            try:
                self.launcher.wait(15)
            except subprocess.TimeoutExpired:
                forced = True
                # Only this explicitly observed temporary app may be signaled.
                if self.pid is not None and process_pin(self.pid) == self.identity:
                    os.kill(self.pid, 15)
                self.launcher.wait(10)
        os.close(self.control)
        self.fifo.unlink(missing_ok=True)
        self._stop_evidence = dict(self.failure('stopped'), forced_termination=forced)
        return self._stop_evidence


def main():
    if len(sys.argv) != 5 or sys.argv[1] != '--isolated-test':
        raise SystemExit('isolated application acceptance only')
    root, bundle, mode = Path(sys.argv[2]).resolve(), Path(sys.argv[3]).resolve(strict=True), sys.argv[4]
    if not str(root).startswith('/private/tmp/tisra-slice-') or mode not in {'granted','disabled'}:
        raise SystemExit('invalid synthetic selection')
    home = root / 'arl'
    selection_file = root / 'selected-test-library.json'
    if selection_file.exists():
        selected = json.loads(selection_file.read_text())
        journal_mode = 'reopen'
    else:
        selected = dict(library_id=str(uuid.uuid4()), instance_id=str(uuid.uuid4()))
        selection_file.write_text(json.dumps(selected))
        journal_mode = 'create'
    executable = Path(process_pin(os.getpid())['executable'])
    paths = [*sorted((ROOT / 'arl').glob('*.py')), ROOT / 'tests/__init__.py',
             ROOT / 'tests/capture_host_source_fixture.py']
    source = LaunchSpec('tisra', executable,
        ('-B', '-m', 'tests.capture_host_source_fixture', '--isolated-test', str(home), 'tisra'),
        ROOT, pin_sources(paths), (ROOT,))
    native = None
    native_history = []
    provider_calls = []
    def forbidden(*args, **kwargs):
        provider_calls.append(True)
        raise AssertionError('Model/provider execution forbidden')
    Router.complete = forbidden
    actual_run = Runtime.run
    def diagnostic_run(runtime):
        try:
            return actual_run(runtime)
        except BaseException as error:
            print(json.dumps(dict(stage='actual_host_runtime', error_type=type(error).__name__,
                errno=getattr(error, 'errno', None), code=getattr(error, 'code', None),
                detail=str(error)[:4096])), file=sys.stderr, flush=True)
            raise
    Runtime.run = diagnostic_run
    paused, released = threading.Event(), threading.Event()

    def select_native(identity, reopen=False):
        nonlocal native
        descriptor = dict(mode='reopen' if reopen else journal_mode, enabled=True,
            host=process_pin(os.getpid()), **selected, registrations=[dict(process=identity.to_native(),
            writer_app='tisra', participant_id=PARTICIPANT.participant_id,
            actor_kind=PARTICIPANT.actor_kind, auth_epoch=PARTICIPANT.auth_epoch,
            active=True, write_granted=True, library_id=selected['library_id'])])
        native = NativeApplication(root, bundle, descriptor)
        native_history.append(dict(identity=native.identity, metadata=native.metadata))
        pin = CaptureConsumerPin(selected['library_id'], selected['instance_id'], native.identity['sha256'])
        if native.metadata['code_sha256'] != pin.code_sha256:
            raise AssertionError('Native code metadata differs from observed executable')
        return NativeCaptureSelection(native.pid, native.identity['executable'], pin.code_sha256,
            root / 'native/capture.sock', root / 'native/library/ledger.sqlite', pin)

    config = CaptureHostConfig(source, sha(executable.read_bytes()), PARTICIPANT,
        'native-tisra-isolated', select_native, library_granted=True, methods=frozenset(METHODS))
    profiles = tuple(CaptureSourceProfile(p.app, config, True) if p.app == 'tisra' and mode == 'granted' else p
                     for p in production_profiles())
    attachment = attachment_for_profiles(profiles)
    finished = threading.Event()
    errors = []
    def controller():
        try:
            deadline = time.monotonic() + 50
            while not finished.is_set() and time.monotonic() < deadline:
                if attachment.runtime is not None and attachment.runtime.ready.wait(0.03): break
            else: raise AssertionError('Actual host not ready')
            runtime = attachment.runtime
            process = attachment.supervisor.children['tisra'] if attachment.supervisor else None
            gate = read_line(process) if process else None
            emit(dict(event='ready', **selected, capture=runtime.capture is not None,
                worker=runtime.worker is not None, native_pid=native.pid if native else None,
                source_pid=process.pid if process else None, gate=gate,
                providers=sorted(runtime.policies['tisra'].providers)))
            for line in sys.stdin:
                command = json.loads(line)
                if command == {'command': 'stop'}: runtime.shutdown(); return
                if set(command) == {'method','params'} and process is not None:
                    process.stdin.write(json.dumps(command) + '\n'); process.stdin.flush(); emit(read_line(process)); continue
                action = command.get('command')
                if action == 'restart_native':
                    previous = native.pid
                    stopped = native.stop(); attachment.verifier.revoke(previous)
                    if stopped['forced_termination']:
                        raise AssertionError('Native application did not terminate through its lifetime hook')
                    identity = attachment.registrations.identity('tisra', PARTICIPANT)
                    selection = select_native(identity, reopen=True)
                    attachment.verifier.register(config.native_app, selection.pid, selection.executable)
                    attachment.composition.replace_native_consumer(selection.pid)
                    emit(dict(restarted=True, previous_pid=previous, native_pid=selection.pid, previous=stopped))
                elif action == 'revoke_native':
                    native.command({'command': 'revoke', 'writer_app': 'tisra'}); emit(native.read())
                elif action == 'revoke_source':
                    attachment.registrations.revoke('tisra'); emit({'revoked': True})
                elif action == 'arm_lost_ack' and command.get('where') in {'before','after'}:
                    original = attachment.composition.consumer.acknowledge
                    where = command['where']
                    def lost(*args, **kwargs):
                        if where == 'after': original(*args, **kwargs)
                        raise OSError('Synthetic lost native ACK ' + where)
                    attachment.composition.consumer.acknowledge = lost; emit({'armed': where})
                elif action == 'pause_after_capture':
                    original = attachment.composition.consumer.capture
                    def capture(*args, **kwargs):
                        result = original(*args, **kwargs); paused.set()
                        if not released.wait(15): raise AssertionError('Synthetic cancellation barrier timed out')
                        return result
                    attachment.composition.consumer.capture = capture; emit({'armed': True})
                elif action == 'await_capture': emit({'captured': paused.wait(15)})
                elif action == 'release_capture': released.set(); emit({'released': True})
                else: raise AssertionError('Unknown finite test command')
            runtime.shutdown()
        except BaseException as error:
            errors.append(str(error))
            released.set()
            if attachment.runtime is not None: attachment.runtime.shutdown()
    thread = threading.Thread(target=controller, daemon=True); thread.start()
    result = run(home, capture_attachment=attachment)
    finished.set(); thread.join(5)
    native_stop = native.stop() if native is not None else None
    emit(dict(event='stopped', result=result, errors=errors, provider_calls=len(provider_calls),
        native_history=native_history, native_stop=native_stop, closed=attachment._closed,
        worker_stopped=attachment.runtime.worker is None or not attachment.runtime.worker.is_alive(),
        fd_closed=attachment.composition is None or attachment.composition.consumer._ledger_fd is None))
    return result


if __name__ == '__main__':
    raise SystemExit(main())
