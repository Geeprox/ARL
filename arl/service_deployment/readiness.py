"""Pure projection of independent host/registry evidence, never a health probe."""
from __future__ import annotations

from ..contracts import Fault, encode
from .models import (Configuration, DeploymentObservation, EvidenceSource, Manifest,
                     RegistrationBinding, ServiceStatus)
from .validation import integer, digest, ident, parse_configuration, parse_manifest, strict_json


def project_status(manifest: Manifest, configuration: Configuration, *,
                   registry_rows: tuple[dict, ...] = (),
                   registry_source: EvidenceSource = EvidenceSource.SYNTHETIC,
                   registration_binding: RegistrationBinding | None = None,
                   observation: DeploymentObservation | None = None,
                   dependency_statuses: tuple[ServiceStatus, ...] = (),
                   now_ms: int) -> ServiceStatus:
    """Consumes an already-captured existing AppRegistry snapshot.

    HOST arguments are exclusively trusted host injection, not manifest/config/RPC
    claims. The integration owner supplies the current generation/active_guard
    binding. The package has no registry writer, capture API or evidence importer.
    Synthetic observations can exercise all comparisons but can never yield ready.
    """
    integer(now_ms, "now_ms")
    if type(manifest) is not Manifest or type(configuration) is not Configuration:
        raise Fault("invalid_service_catalog")
    if (parse_manifest(strict_json(encode(manifest.wire()))) != manifest or
            parse_configuration(strict_json(encode(configuration.wire())), manifest) != configuration):
        raise Fault("invalid_service_catalog")
    if (type(registry_rows) is not tuple or len(registry_rows) > 100 or
            type(registry_source) is not EvidenceSource or
            any(type(row) is not dict for row in registry_rows) or
            type(dependency_statuses) is not tuple or len(dependency_statuses) > 32 or
            any(type(status) is not ServiceStatus for status in dependency_statuses) or
            len({s.service_id for s in dependency_statuses}) != len(dependency_statuses)):
        raise Fault("invalid_registry_evidence")
    rows = [r for r in registry_rows if r.get("id") == manifest.service_id]
    if len(rows) > 1:
        raise Fault("duplicate_registry_evidence")
    row = rows[0] if rows else None
    registration, connection, authentication, authorization = "unregistered", "never_seen", "unverified", "none"
    if row is not None:
        registration = _enum(row.get("registration"), {"unregistered", "registered", "revoked"})
        connection = _enum(row.get("connection"), {"never_seen", "connected", "stale", "disconnected"})
        authentication = _enum(row.get("authentication"), {"unverified", "verified", "stale"})
        authorization = _enum(row.get("authorization"), {"none", "limited"})
    deployment, readiness, source, health_checked, ready_until, generation = "not_observed", "not_checked", "none", None, None, None

    def result():
        return ServiceStatus(manifest.service_id, manifest.version, configuration.target_id, configuration.deployment_id,
                             manifest.digest, configuration.digest,
                             generation, registration, connection, authentication, authorization,
                             deployment, readiness, source, now_ms, health_checked, ready_until)

    if observation is None:
        return result()
    if type(observation) is not DeploymentObservation or type(observation.installed) is not bool:
        raise Fault("invalid_deployment_evidence")
    if type(observation.credential_resolution) is not str or observation.credential_resolution not in {"not_checked", "resolved", "unavailable"}:
        raise Fault("invalid_deployment_evidence")
    binding = observation.binding
    _validate_binding(binding)
    source = binding.source.value
    expected = (manifest.service_id, configuration.deployment_id, configuration.target_id, configuration.backend,
                manifest.digest, configuration.digest)
    if _identity(binding) != expected:
        readiness = "evidence_mismatch"
        return result()
    if binding.source is EvidenceSource.SYNTHETIC or registry_source is EvidenceSource.SYNTHETIC:
        deployment, readiness, source = "synthetic_only", "synthetic_only", "synthetic"
        return result()
    if registration_binding is None:
        readiness = "registration_binding_missing"
        return result()
    _validate_binding(registration_binding)
    if registration_binding.source is EvidenceSource.SYNTHETIC:
        deployment, readiness, source = "synthetic_only", "synthetic_only", "synthetic"
        return result()
    if binding != registration_binding:
        readiness = "evidence_mismatch"
        return result()
    generation = binding.generation
    deployment = "observed" if observation.installed else "not_deployed"
    if not observation.installed:
        readiness = "not_deployed"
        return result()
    if not _configuration_complete(manifest, configuration):
        readiness = "configuration_incomplete"
        return result()
    if configuration.credential_refs and observation.credential_resolution != "resolved":
        readiness = "credential_unavailable" if observation.credential_resolution == "unavailable" else "credential_not_checked"
        return result()
    if registration != "registered":
        readiness = "revoked" if registration == "revoked" else "not_registered"
        return result()
    descriptor = manifest.descriptor
    if (row.get("name") != descriptor.name or row.get("icon_ref") != descriptor.icon_ref or
            row.get("version") != descriptor.version or row.get("advertised_capabilities") != []):
        readiness = "registry_descriptor_mismatch"
        return result()
    if authentication != "verified" or connection != "connected":
        readiness = "stale" if "stale" in (authentication, connection) else "unverified"
        return result()
    stale_after = row.get("stale_after_ms")
    if type(stale_after) is not int or not 1 <= stale_after <= 30000:
        raise Fault("invalid_registry_evidence")
    for field in ("last_seen_at_ms", "last_verified_at_ms"):
        stamp = row.get(field)
        if type(stamp) is not int or not 0 <= stamp <= now_ms:
            readiness = "invalid_evidence_time"
            return result()
        if now_ms - stamp > stale_after:
            readiness = "stale"
            return result()
    health = observation.health
    if health is None:
        readiness = "not_checked"
        return result()
    from .models import HealthObservation
    if type(health) is not HealthObservation:
        raise Fault("invalid_health_evidence")
    integer(health.checked_at_ms, "health.checked_at_ms")
    integer(health.port, "health.port", 1, 65535)
    if health.status is not None:
        integer(health.status, "health.status", 100, 599)
    port = next((p for p in configuration.port_bindings if p.name == manifest.health.endpoint.port), None)
    ep = manifest.health.endpoint
    if (port is None or (health.scheme, health.port, health.path) != (ep.scheme, port.host_port, ep.path)):
        readiness = "health_endpoint_mismatch"
        return result()
    health_checked = health.checked_at_ms
    if health.checked_at_ms > now_ms:
        readiness = "invalid_evidence_time"
    elif now_ms - health.checked_at_ms > manifest.health.stale_after_ms:
        readiness = "stale"
    elif health.status != manifest.health.expected_status:
        readiness = "health_failed"
    else:
        ready_until = min(row["last_seen_at_ms"] + stale_after, row["last_verified_at_ms"] + stale_after,
                          health.checked_at_ms + manifest.health.stale_after_ms)
        by_dependency = {s.service_id: s for s in dependency_statuses}
        for dep in manifest.dependencies:
            if not dep.required:
                continue
            status = by_dependency.get(dep.service_id)
            if (status is None or status.version != dep.version or status.source != "host_observation" or
                    status.readiness != "ready" or type(status.ready_until_ms) is not int or
                    type(status.checked_at_ms) is not int or not 0 <= status.checked_at_ms <= now_ms <= status.ready_until_ms):
                readiness, ready_until = "dependency_not_ready", None
                return result()
            ready_until = min(ready_until, status.ready_until_ms)
        readiness = "ready"
    return result()


def _enum(value, allowed):
    if type(value) is not str or value not in allowed:
        raise Fault("invalid_registry_evidence")
    return value


def _validate_binding(binding):
    from .models import Backend
    if type(binding) is not RegistrationBinding or type(binding.source) is not EvidenceSource or type(binding.backend) is not Backend:
        raise Fault("invalid_deployment_evidence")
    ident(binding.service_id, "binding.service_id")
    ident(binding.deployment_id, "binding.deployment_id")
    ident(binding.target_id, "binding.target_id")
    digest(binding.manifest_sha256, "binding.manifest_sha256")
    digest(binding.configuration_sha256, "binding.configuration_sha256")
    integer(binding.generation, "binding.generation", 1)


def _identity(binding):
    return (binding.service_id, binding.deployment_id, binding.target_id, binding.backend,
            binding.manifest_sha256, binding.configuration_sha256)


def _configuration_complete(manifest, config):
    ports, mounts, parameters, credentials = ({p.name for p in config.port_bindings}, {m.name for m in config.mount_bindings},
                                             dict(config.parameters), dict(config.credential_refs))
    return (all(not p.required or p.name in ports for p in manifest.ports) and
            manifest.portal.port in ports and manifest.health.endpoint.port in ports and
            all(not m.required or m.name in mounts for m in manifest.mounts) and
            all(not p.required or p.key in parameters for p in manifest.parameters) and
            all(not c.required or c.key in credentials for c in manifest.credential_requirements) and
            not (config.backend.value == "mac_native" and config.mount_bindings))
