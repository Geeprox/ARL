"""Independent narrow integration tests; all identities/evidence are synthetic."""
from dataclasses import replace
from contextlib import ExitStack
import io
import json
import os
from pathlib import Path
import tempfile
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from arl import PROTOCOL
from arl.contracts import Fault, encode
from arl.control import ControlPlane
from arl.app_connections import AppConnections
from arl.host import make_runtime, metadata_policies
from arl.service import Handler, Runtime
from arl.service_deployment.__main__ import main as dry_run_main
from arl.service_deployment.models import DeploymentObservation, EvidenceSource, HealthObservation, RegistrationBinding
from arl.service_deployment.portal import CATALOG_METHOD, REVIEW_METHOD, ServicePortal

FIXTURE = Path(__file__).resolve().parents[1] / "service_deployment/fixtures/docker-catalog.json"
NOW = 1_000_000


def catalog_value():
    return json.loads(FIXTURE.read_bytes())


def composition(value=None):
    portal = ServicePortal(encode(value if value is not None else catalog_value()))
    # Exercise the real Runtime dispatcher/ControlPlane without IO or Runtime.run.
    runtime = Runtime.__new__(Runtime)
    runtime.policies = portal.policies(metadata_policies())
    runtime.stopping = threading.Event()
    runtime.ready = threading.Event()
    runtime.identity_verifier = lambda connection, app: None
    runtime.local_enabled = False
    runtime.priority_authority = None
    runtime.execute_jobs = False
    runtime.router = SimpleNamespace(providers={})
    runtime.control = ControlPlane(runtime, clock=lambda: NOW)
    runtime.service_portal = portal
    runtime.app_connections = AppConnections(runtime.control.apps)
    portal.bind_runtime(runtime)
    return runtime, portal


def connected(runtime, identity):
    # Trusted synthetic session fixture; production method policies stay unchanged.
    descriptor=runtime.control.apps.entries[identity]['descriptor']
    binding=('synthetic-peer-'+identity,lambda:True)
    reply=runtime.app_connections.dispatch(identity,'connection.open',{'client_nonce':'a'*64,'name':descriptor.name,
        'icon_ref':descriptor.icon_ref,'version':descriptor.version,'capabilities':list(descriptor.capabilities)},binding,runtime.policies[identity])
    runtime.app_connections.dispatch(identity,'connection.confirm',{k:reply[k] for k in ('session_id','challenge')},binding,runtime.policies[identity])


def request(runtime, method=CATALOG_METHOD, params=None, app="settings", verified=None):
    return runtime.dispatch({"protocol": PROTOCOL, "app": app, "method": method,
                             "params": {} if params is None else params}, verified_app=verified)


def review(runtime, portal, identity="service.hub"):
    return request(runtime, REVIEW_METHOD, {"service_id": identity, "catalog_sha256": portal.catalog_sha256})


def observation(portal, identity, generation=1, source=EvidenceSource.HOST, installed=True):
    manifest = next(m for m in portal._manifests if m.service_id == identity)
    configuration = next(c for c in portal._configurations if c.service_id == identity)
    binding = RegistrationBinding(identity, configuration.deployment_id, configuration.target_id, configuration.backend,
                                  manifest.digest, configuration.digest, generation, source)
    port = next(p.host_port for p in configuration.port_bindings if p.name == manifest.health.endpoint.port)
    return DeploymentObservation(binding, installed, HealthObservation(manifest.health.endpoint.scheme, port,
                                  manifest.health.endpoint.path, manifest.health.expected_status, NOW), "not_checked")


class PortalHooks(unittest.TestCase):
    def test_read_dispatch_has_no_effects_and_no_false_registration(self):
        runtime, portal = composition()
        calls = []
        def deny(*args, **kwargs):
            calls.append("forbidden_effect")
            raise AssertionError("unexpected_effect")
        with ExitStack() as stack:
            for target in ("builtins.open", "pathlib.Path.open", "pathlib.Path.exists", "os.open", "os.system", "os.mkdir",
                           "os.makedirs", "os.fork", "subprocess.Popen", "subprocess.run", "socket.socket", "socket.create_connection",
                           "threading.Thread.start", "arl.control.AppRegistry.register", "arl.control.AppRegistry.observe_verified"):
                stack.enter_context(patch(target, side_effect=deny))
            index = request(runtime)
            result = review(runtime, portal)
        self.assertEqual(calls, [])
        self.assertEqual(len(index["entries"]), 2)
        self.assertEqual(result["plan"]["effects_performed"], [])
        self.assertEqual(result["plan"]["execution"], "not_performed")
        self.assertEqual(result["plan"]["registration"], "not_performed")
        self.assertFalse(result["plan"]["apply_available"])
        self.assertTrue(all(s["readiness"] == "not_checked" and s["registration"] == "unregistered" for s in result["statuses"]))

    def test_host_factory_forwards_attachment_into_existing_runtime(self):
        portal = ServicePortal()
        with patch("arl.host.Runtime", return_value="same_runtime") as factory:
            self.assertEqual(make_runtime(Path("/never-created"), service_portal=portal), "same_runtime")
            self.assertIs(factory.call_args.kwargs["service_portal"], portal)
            self.assertFalse(factory.call_args.kwargs["execute_jobs"])
        with self.assertRaises(Fault):
            make_runtime(Path("/never-created"), capture_attachment=object(), service_portal=portal)

    def test_real_host_constructor_attaches_one_existing_runtime_without_starting(self):
        portal = ServicePortal(encode(catalog_value()))
        with tempfile.TemporaryDirectory(prefix="sp-", dir="/private/tmp") as folder:
            with patch("socket.socket", side_effect=AssertionError("socket")), patch("subprocess.Popen", side_effect=AssertionError("process")), patch("threading.Thread.start", side_effect=AssertionError("thread")):
                runtime = make_runtime(Path(folder) / "home", service_portal=portal)
                self.assertIs(runtime.service_portal, portal)
                self.assertIs(portal._runtime.control.apps, runtime.control.apps)
                self.assertIsNone(runtime.server)
                self.assertIsNone(runtime.store)
                self.assertIsNone(runtime.worker)
                self.assertFalse(runtime.ready.is_set())
                self.assertEqual(request(runtime)["kind"], "service_portal_catalog")
                self.assertEqual(list((Path(folder) / "home").iterdir()), [])
                runtime.control.close()
                portal.close()

    def test_wire_rejects_duplicate_fields_and_diagnostics_redact_input(self):
        runtime, portal = composition()
        record = {"protocol": PROTOCOL, "app": "settings", "method": CATALOG_METHOD, "params": {"input": "secret-sentinel"}}
        for raw in (encode(record) + b"\n", b'{"params":{},' + encode(record)[1:] + b"\n"):
            chunks = [raw, b""]
            handler = Handler.__new__(Handler)
            handler.request = SimpleNamespace(settimeout=lambda _: None, recv=lambda _: chunks.pop(0))
            handler.server = SimpleNamespace(runtime=runtime)
            handler.wfile = io.BytesIO()
            with patch("arl.service.peer_uid", return_value=os.geteuid()), patch("socket.socket", side_effect=AssertionError("socket")):
                handler.handle()
            response = json.loads(handler.wfile.getvalue())
            self.assertFalse(response["ok"])
            self.assertNotIn(b"secret-sentinel", handler.wfile.getvalue())
        diagnostics = runtime.control.diagnostics.query({})
        self.assertNotIn(b"secret-sentinel", encode(diagnostics))
        self.assertEqual(response["error"]["code"], "duplicate_field")

    def test_only_settings_can_read_and_services_have_no_grants(self):
        runtime, portal = composition()
        for identity in ("service.hub", "service.indexer"):
            policy = runtime.policies[identity]
            self.assertEqual(policy.tools | policy.providers | policy.methods, frozenset())
            with self.assertRaises(Fault):
                request(runtime, app=identity, verified=identity)
        with self.assertRaises(Fault):
            request(runtime, app="mio")

    def test_rpc_rejects_catalog_paths_credentials_observations_and_apply(self):
        runtime, portal = composition()
        for extras in ({"input": "/tmp/catalog.json"}, {"shell": "touch marker"}, {"manifest": {}},
                       {"observation": {"source": "host_observation"}}, {"credential_refs": {"TOKEN": "sentinel"}}):
            with self.subTest(extras=tuple(extras)), self.assertRaises(Fault):
                request(runtime, CATALOG_METHOD, extras)
        for method in ("settings.service_portal.apply.v1", "settings.service_portal.register.v1", "service.install"):
            with self.assertRaises(Fault):
                request(runtime, method)

    def test_catalog_hash_pins_request_and_response_is_bounded(self):
        runtime, portal = composition()
        with self.assertRaises(Fault) as error:
            request(runtime, REVIEW_METHOD, {"service_id": "service.hub", "catalog_sha256": "0" * 64})
        self.assertEqual(error.exception.code, "service_catalog_changed")
        self.assertLessEqual(len(encode(review(runtime, portal))), 120000)
        with patch("arl.service_deployment.portal.MAX_RESPONSE_BYTES", 32), self.assertRaises(Fault) as error:
            review(runtime, portal)
        self.assertEqual(error.exception.code, "service_portal_response_too_large")

    def test_duplicate_large_invalid_paths_and_sensitive_config_fail_closed(self):
        invalid = []
        duplicate = b'{"schema_version":1,' + encode(catalog_value())[1:]
        with self.assertRaises(Fault):
            ServicePortal(duplicate)
        with self.assertRaises(Fault):
            ServicePortal(b" " * 65537)
        for path in ("relative", "/tmp/../private", "/tmp//data", "/tmp/./data"):
            value = catalog_value(); value["configurations"][0]["mount_bindings"][0]["source"] = path; invalid.append(value)
        value = catalog_value(); value["configurations"][0]["parameters"]["API_TOKEN"] = "secret-sentinel"; invalid.append(value)
        value = catalog_value(); value["inventory"]["source"] = "host_observation"; invalid.append(value)
        for value in invalid:
            with self.assertRaises(Fault) as error:
                ServicePortal(encode(value))
            self.assertNotIn("secret-sentinel", str(error.exception))

    def test_mount_shell_text_is_inert_and_never_resolved(self):
        value = catalog_value()
        value["configurations"][0]["mount_bindings"][0]["source"] = "/tmp/$(touch portal-marker)"
        runtime, portal = composition(value)
        with patch("os.system", side_effect=AssertionError("shell")), patch("subprocess.Popen", side_effect=AssertionError("process")), patch("pathlib.Path.exists", side_effect=AssertionError("probe")):
            result = review(runtime, portal)
        self.assertIn("$(touch portal-marker)", result["plan"]["services"][-1]["mounts"][0])

    def test_cli_stdin_redacts_refs_and_enum_values_without_running_shell(self):
        value = catalog_value()
        value["manifests"][0]["credential_requirements"] = [{"key": "API_TOKEN", "purpose": "service read", "required": True}]
        value["configurations"][0]["credential_refs"] = {"API_TOKEN": "opaqueRefSentinel"}
        value["manifests"][0]["parameters"][2]["choices"] = ["privateEnumSentinel"]
        value["configurations"][0]["parameters"]["DISPLAY_MODE"] = "privateEnumSentinel"
        output = io.BytesIO()
        with patch("sys.stdin", SimpleNamespace(buffer=io.BytesIO(encode(value)))), patch("sys.stdout", SimpleNamespace(buffer=output)), patch("builtins.open", side_effect=AssertionError("file")), patch("subprocess.Popen", side_effect=AssertionError("process")):
            result = dry_run_main(["--input", "-"])
        self.assertEqual(result, 0)
        self.assertNotIn(b"opaqueRefSentinel", output.getvalue())
        self.assertNotIn(b"privateEnumSentinel", output.getvalue())
        runtime, portal = composition(value)
        self.assertNotIn(b"opaqueRefSentinel", encode(review(runtime, portal)))
        self.assertNotIn(b"privateEnumSentinel", encode(review(runtime, portal)))

    def test_registration_is_separate_from_plan_and_verified_connection(self):
        runtime, portal = composition()
        portal.register_observed(observation(portal, "service.indexer"), active_guard=lambda: True)
        status = review(runtime, portal, "service.indexer")["statuses"][0]
        self.assertEqual(status["readiness"], "unverified")
        self.assertEqual(status["authorization"], "none")
        runtime.control.apps.observe_verified("service.indexer")
        self.assertEqual(review(runtime, portal, "service.indexer")["statuses"][0]["readiness"], "unverified")
        connected(runtime, "service.indexer")
        result = review(runtime, portal, "service.indexer")
        self.assertEqual(result["statuses"][0]["readiness"], "ready")
        self.assertEqual(result["plan"]["execution"], "not_performed")
        self.assertEqual(result["plan"]["registration"], "not_performed")
        self.assertEqual(result["registry"][0]["authorized_tools"], [])

    def test_generation_guard_and_health_expiry_clear_ready(self):
        runtime, portal = composition()
        active = {"value": True}
        portal.register_observed(observation(portal, "service.indexer"), active_guard=lambda: active["value"])
        connected(runtime, "service.indexer")
        self.assertEqual(review(runtime, portal, "service.indexer")["statuses"][0]["readiness"], "ready")
        current = observation(portal, "service.indexer")
        portal.observe(replace(current, health=replace(current.health, checked_at_ms=NOW - 90001)))
        self.assertEqual(review(runtime, portal, "service.indexer")["statuses"][0]["readiness"], "stale")
        active["value"] = False
        self.assertEqual(review(runtime, portal, "service.indexer")["statuses"][0]["readiness"], "revoked")
        with self.assertRaises(Fault):
            portal.register_observed(current, active_guard=lambda: True)

    def test_mismatch_synthetic_and_uninstalled_cannot_register(self):
        runtime, portal = composition()
        current = observation(portal, "service.indexer")
        for bad in (replace(current, binding=replace(current.binding, target_id="different-target")),
                    observation(portal, "service.indexer", source=EvidenceSource.SYNTHETIC),
                    observation(portal, "service.indexer", installed=False), {"source": "host_observation"}):
            with self.assertRaises(Fault):
                portal.register_observed(bad, active_guard=lambda: True)
        self.assertEqual(review(runtime, portal, "service.indexer")["statuses"][0]["registration"], "unregistered")

    def test_dependency_recomputed_from_same_registry_snapshot(self):
        runtime, portal = composition()
        for identity in ("service.indexer", "service.hub"):
            portal.register_observed(observation(portal, identity), active_guard=lambda: True)
            connected(runtime, identity)
        self.assertEqual(review(runtime, portal)["statuses"][-1]["readiness"], "ready")
        runtime.control.apps.revoke("service.indexer")
        self.assertEqual(review(runtime, portal)["statuses"][-1]["readiness"], "dependency_not_ready")

    def test_empty_catalog_close_and_namespace_collision_are_explicit(self):
        portal = ServicePortal()
        runtime = SimpleNamespace(control=SimpleNamespace(apps=SimpleNamespace(entries={})), stopping=threading.Event())
        portal.bind_runtime(runtime)
        self.assertEqual(portal.dispatch(CATALOG_METHOD, {})["entries"], [])
        portal.close()
        with self.assertRaises(Fault):
            portal.dispatch(CATALOG_METHOD, {})
        _, populated = composition()
        policies = metadata_policies(); policies["service.hub"] = policies["mio"]
        with self.assertRaises(Fault):
            populated.policies(policies)


if __name__ == "__main__":
    unittest.main()
