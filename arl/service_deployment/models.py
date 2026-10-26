"""Immutable service planning contracts. No executor, registry or IO ownership."""
from __future__ import annotations

from dataclasses import asdict, dataclass
from enum import Enum
import hashlib

from ..contracts import encode
from ..control import AppDescriptor


class Backend(str, Enum):
    MAC_NATIVE = "mac_native"
    DOCKER = "docker"
    NAS_DOCKER = "nas_docker"


class EvidenceSource(str, Enum):
    HOST = "host_observation"
    SYNTHETIC = "synthetic"


@dataclass(frozen=True)
class RuntimeSpec:
    backend: Backend
    image: str | None = None
    artifact_url: str | None = None
    artifact_sha256: str | None = None
    bundle_id: str | None = None


@dataclass(frozen=True)
class Port:
    name: str
    service_port: int
    protocol: str
    required: bool


@dataclass(frozen=True)
class Mount:
    name: str
    destination: str
    access: str
    kind: str
    required: bool


@dataclass(frozen=True)
class Parameter:
    key: str
    kind: str
    required: bool
    choices: tuple[str, ...] = ()
    minimum: int | None = None
    maximum: int | None = None


@dataclass(frozen=True)
class CredentialRequirement:
    key: str
    purpose: str
    required: bool


@dataclass(frozen=True)
class Dependency:
    service_id: str
    version: str
    required: bool


@dataclass(frozen=True)
class EndpointSpec:
    scheme: str
    port: str
    path: str


@dataclass(frozen=True)
class HealthSpec:
    endpoint: EndpointSpec
    expected_status: int
    timeout_ms: int
    interval_ms: int
    stale_after_ms: int


@dataclass(frozen=True)
class Manifest:
    service_id: str
    name: str
    version: str
    icon_ref: str
    repository_url: str
    revision: str
    license_spdx: str
    runtimes: tuple[RuntimeSpec, ...]
    ports: tuple[Port, ...]
    mounts: tuple[Mount, ...]
    parameters: tuple[Parameter, ...]
    credential_requirements: tuple[CredentialRequirement, ...]
    dependencies: tuple[Dependency, ...]
    portal: EndpointSpec
    health: HealthSpec

    @property
    def descriptor(self) -> AppDescriptor:
        # Existing registry DTO; service planning never authenticates or grants.
        return AppDescriptor(self.service_id, self.name, self.icon_ref, self.version)

    def wire(self) -> dict:
        result = asdict(self)
        result["runtimes"] = [{"backend": r.backend.value,
                              **({"image": r.image} if r.image is not None else
                                 {"artifact_url": r.artifact_url, "artifact_sha256": r.artifact_sha256,
                                  "bundle_id": r.bundle_id})} for r in self.runtimes]
        result["parameters"] = [{"key": p.key, "kind": p.kind, "required": p.required,
                                **({"choices": list(p.choices)} if p.kind == "enum" else
                                   {"minimum": p.minimum, "maximum": p.maximum} if p.kind == "integer" else {})}
                               for p in self.parameters]
        return {"schema_version": 1, **result}

    @property
    def digest(self) -> str:
        return hashlib.sha256(encode(self.wire())).hexdigest()


@dataclass(frozen=True)
class PortBinding:
    name: str
    host_port: int
    exposure: str = "target_loopback"


@dataclass(frozen=True)
class MountBinding:
    name: str
    source: str


@dataclass(frozen=True)
class Configuration:
    service_id: str
    deployment_id: str
    target_id: str
    backend: Backend
    port_bindings: tuple[PortBinding, ...]
    mount_bindings: tuple[MountBinding, ...]
    parameters: tuple[tuple[str, object], ...]
    credential_refs: tuple[tuple[str, str], ...]

    def wire(self) -> dict:
        result = asdict(self)
        result["parameters"] = dict(self.parameters)
        result["credential_refs"] = dict(self.credential_refs)
        return {"schema_version": 1, **result}

    @property
    def digest(self) -> str:
        return hashlib.sha256(encode(self.wire())).hexdigest()


@dataclass(frozen=True)
class ReservedPort:
    protocol: str
    port: int


@dataclass(frozen=True)
class TargetInventory:
    target_id: str
    supported_backends: tuple[Backend, ...]
    occupied_ports: tuple[ReservedPort, ...]
    source: EvidenceSource
    observed_at_ms: int


@dataclass(frozen=True)
class Issue:
    code: str
    severity: str
    service_id: str
    field: str


@dataclass(frozen=True)
class PlanStep:
    service_id: str
    kind: str
    detail: str
    state: str = "not_performed"


@dataclass(frozen=True)
class ServicePlan:
    service_id: str
    name: str
    backend: str
    target_id: str
    deployment_id: str
    manifest_sha256: str
    configuration_sha256: str
    asset: str
    proposed_registration: AppDescriptor
    ports: tuple[str, ...]
    mounts: tuple[str, ...]
    configuration_keys: tuple[str, ...]
    credential_requirements: tuple[str, ...]
    portal: str
    health: str


@dataclass(frozen=True)
class DeploymentPlan:
    root_service_id: str
    services: tuple[ServicePlan, ...]
    dependency_order: tuple[str, ...]
    issues: tuple[Issue, ...]
    steps: tuple[PlanStep, ...]
    inventory_source: str

    @property
    def state(self) -> str:
        return "blocked" if any(i.severity == "blocking" for i in self.issues) else "reviewable"

    def wire(self) -> dict:
        # Constants cannot be supplied by config or promoted to execution success.
        return {"schema_version": 1, "kind": "service_deployment_plan",
                "state": self.state, "execution": "not_performed",
                "registration": "not_performed", "readiness": "not_checked",
                "apply_available": False, "effects_performed": [], **asdict(self)}


@dataclass(frozen=True)
class RegistrationBinding:
    """Host-owned binding to the current registry guard; never accepted over RPC.

    The integration owner must create this only for a reviewed deployment generation
    and revoke its existing AppRegistry active_guard when that generation changes.
    """
    service_id: str
    deployment_id: str
    target_id: str
    backend: Backend
    manifest_sha256: str
    configuration_sha256: str
    generation: int
    source: EvidenceSource


@dataclass(frozen=True)
class HealthObservation:
    scheme: str
    port: int
    path: str
    status: int | None
    checked_at_ms: int


@dataclass(frozen=True)
class DeploymentObservation:
    binding: RegistrationBinding
    installed: bool
    health: HealthObservation | None
    credential_resolution: str = "not_checked"


@dataclass(frozen=True)
class ServiceStatus:
    service_id: str
    version: str
    target_id: str
    deployment_id: str
    manifest_sha256: str
    configuration_sha256: str
    generation: int | None
    registration: str
    connection: str
    authentication: str
    authorization: str
    deployment: str
    readiness: str
    source: str
    checked_at_ms: int
    health_checked_at_ms: int | None
    ready_until_ms: int | None

    def wire(self) -> dict:
        return {"schema_version": 1, "kind": "service_deployment_status", **asdict(self)}
