"""ARL-owned private pipe host. No listener, shell, public credential API or UI grant."""
from __future__ import annotations

import asyncio
import base64
import json
import logging
import os
from pathlib import Path
import stat
import sys
import time
from dataclasses import asdict

# -I permits only the signed, staged resource root, never cwd/PYTHONPATH/user site.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from homeplane.nas_connection import NASConnectionConfig, NASConnectionError
from homeplane.nas_connection.worker import error_code
from homeplane.nas_connection.adapters import SMBReader
from homeplane.nas_connection.state import StateStore
from arl_nas_credential import Admission, CallerPins, CredentialFault, Failure, NASReadScope
from arl_nas_credential.broker import PrivateCredential
from arl_nas_credential.scope_bridge import make_scoped_nas_manager

MAX_INPUT = 2 * 1024 * 1024
MAX_OUTPUT = 2 * 1024 * 1024
STAGES = frozenset({"reserve", "lease", "connect", "connect_effect", "reply",
                    "provider_reply", "request", "request_reply", "inventory_metadata"})
ERRORS = frozenset(x.value for x in Failure) | frozenset({
    "nas_unavailable", "nas_invalid_request", "nas_auth_failed", "nas_access_denied",
    "nas_timeout", "nas_transport_failed", "nas_dependency_missing", "nas_source_changed",
    "nas_object_unknown", "nas_revision_changed", "nas_missing", "nas_budget_exceeded", "nas_cursor_expired", "nas_busy",
    "binding_changed", "invalid_reply", "cancelled", "expired"})

def strict(data):
    def pairs(values):
        result = {}
        for key, value in values:
            if key in result:
                raise ValueError("duplicate")
            result[key] = value
        return result
    return json.loads(data, object_pairs_hook=pairs,
                      parse_constant=lambda _: (_ for _ in ()).throw(ValueError("nonfinite")))

def public_error(error):
    value = getattr(error, "code", None)
    if isinstance(value, Failure):
        value = value.value
    return value if type(value) is str and value in ERRORS else "nas_transport_failed"


class PrivateWire:
    """One inherited anonymous-pipe pair; native owner revalidates every use."""
    def __init__(self, reader, writer, parent, *, kernel_check=True):
        self.reader, self.writer, self.parent = reader, writer, parent
        self.kernel_check = kernel_check
        self.sequence = 0
        self.nonce = None
        self.identities = [(os.fstat(n).st_dev, os.fstat(n).st_ino) for n in (0, 1)] if kernel_check else []

    def verify(self):
        if not self.kernel_check:
            return  # Constructor injection is used only by offline unit harnesses, never CLI input.
        if os.getppid() != self.parent or self.parent <= 1:
            raise CredentialFault(Failure.CALLER_UNVERIFIED)
        for n, identity in zip((0, 1), self.identities):
            row = os.fstat(n)
            if not stat.S_ISFIFO(row.st_mode) or (row.st_dev, row.st_ino) != identity or row.st_uid != os.getuid():
                raise CredentialFault(Failure.CALLER_UNVERIFIED)

    async def read(self):
        self.verify()
        data = await self.reader.readline()
        if not data or len(data) > MAX_INPUT or not data.endswith(b"\n"):
            raise EOFError()
        self.verify()
        result = strict(data)
        if type(result) is not dict:
            raise ValueError("frame")
        return result

    async def send(self, value):
        self.verify()
        data = json.dumps(value, separators=(",", ":"), allow_nan=False, ensure_ascii=False).encode() + b"\n"
        if len(data) > MAX_OUTPUT:
            raise CredentialFault(Failure.BUDGET_EXHAUSTED)
        self.writer.write(data)
        await self.writer.drain()

    async def authorize(self, stage, scope, caller, *, lease=False, upload_digest=None, consume=False):
        self.sequence += 1
        sequence = self.sequence
        frame = {"kind": "lease" if lease else "authorize", "sequence": sequence,
                 "nonce": self.nonce, "stage": stage, "scope": asdict(scope), "caller": asdict(caller)}
        if upload_digest is not None:
            if lease: raise CredentialFault(Failure.PROVIDER_INVALID)
            frame["kind"] = "upload_consume" if consume else "upload_check"
            frame["plan_digest"] = upload_digest
        await self.send(frame)
        result = await asyncio.wait_for(self.read(), timeout=5)
        allowed = {"kind", "sequence", "nonce", "ok", "remaining_seconds"}
        if lease:
            allowed.add("credential")
        if (set(result) != allowed or result["kind"] != "authorization"
                or type(result["sequence"]) is not int or result["sequence"] != sequence
                or result["nonce"] != self.nonce or result["ok"] is not True
                or type(result["remaining_seconds"]) not in (int, float)
                or not 0 < result["remaining_seconds"] <= 120):
            raise CredentialFault(Failure.CALLER_UNVERIFIED)
        return result


class NativePipeAuthority:
    def __init__(self, wire, caller, scope, deadline):
        self.wire, self.caller, self.scope, self.deadline = wire, caller, scope, deadline
        self.revoked = False

    async def verify(self, caller, scope, stage):
        if self.revoked or time.monotonic() >= self.deadline:
            raise CredentialFault(Failure.EXPIRED)
        if caller != self.caller or scope != self.scope or stage not in STAGES:
            raise CredentialFault(Failure.CALLER_UNVERIFIED)
        await self.wire.authorize(stage, scope, caller)
        if self.revoked or time.monotonic() >= self.deadline:
            raise CredentialFault(Failure.EXPIRED)


class NativePipeProvider:
    def __init__(self, authority):
        self.authority, self.used = authority, False

    async def use(self, scope, caller, consume):
        if self.used or scope != self.authority.scope or caller != self.authority.caller:
            raise CredentialFault(Failure.TICKET_INVALID)
        self.used = True
        reply = await self.authority.wire.authorize("lease", scope, caller, lease=True)
        raw = bytearray(base64.b64decode(reply.pop("credential"), validate=True))
        lease = None
        value = None
        try:
            value = strict(raw)
            if (type(value) is not dict or set(value) != {"schema", "endpoint_fingerprint", "username", "password"}
                    or type(value["schema"]) is not int or value["schema"] not in (1, 2)
                    or type(value["username"]) is not str or type(value["password"]) is not str):
                raise CredentialFault(Failure.CREDENTIAL_INVALID)
            lease = PrivateCredential(scope, min(self.authority.deadline,
                time.monotonic() + reply["remaining_seconds"]), value.pop("username").encode(),
                value.pop("password").encode())
            value.clear()
            await consume(lease)
        finally:
            if lease is not None:
                lease.clear()
            if value is not None:
                value.clear()
            raw[:] = b"\0" * len(raw)
            raw.clear()


class OwnedSMBTransport:
    """Blocking SMB lives inside this killable host, with no grandchildren."""
    def __init__(self):
        self.reader = None
        self.closed = False
        self.busy = False

    async def connect(self, config, credentials):
        if self.closed or self.reader is not None or config.transport != "smb" or not config.require_encryption:
            raise CredentialFault(Failure.DISABLED)
        try:
            self.reader = await asyncio.to_thread(SMBReader, config, credentials)
            return await self.request("health", {})
        except Exception as exc:
            raise NASConnectionError(error_code(exc)) from None

    async def request(self, operation, payload):
        if self.closed or self.reader is None or self.busy:
            raise CredentialFault(Failure.BUSY)
        self.busy = True
        try:
            reader = self.reader
            if operation == "health":
                return await asyncio.to_thread(reader.health)
            if operation == "list":
                return await asyncio.to_thread(reader.list_page, payload["path"], payload["cursor"], payload["limit"])
            if operation == "stat":
                return await asyncio.to_thread(reader.stat, payload["path"])
            if operation == "read":
                return await asyncio.to_thread(reader.read_range, payload["path"], payload["revision"],
                                               payload["offset"], payload["length"])
            raise CredentialFault(Failure.DISABLED)
        except BaseException:
            # A timed-out thread must never be reused. Native parent owns process teardown.
            self.closed = True
            raise
        finally:
            self.busy = False

    async def close(self):
        self.closed = True
        reader, self.reader = self.reader, None
        if reader is not None:
            await asyncio.to_thread(reader.close)


class NativeRuntimeHost:
    def __init__(self, wire, *, transport_factory=OwnedSMBTransport):
        self.wire, self.transport_factory = wire, transport_factory
        self.connection = None
        self.transport = None
        self.authority = None
        self.monitor = None
        self.failure = None
        self.last_health = 0.
        self.file_sequence, self.file_calls = 1, 0
        self.file_reader = None

    async def connect(self, bootstrap):
        if set(bootstrap) != {"kind", "id", "nonce", "caller", "config", "credential_generation", "config_generation"}:
            raise CredentialFault(Failure.PROVIDER_INVALID)
        if bootstrap["kind"] != "connect" or bootstrap["id"] != 1:
            raise CredentialFault(Failure.PROVIDER_INVALID)
        nonce = bootstrap["nonce"]
        if type(nonce) is not str or len(nonce) != 32 or any(c not in "0123456789abcdef" for c in nonce):
            raise CredentialFault(Failure.PROVIDER_INVALID)
        self.wire.nonce = nonce
        caller = CallerPins(**bootstrap["caller"])
        if self.wire.kernel_check and (caller.pid != os.getppid() or caller.uid != os.getuid()):
            raise CredentialFault(Failure.CALLER_UNVERIFIED)
        config = NASConnectionConfig.model_validate(bootstrap["config"])
        if config.transport != "smb" or not config.enabled or not config.require_encryption or config.health_interval_seconds != 300:
            raise CredentialFault(Failure.DISABLED)
        generation = bootstrap["config_generation"]
        scope = NASReadScope.from_config(config, generation, bootstrap["credential_generation"])
        # Working directory was created private by native owner. No user path or command selects state.
        directory = Path.cwd()
        info = directory.stat()
        if directory.is_symlink() or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
            raise CredentialFault(Failure.CALLER_UNVERIFIED)
        state_path = directory / "connection.json"
        if state_path.exists():
            raise CredentialFault(Failure.SOURCE_CHANGED)
        if generation > 1:
            seed = StateStore(state_path)
            seed.save(config.model_copy(update={"enabled": False}), generation - 1, None)
            seed.release()
        deadline = time.monotonic() + 120
        self.authority = NativePipeAuthority(self.wire, caller, scope, deadline)
        provider = NativePipeProvider(self.authority)
        def owned_transport():
            self.transport = self.transport_factory()
            return self.transport
        self.connection = make_scoped_nas_manager(state_path, scope=scope, caller=caller,
            admission=Admission(enabled=True, ttl_seconds=120, connection_attempts=1),
            authorizer=self.authority, provider=provider, transport_factory=owned_transport,
            current_credential_generation=lambda: bootstrap["credential_generation"] if not self.authority.revoked else "",
            connect_coordinator_seconds=80)
        manager = self.connection.manager
        await manager.configure(config, expected_generation=generation - 1)
        try:
            # Seven native authorization callbacks surround the separately timed
            # SMB connect. Leave cleanup time below the native 90-second request,
            # and never extend the original authority deadline.
            async with asyncio.timeout(min(90, max(.001, self.authority.deadline - time.monotonic()))):
                while manager.status().state not in {"online", "backoff", "paused"}:
                    await asyncio.sleep(.005)
            if manager.status().state != "online":
                failure = self.connection.credentials.snapshot().failure
                if failure is not None:
                    raise CredentialFault(Failure(failure))
                raise NASConnectionError(manager.status().failure or "nas_transport_failed")
        except BaseException:
            await self.stop()
            raise
        self.last_health = time.monotonic()
        self.monitor = asyncio.create_task(self.watch())
        return self.snapshot()

    async def watch(self):
        # Never let manager's background retry outlive one manual native admission.
        while self.connection is not None:
            await asyncio.sleep(.05)
            state = self.connection.manager.status()
            if time.monotonic() >= self.authority.deadline or state.state != "online":
                self.failure = "expired" if time.monotonic() >= self.authority.deadline else state.failure or "nas_unavailable"
                await self.stop(from_monitor=True)
                return

    def snapshot(self):
        if self.connection is None:
            return {"connected": False, "readable": False, "epoch": None, "failure": self.failure, "scope": None}
        record = self.connection.manager.status()
        online = record.state == "online" and record.reachable is True and record.authenticated is True
        return {"connected": online, "readable": online and record.readable is True,
                "epoch": record.connection_epoch if online else None, "failure": record.failure,
                "scope": asdict(self.connection.credentials.scope)}

    async def command(self, frame):
        if frame.get("kind") == "files":
            from homeplane.nas_connection.contracts import FILE_OUTPUT, file_request
            if (set(frame) != {"kind", "id", "nonce", "request"} or frame["nonce"] != self.wire.nonce
                    or type(frame["id"]) is not int or frame["id"] <= self.file_sequence
                    or self.connection is None):
                raise CredentialFault(Failure.PROVIDER_INVALID)
            from nas_file_reader_host import OPERATIONS, request as reader_request, execute as reader_execute
            extended = type(frame["request"]) is dict and frame["request"].get("operation") in OPERATIONS
            request = reader_request(frame["request"]) if extended else file_request(frame["request"])
            self.file_sequence = frame["id"]; self.file_calls += 1
            connection, authority = self.connection, self.authority
            await connection.credentials.check("request")
            try:
                # The coordinator includes native authorization round trips and multiple
                # individually timed SMB reads; retain the existing authority deadline.
                async with asyncio.timeout(min(90, max(.001, authority.deadline - time.monotonic()))):
                    result = await reader_execute(self, request) if extended else await connection.manager.file_operation(request)
            except TimeoutError:
                raise NASConnectionError("nas_timeout") from None
            await connection.credentials.check("request_reply")
            if self.connection is not connection or self.authority is not authority:
                raise NASConnectionError("nas_source_changed")
            if len(json.dumps(result, ensure_ascii=False).encode()) > FILE_OUTPUT:
                raise NASConnectionError("nas_budget_exceeded")
            return result
        if frame.get("kind") == "upload_new":
            from nas_upload_host import upload_new
            return await upload_new(self, frame)
        if frame.get("kind") == "directories":
            return await self.directories(frame)
        if set(frame) != {"kind", "id", "nonce"} or frame["nonce"] != self.wire.nonce or type(frame["id"]) is not int:
            raise CredentialFault(Failure.PROVIDER_INVALID)
        if frame["kind"] == "stop":
            await self.stop()
            return self.snapshot()
        if frame["kind"] == "status":
            # Health runs only while native is awaiting this response, so the
            # private wire has one reader. No unattended credential callback.
            if self.connection is not None and time.monotonic() - self.last_health >= 15:
                try:
                    await self.connection.manager._request("health", {})
                    self.last_health = time.monotonic()
                except Exception as exc:
                    self.failure = public_error(exc)
                    await self.stop()
            return self.snapshot()
        if frame["kind"] == "list" and self.connection is not None:
            return await self.connection.bounded_inventory().run()
        raise CredentialFault(Failure.DISABLED)

    async def directories(self, frame):
        from homeplane.nas_connection.contracts import relative_path
        if (set(frame) != {"kind", "id", "nonce", "path", "cursor"}
                or frame["nonce"] != self.wire.nonce or type(frame["id"]) is not int
                or self.connection is None):
            raise CredentialFault(Failure.PROVIDER_INVALID)
        path = relative_path(frame["path"], allow_root=True)
        cursor = frame["cursor"]
        if cursor is not None and (not isinstance(cursor, str) or len(cursor) != 32
                or any(c not in "0123456789abcdef" for c in cursor)):
            raise CredentialFault(Failure.PROVIDER_INVALID)
        manager = self.connection.manager
        directory_ref = None
        if path:
            directory_ref = next((key for key, value in manager._objects.items()
                                  if value == (path, "directory")), None)
            if directory_ref is None:
                raise NASConnectionError("nas_object_unknown")
        # Use the existing manager/broker authorization and retained-ancestor
        # transport. Native UI may navigate only directories already returned
        # within this admitted root. Public inventory still exposes opaque refs.
        page = await manager.list_page(manager.config.source_ref, cursor=cursor,
                                       limit=128, directory_ref=directory_ref)
        directories = [manager._path(entry.object_ref, directory=True)
                       for entry in page.entries if entry.kind == "directory"]
        return {"path": path, "directories": directories, "next_cursor": page.next_cursor}

    async def stop(self, *, from_monitor=False):
        if self.authority is not None:
            self.authority.revoked = True
        if not from_monitor and self.monitor is not None:
            self.monitor.cancel()
            self.monitor = None
        self.file_reader = None
        connection, self.connection = self.connection, None
        if connection is not None:
            connection.credentials.cancel()
            await connection.manager.close()


async def main():
    logging.disable(logging.CRITICAL)
    loop = asyncio.get_running_loop()
    reader = asyncio.StreamReader(limit=MAX_INPUT + 1)
    await loop.connect_read_pipe(lambda: asyncio.StreamReaderProtocol(reader), sys.stdin.buffer)
    transport, protocol = await loop.connect_write_pipe(asyncio.streams.FlowControlMixin, sys.stdout.buffer)
    writer = asyncio.StreamWriter(transport, protocol, reader, loop)
    wire = PrivateWire(reader, writer, os.getppid())
    host = NativeRuntimeHost(wire)
    try:
        frame = await wire.read()
        if frame.get("kind") == "server_connect":
            from nas_server_host import ServerBridge
            host = ServerBridge(wire)
        result = await host.connect(frame)
        await wire.send({"kind": "result", "id": 1, "nonce": wire.nonce, "ok": True, "value": result})
        while True:
            frame = await wire.read()
            try:
                result = await host.command(frame)
                await wire.send({"kind": "result", "id": frame["id"], "nonce": wire.nonce, "ok": True, "value": result})
                if frame["kind"] == "stop":
                    return
            except Exception as exc:
                await wire.send({"kind": "result", "id": frame.get("id"), "nonce": wire.nonce,
                                 "ok": False, "error": public_error(exc)})
    except (EOFError, BrokenPipeError):
        pass
    except Exception as exc:
        await wire.send({"kind": "result", "id": 1, "nonce": wire.nonce, "ok": False, "error": public_error(exc)})
    finally:
        await host.stop()
        writer.close()


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-check"]:
        import smbprotocol, pydantic, cryptography, spnego
        print(json.dumps({"runtime": "arl.nas.private.v1", "python": sys.version.split()[0],
                          "smbprotocol": "1.15.0", "network": False, "credentials": False}))
    elif len(sys.argv) == 1:
        asyncio.run(main())
    else:
        raise SystemExit(2)
