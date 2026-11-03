"""Neutral typed consumer for the explicit Codex application host seam."""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
import time
import uuid

from .client import Client
from .codex_application import EXECUTE, RECOVER
from .codex_server import NAME
from .contracts import Fault


class CodexApplicationClient:
    def __init__(self, client):
        self.client = client

    def connect(self, name='ARL acceptance consumer'):
        self.client.connect(timeout=10)
        accepted = self.client.open_app_session(name, (NAME,), icon_ref='sf:cpu', version='1')
        if NAME not in accepted:
            raise Fault('tool_not_authorized')
        return self.client.rpc('application.models.discover.v1', {'session_id': self.client.app_session})

    def resolve(self, text, *, model, effort, priority='explicit', deadline_ms=30000, request_id=None):
        catalog = self.client.rpc('application.models.discover.v1', {'session_id': self.client.app_session})
        if catalog.get('execution', {}).get('method') != EXECUTE:
            raise Fault('application_models_execution_unavailable')
        offers = [p for p in catalog['packages'] if p['available'] and p['model'] == model
            and effort in p['supported_efforts'] and not p['reasons']]
        if not offers:
            raise Fault('provider_model_change_not_authorized')
        request = {'schema_version': 1, 'session_id': self.client.app_session,
            'catalog_version': catalog['catalog_version'], 'request_id': request_id or str(uuid.uuid4()),
            'request_sha256': hashlib.sha256(text.encode('utf-8')).hexdigest(), 'task_kind': 'explain',
            'package_id': offers[0]['package_id'], 'priority': priority, 'deadline_ms': deadline_ms,
            'thinking_effort': effort, 'service_tier': 'default', 'allow_degradation': False}
        resolved = self.client.rpc('application.models.request.v1', request)
        expected = {'model': model, 'effort': effort, 'priority': priority,
            'deadline_ms': deadline_ms, 'service_tier': 'default'}
        if resolved.get('accepted') is not True or resolved.get('resolved') != expected:
            raise Fault('application_models_resolution_rejected')
        return resolved

    def execute(self, resolved, text, *, max_output_bytes=128):
        p = {k: resolved[k] for k in ('schema_version', 'session_id', 'request_id', 'request_sha256', 'resolution_id')}
        p.update(input=text, max_output_bytes=max_output_bytes)
        result = self.client.rpc(EXECUTE, p)
        self.validate(result, resolved['request_id'], resolved['request_sha256'], resolved['resolved'])
        return result

    def recover(self, request_id, request_sha256, *, expected=None):
        result = self.client.rpc(RECOVER, {'schema_version': 1, 'session_id': self.client.app_session,
            'request_id': request_id, 'request_sha256': request_sha256})
        self.validate(result, request_id, request_sha256, expected)
        return result

    @staticmethod
    def validate(result, request_id, request_sha256, expected=None):
        if (type(result) is not dict or result.get('schema_version') != 1
                or result.get('request_id') != request_id or result.get('request_sha256') != request_sha256):
            raise Fault('application_models_result_mismatch')
        actual = result.get('execution') or {}
        if expected is not None and any(actual.get(k) != v for k, v in expected.items()):
            raise Fault('application_models_result_mismatch')
        job = result.get('job') or {}
        if job.get('state') == 'succeeded':
            body = job.get('result') or {}
            preferences = body.get('execution_preferences') or {}
            if (body.get('model') != actual.get('model') or body.get('request_sha256') != request_sha256
                    or preferences.get('reasoning_effort') != actual.get('effort')
                    or preferences.get('service_tier') != actual.get('service_tier')
                    or body.get('output_sha256') != hashlib.sha256(body.get('text', '').encode()).hexdigest()
                    or body.get('thread_id') != job.get('progress', {}).get('native', {}).get('thread_id')
                    or body.get('turn_id') != job.get('progress', {}).get('native', {}).get('turn_id')
                    or job.get('progress', {}).get('native', {}).get('terminal') != 'completed'):
                raise Fault('application_models_result_mismatch')


def acceptance(home, caller, *, mode, model, effort, priority='explicit'):
    client = Client(home, caller)
    consumer = CodexApplicationClient(client)
    text = ('Return exactly ARL_CODEX_OK as the text value. Do not call tools or access files.' if mode == 'success'
        else 'List every integer from 1 through 2000, separated by spaces, as the text value. Do not call tools or access files.')
    try:
        catalog = consumer.connect()
        resolved = consumer.resolve(text, model=model, effort=effort, priority=priority)
        submitted = consumer.execute(resolved, text, max_output_bytes=128 if mode == 'success' else 32768)
        # A second socket/client observes the exact existing job, without another
        # submit. The UUID/body and server-frozen model/preferences remain fixed.
        observer = Client(home, caller)
        deadline = time.monotonic()+35
        cancel_requested = False
        while time.monotonic() < deadline:
            job = observer.rpc('get', {'id': submitted['job']['id']})
            native = job.get('progress', {}).get('native', {})
            if (mode == 'cancel' and not cancel_requested and job['state'] == 'running'
                    and native.get('turn_id') and native.get('terminal') == 'unknown'):
                observer.rpc('cancel', {'id': job['id']})
                cancel_requested = True
            if job['state'] in {'succeeded', 'failed', 'cancelled', 'needs_review'}:
                break
            time.sleep(.01)
        else:
            raise Fault('job_timeout')
        client.close_app_session()
        consumer.connect()
        recovered = consumer.recover(resolved['request_id'], resolved['request_sha256'], expected=resolved['resolved'])
        if recovered['job']['id'] != submitted['job']['id']:
            raise Fault('application_models_result_mismatch')
        job, native = recovered['job'], recovered['job'].get('progress', {}).get('native', {})
        success = (job['state'] == 'succeeded' and (job.get('result') or {}).get('text') == 'ARL_CODEX_OK')
        cancelled = (cancel_requested and job['state'] == 'cancelled' and native.get('terminal') == 'interrupted'
            and native.get('interrupt') == 'acknowledged' and not (job.get('result') or {}).get('text'))
        return {'ok': success if mode == 'success' else cancelled, 'mode': mode,
            'request_id': resolved['request_id'], 'request_sha256': resolved['request_sha256'],
            'job_id': job['id'], 'job_state': job['state'], 'error_code': job.get('error'),
            'execution': recovered['execution'], 'native': native,
            'expected_text_matched': success, 'cancel_requested_after_turn_ack': cancel_requested,
            'reconnected_new_session': True, 'recovered_same_job': True,
            'simulated': (job.get('result') or {}).get('simulated'),
            'turns_started': 1, 'catalog_source': catalog['catalog_source'],
            'generated_text_published': bool((job.get('result') or {}).get('text'))}
    finally:
        client.close_app_session()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--home', required=True)
    parser.add_argument('--caller', required=True)
    parser.add_argument('--model', required=True)
    parser.add_argument('--effort', required=True)
    parser.add_argument('--mode', choices=('success', 'cancel'), required=True)
    parser.add_argument('--priority', choices=('background', 'explicit', 'interactive'), default='explicit')
    args = parser.parse_args()
    # Host registers the already-created kernel process before releasing it.
    print('ready-for-registration', flush=True)
    if sys.stdin.readline().strip() != 'registered':
        raise SystemExit(2)
    try:
        result = acceptance(args.home, args.caller, mode=args.mode, model=args.model,
            effort=args.effort, priority=args.priority)
    except Fault as exc:
        result = {'ok': False, 'error_code': exc.code}
    print(json.dumps(result, sort_keys=True), flush=True)
    raise SystemExit(0 if result['ok'] else 1)


if __name__ == '__main__':
    main()
