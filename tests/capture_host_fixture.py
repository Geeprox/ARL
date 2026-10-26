"""Run the actual host main-thread lifecycle with disposable controlled peers.

Only this test helper launches the synthetic native Ledger owner. Production
select_native is trusted host code selecting a separately admitted live owner.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
import time
import uuid

from arl.contracts import Fault, Tool, AppPolicy, object_schema
from arl.host import run
from arl.providers import Router
from arl.storage import Store
from arl.supervisor import LaunchSpec, pin_sources
from arl.tisra_capture_host import CaptureHostAttachment, CaptureHostConfig, NativeCaptureSelection
from arl.tisra_capture_runtime import CaptureConsumerPin
from arl.tisra_capture_uploads import METHODS
from tests.test_capture_process_end_to_end import ROOT, PARTICIPANT, process_pin, read_line, sha


def emit(value):
    print(json.dumps(value), flush=True)


def main():
    if len(sys.argv) != 5 or sys.argv[1] != '--isolated-test':
        raise SystemExit('isolated fixture only')
    root, native_path, mode = Path(sys.argv[2]), Path(sys.argv[3]).resolve(strict=True), sys.argv[4]
    if not str(root).startswith('/tmp/cap-host-') or mode not in {'disabled', 'granted', 'denied', 'bad_hash', 'select_failure'}:
        raise SystemExit('invalid isolated fixture')
    home, native_root = root / 'arl', root / 'native'
    library_id, instance_id = str(uuid.uuid4()), str(uuid.uuid4())
    sentinel = root / 'source-pin.txt'
    sentinel.write_text('synthetic reviewed source closure\n')
    source_paths = [*sorted((ROOT / 'arl').glob('*.py')),
                    ROOT / 'tests/__init__.py', ROOT / 'tests/capture_host_source_fixture.py', sentinel]
    executable = Path(process_pin(os.getpid())['executable'])
    spec = LaunchSpec('tisra', executable,
        ('-B', '-m', 'tests.capture_host_source_fixture', '--isolated-test', str(home), 'tisra'),
        ROOT, pin_sources(source_paths), (ROOT,))
    native = None
    selector_calls = 0
    provider_calls = []
    def forbidden_provider(*args, **kwargs):
        provider_calls.append('unexpected')
        raise AssertionError('provider execution forbidden in capture acceptance')
    Router.complete = forbidden_provider
    finished = threading.Event()
    controller_errors = []

    def select_native(identity):
        nonlocal native, selector_calls
        selector_calls += 1
        if mode == 'select_failure':
            raise Fault('synthetic_selection_failed')
        native = subprocess.Popen([str(native_path), '--isolated-test', str(native_root)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
        descriptor = dict(mode='create', library_id=library_id, instance_id=instance_id,
            host=process_pin(os.getpid()), registrations=[dict(process=identity.to_native(), writer_app='tisra',
                participant_id=PARTICIPANT.participant_id, actor_kind=PARTICIPANT.actor_kind,
                auth_epoch=PARTICIPANT.auth_epoch, active=True, write_granted=True, library_id=library_id)])
        native.stdin.write(json.dumps(descriptor) + '\n'); native.stdin.flush()
        metadata = read_line(native)
        pin = CaptureConsumerPin(library_id, instance_id, sha(native_path.read_bytes()))
        if metadata['code_sha256'] != pin.code_sha256 or metadata['library_id'] != library_id or metadata['instance_id'] != instance_id:
            raise AssertionError('selected native metadata mismatch')
        return NativeCaptureSelection(native.pid, str(native_path), pin.code_sha256,
            native_root / 'capture.sock', native_root / 'library/ledger.sqlite', pin)

    config = CaptureHostConfig(spec, '0' * 64 if mode == 'bad_hash' else sha(executable.read_bytes()),
        PARTICIPANT, 'native-capture-test', select_native,
        **(dict(library_granted=True, methods=frozenset(METHODS)) if mode == 'granted' else {}))
    attachment = CaptureHostAttachment(config, enabled=mode != 'disabled')
    pending = None
    if mode == 'disabled':
        home.mkdir(mode=0o700)
        store = Store(home / 'state.sqlite')
        tool = Tool('runtime.ping', object_schema(), lambda a, c: {'pong': True})
        pending = store.submit('tisra', 'synthetic-queued', tool, {}, AppPolicy(frozenset({tool.name})))
        store.close()

    def controller():
        try:
            deadline = time.monotonic() + 20
            while not finished.is_set() and time.monotonic() < deadline:
                if attachment.runtime is not None and attachment.runtime.ready.wait(0.02):
                    break
            else:
                if not finished.is_set():
                    raise AssertionError('host startup timeout')
                return
            runtime = attachment.runtime
            source = attachment.supervisor.children['tisra'] if attachment.supervisor is not None else None
            released = read_line(source) if source is not None else None
            if source is not None and released != {'released': True, 'pid': source.pid}:
                raise AssertionError('source gate release mismatch')
            waiting = runtime.store.get('tisra', pending['id']) if pending is not None else None
            emit(dict(event='ready', library_id=library_id, instance_id=instance_id, source_pid=source.pid if source else None,
                native_pid=native.pid if native else None, gate_released=released is not None,
                capture=runtime.capture is not None, worker=runtime.worker is not None,
                providers=sorted(runtime.policies['tisra'].providers), methods=sorted(runtime.policies['tisra'].methods),
                pending_state=waiting['state'] if waiting else None, pending_attempts=waiting['attempts'] if waiting else None))
            for line in sys.stdin:
                command = json.loads(line)
                if command == {'command': 'stop'}:
                    runtime.shutdown()
                    return
                if set(command) == {'method', 'params'} and source is not None:
                    source.stdin.write(json.dumps(command) + '\n'); source.stdin.flush()
                    emit(read_line(source))
                elif command == {'command': 'source_drift'}:
                    sentinel.write_text('synthetic changed source closure\n'); emit({'changed': True})
                elif command == {'command': 'revoke_source'}:
                    attachment.registrations.revoke('tisra'); emit({'revoked': True})
                elif command == {'command': 'revoke_native'}:
                    native.stdin.write(json.dumps({'command': 'revoke', 'writer_app': 'tisra'}) + '\n'); native.stdin.flush()
                    emit(read_line(native))
                elif command == {'command': 'close_while_running'}:
                    try:
                        attachment.close()
                    except Fault as error:
                        emit({'error': error.code})
                    else:
                        raise AssertionError('in-use capture descriptor closed')
                else:
                    raise AssertionError('invalid synthetic host command')
            runtime.shutdown()
        except BaseException as error:
            controller_errors.append(type(error).__name__)
            if attachment.runtime is not None:
                attachment.runtime.shutdown()

    thread = threading.Thread(target=controller, daemon=True)
    thread.start()
    result = run(home, capture_attachment=attachment)
    finished.set()
    thread.join(3)
    source = attachment.supervisor.children.get('tisra') if attachment.supervisor is not None else None
    summary = dict(event='stopped', result=result, closed=attachment._closed,
        runtime_closed=attachment.runtime.closed.is_set(), selector_calls=selector_calls,
        source_exited=source is None or source.poll() is not None,
        source_registered=source is not None and attachment.verifier.is_registered('tisra', source.pid),
        fd_closed=attachment.composition is None or attachment.composition.consumer._ledger_fd is None,
        worker_stopped=attachment.runtime.worker is None or not attachment.runtime.worker.is_alive(),
        controller_errors=controller_errors)
    summary['provider_calls'] = len(provider_calls)
    proof = home / 'synthetic-gate.json'
    summary['gate_proof'] = json.loads(proof.read_text()) if proof.exists() else None
    if summary['gate_proof'] is not None:
        try:
            os.kill(summary['gate_proof']['pid'], 0)
        except ProcessLookupError:
            summary['gate_child_reaped'] = True
        else:
            summary['gate_child_reaped'] = False
    for process in (source, native):
        if process is None:
            continue
        if process.poll() is None:
            if process is native:
                process.stdin.write('{"command":"stop"}\n'); process.stdin.flush()
            try:
                process.wait(3)
            except subprocess.TimeoutExpired:
                process.terminate(); process.wait(3)
        for pipe in (process.stdin, process.stdout, process.stderr):
            if pipe is not None and not pipe.closed:
                pipe.close()
    emit(summary)
    return result


if __name__ == '__main__':
    raise SystemExit(main())
