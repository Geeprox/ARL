"""Paired adapter for the scoped NAS manager; factory adoption is source-only."""
from __future__ import annotations

import re
from dataclasses import asdict, dataclass

from homeplane.nas_connection import NASConnectionConfig, NASConnectionError, NASConnectionManager, NASCredentials
from homeplane.nas_connection.contracts import MAX_PAGE, MAX_RANGE, relative_path
from homeplane.nas_connection.transport import WorkerTransport

from .broker import CredentialBroker, _Ticket
from .contracts import Admission, CredentialFault, CurrentSource, Failure, NASReadScope

_TO_NAS = {Failure.TRANSPORT_TIMEOUT: "nas_timeout", Failure.TRANSPORT_FAILED: "nas_transport_failed",
           Failure.ACCESS_DENIED: "nas_access_denied", Failure.HOST_KEY_MISMATCH: "nas_host_key_mismatch",
           Failure.BUSY: "nas_busy"}
_FROM_NAS = {"nas_timeout": Failure.TRANSPORT_TIMEOUT, "nas_transport_failed": Failure.TRANSPORT_FAILED,
             "nas_auth_failed": Failure.AUTH_FAILED, "nas_access_denied": Failure.ACCESS_DENIED,
             "nas_host_key_mismatch": Failure.HOST_KEY_MISMATCH,
             "nas_dependency_missing": Failure.UNSUPPORTED}
_OPERATIONS = {"health", "list", "stat", "read"}


@dataclass(frozen=True, repr=False)
class _OpaqueNASCredentials(NASCredentials):
    # The background coroutine retains this secret-free ticket, not a pair.
    ticket: _Ticket

    def __repr__(self):
        return "<OpaqueNASCredentials secret_free>"

    def payload(self):
        # Resolver cannot be installed alone with the ordinary WorkerTransport.
        raise NASConnectionError("nas_auth_failed")


def _nas_fault(fault):
    return NASConnectionError(_TO_NAS.get(fault.code, "nas_auth_failed"))


def _valid_payload(operation, payload):
    if type(payload) is not dict or operation not in _OPERATIONS:
        return False
    try:
        if operation == "health":
            return payload == {}
        relative_path(payload["path"], allow_root=operation == "list")
        if operation == "stat":
            return set(payload) == {"path"}
        if operation == "list":
            return (set(payload) == {"path", "cursor", "limit"}
                    and (payload["cursor"] is None or (type(payload["cursor"]) is str and len(payload["cursor"]) <= 4096))
                    and type(payload["limit"]) is int and 1 <= payload["limit"] <= MAX_PAGE)
        return (set(payload) == {"path", "revision", "offset", "length"}
                and isinstance(payload["revision"], str) and re.fullmatch(r"[0-9a-f]{64}", payload["revision"]) is not None
                and type(payload["offset"]) is int and 0 <= payload["offset"] <= 2**63 - 1
                and type(payload["length"]) is int and 1 <= payload["length"] <= MAX_RANGE)
    except (KeyError, TypeError, NASConnectionError):
        return False


class ScopedTransport:
    def __init__(self, broker: CredentialBroker, transport_factory):
        self._broker, self._factory = broker, transport_factory
        self._transport = None
        self._closed = False

    async def connect(self, config, credentials):
        fault, result = None, None
        try:
            if (self._closed or self._transport is not None or not isinstance(config, NASConnectionConfig)
                    or not config.enabled or type(credentials) is not _OpaqueNASCredentials
                    or NASReadScope.from_config(config, self._broker.scope.config_generation,
                                               self._broker.scope.credential_generation) != self._broker.scope):
                self._broker._reject(Failure.SOURCE_CHANGED)

            async def consume(lease):
                transport_fault, record, pair = None, None, None
                try:
                    # No library/worker is constructed until lease and admission.
                    self._transport = self._factory()
                    await self._broker.check("connect_effect")
                    self._broker._check_private_lease(lease)
                    username, password = lease._pair()
                    pair = NASCredentials(username, password)
                    username = password = None
                    # Preparing immutable library values must not bypass the
                    # shorter private lease, cancellation or exact scope.
                    self._broker._check_private_lease(lease)
                    record = await self._transport.connect(config, pair)
                except CredentialFault as exc:
                    transport_fault = exc.code
                except NASConnectionError as exc:
                    transport_fault = _FROM_NAS.get(exc.code, Failure.TRANSPORT_FAILED)
                except TimeoutError:
                    transport_fault = Failure.TRANSPORT_TIMEOUT
                except Exception:
                    transport_fault = Failure.TRANSPORT_FAILED
                finally:
                    username = password = pair = None
                    lease.clear()
                if transport_fault:
                    raise CredentialFault(transport_fault)
                # A transport reply is not a generic provider result or secret DTO.
                if (type(record) is not dict or set(record) != {"reachable", "authenticated", "readable"}
                        or any(value is not True for value in record.values())):
                    raise CredentialFault(Failure.TRANSPORT_FAILED)
                return {"reachable": True, "authenticated": True, "readable": True}

            result = await self._broker.use(credentials.ticket, consume)
        except CredentialFault as exc:
            fault = exc.code
        if fault:
            await self.close()
            raise _nas_fault(CredentialFault(fault))
        return result

    async def request(self, operation, payload):
        if not _valid_payload(operation, payload):
            raise NASConnectionError("nas_invalid_request")
        fault, result, nas_code = None, None, None
        try:
            await self._broker.check("request")
            if self._transport is None or self._closed:
                raise CredentialFault(Failure.TRANSPORT_FAILED)
            self._broker._check_current()
            try:
                result = await self._transport.request(operation, payload)
            except NASConnectionError as exc:
                nas_code = exc.code
            except TimeoutError:
                nas_code = "nas_timeout"
            except Exception:
                nas_code = "nas_transport_failed"
            # Even an error reply is withheld if authority changed in flight.
            await self._broker.check("request_reply")
            if nas_code in {"nas_auth_failed", "nas_access_denied", "nas_host_key_mismatch", "nas_dependency_missing"}:
                self._broker._reject(_FROM_NAS[nas_code])
            if nas_code:
                raise NASConnectionError(nas_code)
            if type(result) is not dict:
                raise NASConnectionError("nas_transport_failed")
            self._broker._check_current()
        except CredentialFault as exc:
            fault = exc.code
        if fault:
            await self.close()
            raise _nas_fault(CredentialFault(fault))
        return result

    async def close(self):
        self._closed = True
        transport, self._transport = self._transport, None
        if transport is not None:
            try:
                await transport.close()
            except Exception:
                pass  # Teardown cannot publish a transport's exception text.


@dataclass(frozen=True)
class ScopedNASConnection:
    manager: NASConnectionManager
    credentials: CredentialBroker

    def bounded_inventory(self, *, bounds=None, directory_ref=None):
        """One bounded metadata operation on this already admitted connection."""
        from .inventory import BoundedInventory, InventoryBounds
        return BoundedInventory(self, scope=self.credentials.scope,
                                bounds=bounds if bounds is not None else InventoryBounds(),
                                directory_ref=directory_ref)

    def snapshot(self):
        return {"schema_version": 1, "service": self.credentials.scope.service,
                "scope": asdict(self.credentials.scope),
                "credential_reference_saved": bool(self.manager.config and
                    self.manager.config.credential_ref == self.credentials.scope.credential_ref),
                "credential": asdict(self.credentials.snapshot()),
                "connection": self.manager.status().model_dump(mode="json"),
                "writable": {"state": "unsupported", "checked_at": None},
                "steward_content_grant": "not_provided"}


def make_scoped_nas_manager(state_path, *, scope, caller, admission=Admission(), authorizer=None,
                            provider=None, transport_factory=WorkerTransport, current_credential_generation=None,
                            connect_coordinator_seconds=None):
    """Trusted host composition only. Never call from a raw model/UI decoder.

    Pair both seams using create_app(nas_manager=connection.manager). A current
    native credential-generation hook is required; no constant production pin.
    """
    holder = {}

    def current_source():
        manager = holder.get("manager")
        if manager is None or manager.config is None or current_credential_generation is None:
            return None
        generation = current_credential_generation()
        return CurrentSource(NASReadScope.from_config(manager.config, manager.generation, generation),
                             manager.config.enabled)

    broker = CredentialBroker(scope=scope, caller=caller, admission=admission, authorizer=authorizer,
                              provider=provider, current_source=current_source)

    async def resolver(reference):
        fault, ticket = None, None
        try:
            ticket = await broker.reserve(reference)
        except CredentialFault as exc:
            fault = exc.code
        if fault:
            raise _nas_fault(CredentialFault(fault))
        return _OpaqueNASCredentials("", "", ticket)

    manager = NASConnectionManager(state_path, credential_resolver=resolver,
                                   transport_factory=lambda: ScopedTransport(broker, transport_factory),
                                   connect_coordinator_seconds=connect_coordinator_seconds)
    holder["manager"] = manager
    return ScopedNASConnection(manager, broker)
