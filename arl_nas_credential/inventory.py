"""Host-private, single-use bounded metadata inventory on an existing NAS session.

No listener, credential resolution, connect/reconnect, content read or write.
The enclosing host must supply its already admitted ScopedNASConnection. This
consumer adds a finite page budget; it does not grant access or activate a host.
"""
from __future__ import annotations

import asyncio
import math
import re
import time
from dataclasses import dataclass

from .broker import CredentialBroker
from .contracts import CredentialFault, NASReadScope

_PAGE_KEYS = frozenset({"schema_version", "source_ref", "config_generation", "connection_epoch",
                        "entries", "next_cursor", "enumeration_complete",
                        "completed_scan_token", "snapshot_consistent"})
_ENTRY_KEYS = frozenset({"object_ref", "kind", "revision", "size", "modified_ns",
                         "media_kind", "closed", "revision_basis"})
_NAS_ERRORS = frozenset({"nas_not_configured", "nas_disabled", "nas_unavailable", "nas_busy",
                        "nas_source_changed", "nas_object_unknown", "nas_cursor_expired",
                        "nas_missing", "nas_revision_changed", "nas_invalid_request",
                        "nas_budget_exceeded", "nas_auth_failed", "nas_access_denied",
                        "nas_host_key_mismatch", "nas_dependency_missing", "nas_timeout",
                        "nas_transport_failed"})


class InventoryFault(Exception):
    def __init__(self, code):
        allowed = _NAS_ERRORS | {"inventory_invalid", "inventory_consumed", "inventory_cancelled",
                                 "inventory_deadline", "inventory_binding_changed",
                                 "inventory_reply_invalid", "inventory_transport_failed"}
        self.code = code if type(code) is str and code in allowed else "inventory_transport_failed"
        super().__init__(self.code)


def _integer(value, lower, upper):
    return type(value) is int and lower <= value <= upper


def _opaque(value, maximum=128):
    return type(value) is str and 1 <= len(value) <= maximum and re.fullmatch(r"[A-Za-z0-9_-]+", value) is not None


def _reference(value):
    return type(value) is str and re.fullmatch(r"[0-9a-f]{64}", value) is not None


@dataclass(frozen=True)
class InventoryBounds:
    max_pages: int = 2
    max_entries: int = 128
    page_size: int = 64
    seconds: float = 10

    def __post_init__(self):
        if (not _integer(self.max_pages, 1, 8) or not _integer(self.max_entries, 1, 512)
                or not _integer(self.page_size, 1, 128)
                or type(self.seconds) not in {int, float} or not math.isfinite(self.seconds)
                or not 0.05 <= self.seconds <= 30):
            raise InventoryFault("inventory_invalid")


class BoundedInventory:
    """Borrow one exact manager/broker/scope; no factory or public decoder.

    directory_ref is a previously returned opaque directory reference, never a
    filesystem path. None means the configured root, only one directory deep.
    A complete enumeration is not an atomic snapshot or a whole-share scan.
    """
    def __init__(self, connection, *, scope: NASReadScope,
                 bounds: InventoryBounds = InventoryBounds(), directory_ref=None,
                 clock=time.monotonic):
        broker = getattr(connection, "credentials", None)
        manager = getattr(connection, "manager", None)
        if (type(broker) is not CredentialBroker or manager is None
                or not isinstance(scope, NASReadScope) or scope != broker.scope
                or type(bounds) is not InventoryBounds
                or (directory_ref is not None and not _reference(directory_ref))):
            raise InventoryFault("inventory_invalid")
        self._connection, self._manager, self._broker = connection, manager, broker
        self._scope, self._bounds, self._directory = scope, bounds, directory_ref
        self._clock, self._used, self._cancelled, self._task = clock, False, False, None

    def cancel(self):
        self._cancelled = True
        if self._task is not None and not self._task.done():
            self._task.cancel()

    def _current(self, deadline, expected_epoch):
        if self._cancelled:
            raise InventoryFault("inventory_cancelled")
        if self._clock() >= deadline:
            raise InventoryFault("inventory_deadline")
        if (self._connection.manager is not self._manager
                or self._connection.credentials is not self._broker
                or self._broker.scope != self._scope):
            raise InventoryFault("inventory_binding_changed")
        config = self._manager.config
        if (config is None or not config.enabled
                or NASReadScope.from_config(config, self._manager.generation,
                                           self._scope.credential_generation) != self._scope):
            raise InventoryFault("inventory_binding_changed")
        status = self._manager.status().model_dump(mode="json")
        if (status.get("source_ref") != self._scope.source_ref
                or type(status.get("config_generation")) is not int
                or status["config_generation"] != self._scope.config_generation):
            raise InventoryFault("inventory_binding_changed")
        if not all(status.get(key) is True for key in ("configured", "enabled", "reachable", "authenticated", "readable")) or status.get("state") != "online":
            raise InventoryFault("nas_unavailable")
        epoch = status.get("connection_epoch")
        if not _opaque(epoch) or (expected_epoch is not None and epoch != expected_epoch):
            raise InventoryFault("inventory_binding_changed")
        return epoch

    async def _check(self, deadline, epoch):
        self._current(deadline, epoch)
        await self._broker.check("inventory_metadata")
        # Code verification may await. Recheck the captured binding afterwards.
        return self._current(deadline, epoch)

    def _page(self, value, epoch, limit):
        raw = value.model_dump(mode="json")
        if (type(raw) is not dict or set(raw) != _PAGE_KEYS
                or type(raw["schema_version"]) is not int or raw["schema_version"] != 1
                or raw["source_ref"] != self._scope.source_ref
                or type(raw["config_generation"]) is not int
                or raw["config_generation"] != self._scope.config_generation
                or raw["connection_epoch"] != epoch or raw["snapshot_consistent"] is not False
                or type(raw["entries"]) is not list or len(raw["entries"]) > limit
                or type(raw["enumeration_complete"]) is not bool):
            raise InventoryFault("inventory_reply_invalid")
        cursor, token, complete = raw["next_cursor"], raw["completed_scan_token"], raw["enumeration_complete"]
        if ((cursor is not None and not _opaque(cursor, 4096))
                or (token is not None and not _opaque(token))
                or (complete and (cursor is not None or token is None))
                or (not complete and token is not None)):
            raise InventoryFault("inventory_reply_invalid")
        entries = []
        for entry in raw["entries"]:
            if (type(entry) is not dict or set(entry) != _ENTRY_KEYS
                    or not _reference(entry["object_ref"]) or not _reference(entry["revision"])
                    or entry["kind"] not in {"file", "directory"}
                    or not _integer(entry["size"], 0, 2**63 - 1)
                    or (entry["modified_ns"] is not None and not _integer(entry["modified_ns"], 0, 2**63 - 1))
                    or entry["media_kind"] not in {"image", "video", "audio", "other"}
                    or entry["closed"] is not None or entry["revision_basis"] != "metadata"):
                raise InventoryFault("inventory_reply_invalid")
            entries.append(dict(entry))
        return entries, cursor, token, complete

    async def run(self):
        if self._used:
            raise InventoryFault("inventory_consumed")
        self._used = True
        self._task = asyncio.current_task()
        deadline = min(self._clock() + self._bounds.seconds, self._broker.deadline)
        try:
            epoch = await self._check(deadline, None)
            entries, seen, cursors, cursor, token, complete, pages = [], set(), set(), None, None, False, 0
            while pages < self._bounds.max_pages and len(entries) < self._bounds.max_entries:
                await self._check(deadline, epoch)
                limit = min(self._bounds.page_size, self._bounds.max_entries - len(entries))
                reply = await asyncio.wait_for(
                    self._manager.list_page(self._scope.source_ref, cursor=cursor, limit=limit,
                                            directory_ref=self._directory),
                    timeout=max(0.001, deadline - self._clock()))
                await self._check(deadline, epoch)
                page, next_cursor, token, complete = self._page(reply, epoch, limit)
                for entry in page:
                    if entry["object_ref"] in seen:
                        raise InventoryFault("inventory_reply_invalid")
                    seen.add(entry["object_ref"])
                entries.extend(page)
                pages += 1
                if complete:
                    break
                if next_cursor is None:
                    break
                if next_cursor in cursors:
                    raise InventoryFault("inventory_reply_invalid")
                cursors.add(next_cursor)
                cursor = next_cursor
            await self._check(deadline, epoch)
            reason = None if complete else ("entry_budget" if len(entries) >= self._bounds.max_entries
                     else "page_budget" if pages >= self._bounds.max_pages else "provider_incomplete")
            return {"schema_version": 1, "source_ref": self._scope.source_ref,
                    "config_generation": self._scope.config_generation, "connection_epoch": epoch,
                    "directory_ref": self._directory, "entries": entries, "pages": pages,
                    "enumeration_complete": complete, "snapshot_consistent": False,
                    "completed_scan_token": token if complete else None, "stopped_reason": reason,
                    "content_read": False, "recursive": False, "writes": 0}
        except asyncio.CancelledError:
            self._cancelled = True
            raise
        except asyncio.TimeoutError:
            raise InventoryFault("inventory_deadline") from None
        except CredentialFault as exc:
            code = {"cancelled": "inventory_cancelled", "expired": "inventory_deadline",
                    "revoked": "inventory_binding_changed", "source_changed": "inventory_binding_changed"}.get(exc.code.value, "nas_unavailable")
            raise InventoryFault(code) from None
        except InventoryFault:
            raise
        except Exception as exc:
            code = getattr(exc, "code", None)
            raise InventoryFault(code if type(code) is str and code in _NAS_ERRORS else "inventory_transport_failed") from None
        finally:
            self._task = None
