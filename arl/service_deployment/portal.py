"""Finite, read-only portal attachment to the existing ARL Runtime/ControlPlane.

Catalog bytes and observation objects are trusted host composition inputs, never
RPC arguments. Reads do not enroll, install, probe, resolve secrets or grant tools.
"""
from __future__ import annotations

from dataclasses import dataclass, replace
import hashlib
import threading

from ..contracts import AppPolicy, Fault, encode, object_schema, string, validate
from .models import DeploymentObservation, EvidenceSource
from .planning import build_plan
from .readiness import _validate_binding, project_status
from .validation import (MAX_SERVICES, arr, digest, integer, obj, parse_configuration,
                         parse_inventory, parse_manifest, service_id, strict_json)

CATALOG_METHOD = "settings.service_portal.catalog.v1"
REVIEW_METHOD = "settings.service_portal.review.v1"
METHODS = {
    CATALOG_METHOD: object_schema(),
    REVIEW_METHOD: object_schema({"service_id": string(64), "catalog_sha256": string(64)},
                                 ["service_id", "catalog_sha256"]),
}
MAX_RESPONSE_BYTES = 120000  # Existing ARLClient response frame is 131072 bytes.


@dataclass
class _RegistrationLease:
    observation: DeploymentObservation
    guard: object
    active: bool = True

    def is_active(self):
        # Called inside AppRegistry's lock. Never acquire the portal lock here.
        try:
            return self.active and self.guard() is True
        except Exception:
            return False


class ServicePortal:
    def __init__(self, catalog_bytes: bytes | None = None):
        self._runtime = None
        self._lock = threading.RLock()
        self._leases = {}
        self._generations = {}
        self._closed = False
        self._manifests, self._configurations, self._inventory = (), (), None
        if catalog_bytes is not None:
            if type(catalog_bytes) is not bytes:
                raise Fault("invalid_service_catalog")
            value = strict_json(catalog_bytes)
            obj(value, {"schema_version", "root_service_id", "manifests", "configurations", "inventory"}, "catalog")
            integer(value["schema_version"], "schema_version", 1, 1)
            root = service_id(value["root_service_id"], "root_service_id")
            self._manifests = tuple(parse_manifest(m) for m in arr(value["manifests"], "manifests", MAX_SERVICES))
            catalog = {m.service_id: m for m in self._manifests}
            configurations = []
            for c in arr(value["configurations"], "configurations", MAX_SERVICES):
                if type(c) is not dict or c.get("service_id") not in catalog:
                    raise Fault("unknown_configuration_service")
                configurations.append(parse_configuration(c, catalog[c["service_id"]]))
            self._configurations = tuple(configurations)
            self._inventory = parse_inventory(value["inventory"]) if value["inventory"] is not None else None
            build_plan(root, self._manifests, self._configurations, inventory=self._inventory)
        # A digest pins selection across catalog/review requests; values stay private.
        self.catalog_sha256 = hashlib.sha256(encode({
            "manifests": [m.wire() for m in sorted(self._manifests, key=lambda m: m.service_id)],
            "configurations": [c.wire() for c in sorted(self._configurations, key=lambda c: c.service_id)],
            "inventory": None if self._inventory is None else {
                "target_id": self._inventory.target_id,
                "supported_backends": [b.value for b in self._inventory.supported_backends],
                "occupied_ports": [{"protocol": p.protocol, "port": p.port} for p in self._inventory.occupied_ports],
                "source": self._inventory.source.value, "observed_at_ms": self._inventory.observed_at_ms},
        })).hexdigest()

    def policies(self, existing):
        """Extend the finite existing registry namespace; zero service tool grants."""
        result = dict(existing)
        # A disabled empty portal imposes no settings requirement on legacy hosts.
        if "settings" not in result and not self._manifests:
            return result
        if "settings" not in result or len(result) + len(self._manifests) > 100:
            raise Fault("invalid_service_portal_composition")
        result["settings"] = replace(result["settings"], methods=result["settings"].methods | frozenset(METHODS))
        for manifest in self._manifests:
            if manifest.service_id in result:
                raise Fault("service_registry_collision")
            result[manifest.service_id] = AppPolicy(frozenset(), frozenset(), 0, 0, 0, methods=frozenset())
        return result

    def bind_runtime(self, runtime):
        with self._lock:
            if self._runtime is not None or self._closed:
                raise Fault("service_portal_already_bound")
            if any(m.service_id not in runtime.control.apps.entries for m in self._manifests):
                raise Fault("invalid_service_portal_composition")
            self._runtime = runtime

    def _host(self):
        if self._runtime is None or self._closed:
            raise Fault("service_portal_unavailable")
        return self._runtime

    def dispatch(self, method, params):
        if method not in METHODS:
            raise Fault("unknown_method")
        validate(params, METHODS[method])
        with self._lock:
            runtime = self._host()
            if runtime.stopping.is_set():
                raise Fault("service_portal_unavailable")
            if method == CATALOG_METHOD:
                configurations = {c.service_id: c for c in self._configurations}
                result = {"schema_version": 1, "kind": "service_portal_catalog", "catalog_sha256": self.catalog_sha256,
                          "entries": [{"service_id": m.service_id, "name": m.name, "version": m.version,
                                       "configured": m.service_id in configurations}
                                      for m in sorted(self._manifests, key=lambda m: m.service_id)]}
            else:
                root = service_id(params["service_id"], "service_id")
                digest(params["catalog_sha256"], "catalog_sha256")
                if params["catalog_sha256"] != self.catalog_sha256:
                    raise Fault("service_catalog_changed")
                plan = build_plan(root, self._manifests, self._configurations, inventory=self._inventory)
                now = runtime.control.clock()
                # Capture the existing registry once. Never use caller registry JSON.
                all_rows = tuple(runtime.control.apps.snapshot(runtime.policies))
                by_manifest = {m.service_id: m for m in self._manifests}
                by_config = {c.service_id: c for c in self._configurations}
                statuses = []
                for identity in plan.dependency_order:
                    if identity not in by_config:
                        continue
                    lease = self._leases.get(identity)
                    observation = lease.observation if lease else None
                    statuses.append(project_status(by_manifest[identity], by_config[identity], registry_rows=all_rows,
                        registry_source=EvidenceSource.HOST, registration_binding=observation.binding if observation else None,
                        observation=observation, dependency_statuses=tuple(statuses), now_ms=now))
                selected = {entry.service_id for entry in plan.services}
                result = {"schema_version": 1, "kind": "service_portal_review", "catalog_sha256": self.catalog_sha256,
                          "checked_at_ms": now, "plan": plan.wire(), "statuses": [s.wire() for s in statuses],
                          "registry": [r for r in all_rows if r["id"] in selected]}
            if len(encode(result)) > MAX_RESPONSE_BYTES:
                raise Fault("service_portal_response_too_large")
            return result

    def register_observed(self, observation, *, active_guard):
        """Trusted host-only admission after separate deployment verification.

        Does not authenticate the service. Existing verified-peer evidence and a
        fresh exact-endpoint health observation are still required for ready.
        This function is deliberately absent from METHODS and caller schemas.
        """
        with self._lock:
            runtime = self._host()
            if (type(observation) is not DeploymentObservation or observation.installed is not True
                    or not callable(active_guard)):
                raise Fault("invalid_deployment_evidence")
            binding = observation.binding
            _validate_binding(binding)
            if binding.source is not EvidenceSource.HOST:
                raise Fault("synthetic_registration_forbidden")
            manifest = next((m for m in self._manifests if m.service_id == binding.service_id), None)
            configuration = next((c for c in self._configurations if c.service_id == binding.service_id), None)
            if manifest is None or configuration is None:
                raise Fault("unknown_service")
            expected = (manifest.service_id, configuration.deployment_id, configuration.target_id,
                        configuration.backend, manifest.digest, configuration.digest)
            actual = (binding.service_id, binding.deployment_id, binding.target_id, binding.backend,
                      binding.manifest_sha256, binding.configuration_sha256)
            if actual != expected or binding.generation <= self._generations.get(binding.service_id, 0):
                raise Fault("service_observation_mismatch")
            if observation.credential_resolution not in {"not_checked", "resolved", "unavailable"}:
                raise Fault("invalid_deployment_evidence")
            lease = _RegistrationLease(observation, active_guard)
            if not lease.is_active():
                raise Fault("service_generation_inactive")
            previous = self._leases.get(binding.service_id)
            if previous:
                previous.active = False
            runtime.control.apps.register(manifest.descriptor, active_guard=lease.is_active)
            self._leases[binding.service_id] = lease
            self._generations[binding.service_id] = binding.generation

    def observe(self, observation):
        """Replace evidence for an admitted generation; never enroll via a read."""
        with self._lock:
            self._host()
            if type(observation) is not DeploymentObservation:
                raise Fault("invalid_deployment_evidence")
            lease = self._leases.get(observation.binding.service_id)
            if lease is None or observation.binding != lease.observation.binding:
                raise Fault("service_observation_mismatch")
            lease.observation = observation

    def close(self):
        with self._lock:
            for lease in self._leases.values():
                lease.active = False
            self._closed = True
