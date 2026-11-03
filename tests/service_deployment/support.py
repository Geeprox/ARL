from copy import deepcopy
from pathlib import Path
import json

from arl.contracts import AppPolicy
from arl.control import AppRegistry
from arl.app_connections import AppConnections
from arl.diagnostics import Diagnostics
from arl.service_deployment import (DeploymentObservation, EvidenceSource, HealthObservation,
                                    RegistrationBinding, parse_configuration, parse_manifest)

NOW = 1000000


def fixture(name="docker-catalog.json"):
    return json.loads((Path(__file__).with_name("fixtures") / name).read_text())


def single(name="docker-catalog.json", index=1):
    data = fixture(name)
    if len(data["manifests"]) == 1:
        index = 0
    manifest = parse_manifest(data["manifests"][index])
    config = parse_configuration(data["configurations"][index], manifest)
    return manifest, config


def evidence(manifest, config, *, source=EvidenceSource.HOST, installed=True, health_status=200,
             stamp=NOW, generation=1):
    # Synthetic test construction exercises the trusted injection branch. This is
    # not a real host observation, registration, or live acceptance receipt.
    binding = RegistrationBinding(manifest.service_id, config.deployment_id, config.target_id, config.backend,
                                  manifest.digest, config.digest, generation, source)
    port = next(p.host_port for p in config.port_bindings if p.name == manifest.health.endpoint.port)
    h = HealthObservation(manifest.health.endpoint.scheme, port, manifest.health.endpoint.path, health_status, stamp)
    observation = DeploymentObservation(binding, installed, h)
    policies = {manifest.service_id: AppPolicy(frozenset(), methods=frozenset(), max_calls=0)}
    registry = AppRegistry(policies, Diagnostics(policies, clock=lambda: stamp), clock=lambda: stamp)
    registry.register(manifest.descriptor)
    # A one-way verified observation no longer establishes a connected app.
    # Use the actual open/confirm state machine with a synthetic trusted peer;
    # this is test construction, not real host/transport acceptance.
    connections = AppConnections(registry)
    descriptor = manifest.descriptor
    peer_binding = ('synthetic-service-registration', lambda: True)
    opened = connections.dispatch(manifest.service_id, 'connection.open', {
        'client_nonce': 'a'*64, 'name': descriptor.name, 'icon_ref': descriptor.icon_ref,
        'version': descriptor.version, 'capabilities': list(descriptor.capabilities)},
        peer_binding, policies[manifest.service_id])
    connections.dispatch(manifest.service_id, 'connection.confirm',
        {k: opened[k] for k in ('session_id', 'challenge')}, peer_binding, policies[manifest.service_id])
    return binding, observation, tuple(deepcopy(registry.snapshot(policies))), registry
