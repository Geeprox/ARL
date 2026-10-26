import json

from arl.client import Client
from arl.contracts import AppPolicy
from arl.service import Runtime
from tests.test_runtime import RuntimeCase, running


class SettingsTests(RuntimeCase):
    def test_public_settings_metadata_with_strict_peer_verifier(self):
        with running(self.home, identity_verifier=lambda connection, app: "tisra" if app == "tisra" else None) as (_, tisra):
            job = tisra.submit("text.sha256", {"text": "synthetic-private-payload"}, "private-key")
            tisra.wait(job["id"])
            settings = Client(self.home, "settings")
            self.assertTrue(settings.rpc("health")["live"])
            self.assertTrue(settings.rpc("ready")["ready"])
            result = settings.rpc("overview")
            self.assertEqual(result["queue"]["counts"]["succeeded"], 1)
            self.assertEqual(result["protocol"], "arl/1")
            self.assertTrue(result["policy"]["identity_verifier_configured"])
            for secret in (job["id"], "private-key", "synthetic-private-payload", str(self.home)):
                self.assertNotIn(secret, json.dumps(result))
            calendar = next(t for t in result["capabilities"] if t["name"] == "apple.calendar.list")
            self.assertEqual(calendar["authorization_gate"], "permission_required")
            self.assertEqual(calendar["identity_gate"], "verified_peer_required")

    def test_unverified_settings_cannot_read_objects_or_mutate_even_without_verifier(self):
        with running(self.home) as (runtime, tisra):
            job = tisra.submit("runtime.ping", {}, "object")
            settings = Client(self.home, "settings")
            for method, params in [("get", {"id": job["id"]}), ("cancel", {"id": job["id"]}),
                    ("resume", {"id": job["id"]}), ("submit", {"tool": "runtime.ping", "args": {}, "key": "attack"}),
                    ("wake", {"target": "friday"}), ("poll_wakes", {}), ("stop", {}),
                    ("providers", {}), ("capabilities", {})]:
                self.assert_fault("method_not_authorized", lambda: settings.rpc(method, params))
            self.assertTrue(runtime.ready.is_set())
            self.assertFalse((self.home/"disabled").exists())
            self.assertEqual(sum(settings.rpc("overview")["queue"]["counts"].values()), 1)

    def test_public_metadata_exception_is_not_identity_or_role_escalation(self):
        with running(self.home, identity_verifier=lambda connection, app: "tisra" if app == "tisra" else None) as (runtime, _):
            self.assert_fault("app_identity_unverified", lambda: Client(self.home, "friday").rpc("health"))
            request = {"protocol": "arl/1", "app": "settings", "method": "overview", "params": {}}
            self.assert_fault("app_identity_unverified", lambda: runtime.dispatch(request, verified_app="friday"))
            request["params"] = {"owner": "tisra"}
            self.assert_fault("invalid_arguments", lambda: runtime.dispatch(request))
            request["params"] = {}; request["owner"] = "tisra"
            self.assert_fault("invalid_request", lambda: runtime.dispatch(request))
            self.assert_fault("method_not_authorized", lambda: Client(self.home, "tisra").rpc("overview"))

    def test_host_can_revoke_public_metadata_and_flag_cannot_exempt_writes(self):
        runtime = Runtime(self.home, identity_verifier=lambda c, a: None)
        request = {"protocol": "arl/1", "app": "settings", "method": "overview", "params": {}}
        runtime.policies["settings"] = AppPolicy(frozenset(), public_metadata=False, methods=frozenset({"overview"}))
        self.assert_fault("app_identity_unverified", lambda: runtime.dispatch(request))
        runtime.policies["settings"] = AppPolicy(frozenset(), public_metadata=True)
        request["method"] = "stop"
        self.assert_fault("app_identity_unverified", lambda: runtime.dispatch(request))
        runtime.policies["friday"] = AppPolicy(frozenset(), public_metadata=True)
        request.update(app="friday", method="health")
        self.assert_fault("app_identity_unverified", lambda: runtime.dispatch(request))

    def test_overview_before_ready_and_no_arbitrary_discovery_fields(self):
        class Discovery:
            name = "mock"; paid = False
            def discover(self):
                return {"name": "mock", "paid": False, "availability": "ready", "models": ["deterministic-v1", "/private/secret", "../../key", "https://secret"],
                        "reason": "sensitive exception", "key": "synthetic-secret", "path": str(self.home)}
        provider = Discovery(); provider.home = self.home
        runtime = Runtime(self.home, providers={"mock": provider})
        result = runtime.dispatch({"protocol": "arl/1", "app": "settings", "method": "overview", "params": {}})
        self.assertFalse(result["health"]["ready"])
        self.assertFalse(result["queue"]["available"])
        self.assertEqual(result["providers"][0]["models"], ["deterministic-v1"])
        self.assertNotIn("secret", json.dumps(result))
        self.assertNotIn(str(self.home), json.dumps(result))
        budgets = {b["app"]: b for b in result["budgets"]}
        self.assertEqual(budgets["settings"]["max_calls"], 0)
        self.assertFalse(result["policy"]["paid_inference_enabled"])
