import concurrent.futures
import http.client
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / 'nas'), str(ROOT.parents[1])]
# 按 NAS 目录中的独立模块名加载，避免覆盖旧桥接测试的运行时来源。
spec = importlib.util.spec_from_file_location('model_context', ROOT.parents[1] / 'arl/codex_context.py')
context = importlib.util.module_from_spec(spec)
spec.loader.exec_module(context)
sys.modules.setdefault('model_context', context)

from contract import MODEL
from local_api import atomic, chat_completion, server
from router import OpenAIError, Router, openai_completion, proxy_address, validate_policy


APP = 'bilinote'
REQUEST = {'model': MODEL, 'messages': [{'role': 'user', 'content': '概括这段合成字幕'}]}


class RouterTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.home = Path(temporary.name)
        self.queue, self.control, self.state = (self.home / name for name in ('queue', 'control', 'state'))
        for path in (self.queue / APP, self.queue / 'pdf2zh', self.control, self.state):
            path.mkdir(parents=True)
        self.key = self.home / 'openai'
        self.key.write_text('sk-' + 'synthetic' * 4)
        self.key.chmod(0o600)
        self.api_calls, self.codex_calls = [], []
        self.configure()
        self.route = self.router()

    def configure(self, *, mode='openai_preferred', cap=1, total=2, apps=(APP,)):
        policy = {
            'schema': 1, 'revision': str(uuid.uuid4()), 'global_daily_api_requests': total,
            'apps': {app: {'mode': mode, 'api_model': 'gpt-5-mini', 'daily_api_requests': cap} for app in apps},
        }
        atomic(self.control / 'policy.json', policy)
        return policy

    def router(self, *, apps=(APP,), api=None):
        def call_api(_key, model, value, request):
            self.api_calls.append(request['id'])
            self.assertEqual(model, 'gpt-5-mini')
            return 200, chat_completion(request['id'], value['model'], 'API 合成摘要'), 57

        def call_codex(app, root, value, request):
            self.codex_calls.append((app, request['id']))
            return 200, chat_completion(request['id'], value['model'], 'Codex 合成摘要')

        return Router(self.queue, self.control, self.state, self.key, apps, api=api or call_api, codex=call_codex)

    def catalog(self, app=APP):
        atomic(self.queue / app / 'catalog.json', {
            'published_at': time.time(), 'models': [{'id': MODEL, 'object': 'model'}],
            'schema_version': 2, 'catalog_version': 'test', 'package_revision': 'test',
            'quota_policy': 'test', 'local_lifetime_call_limit': None,
        })

    def test_api_remains_available_without_mac_and_restart_preserves_cap(self):
        self.assertEqual(self.route.models(APP)[0], 200)
        identity = str(uuid.uuid4())
        first = self.route.complete(APP, REQUEST, identity)
        self.assertEqual((first[0], first[2]), (200, 'openai'))
        self.assertFalse(self.codex_calls)
        restarted = self.router()
        self.assertEqual(restarted.complete(APP, REQUEST, identity), first)
        self.assertEqual(restarted.complete(APP, REQUEST, None)[0], 429)
        self.catalog()
        second = restarted.complete(APP, REQUEST, None)
        self.assertEqual((second[0], second[2]), (200, 'codex'))
        restarted.publish()
        status = json.loads((self.control / 'status.json').read_text())
        self.assertEqual(status['apps'][APP]['last_reason'], 'daily_api_limit')
        self.assertEqual(status['apps'][APP]['reported_tokens'], 57)
        self.assertEqual(len(self.api_calls), 1)

    def test_global_limit_reservation_is_shared_and_atomic(self):
        apps = (APP, 'pdf2zh')
        self.configure(cap=8, total=1, apps=apps)
        for app in apps:
            self.catalog(app)
        route = self.router(apps=apps)
        gate = threading.Barrier(6)

        def call(app):
            gate.wait(timeout=5)
            return route.complete(app, REQUEST, None)[2]

        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
            used = list(pool.map(call, apps * 3))
        self.assertEqual(used.count('openai'), 1)
        self.assertEqual(used.count('codex'), 5)

    def test_disabling_limits_keeps_usage_and_upstream_quota_fallback(self):
        self.catalog()
        self.assertEqual(self.route.complete(APP, REQUEST, None)[2], 'openai')
        self.assertEqual(self.route.complete(APP, REQUEST, None)[2], 'codex')
        policy = self.configure(cap=None, total=None)
        policy.pop('global_daily_api_requests')
        atomic(self.control / 'policy.json', policy)
        for _ in range(3):
            self.assertEqual(self.route.complete(APP, REQUEST, None)[2], 'openai')
        self.route.publish()
        status = json.loads((self.control / 'status.json').read_text())
        self.assertFalse(status['policy_invalid'])
        self.assertIsNone(status['global_daily_api_requests'])
        self.assertIsNone(status['apps'][APP]['daily_api_requests'])
        self.assertEqual(status['apps'][APP]['api_requests'], 4)
        self.assertEqual(status['apps'][APP]['reported_tokens'], 228)

        def rejected(*_):
            raise OpenAIError('api_rate_or_quota', rejected=True)

        self.assertEqual(self.router(api=rejected).complete(APP, REQUEST, None)[2], 'codex')

    def test_optional_limits_are_independent_and_zero_still_pauses_api(self):
        self.catalog()
        cases = ((0, None, 'codex'), (None, 0, 'codex'), (None, None, 'openai'))
        for total, cap, provider in cases:
            with self.subTest(total=total, cap=cap):
                policy = self.configure(cap=cap, total=total)
                if cap is None:
                    policy['apps'][APP].pop('daily_api_requests')
                    atomic(self.control / 'policy.json', policy)
                self.assertEqual(self.route.complete(APP, REQUEST, None)[2], provider)

    def test_invalid_limit_values_are_rejected(self):
        for value in (True, False, -1, 100001, '1', 1.0):
            with self.subTest(value=value):
                policy = self.configure(total=value)
                with self.assertRaises(ValueError):
                    validate_policy(policy, (APP,))
                policy = self.configure(cap=value)
                with self.assertRaises(ValueError):
                    validate_policy(policy, (APP,))

    def test_ambiguous_api_failure_keeps_reservation_and_does_not_replay(self):
        self.catalog()

        def unavailable(*_):
            self.api_calls.append('sent')
            raise OpenAIError('api_result_unknown')

        route = self.router(api=unavailable)
        identity = str(uuid.uuid4())
        reply = route.complete(APP, REQUEST, identity)
        self.assertEqual(reply[0], 422)
        self.assertEqual(self.router().complete(APP, REQUEST, identity), reply)
        changed = {**REQUEST, 'messages': [{'role': 'user', 'content': 'another request'}]}
        self.assertEqual(route.complete(APP, changed, identity)[0], 409)
        self.assertEqual(self.api_calls, ['sent'])
        self.assertFalse(self.codex_calls)

    def test_explicit_quota_rejection_can_fall_back_once(self):
        self.catalog()
        identity = str(uuid.uuid4())

        def capped(*_):
            self.api_calls.append('rejected')
            raise OpenAIError('api_rate_or_quota', rejected=True)

        route = self.router(api=capped)
        reply = route.complete(APP, REQUEST, identity)
        self.assertEqual((reply[0], reply[2]), (200, 'codex'))
        self.assertEqual(route.complete(APP, REQUEST, identity), reply)
        self.assertEqual(self.api_calls, ['rejected'])
        self.assertEqual(self.codex_calls, [(APP, identity)])

    def test_tls_failure_before_sending_can_fall_back(self):
        request = {'id': str(uuid.uuid4()), 'messages': REQUEST['messages']}
        with patch('router.http.client.HTTPSConnection') as factory:
            connection = factory.return_value
            connection.connect.side_effect = TimeoutError
            with self.assertRaises(OpenAIError) as caught:
                openai_completion('synthetic', 'gpt-5-mini', REQUEST, request)
            self.assertTrue(caught.exception.rejected)
            self.assertEqual(str(caught.exception), 'api_unreachable')
            connection.request.assert_not_called()

    def test_failure_after_sending_keeps_the_original_attempt(self):
        request = {'id': str(uuid.uuid4()), 'messages': REQUEST['messages']}
        with patch('router.http.client.HTTPSConnection') as factory:
            connection = factory.return_value
            connection.getresponse.side_effect = TimeoutError
            with self.assertRaises(OpenAIError) as caught:
                openai_completion('synthetic', 'gpt-5-mini', REQUEST, request)
            self.assertFalse(caught.exception.rejected)
            self.assertEqual(str(caught.exception), 'api_result_unknown')
            connection.request.assert_called_once()

    def test_connect_proxy_only_tunnels_to_official_api(self):
        request = {'id': str(uuid.uuid4()), 'messages': REQUEST['messages']}
        with patch('router.http.client.HTTPSConnection') as factory:
            connection = factory.return_value
            connection.connect.side_effect = TimeoutError
            with self.assertRaises(OpenAIError) as caught:
                openai_completion('synthetic', 'gpt-5-mini', REQUEST, request, proxy=proxy_address('192.168.0.10:19148'))
            self.assertTrue(caught.exception.rejected)
            factory.assert_called_once_with('192.168.0.10', 19148, timeout=8)
            connection.set_tunnel.assert_called_once_with('api.openai.com', 443)
            connection.request.assert_not_called()

    def test_valid_policy_is_reloaded_and_kept_when_mount_is_unavailable(self):
        self.catalog()
        new = self.configure(mode='codex')
        self.assertEqual(self.route.complete(APP, REQUEST, None)[2], 'codex')
        (self.control / 'policy.json').unlink()
        restarted = self.router()
        restarted.publish()
        status = json.loads((self.control / 'status.json').read_text())
        self.assertTrue(status['policy_invalid'])
        self.assertEqual(status['applied_revision'], new['revision'])
        self.assertEqual(restarted.complete(APP, REQUEST, None)[2], 'codex')
        self.assertFalse(self.api_calls)

    def test_container_loopback_keeps_application_token_and_stream_format(self):
        old_dir = Path.cwd()
        os.chdir(self.home)
        self.addCleanup(os.chdir, old_dir)
        root = Path('queue') / APP
        marker = self.home / 'enrolled'
        marker.touch()
        token = 'synthetic-app-token'
        backend = server(APP, root, token, router=self.route, socket_path=root / 'router.sock')
        frontend = server(APP, root, token, router_marker=marker, address=('127.0.0.1', 0))
        for endpoint in (backend, frontend):
            thread = threading.Thread(target=endpoint.serve_forever)
            thread.start()
            self.addCleanup(endpoint.server_close)
            self.addCleanup(thread.join, 5)
            self.addCleanup(endpoint.shutdown)
        with self.connection(frontend) as conn:
            conn.request('GET', '/v1/models', headers={'Authorization': 'Bearer wrong'})
            result = conn.getresponse()
            self.assertEqual(result.status, 401)
            result.read()
            headers = {'Authorization': 'Bearer ' + token}
            conn.request('GET', '/v1/models', headers=headers)
            result = conn.getresponse()
            self.assertEqual(result.status, 200)
            self.assertEqual(json.loads(result.read())['data'][0]['id'], MODEL)
            body = json.dumps({**REQUEST, 'stream': True}).encode()
            conn.request('POST', '/v1/chat/completions', body=body, headers=headers)
            result = conn.getresponse()
            self.assertEqual(result.status, 200)
            self.assertEqual(result.getheader('X-ARL-Provider'), 'openai')
            self.assertIn(b'data: [DONE]', result.read())

    def connection(self, frontend):
        from contextlib import closing
        return closing(http.client.HTTPConnection('127.0.0.1', frontend.server_port, timeout=5))


if __name__ == '__main__':
    unittest.main()
