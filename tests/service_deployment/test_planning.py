from copy import deepcopy
from dataclasses import replace
import unittest

from arl.contracts import Fault, encode
from arl.service_deployment import build_plan, parse_configuration, parse_manifest, parse_inventory
from arl.service_deployment.__main__ import plan_catalog
from arl.service_deployment.models import PortBinding
from support import fixture, single


class PlanningTests(unittest.TestCase):
    def codes(self, plan):
        return {i.code for i in plan.issues}

    def test_fixture_plans_are_not_execution_registration_or_readiness(self):
        for name in ("docker-catalog.json", "mac-native-catalog.json", "nas-catalog.json"):
            plan = plan_catalog(fixture(name))
            wire = plan.wire()
            self.assertEqual(plan.state, "reviewable")
            self.assertEqual(wire["effects_performed"], [])
            self.assertFalse(wire["apply_available"])
            self.assertEqual(wire["execution"], "not_performed")
            self.assertEqual(wire["registration"], "not_performed")
            self.assertEqual(wire["readiness"], "not_checked")
            self.assertTrue(all(step.state == "not_performed" for step in plan.steps))

    def test_dependencies_sort_deterministically_and_pin_versions(self):
        data = fixture()
        plan = plan_catalog(data)
        self.assertEqual(plan.dependency_order, ("service.indexer", "service.hub"))
        data["manifests"].reverse(); data["configurations"].reverse()
        self.assertEqual(encode(plan.wire()), encode(plan_catalog(data).wire()))
        data["manifests"][1]["dependencies"][0]["version"] = "2.0.0"
        self.assertIn("dependency_version_mismatch", self.codes(plan_catalog(data)))

    def test_missing_required_and_optional_dependency(self):
        data = fixture(); data["manifests"].pop(); data["configurations"].pop()
        self.assertEqual(plan_catalog(data).state, "blocked")
        self.assertIn("dependency_missing", self.codes(plan_catalog(data)))
        data["manifests"][0]["dependencies"][0]["required"] = False
        self.assertEqual(plan_catalog(data).state, "reviewable")
        self.assertIn("optional_dependency_absent", self.codes(plan_catalog(data)))

    def test_transitive_cycle_is_blocked(self):
        data = fixture()
        data["manifests"][1]["dependencies"] = [{"service_id":"service.hub", "version":"1.0.0", "required":True}]
        plan = plan_catalog(data)
        self.assertEqual(plan.state, "blocked")
        self.assertIn("dependency_cycle", self.codes(plan))

    def test_missing_dependency_configuration_and_duplicate_catalog(self):
        data = fixture(); data["configurations"].pop()
        self.assertIn("configuration_missing", self.codes(plan_catalog(data)))
        data = fixture(); data["manifests"] += [deepcopy(data["manifests"][0])]
        with self.assertRaises(Fault):
            plan_catalog(data)
        data = fixture(); data["configurations"] += [deepcopy(data["configurations"][0])]
        with self.assertRaises(Fault):
            plan_catalog(data)

    def test_conflicts_on_same_target_and_protocol_only(self):
        data = fixture(); data["configurations"][1]["port_bindings"][0]["host_port"] = 48080
        self.assertIn("port_conflict", self.codes(plan_catalog(data)))
        data["configurations"][1]["target_id"] = "other-synthetic-target"
        self.assertNotIn("port_conflict", self.codes(plan_catalog(data)))
        data = fixture(); data["inventory"]["occupied_ports"] = [{"protocol":"tcp", "port":48080}]
        self.assertIn("port_occupied_in_snapshot", self.codes(plan_catalog(data)))
        data["inventory"]["occupied_ports"][0]["protocol"] = "udp"
        self.assertNotIn("port_occupied_in_snapshot", self.codes(plan_catalog(data)))

    def test_deployment_id_conflict_and_unsupported_runtime(self):
        data = fixture(); data["configurations"][1]["deployment_id"] = data["configurations"][0]["deployment_id"]
        self.assertIn("deployment_id_conflict", self.codes(plan_catalog(data)))
        data = fixture(); data["inventory"]["supported_backends"] = ["mac_native"]
        self.assertIn("target_backend_unsupported", self.codes(plan_catalog(data)))

    def test_partial_configuration_has_precise_blockers(self):
        data = fixture("nas-catalog.json")
        c = data["configurations"][0]
        c["port_bindings"] = []; c["mount_bindings"] = []; c["parameters"] = {}; c["credential_refs"] = {}
        plan = plan_catalog(data)
        self.assertEqual(plan.state, "blocked")
        self.assertTrue({"required_port_missing", "endpoint_port_missing", "required_mount_missing",
                         "required_parameter_missing", "required_credential_reference_missing"} <= self.codes(plan))

    def test_nas_credentials_mounts_health_are_descriptions(self):
        plan = plan_catalog(fixture("nas-catalog.json"))
        wire = encode(plan.wire()).decode()
        self.assertNotIn("synthetic-opaque-ref", wire)
        self.assertNotIn("http://127.0.0.1", wire)
        self.assertTrue({"nas_transport_not_configured", "credential_resolution_not_performed", "mount_write_review_required"} <= self.codes(plan))
        self.assertIn("timeout 1000 ms", plan.services[0].health)
        self.assertIn("synthetic-nas", plan.services[0].portal)

    def test_forged_dataclass_cannot_bypass_parsers(self):
        m, c = single()
        bad = replace(c, port_bindings=(PortBinding("web", True),))
        with self.assertRaises(Fault):
            build_plan(m.service_id, (m,), (bad,))
        bad = replace(m, version="1 0")
        with self.assertRaises(Fault):
            build_plan(m.service_id, (bad,), (c,))

    def test_unknown_inventory_is_notice_and_no_plan_success(self):
        data = fixture(); data["inventory"] = None
        plan = plan_catalog(data)
        self.assertEqual(plan.state, "reviewable")
        self.assertIn("target_inventory_unavailable", self.codes(plan))
        self.assertNotIn("succeeded", encode(plan.wire()).decode())
