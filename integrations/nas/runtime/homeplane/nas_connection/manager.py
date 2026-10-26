"""Independent background NAS ownership; failed reads are never replayed."""

from __future__ import annotations

import asyncio
import base64
import hashlib
import json
import math
import unicodedata
import time
import uuid
from datetime import UTC, datetime
from typing import Awaitable, Callable

from .contracts import (
    MAX_PAGE,
    MAX_RANGE,
    FILE_OUTPUT, FILE_SESSION_BYTES, file_request,
    NASConnectionConfig,
    NASConnectionEntry,
    NASConnectionError,
    NASConnectionPage,
    NASConnectionStatus,
    NASCredentials,
    relative_path,
)
from .state import StateStore
from .transport import Transport, WorkerTransport

from ..runtime_log import observe, stage_span

PAUSE = {"nas_auth_failed", "nas_access_denied", "nas_host_key_mismatch", "nas_dependency_missing"}
NONFATAL = {"nas_missing", "nas_revision_changed", "nas_invalid_request", "nas_budget_exceeded",
            "nas_cursor_expired", "nas_object_unknown", "nas_busy", "nas_source_changed"}


class NASConnectionManager:
    def __init__(self, state_path, *, credential_resolver: Callable[[str], Awaitable[NASCredentials | None]],
                 transport_factory: Callable[[], Transport] = WorkerTransport,
                 connect_coordinator_seconds: float | None = None):
        # Trusted native assembly may budget authorization callbacks separately
        # from the unchanged per-SMB timeout. Ordinary owners keep their budget.
        if connect_coordinator_seconds is not None and (
                type(connect_coordinator_seconds) not in (int, float)
                or not math.isfinite(connect_coordinator_seconds)
                or not 1 <= connect_coordinator_seconds <= 90):
            raise ValueError("invalid_connect_coordinator_budget")
        self._connect_coordinator_seconds = connect_coordinator_seconds
        self.store = StateStore(state_path)
        self.config, self.generation, self.paused = self.store.load()
        self.resolver, self.factory = credential_resolver, transport_factory
        self._transport = self._task = self._epoch = None
        self._io, self._edit, self._wake = asyncio.Lock(), asyncio.Lock(), asyncio.Event()
        self._objects, self._cursors = {}, {}
        self._file_cursors, self._file_bytes = {}, 0
        self._state = "stopped" if self.config and self.config.enabled else "disabled"
        self._reachable = self._authenticated = self._readable = None
        self._failure, self._checked, self._next_retry = self.paused, None, None
        self._checked_mono = None
        self._failures = 0

    def status(self) -> NASConnectionStatus:
        state = self._state if self.config else "not_configured"
        if self.config and not self.config.enabled:
            state = "disabled"
        elif self.paused:
            state = "paused"
        stale = bool(state == "online" and self._checked_mono is not None
                     and time.monotonic() - self._checked_mono >
                     self.config.health_interval_seconds + self.config.operation_timeout_seconds)
        if stale:
            state = "backoff"
        return NASConnectionStatus(
            source_ref=self.config.source_ref if self.config else None, config_generation=self.generation,
            connection_epoch=self._epoch, configured=self.config is not None,
            enabled=bool(self.config and self.config.enabled), state=state,
            reachable=None if stale else self._reachable,
            authenticated=None if stale else self._authenticated, readable=False if stale else self._readable,
            failure="nas_unavailable" if stale else self._failure,
            retry_in_seconds=max(0, self._next_retry - time.monotonic()) if self._next_retry else None,
            checked_at=self._checked,
        )

    def _claim(self, expected=None):
        if self.store.fd is None:
            self.store.claim()
            self.config, self.generation, self.paused = self.store.load()
        if expected is not None and expected != self.generation:
            raise NASConnectionError("nas_source_changed")

    @observe('nas.configure', upstream='nas')
    async def configure(self, config: NASConnectionConfig, *, expected_generation: int):
        async with self._edit:
            self._claim(expected_generation)
            self.store.save(config, self.generation + 1, None)
            self.config, self.generation, self.paused = config, self.generation + 1, None
            await self._stop_runtime()
            self._clear_health()
            self._failures = 0
            self._state = "stopped" if config.enabled else "disabled"
            if config.enabled:
                self._launch()
            return self.status()

    @observe('nas.start', upstream='nas')
    async def start(self):
        async with self._edit:
            if self.config is None and not self.store.path.exists():
                return self.status()
            self._claim()
            if self.config and self.config.enabled and not self.paused:
                self._launch()
            return self.status()

    @observe('nas.resume', upstream='nas')
    async def resume(self, *, expected_generation: int):
        if self.config is None:
            raise NASConnectionError("nas_not_configured")
        return await self.configure(self.config.model_copy(update={"enabled": True}),
                                    expected_generation=expected_generation)

    @observe('nas.disable', upstream='nas')
    async def disable(self, *, expected_generation: int):
        if self.config is None:
            raise NASConnectionError("nas_not_configured")
        return await self.configure(self.config.model_copy(update={"enabled": False}),
                                    expected_generation=expected_generation)

    def _launch(self):
        if self._task is None or self._task.done():
            self._task = asyncio.create_task(self._run(), name="nas-connection-owner")

    def _clear_health(self):
        self._reachable = self._authenticated = self._readable = None
        self._failure = self._checked = self._next_retry = None
        self._checked_mono = None

    async def _drop(self):
        transport, self._transport = self._transport, None
        self._epoch = None
        self._objects.clear()
        self._cursors.clear()
        self._file_cursors.clear()
        self._file_bytes = 0
        if transport:
            await transport.close()

    async def _stop_runtime(self):
        task, self._task = self._task, None
        if task:
            task.cancel()
            try:
                await task
            except asyncio.CancelledError:
                pass
            except Exception:
                # Background failures already invalidate health; shutdown must still reap.
                self._failure = "nas_transport_failed"
        await self._drop()
        self._next_retry = None

    @observe('nas.close', upstream='nas')
    async def close(self):
        async with self._edit:
            try:
                await self._stop_runtime()
                self._clear_health()
                self._state = "stopped"
            finally:
                self.store.release()

    @observe('nas.health', upstream='nas', failure_code='code')
    async def _failure_result(self, code):
        self._failure, self._checked = code, datetime.now(UTC)
        # A fixed error code alone is not proof the endpoint was reached/authenticated.
        self._reachable = False if code in {"nas_timeout", "nas_transport_failed"} else None
        self._authenticated = (False if code in {"nas_auth_failed", "nas_host_key_mismatch"}
                               else None)
        self._readable = False
        await self._drop()
        if code in PAUSE:
            self.store.save(self.config, self.generation, code)
            self.paused, self._state, self._next_retry = code, "paused", None
        else:
            self._failures += 1
            delay = min(self.config.backoff_max_seconds,
                        self.config.backoff_initial_seconds * 2 ** min(self._failures - 1, 16))
            self._state = "backoff"
            self._next_retry = time.monotonic() + delay
        self._wake.set()

    async def _wait(self, seconds):
        self._wake.clear()
        try:
            await asyncio.wait_for(self._wake.wait(), max(0.001, seconds))
        except TimeoutError:
            pass

    @observe('nas.owner', upstream='nas')
    async def _run(self):
        try:
            while self.config and self.config.enabled and not self.paused:
                if self._transport is None:
                    if self._next_retry and self._next_retry > time.monotonic():
                        await self._wait(self._next_retry - time.monotonic())
                        continue
                    self._state, self._next_retry = "connecting", None
                    generation = self.generation
                    self._transport = self.factory()
                    try:
                        with stage_span('nas.connect', upstream='nas'):
                            async with asyncio.timeout(self._connect_coordinator_seconds or self.config.connect_timeout_seconds):
                                credentials = await self.resolver(self.config.credential_ref)
                                if not isinstance(credentials, NASCredentials):
                                    raise NASConnectionError("nas_auth_failed")
                                result = await self._transport.connect(self.config, credentials)
                            if generation != self.generation:
                                continue
                            if result != {"reachable": True, "authenticated": True, "readable": True}:
                                raise NASConnectionError("nas_transport_failed")
                        self._epoch = uuid.uuid4().hex
                        self._reachable = self._authenticated = self._readable = True
                        self._state, self._failure, self._checked = "online", None, datetime.now(UTC)
                        self._checked_mono = time.monotonic()
                        self._failures = 0
                    except TimeoutError:
                        await self._failure_result("nas_timeout")
                        continue
                    except NASConnectionError as exc:
                        await self._failure_result(exc.code)
                        continue
                    except Exception:
                        await self._failure_result("nas_transport_failed")
                        continue
                await self._wait(self.config.health_interval_seconds)
                if self._transport is None or self._io.locked():
                    continue
                try:
                    await self._request("health", {})
                except NASConnectionError:
                    pass
        finally:
            await self._drop()

    def _source(self, source_ref):
        if self.config is None:
            raise NASConnectionError("nas_not_configured")
        if source_ref != self.config.source_ref:
            raise NASConnectionError("nas_source_changed")
        if not self.config.enabled:
            raise NASConnectionError("nas_disabled")
        if self.status().state != "online" or self._epoch is None or self._transport is None:
            raise NASConnectionError("nas_unavailable")
        return self.generation, self._epoch

    def _fence(self, fence):
        if fence != (self.generation, self._epoch):
            raise NASConnectionError("nas_source_changed")

    @observe('nas.read', upstream='nas')
    async def _request(self, operation, payload):
        if operation != "health":
            self._source(self.config.source_ref)
        elif self._state != "online" or self._transport is None:
            raise NASConnectionError("nas_unavailable")
        if self._io.locked():
            raise NASConnectionError("nas_busy")
        async with self._io:
            fence = (self.generation, self._epoch)
            try:
                result = await asyncio.wait_for(self._transport.request(operation, payload),
                                                self.config.operation_timeout_seconds)
                self._fence(fence)
                if operation == "health" and result != {"reachable": True, "authenticated": True, "readable": True}:
                    raise NASConnectionError("nas_transport_failed")
                self._checked = datetime.now(UTC)
                self._checked_mono = time.monotonic()
                return result
            except asyncio.CancelledError:
                if fence == (self.generation, self._epoch):
                    await self._failure_result("nas_transport_failed")
                raise
            except TimeoutError:
                self._fence(fence)
                if fence == (self.generation, self._epoch):
                    await self._failure_result("nas_timeout")
                raise NASConnectionError("nas_timeout") from None
            except NASConnectionError as exc:
                self._fence(fence)
                if exc.code not in NONFATAL and fence == (self.generation, self._epoch):
                    await self._failure_result(exc.code)
                raise
            except Exception:
                self._fence(fence)
                if fence == (self.generation, self._epoch):
                    await self._failure_result("nas_transport_failed")
                raise NASConnectionError("nas_transport_failed") from None

    def _entry(self, data):
        try:
            path = relative_path(data["path"])
            if type(data["size"]) is not int or data["size"] < 0 or data["kind"] not in {"file", "directory"}:
                raise ValueError()
            # Validate all public fields before adding the private locator to the map.
            NASConnectionEntry(object_ref="0" * 64, kind=data["kind"], revision=data["revision"],
                               size=data["size"], modified_ns=data.get("modified_ns"))
        except (KeyError, TypeError, ValueError, NASConnectionError):
            raise NASConnectionError("nas_transport_failed") from None
        key = hashlib.sha256(f"{self.config.source_ref}\0{self._epoch}\0{path}".encode()).hexdigest()
        if len(self._objects) >= 8192 and key not in self._objects:
            raise NASConnectionError("nas_budget_exceeded")
        self._objects[key] = (path, data["kind"])
        suffix = path.rsplit(".", 1)[-1].lower() if "." in path else ""
        media = ("image" if suffix in {"jpg", "jpeg", "png", "heic", "webp", "gif"} else
                 "video" if suffix in {"mp4", "mov", "mkv", "ts", "m4v"} else
                 "audio" if suffix in {"mp3", "wav", "opus", "m4a", "flac"} else "other")
        return NASConnectionEntry(object_ref=key, kind=data["kind"], revision=data["revision"],
                                  size=data["size"], modified_ns=data.get("modified_ns"), media_kind=media)

    def _path(self, object_ref, *, directory=False):
        record = self._objects.get(object_ref)
        if record is None:
            raise NASConnectionError("nas_object_unknown")
        if directory and record[1] != "directory":
            raise NASConnectionError("nas_invalid_request")
        return record[0]

    @observe('nas.read', upstream='nas')
    async def list_page(self, source_ref: str, cursor: str | None = None, limit: int = MAX_PAGE,
                        *, directory_ref: str | None = None) -> NASConnectionPage:
        fence = self._source(source_ref)
        if type(limit) is not int or not 1 <= limit <= MAX_PAGE:
            raise NASConnectionError("nas_invalid_request")
        path = self._path(directory_ref, directory=True) if directory_ref else ""
        internal = None
        if cursor:
            record = self._cursors.pop(cursor, None)
            if record is None or record[:3] != (*fence, path) or record[4] < time.monotonic():
                raise NASConnectionError("nas_cursor_expired")
            internal = record[3]
        result = await self._request("list", {"path": path, "cursor": internal, "limit": limit})
        self._fence(fence)
        if len(result["entries"]) > limit:
            raise NASConnectionError("nas_budget_exceeded")
        entries = [self._entry(x) for x in result["entries"]]
        next_cursor = None
        if result.get("cursor"):
            if len(self._cursors) >= 8:
                raise NASConnectionError("nas_budget_exceeded")
            next_cursor = uuid.uuid4().hex
            self._cursors[next_cursor] = (*fence, path, result["cursor"], time.monotonic() + 120)
        complete = result.get("complete") is True and next_cursor is None
        return NASConnectionPage(source_ref=source_ref, config_generation=fence[0], connection_epoch=fence[1],
                                 entries=entries, next_cursor=next_cursor, enumeration_complete=complete,
                                 completed_scan_token=uuid.uuid4().hex if complete else None)

    @observe('nas.read', upstream='nas')
    async def stat(self, source_ref: str, object_ref: str,
                   expected_revision: str | None = None) -> NASConnectionEntry:
        fence = self._source(source_ref)
        result = await self._request("stat", {"path": self._path(object_ref)})
        self._fence(fence)
        entry = self._entry(result)
        if expected_revision is not None and entry.revision != expected_revision:
            raise NASConnectionError("nas_revision_changed")
        return entry

    @observe('nas.read', upstream='nas')
    async def read_range(self, source_ref: str, object_ref: str, expected_revision: str,
                         offset: int, length: int) -> bytes:
        fence = self._source(source_ref)
        if (type(offset) is not int or type(length) is not int or offset < 0 or offset > 2**63 - 1
                or not 1 <= length <= MAX_RANGE or not isinstance(expected_revision, str)
                or len(expected_revision) != 64):
            raise NASConnectionError("nas_invalid_request")
        result = await self._request("read", {"path": self._path(object_ref), "revision": expected_revision,
                                              "offset": offset, "length": length})
        self._fence(fence)
        try:
            data = base64.b64decode(result["data"], validate=True)
        except (ValueError, KeyError):
            raise NASConnectionError("nas_transport_failed") from None
        if len(data) > length:
            raise NASConnectionError("nas_budget_exceeded")
        return data


    def _file_entry(self, entry):
        result = entry.model_dump(mode="json")
        result["path"] = "/".join(x for x in (self.config.root, self._path(entry.object_ref)) if x)
        return result

    def _file_envelope(self, operation, fence):
        return {"schema_version": 1, "operation": operation, "source_ref": self.config.source_ref,
                "config_generation": fence[0], "connection_epoch": fence[1],
                "location": {"host": self.config.host, "port": self.config.effective_port,
                             "share": self.config.share, "root": self.config.root},
                "snapshot_consistent": False}

    async def file_operation(self, value):
        request = file_request(value)
        source = self.config.source_ref if self.config else ""
        fence = self._source(source)
        operation = request["operation"]
        if operation == "read":
            if (request["source_ref"] != source or
                    (request["config_generation"], request["connection_epoch"]) != fence):
                raise NASConnectionError("nas_source_changed")
            length, offset = request["length"], request["offset"]
            entry = await self.stat(source, request["object_ref"], request["revision"])
            if entry.object_ref != request["object_ref"] or entry.kind != "file" or offset > entry.size:
                raise NASConnectionError("nas_invalid_request")
            data = await self.read_range(source, entry.object_ref, entry.revision, offset, length)
            after = await self.stat(source, entry.object_ref, entry.revision)
            self._fence(fence)
            if after != entry or len(data) != min(length, entry.size - offset):
                raise NASConnectionError("nas_revision_changed")
            self._file_bytes += len(data)  # Telemetry only; no lifetime read quota.
            result = self._file_envelope(operation, fence)
            result.update(entry=self._file_entry(entry), offset=offset, length=length,
                          bytes_read=len(data), data_base64=base64.b64encode(data).decode(),
                          eof=offset + len(data) == entry.size,
                          next_offset=offset + len(data) if offset + len(data) < entry.size else None)
            return result

        directory, keyword, limit = request.get("directory_ref"), request.get("keyword"), request["limit"]
        if directory is not None: self._path(directory, directory=True)
        binding = (fence, operation, directory, keyword, limit)
        now = time.monotonic()
        for token, record in list(self._file_cursors.items()):
            if record[4] <= now:
                self._file_cursors.pop(token)
                if record[2]: self._cursors.pop(record[2], None)
        cursor = request.get("cursor")
        if cursor:
            record = self._file_cursors.pop(cursor, None)
            if record is None or record[0] != binding or record[4] <= now:
                raise NASConnectionError("nas_cursor_expired")
            _, pending, internal, complete, _, stalled = record
        else:
            pending, internal, complete, stalled = [], None, False, False
        entries, pages, scanned = [], 0, 0
        match = unicodedata.normalize("NFC", keyword).casefold() if keyword is not None else None
        while len(entries) < limit:
            if pending:
                candidate = pending[0]
                if len(json.dumps(entries + [candidate], ensure_ascii=True).encode()) > FILE_OUTPUT - 16384:
                    break
                entries.append(pending.pop(0))
                continue
            if complete or stalled or pages >= 2: break
            page = await self.list_page(source, cursor=internal, limit=128, directory_ref=directory)
            self._fence(fence)
            pages += 1; scanned += len(page.entries)
            internal, complete = page.next_cursor, page.enumeration_complete
            stalled = not complete and internal is None
            for entry in page.entries:
                path = self._path(entry.object_ref)
                if match is None or (entry.kind == "file" and match in unicodedata.normalize("NFC", path.rsplit("/", 1)[-1]).casefold()):
                    pending.append(self._file_entry(entry))
            if stalled and not pending: break
        self._fence(fence)
        finished = complete and not pending
        next_cursor = None
        if pending or internal:
            if len(self._file_cursors) >= 8:
                raise NASConnectionError("nas_budget_exceeded")
            next_cursor = uuid.uuid4().hex
            self._file_cursors[next_cursor] = (binding, pending, internal, complete, now + 120, stalled)
        result = self._file_envelope(operation, fence)
        result.update(directory_ref=directory, keyword=keyword, entries=entries,
                      match_mode="nfc_casefold_basename_contains" if match is not None else None,
                      next_cursor=next_cursor, enumeration_complete=finished, partial=not finished,
                      stopped_reason=None if finished else "result_budget" if pending else "provider_incomplete" if stalled else "page_budget" if pages >= 2 else "provider_incomplete",
                      scanned_count=scanned, pages=pages, recursive=False)
        return result
