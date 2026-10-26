"""Deterministic dry-run planner. Every step is explanatory and unperformed."""
from __future__ import annotations

from ..contracts import Fault, encode
from .models import (Backend, Configuration, DeploymentPlan, Issue, Manifest,
                     PlanStep, ServicePlan, TargetInventory)
from .validation import MAX_SERVICES

MAX_PLAN_BYTES = 120000
MAX_ISSUES = 512


def build_plan(root_service_id: str, manifests: tuple[Manifest, ...],
               configurations: tuple[Configuration, ...], *,
               inventory: TargetInventory | None = None) -> DeploymentPlan:
    """Host/library API, not an execution method or caller enrollment route.

    Arguments must come from the strict parsers. Inventory is only a declared
    resource snapshot; even a host inventory never supplies execution authority.
    No registry method, probe, path existence check, resolver or clock is called.
    """
    if (type(manifests) is not tuple or type(configurations) is not tuple or
            len(manifests) > MAX_SERVICES or len(configurations) > MAX_SERVICES or
            any(type(m) is not Manifest for m in manifests) or
            any(type(c) is not Configuration for c in configurations) or
            len({m.service_id for m in manifests}) != len(manifests) or
            len({c.service_id for c in configurations}) != len(configurations)):
        raise Fault("invalid_service_catalog")
    from .validation import parse_configuration, parse_manifest, strict_json, validate_inventory
    for manifest in manifests:
        if parse_manifest(strict_json(encode(manifest.wire()))) != manifest:
            raise Fault("invalid_service_catalog")
    catalog = {m.service_id: m for m in manifests}
    configs = {c.service_id: c for c in configurations}
    if root_service_id not in catalog:
        raise Fault("unknown_service")
    if set(configs) - set(catalog):
        raise Fault("unknown_configuration_service")
    for config in configurations:
        if parse_configuration(strict_json(encode(config.wire())), catalog[config.service_id]) != config:
            raise Fault("invalid_service_catalog")
    if inventory is not None:
        validate_inventory(inventory)
    issues, order, visited, visiting = [], [], set(), set()

    def issue(code, service, field, severity="blocking"):
        record = Issue(code, severity, service, field)
        if record not in issues:
            issues.append(record)

    def visit(service):
        if service in visiting:
            issue("dependency_cycle", service, "dependencies")
            return
        if service in visited:
            return
        visiting.add(service)
        for dep in catalog[service].dependencies:
            if dep.service_id not in catalog:
                issue("dependency_missing" if dep.required else "optional_dependency_absent",
                      service, "dependencies." + dep.service_id, "blocking" if dep.required else "notice")
                continue
            if not dep.required and dep.service_id not in configs:
                issue("optional_dependency_not_selected", service, "dependencies." + dep.service_id, "notice")
                continue
            if catalog[dep.service_id].version != dep.version:
                issue("dependency_version_mismatch", service, "dependencies." + dep.service_id)
            visit(dep.service_id)
        visiting.remove(service)
        visited.add(service)
        order.append(service)

    visit(root_service_id)
    selected_ports, deployment_ids, services, steps = {}, set(), [], []
    for service in order:
        manifest, config = catalog[service], configs.get(service)
        if config is None:
            issue("configuration_missing", service, "configuration")
            continue
        identity = (config.target_id, config.deployment_id)
        if identity in deployment_ids:
            issue("deployment_id_conflict", service, "deployment_id")
        deployment_ids.add(identity)
        runtime = next(r for r in manifest.runtimes if r.backend == config.backend)
        if inventory is None or inventory.target_id != config.target_id:
            issue("target_inventory_unavailable", service, "target_id", "notice")
        elif config.backend not in inventory.supported_backends:
            issue("target_backend_unsupported", service, "backend")
        by_port, port_strings = {p.name: p for p in manifest.ports}, []
        for port in config.port_bindings:
            p = by_port[port.name]
            identity = (config.target_id, p.protocol, port.host_port)
            if identity in selected_ports:
                issue("port_conflict", service, "port_bindings." + port.name)
                issue("port_conflict", selected_ports[identity], "port_bindings")
            selected_ports[identity] = service
            if inventory is not None and inventory.target_id == config.target_id and any(
                    reserved.protocol == p.protocol and reserved.port == port.host_port
                    for reserved in inventory.occupied_ports):
                issue("port_occupied_in_snapshot", service, "port_bindings." + port.name)
            port_strings.append(f"{port.name}: target loopback {port.host_port}/{p.protocol} → service {p.service_port}")
        bound_ports = {p.name for p in config.port_bindings}
        for p in manifest.ports:
            if p.required and p.name not in bound_ports:
                issue("required_port_missing", service, "port_bindings." + p.name)
        for ep in (manifest.portal, manifest.health.endpoint):
            if ep.port not in bound_ports:
                issue("endpoint_port_missing", service, "port_bindings." + ep.port)
        by_mount, mount_strings = {m.name: m for m in manifest.mounts}, []
        for binding in config.mount_bindings:
            m = by_mount[binding.name]
            mount_strings.append(f"{binding.name}: {binding.source} → {m.destination} ({m.access}, {m.kind})")
            if m.access == "rw":
                issue("mount_write_review_required", service, "mount_bindings." + binding.name, "notice")
        bound_mounts = {m.name for m in config.mount_bindings}
        for m in manifest.mounts:
            if m.required and m.name not in bound_mounts:
                issue("required_mount_missing", service, "mount_bindings." + m.name)
        keys, credentials = dict(config.parameters), dict(config.credential_refs)
        for p in manifest.parameters:
            if p.required and p.key not in keys:
                issue("required_parameter_missing", service, "parameters." + p.key)
        for c in manifest.credential_requirements:
            if c.required and c.key not in credentials:
                issue("required_credential_reference_missing", service, "credential_refs." + c.key)
            if c.key in credentials:
                # Opaque reference presence is never resolution or permission evidence.
                issue("credential_resolution_not_performed", service, "credential_refs." + c.key, "notice")
        if config.backend == Backend.MAC_NATIVE and config.mount_bindings:
            issue("native_mount_application_not_defined", service, "mount_bindings")
        if config.backend == Backend.NAS_DOCKER:
            issue("nas_transport_not_configured", service, "target_id", "notice")

        def describe_endpoint(ep):
            binding = next((p for p in config.port_bindings if p.name == ep.port), None)
            host_port = str(binding.host_port) if binding else "unbound"
            # Target loopback is not a URL to the Mac displaying the portal.
            return f"{config.target_id} · {ep.scheme} · target loopback:{host_port}{ep.path}"

        asset = runtime.image if runtime.image is not None else f"{runtime.artifact_url} · sha256:{runtime.artifact_sha256} · {runtime.bundle_id}"
        health = (f"{describe_endpoint(manifest.health.endpoint)} · HTTP {manifest.health.expected_status} · "
                  f"timeout {manifest.health.timeout_ms} ms · interval {manifest.health.interval_ms} ms · "
                  f"stale after {manifest.health.stale_after_ms} ms")
        services.append(ServicePlan(service, manifest.name, config.backend.value, config.target_id, config.deployment_id,
                        manifest.digest, config.digest, asset, manifest.descriptor, tuple(port_strings), tuple(mount_strings),
                        tuple(sorted(keys)), tuple(f"{c.key}: {c.purpose}" for c in manifest.credential_requirements),
                        describe_endpoint(manifest.portal), health))
        details = (
            ("review_source", "Review the pinned repository revision, declared license and artifact provenance."),
            ("verify_target", "Verify the selected target runtime and current resource availability."),
            ("verify_dependencies", "Require current registered/healthy evidence for declared dependencies in dependency order."),
            ("review_ports", "Review loopback bindings and repeat the target port check before any future apply."),
            ("review_mounts", "Review source type, ownership and access; no paths are inspected or created by this plan."),
            ("review_configuration", "Review typed parameters; resolve opaque credential refs only through the owning authorized host."),
            ("stage_asset", "A future approved executor would verify the exact artifact before staging it."),
            ("start_service", "A future approved executor would start the reviewed deployment generation."),
            ("observe_health", "Require a target-bound health observation; this plan performs no probe."),
            ("register_portal", "The trusted host may register the existing AppDescriptor only after separately verified deployment evidence."),
        )
        steps.extend(PlanStep(service, kind, detail) for kind, detail in details)
    result = DeploymentPlan(root_service_id, tuple(services), tuple(order), tuple(issues), tuple(steps),
                            inventory.source.value if inventory is not None else "none")
    if len(result.issues) > MAX_ISSUES or len(encode(result.wire())) > MAX_PLAN_BYTES:
        raise Fault("service_plan_too_large")
    return result
