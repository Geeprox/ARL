"""One production RuntimeStore race against a real isolated ARL host."""
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

sys.dont_write_bytecode = True
ROOT = Path(os.environ.get('ARL_CONTROL_SOURCE', Path(__file__).resolve().parents[3]))
HARNESS = Path(os.environ['ARL_CONTROL_HARNESS'])
sys.path.insert(0, str(ROOT))
from arl.contracts import Fault
from arl.host import metadata_policies
from arl.providers import MockProvider
from arl.service import Runtime

with tempfile.TemporaryDirectory(prefix='arl-legacy-race-', dir='/tmp') as directory:
    home = Path(directory)
    runtime = Runtime(home, policies=metadata_policies(), providers={'mock': MockProvider()},
                      execute_jobs=False, identity_verifier=lambda connection, app: None)
    failures = []
    def serve():
        try:
            runtime.run()
        except Exception as exc:
            failures.append(type(exc).__name__)
    thread = threading.Thread(target=serve)
    thread.start()
    try:
        assert runtime.ready.wait(5), 'host_not_ready'
        diagnostics = runtime.control.diagnostics
        original_query = diagnostics.query
        def no_v3(params):
            raise Fault('unknown_method')
        def delayed_query(params, *, export=False):
            if not export and params.get('level') == 'warning':
                (home/'warning-request-started').write_text('started\n')
                time.sleep(0.7)
                try:
                    return original_query(params, export=export)
                finally:
                    (home/'warning-request-finished').write_text('finished\n')
            return original_query(params, export=export)
        diagnostics.query_v3 = no_v3
        diagnostics.query = delayed_query
        diagnostics.emit('rpc_rejected', code='method_not_authorized', level='warning')
        diagnostics.emit('rpc_rejected', code='method_not_authorized', level='error')
        environment = {'PATH':'/usr/bin:/bin','HOME':str(Path.home()),'TMPDIR':'/tmp'}
        run = subprocess.run([str(HARNESS), str(home), 'legacy-race'], env=environment,
                             capture_output=True, text=True, timeout=15)
        assert run.returncode == 0, 'swift_harness_failed'
        result = json.loads(run.stdout)
        assert result['ok'] and result['legacy'], result
        assert result['levels'] and set(result['levels']) == {'error'}, result
        assert result['log_error'] == '', result
        assert runtime.worker is None and runtime.store.state_counts().get('running', 0) == 0
        print(json.dumps({'passed':True,'legacy':True,'stale_warning_discarded':True,
                          'error_rows':len(result['levels']),'host_execute_jobs':False},sort_keys=True))
    finally:
        runtime.shutdown()
        thread.join(5)
        assert not thread.is_alive() and not failures, failures

environment = {'PATH':'/usr/bin:/bin','HOME':str(Path.home()),'TMPDIR':'/tmp'}
with tempfile.TemporaryDirectory(prefix='arl-scope-check-', dir='/tmp') as directory:
    result = subprocess.run([str(HARNESS), directory, 'messages-scopes'], env=environment,
                            capture_output=True, text=True, timeout=5)
    assert result.returncode == 0, 'scope_harness_failed'
    scopes = json.loads(result.stdout)
    assert scopes['ok'] and set(scopes['ids']) == {'messages.receive.v1', 'messages.send.v1'}, scopes
    assert len(set(scopes['titles'])) == 2, scopes
    assert set(scopes['kinds']) == {'所需文件访问', '系统自动化'}, scopes
    print(json.dumps({'passed':True,'messages_permission_scopes':scopes['ids']},sort_keys=True))

with tempfile.TemporaryDirectory(prefix='arl-disconnect-', dir='/tmp') as directory:
    home = Path(directory)
    runtime = Runtime(home, policies=metadata_policies(), providers={'mock': MockProvider()},
                      execute_jobs=False, identity_verifier=lambda connection, app: None)
    failures = []
    def serve():
        try:
            runtime.run()
        except Exception as exc:
            failures.append(type(exc).__name__)
    thread = threading.Thread(target=serve)
    thread.start()
    process = None
    try:
        assert runtime.ready.wait(5), 'host_not_ready'
        process = subprocess.Popen([str(HARNESS), str(home), 'disconnect'], env=environment,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        limit = time.monotonic() + 5
        while not (home/'disconnect-first-read').exists() and time.monotonic() < limit:
            time.sleep(0.02)
        assert (home/'disconnect-first-read').exists(), 'first_read_not_observed'
        runtime.shutdown()
        thread.join(5)
        assert not thread.is_alive() and not failures, failures
        (home/'disconnect-host-stopped').write_text('stopped\n')
        output, _ = process.communicate(timeout=8)
        assert process.returncode == 0, 'disconnect_harness_failed'
        result = json.loads(output)
        assert (result['ok'] and not result['connected'] and not result['snapshot_present']
                and not result['runtime_present'] and result['overview_error'] == 'disconnected'
                and not result['permission_busy'] and not result['reminders_request_present']), result
        print(json.dumps({'passed':True,'explicit_disconnect_clears_snapshot':True,
                          'action_entry_blocked':True},sort_keys=True))
    finally:
        if thread.is_alive(): runtime.shutdown()
        thread.join(5)
        if process is not None and process.poll() is None:
            process.terminate()
            process.wait(timeout=5)

for code in ('rpc_deadline_exceeded', 'disconnected'):
    with tempfile.TemporaryDirectory(prefix='arl-control-failure-', dir='/tmp') as directory:
        home = Path(directory)
        runtime = Runtime(home, policies=metadata_policies(), providers={'mock': MockProvider()},
                          execute_jobs=False, identity_verifier=lambda connection, app: None)
        failures = []
        def serve():
            try:
                runtime.run()
            except Exception as exc:
                failures.append(type(exc).__name__)
        thread = threading.Thread(target=serve)
        thread.start()
        try:
            assert runtime.ready.wait(5), 'host_not_ready'
            def broken_snapshot():
                raise Fault(code)
            runtime.control.snapshot = broken_snapshot
            result = subprocess.run([str(HARNESS), str(home), 'control-failure'], env=environment,
                                    capture_output=True, text=True, timeout=8)
            assert result.returncode == 0, 'control_failure_harness_failed'
            state = json.loads(result.stdout)
            assert not state['connected'] and not state['permission_busy'], state
            if code == 'disconnected':
                assert not state['snapshot_present'] and state['overview_error'] == code, state
            else:
                assert state['snapshot_present'] and state['control_error'] == code and state['log_error'] == code, state
                assert state['title'] == '状态待更新', state
            print(json.dumps({'passed':True,'control_error':code,'connected':False,
                              'cached_snapshot':state['snapshot_present']},sort_keys=True))
        finally:
            runtime.shutdown()
            thread.join(5)
            assert not thread.is_alive() and not failures, failures
