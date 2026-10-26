import json
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from unittest.mock import patch

from arl.contracts import AppPolicy, Fault
from arl.providers import MockProvider, OllamaProvider, Router
from arl.service import Runtime, default_policies
from arl.capabilities import AppleAdapter
from arl.travel import TravelAdapter
from tests.test_runtime import RuntimeCase, running


class Context:
    def check_cancelled(self):
        pass


class LocalHandler(BaseHTTPRequestHandler):
    calls = []
    def log_message(self, *args):
        pass
    def do_GET(self):
        data = {"/api/tags": {"models": [{"name": "installed-test"}]}}.get(self.path, {})
        self.send_response(200); self.end_headers(); self.wfile.write(json.dumps(data).encode())
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.calls.append((self.path, body))
        data = {"/api/generate": {"response": "local-test", "eval_count": 3}}.get(self.path, {})
        self.send_response(200); self.end_headers(); self.wfile.write(json.dumps(data).encode())


class ProviderTests(unittest.TestCase):
    def setUp(self):
        LocalHandler.calls = []
        self.server = HTTPServer(("127.0.0.1", 0), LocalHandler)
        self.thread = threading.Thread(target=self.server.serve_forever)
        self.thread.start()
        self.url = "http://127.0.0.1:"+str(self.server.server_port)
    def tearDown(self):
        self.server.shutdown(); self.thread.join(); self.server.server_close()
    def assert_fault(self, code, callback):
        with self.assertRaises(Fault) as result:
            callback()
        self.assertEqual(result.exception.code, code)

    def test_real_ollama_adapter_contract_without_real_inference(self):
        provider = OllamaProvider()
        provider.base = self.url
        self.assertEqual(provider.discover()["models"], ["installed-test"])
        args = {"provider": "ollama", "model": "installed-test", "prompt": "synthetic", "max_tokens": 16}
        result = provider.complete(args, Context())
        self.assertEqual(result["text"], "local-test")
        self.assertEqual(LocalHandler.calls[0][0], "/api/generate")
        self.assertEqual(LocalHandler.calls[0][1]["keep_alive"], 0)
        self.assertEqual(LocalHandler.calls[0][1]["options"]["num_predict"], 16)
        args["model"] = "missing-model"
        self.assert_fault("model_not_installed", lambda: provider.complete(args, Context()))
        self.assertEqual(len(LocalHandler.calls), 1)  # No pull or fallback.

    def test_removed_provider_and_explicit_empty_catalog(self):
        router = Router(default_policies())
        self.assertNotIn("laya_mlx", router.providers)
        self.assertEqual(Router(default_policies(), providers={}).discover(), [])
        self.assert_fault("unknown_provider", lambda: router.check("friday", {
            "provider": "laya_mlx", "model": "removed", "prompt": "synthetic", "max_tokens": 16}))

    def test_router_blocks_paid_unknown_and_unauthorized_routes(self):
        router = Router(default_policies())
        args = {"provider": "mock", "model": "deterministic-v1", "prompt": "synthetic", "max_tokens": 16}
        router.check("tisra", args)
        for provider, code in [("codex_app_server", "paid_provider_disabled"), ("jev", "paid_provider_disabled"),
                               ("ollama", "provider_not_authorized"), ("unknown", "unknown_provider")]:
            args["provider"] = provider
            self.assert_fault(code, lambda: router.check("tisra", args))
        args["provider"] = "mock"; args["max_tokens"] = 257
        self.assert_fault("model_budget_exceeded", lambda: router.check("tisra", args))
        args["max_tokens"] = 16; args["prompt"] = "中"*400
        self.assert_fault("model_budget_exceeded", lambda: router.check("tisra", args))
        local = Router(default_policies(True))
        args.update(provider="ollama", prompt="test")
        self.assert_fault("local_inference_disabled", lambda: local.check("tisra", args))


class AdapterTests(RuntimeCase):

    def test_mock_model_routing_and_budget_are_service_side(self):
        with running(self.home) as (_, client):
            args = {"provider": "mock", "model": "deterministic-v1", "prompt": "synthetic", "max_tokens": 16}
            job = client.submit("model.complete", args, "model")
            self.assertTrue(client.wait(job["id"])["result"]["simulated"])
            args["max_tokens"] = 257
            self.assert_fault("model_budget_exceeded", lambda: client.submit("model.complete", args, "budget"))
            args["provider"] = "codex_app_server"
            self.assert_fault("paid_provider_disabled", lambda: client.submit("model.complete", args, "paid"))

    def test_apple_test_double_permission_unlock_and_private_access(self):
        unlocked = threading.Event()
        adapter = AppleAdapter(lambda tool, args: {"status": "ok", "result": {"mock": True}} if unlocked.is_set()
                               else {"status": "needs_unlock"})
        verifier = lambda connection, app: app  # Test double; never production composition.
        with running(self.home, apple=adapter, identity_verifier=verifier) as (runtime, client):
            job = client.submit("apple.calendar.list", {"start": "synthetic", "end": "synthetic"}, "apple")
            self.assertEqual(client.wait(job["id"])["state"], "needs_unlock")
            # Calling dispatcher with a forged JSON ID still has no verified transport identity.
            request = {"protocol": "arl/1", "app": "tisra", "method": "get", "params": {"id": job["id"]}}
            self.assert_fault("app_identity_unverified", lambda: runtime.dispatch(request))
            unlocked.set(); client.rpc("resume", {"id": job["id"]})
            self.assertTrue(client.wait(job["id"])["result"]["mock"])

    def test_travel_schema_and_result_compatibility_no_credentials(self):
        adapter = TravelAdapter()
        self.assertEqual(len(adapter.descriptors), 14)  # Includes the already-published weather tool.
        source = {t["name"]: t["inputSchema"] for t in adapter.descriptors}
        self.assertEqual(source, {t.name: t.schema for t in adapter.tools()})
        result = adapter.call("mio_tunnel_ping", {}, Context())
        self.assertEqual(result, {"content": [{"type": "text", "text": "pong from mac-mini"}], "isError": False})
        self.assert_fault("travel_transport_not_enabled", lambda: adapter.call("mio_maps_geo", {"address": "杭州"}, Context()))
        self.assert_fault("invalid_arguments", lambda: adapter.call("mio_flyai_search_hotel", {
            "dest_name": "synthetic", "check_in_date": 123, "check_out_date": "2026-10-01"}, Context()))



class BusinessGuardProviderTests(unittest.TestCase):
    """Pure production adapter/contract checks; no HTTP server or inference."""
    def test_complete_answer_keeps_tail_within_existing_http_budget(self):
        from arl.contracts import encode
        for answer in ['A' * 32996 + 'END!', '中' * 16000 + 'A' * 17000 + 'END!']:
            self.assertLessEqual(len(encode({'response': answer, 'eval_count': 32})), 65536)
            def wire(url, body=None, timeout=1):
                return {'models': [{'name': 'fixture'}]} if url.endswith('/tags') else {'response': answer, 'eval_count': 32}
            with patch('arl.providers.local_json', side_effect=wire):
                result = OllamaProvider().complete({'model': 'fixture', 'prompt': 'synthetic', 'max_tokens': 32}, Context())
            self.assertEqual(result['text'], answer)

    def test_explicit_101st_model_is_not_confused_with_display_preview(self):
        names = [{'name': 'fixture-' + str(i)} for i in range(101)]
        calls = []
        def wire(url, body=None, timeout=1):
            calls.append(url.rsplit('/', 1)[-1])
            return {'models': names} if url.endswith('/tags') else {'response': 'complete', 'eval_count': 1}
        with patch('arl.providers.local_json', side_effect=wire):
            provider = OllamaProvider()
            self.assertEqual(len(provider.discover()['models']), 100)  # Existing UI metadata bound.
            result = provider.complete({'model': 'fixture-100', 'prompt': 'synthetic', 'max_tokens': 8}, Context())
            self.assertEqual(result['text'], 'complete')
            with self.assertRaises(Fault) as caught:
                provider.complete({'model': 'absent', 'prompt': 'synthetic', 'max_tokens': 8}, Context())
            self.assertEqual(caught.exception.code, 'model_not_installed')
        self.assertEqual(calls, ['tags', 'tags', 'generate', 'tags'])  # No download/fallback.

    def test_existing_http_and_authorization_budgets_still_reject(self):
        from io import BytesIO
        from arl.providers import _blocking_local_json
        class Opener:
            def open(self, *args, **kwargs): return BytesIO(b' ' * 65537)
        with patch('arl.providers.urllib.request.build_opener', return_value=Opener()):
            with self.assertRaises(Fault) as caught: _blocking_local_json('http://127.0.0.1:11434/api/tags')
        self.assertEqual(caught.exception.code, 'provider_response_too_large')
        args = {'provider': 'ollama', 'model': 'fixture-100', 'prompt': 'synthetic', 'max_tokens': 8}
        with self.assertRaises(Fault) as caught: Router(default_policies()).check('tisra', args)
        self.assertEqual(caught.exception.code, 'provider_not_authorized')

    def test_large_history_is_explicitly_outside_unchanged_contract(self):
        from arl import codex_sourced_contract as contract
        from arl.contracts import encode
        request = {'schema_version': 2, 'text': 'Follow up?', 'public_history': [], 'evidence': [], 'migration': None}
        answer = {'text': 'A' * 9000, 'citations': []}
        contract.structured_body(encode(answer), request)
        row = {'run_id': '00000000-0000-4000-8000-000000000001', 'request_sha256': contract.sha(encode(request)),
               'output_sha256': contract.output_digest(answer), 'question': 'Previous', 'answer': answer['text'], 'citations': []}
        request['public_history'] = [row]
        original = encode(request)
        with self.assertRaises(Fault) as caught: contract.request_body(original)
        self.assertEqual(caught.exception.code, 'codex_input_too_large')
        self.assertEqual(encode(request), original)  # No automatic history edit or retry.
