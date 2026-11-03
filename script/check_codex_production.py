"""Neutral real-process Codex acceptance. Offline by default; real mode is explicit.

Exactly one completion and one active-cancel intent, using the existing account,
configured model, Standard tier and the original Store/worker. No installation.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import selectors
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from arl.application_models import METHODS as MODEL_METHODS
from arl.codex_application import EXECUTION_METHODS, compose_codex_application
from arl.codex_server import CodexTextAdapter, CodexService, DEFAULT_BINARY, thread_preferences
from arl.contracts import AppPolicy, Fault
from arl.identity import RegisteredPeerVerifier, process_identity


def run(*, real=False, expected_model=None, effort='medium', binary=DEFAULT_BINARY):
    if type(real) is not bool or real and not expected_model:
        raise Fault('explicit_model_required')
    caller = 'arl-codex-acceptance'
    model = expected_model if real else 'synthetic-model'
    if not real and expected_model not in (None, model):
        raise Fault('provider_model_change_not_authorized')
    command = None if real else [sys.executable, '-B', '-I', str(ROOT/'tests/fixtures/CodexProductionServer.py')]
    thread_preferences(effort, 'default')
    adapter = CodexTextAdapter(binary=binary, enabled=True, test_command=command)
    registry = RegisteredPeerVerifier({caller})
    events, errors, consumers = [], [], []
    adapter.observer = events.append

    def current_peer():
        try:
            return bool(registry.registration_subject(caller))
        except Fault:
            return False

    def launch(home, mode):
        child = subprocess.Popen([sys.executable, '-B', '-m', 'arl.codex_application_client',
            '--home', str(home), '--caller', caller, '--model', model, '--effort', effort,
            '--mode', mode, '--priority', 'interactive' if mode == 'cancel' else 'background'],
            cwd=ROOT, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        consumers.append(child)
        with selectors.DefaultSelector() as selector:
            selector.register(child.stdout, selectors.EVENT_READ)
            if not selector.select(10) or child.stdout.readline().strip() != 'ready-for-registration':
                raise Fault('consumer_start_failed')
        registry.register(caller, child.pid, process_identity(child.pid)['executable'])
        return child

    proof = {'schema_version': 1, 'simulated': not real, 'requested_turns': 2,
        'max_calls': 2, 'service_tier': 'default', 'model': model, 'effort': effort,
        'caller': caller, 'consumer_identity': 'registered_kernel_pid_birth_executable',
        'production_signed_caller_verified': False, 'installed_runtime_changes': False,
        'provider_account_switch': False, 'provider_model_switch': False, 'api_fallback': False,
        'token_hard_cap_supported': False, 'cost_hard_cap_supported': False,
        'results': [], 'ok': False}
    start = time.monotonic()
    with tempfile.TemporaryDirectory(prefix='arlcap-', dir=Path('/tmp').resolve()) as home:
        first = launch(home, 'success')
        service = CodexService(adapter, caller=caller, model=model,
            reasoning_effort=effort, service_tier='default', max_calls=2,
            authorization_current=lambda: True, peer_current=current_peer,
            allow_model_selection=True, allow_test_command=not real)
        policy = AppPolicy(frozenset({service.name}), providers=frozenset(), max_tokens=0,
            max_pending=1, max_calls=2, methods=MODEL_METHODS | EXECUTION_METHODS |
                {'health', 'ready', 'capabilities', 'get', 'cancel', 'heartbeat'},
            priority_bands=frozenset({'background', 'explicit', 'interactive'}), max_deadline_ms=30000)
        runtime = compose_codex_application(home, service=service, peer_verifier=registry,
            policy=policy, isolated=True)
        thread = threading.Thread(target=lambda: _serve(runtime, errors), daemon=True)
        thread.start()
        try:
            if not runtime.ready.wait(10):
                raise Fault('ready_timeout')
            for mode in ('success', 'cancel'):
                child = first if mode == 'success' else launch(home, mode)
                # A no-turn, bounded read-only preflight for this current process
                # generation. Real preflight never changes account/config/model.
                preflight = service.preflight()
                proof['preflight'] = {k: preflight[k] for k in ('model', 'ephemeral', 'read_only', 'synthetic', 'execution_preferences')}
                stdout, stderr = child.communicate('registered\n', timeout=45)
                registry.revoke(child.pid)
                try:
                    result = json.loads(stdout)
                except (ValueError, TypeError):
                    result = {'ok': False, 'error_code': 'consumer_protocol_failed',
                        'stderr_bytes': len(stderr.encode('utf-8'))}
                result['consumer_exit_code'] = child.returncode
                proof['results'].append(result)
                if not result.get('ok') or child.returncode != 0:
                    break
            with runtime.store.lock:
                proof['jobs_total'] = sum(runtime.store.state_counts().values())
                row = runtime.store.db.execute('SELECT calls FROM budget WHERE owner=?', (caller,)).fetchone()
                proof['persistent_call_count'] = row[0] if row else 0
            proof['provider_events'] = events
            proof['ok'] = (len(proof['results']) == 2 and all(r.get('ok') for r in proof['results'])
                and proof['jobs_total'] == proof['persistent_call_count'] == 2)
        except Fault as exc:
            proof['error_code'] = exc.code
        except subprocess.TimeoutExpired:
            proof['error_code'] = 'consumer_timeout'
        finally:
            for child in consumers:
                if child.poll() is None:
                    child.terminate()
                    try:
                        child.communicate(timeout=5)
                    except subprocess.TimeoutExpired:
                        child.kill(); child.communicate(timeout=5)
            runtime.shutdown(); thread.join(40)
            proof['isolated_runtime_closed'] = runtime.closed.is_set() and not thread.is_alive()
            proof['owned_consumers_closed'] = all(p.poll() is not None for p in consumers)
            if errors:
                proof['runtime_error_type'] = type(errors[0]).__name__
                proof['ok'] = False
    proof['elapsed_ms'] = int((time.monotonic()-start)*1000)
    proof['source_sha256'] = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
        for p in (ROOT/'arl/codex_application.py', ROOT/'arl/codex_application_client.py', Path(__file__))}
    return proof


def _serve(runtime, errors):
    try:
        runtime.run()
    except Exception as exc:
        errors.append(exc)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--real', action='store_true', help='Explicitly allow at most two real turns')
    parser.add_argument('--expected-model', help='Must match the existing configured account model')
    parser.add_argument('--effort', default='medium')
    parser.add_argument('--binary', type=Path, default=DEFAULT_BINARY)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        parser.error('Output exists; preserve earlier evidence and choose a new path')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    try:
        result = run(real=args.real, expected_model=args.expected_model, effort=args.effort, binary=args.binary)
    except Fault as exc:
        result = {'ok': False, 'error_code': exc.code, 'requested_turns': 0}
    fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as stream:
        json.dump(result, stream, ensure_ascii=False, sort_keys=True, indent=2)
        stream.write('\n')
    print(json.dumps({'ok': result.get('ok'), 'simulated': result.get('simulated'),
        'results': [{k: r.get(k) for k in ('mode', 'ok', 'job_state', 'error_code')} for r in result.get('results', [])],
        'error_code': result.get('error_code'), 'output': str(args.output)}))
    raise SystemExit(0 if result.get('ok') else 1)


if __name__ == '__main__':
    main()
