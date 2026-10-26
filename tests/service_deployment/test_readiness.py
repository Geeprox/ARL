from copy import deepcopy
from dataclasses import replace
import unittest

from arl.contracts import Fault
from arl.service_deployment import EvidenceSource, project_status
from support import NOW, evidence, fixture, single


class ReadinessTests(unittest.TestCase):
    def setUp(self):
        self.manifest, self.config = single()
        self.binding, self.observation, self.rows, self.registry = evidence(self.manifest, self.config)

    def status(self, **overrides):
        kwargs = dict(registry_rows=self.rows, registry_source=EvidenceSource.HOST,
                      registration_binding=self.binding, observation=self.observation, now_ms=NOW)
        kwargs.update(overrides)
        return project_status(self.manifest, self.config, **kwargs)

    def test_plan_alone_and_registration_without_deployment_do_not_ready(self):
        state = self.status(observation=None)
        self.assertEqual(state.registration, "registered")
        self.assertEqual(state.deployment, "not_observed")
        self.assertEqual(state.readiness, "not_checked")
        self.assertIsNone(state.ready_until_ms)
        state = project_status(self.manifest, self.config, now_ms=NOW)
        self.assertEqual(state.registration, "unregistered")

    def test_synthetic_registry_binding_or_health_never_yields_ready(self):
        for kwargs in (dict(registry_source=EvidenceSource.SYNTHETIC),
                       dict(registration_binding=replace(self.binding, source=EvidenceSource.SYNTHETIC)),
                       dict(observation=replace(self.observation, binding=replace(self.binding, source=EvidenceSource.SYNTHETIC)))):
            with self.subTest(source=next(iter(kwargs))):
                state = self.status(**kwargs)
                self.assertEqual(state.readiness, "synthetic_only")
                self.assertIsNone(state.ready_until_ms)

    def test_all_independent_evidence_yields_only_narrow_health_ready(self):
        state = self.status()
        self.assertEqual(state.readiness, "ready")
        self.assertEqual(state.authorization, "none")
        self.assertEqual(state.ready_until_ms, NOW + 30000)
        self.assertNotIn("authorized_tools", state.wire())

    def test_registration_binding_and_exact_generation_required(self):
        self.assertEqual(self.status(registration_binding=None).readiness, "registration_binding_missing")
        self.assertEqual(self.status(registration_binding=replace(self.binding, generation=2)).readiness, "evidence_mismatch")
        for field, value in (("manifest_sha256", "f" * 64), ("configuration_sha256", "f" * 64),
                             ("target_id", "other-target"), ("deployment_id", "other-deployment")):
            bad = replace(self.binding, **{field: value})
            with self.subTest(field=field):
                self.assertEqual(self.status(observation=replace(self.observation, binding=bad)).readiness, "evidence_mismatch")

    def test_not_deployed_unregistered_revoked_and_unverified_are_distinct(self):
        self.assertEqual(self.status(observation=replace(self.observation, installed=False)).readiness, "not_deployed")
        self.assertEqual(self.status(registry_rows=()).readiness, "not_registered")
        for key, val, expected in (("registration", "revoked", "revoked"), ("authentication", "unverified", "unverified"),
                                   ("connection", "stale", "stale"), ("connection", "never_seen", "unverified")):
            rows = deepcopy(self.rows); rows[0][key] = val
            self.assertEqual(self.status(registry_rows=rows).readiness, expected)

    def test_descriptor_mismatch_fails_closed(self):
        for field, value in (("name", "unreviewed name"), ("icon_ref", "sf:other"), ("version", "2.0.0"),
                             ("advertised_capabilities", ["shell.execute"])):
            rows = deepcopy(self.rows); rows[0][field] = value
            self.assertEqual(self.status(registry_rows=rows).readiness, "registry_descriptor_mismatch")

    def test_registry_future_stale_missing_and_boolean_times(self):
        for field in ("last_seen_at_ms", "last_verified_at_ms"):
            for value, expected in ((NOW + 1, "invalid_evidence_time"), (NOW - 30001, "stale"),
                                     (None, "invalid_evidence_time"), (True, "invalid_evidence_time")):
                rows = deepcopy(self.rows); rows[0][field] = value
                self.assertEqual(self.status(registry_rows=rows).readiness, expected)

    def test_health_missing_failed_future_stale_and_wrong_endpoint(self):
        self.assertEqual(self.status(observation=replace(self.observation, health=None)).readiness, "not_checked")
        for field, value, expected in (("status", 503, "health_failed"), ("status", None, "health_failed"),
                                       ("checked_at_ms", NOW + 1, "invalid_evidence_time"),
                                       ("checked_at_ms", NOW - 90001, "stale"),
                                       ("port", 48082, "health_endpoint_mismatch"),
                                       ("path", "/other", "health_endpoint_mismatch"),
                                       ("scheme", "https", "health_endpoint_mismatch")):
            bad = replace(self.observation, health=replace(self.observation.health, **{field: value}))
            self.assertEqual(self.status(observation=bad).readiness, expected)

    def test_malformed_evidence_does_not_promote_to_unknown_success(self):
        for kwargs in (dict(registry_rows=self.rows + self.rows), dict(registry_source="host_observation"),
                       dict(observation=replace(self.observation, installed=1)),
                       dict(observation=replace(self.observation, health=replace(self.observation.health, checked_at_ms=True))),
                       dict(registration_binding=replace(self.binding, generation=True))):
            with self.assertRaises(Fault):
                self.status(**kwargs)

    def test_changed_config_and_incomplete_config_cannot_ready(self):
        config = replace(self.config, parameters=())
        binding, obs, rows, _ = evidence(self.manifest, config)
        state = project_status(self.manifest, config, registry_rows=rows, registry_source=EvidenceSource.HOST,
                               registration_binding=binding, observation=obs, now_ms=NOW)
        self.assertEqual(state.readiness, "configuration_incomplete")
        config = replace(self.config, deployment_id="changed-deployment")
        state = project_status(self.manifest, config, registry_rows=self.rows, registry_source=EvidenceSource.HOST,
                               registration_binding=self.binding, observation=self.observation, now_ms=NOW)
        self.assertEqual(state.readiness, "evidence_mismatch")

    def test_opaque_reference_does_not_resolve_credentials(self):
        m, c = single("nas-catalog.json")
        binding, obs, rows, _ = evidence(m, c)
        def status(value):
            return project_status(m, c, registry_rows=rows, registry_source=EvidenceSource.HOST,
                                  registration_binding=binding, observation=value, now_ms=NOW)
        self.assertEqual(status(obs).readiness, "credential_not_checked")
        self.assertEqual(status(replace(obs, credential_resolution="unavailable")).readiness, "credential_unavailable")
        self.assertEqual(status(replace(obs, credential_resolution="resolved")).readiness, "ready")

    def test_required_dependency_version_freshness_and_source_gates(self):
        m, c = single("docker-catalog.json", 0)
        binding, obs, rows, _ = evidence(m, c)
        def status(deps):
            return project_status(m, c, registry_rows=rows, registry_source=EvidenceSource.HOST,
                                  registration_binding=binding, observation=obs, dependency_statuses=deps, now_ms=NOW)
        self.assertEqual(status(()).readiness, "dependency_not_ready")
        child = self.status()
        self.assertEqual(status((child,)).readiness, "ready")
        for bad in (replace(child, version="2.0.0"), replace(child, source="synthetic"),
                    replace(child, ready_until_ms=NOW - 1), replace(child, checked_at_ms=NOW + 1),
                    replace(child, readiness="unverified")):
            self.assertEqual(status((bad,)).readiness, "dependency_not_ready")

    def test_revocation_uses_existing_registry_without_module_writer(self):
        policies = {self.manifest.service_id: type("Policy", (), {"tools": frozenset()})()}
        self.registry.revoke(self.manifest.service_id)
        rows = tuple(self.registry.snapshot(policies))
        self.assertEqual(self.status(registry_rows=rows).readiness, "revoked")
