"""Synthetic existing-session tests; no NAS, credentials, mounts or content reads."""
import asyncio
import copy
import unittest
from types import SimpleNamespace

from arl_nas_credential import Admission, CallerPins, CredentialBroker, CurrentSource, NASReadScope
from arl_nas_credential.inventory import BoundedInventory, InventoryBounds, InventoryFault


class DTO:
    def __init__(self, value): self.value = value
    def model_dump(self, *, mode): return copy.deepcopy(self.value)


class Config:
    enabled = True
    source_ref = "fixture_source"
    credential_ref = "fixture_reference"
    def model_dump(self, *, mode):
        return {"source_ref": self.source_ref, "credential_ref": "fixture_reference", "enabled": self.enabled,
                "transport": "smb", "host": "synthetic.invalid", "port": 445, "share": "fixture",
                "root": "bounded", "require_encryption": True, "host_key_sha256": None,
                "sftp_root_confined": False}


class Authorizer:
    def __init__(self): self.allowed = True; self.calls = 0
    async def verify(self, caller, scope, stage):
        self.calls += 1
        if not self.allowed: raise RuntimeError("synthetic peer revoked")


class Provider:
    def __init__(self): self.calls = 0
    async def use(self, *args):
        self.calls += 1
        raise AssertionError("Inventory must not resolve credentials")


def entry(index):
    return {"object_ref": format(index, "064x"), "kind": "file", "revision": "c" * 64,
            "size": 12, "modified_ns": 1234, "media_kind": "image", "closed": None,
            "revision_basis": "metadata"}


def page(items, cursor=None, complete=False):
    return {"schema_version": 1, "source_ref": "fixture_source", "config_generation": 1,
            "connection_epoch": "epoch1", "entries": items, "next_cursor": cursor,
            "enumeration_complete": complete, "completed_scan_token": "scan1" if complete else None,
            "snapshot_consistent": False}


class Manager:
    def __init__(self, pages):
        self.config, self.generation, self.epoch = Config(), 1, "epoch1"
        self.pages, self.calls, self.online = list(pages), [], True
        self.after = None; self.delay = 0; self.finished = False
    def status(self):
        return DTO({"source_ref": self.config.source_ref, "config_generation": self.generation,
                    "connection_epoch": self.epoch, "configured": True, "enabled": True,
                    "reachable": True, "authenticated": True, "readable": self.online,
                    "state": "online" if self.online else "backoff"})
    async def list_page(self, source_ref, *, cursor, limit, directory_ref):
        self.calls.append((source_ref, cursor, limit, directory_ref))
        try:
            if self.delay: await asyncio.sleep(self.delay)
            result = self.pages.pop(0)
            if self.after: self.after()
            return DTO(result)
        finally:
            self.finished = True


class Fixture:
    def __init__(self, pages):
        self.manager, self.authorizer, self.provider = Manager(pages), Authorizer(), Provider()
        self.scope = NASReadScope.from_config(self.manager.config, 1, "1" * 32)
        self.broker = CredentialBroker(scope=self.scope,
            caller=CallerPins("fixture", 501, 1, "a" * 64, "b" * 64, "c" * 64, 1),
            admission=Admission(enabled=True), authorizer=self.authorizer, provider=self.provider,
            current_source=lambda: CurrentSource(self.scope, self.manager.config.enabled))
        self.connection = SimpleNamespace(manager=self.manager, credentials=self.broker)
    def consumer(self, **kwargs):
        return BoundedInventory(self.connection, scope=self.scope, **kwargs)


class InventoryTests(unittest.IsolatedAsyncioTestCase):
    async def test_complete_single_directory_uses_exact_existing_scope(self):
        f = Fixture([page([entry(1)], "cursor1"), page([entry(2)], complete=True)])
        operation = f.consumer(directory_ref="d" * 64)
        result = await operation.run()
        self.assertEqual(len(result["entries"]), 2)
        self.assertTrue(result["enumeration_complete"])
        self.assertFalse(result["snapshot_consistent"])
        self.assertFalse(result["content_read"])
        self.assertFalse(result["recursive"])
        self.assertEqual(result["writes"], 0)
        self.assertEqual(f.manager.calls, [("fixture_source", None, 64, "d" * 64),
                                         ("fixture_source", "cursor1", 64, "d" * 64)])
        self.assertEqual(f.provider.calls, 0)
        with self.assertRaisesRegex(InventoryFault, "inventory_consumed"): await operation.run()

    async def test_budget_returns_honest_partial_not_share_complete(self):
        f = Fixture([page([entry(1)], "cursor1"), page([entry(2)], complete=True)])
        result = await f.consumer(bounds=InventoryBounds(max_pages=1)).run()
        self.assertFalse(result["enumeration_complete"])
        self.assertEqual(result["stopped_reason"], "page_budget")
        self.assertIsNone(result["completed_scan_token"])
        self.assertEqual(len(f.manager.calls), 1)

    async def test_entry_budget_is_sent_to_underlying_page_reader(self):
        f = Fixture([page([entry(1)], "cursor1")])
        result = await f.consumer(bounds=InventoryBounds(max_entries=1)).run()
        self.assertEqual(f.manager.calls[0][2], 1)
        self.assertEqual(result["stopped_reason"], "entry_budget")

    async def test_disconnected_session_never_connects_or_retries(self):
        f = Fixture([]); f.manager.online = False
        with self.assertRaisesRegex(InventoryFault, "nas_unavailable"): await f.consumer().run()
        self.assertEqual(f.manager.calls, [])
        self.assertEqual(f.provider.calls, 0)

    async def test_epoch_and_manager_replacement_fence_late_reply(self):
        for change in ("epoch", "manager"):
            f = Fixture([page([entry(1)], complete=True)])
            def alter():
                if change == "epoch": f.manager.epoch = "epoch2"
                else: f.connection.manager = Manager([])
            f.manager.after = alter
            with self.assertRaisesRegex(InventoryFault, "inventory_binding_changed"):
                await f.consumer().run()

    async def test_peer_and_broker_revocation_fence_publication(self):
        for change in ("peer", "broker"):
            f = Fixture([page([entry(1)], complete=True)])
            def alter():
                if change == "peer": f.authorizer.allowed = False
                else: f.broker.revoke()
            f.manager.after = alter
            with self.assertRaises(InventoryFault): await f.consumer().run()
            self.assertEqual(f.provider.calls, 0)

    async def test_cancel_and_deadline_reap_owned_read(self):
        f = Fixture([page([], complete=True)]); f.manager.delay = 10
        operation = f.consumer()
        task = asyncio.create_task(operation.run())
        while not f.manager.calls: await asyncio.sleep(0)
        operation.cancel()
        with self.assertRaises(asyncio.CancelledError): await task
        self.assertTrue(f.manager.finished)
        f = Fixture([page([], complete=True)]); f.manager.delay = 10
        with self.assertRaisesRegex(InventoryFault, "inventory_deadline"):
            await f.consumer(bounds=InventoryBounds(seconds=.05)).run()
        self.assertTrue(f.manager.finished)

    async def test_metadata_injection_boolean_generation_and_duplicate_rejected(self):
        bad = page([entry(1)], complete=True); bad["entries"][0]["path"] = "/private"
        boolean = page([], complete=True); boolean["config_generation"] = True
        for pages in ([bad], [boolean], [page([entry(1)], "cursor1"), page([entry(1)], complete=True)],
                      [page([entry(1)], "cursor1"), page([entry(2)], "cursor1")]):
            f = Fixture(pages)
            with self.assertRaisesRegex(InventoryFault, "inventory_reply_invalid"):
                await f.consumer().run()

    async def test_no_path_arguments_and_no_exception_text_leak(self):
        f = Fixture([])
        for value in ("/Volumes/private", "..", "a/b"):
            with self.assertRaisesRegex(InventoryFault, "inventory_invalid"):
                f.consumer(directory_ref=value)
        class PrivateError(Exception): code = ["not", "a", "public", "code"]
        async def failing(*args, **kwargs): raise PrivateError("private transport text")
        f.manager.list_page = failing
        with self.assertRaisesRegex(InventoryFault, "^inventory_transport_failed$"):
            await f.consumer().run()


class FileConsumerTests(unittest.IsolatedAsyncioTestCase):
    """Real host/manager/broker; only SMB I/O and credentials are synthetic."""
    async def test_production_file_pages_original_ranges_and_stale_guards(self):
        from test_nas_runtime_assembly import AssemblyTests, SMB, bootstrap
        from unittest.mock import patch
        fixture = AssemblyTests()
        await fixture.asyncSetUp()
        rows = [{"path": "资料😀.txt", "kind": "file", "size": 4, "revision": "b"*64, "modified_ns": 0},
                {"path": "second.txt", "kind": "file", "size": 4, "revision": "c"*64, "modified_ns": 0}]
        def listing(reader, path, cursor, limit):
            self.assertEqual(path, ""); self.assertIsNone(cursor)
            return {"entries": rows, "cursor": None, "complete": True}
        def stat(reader, path): return dict(next(x for x in rows if x["path"] == path))
        def read(reader, path, revision, offset, length):
            import base64
            self.assertEqual(stat(reader,path)["revision"], revision)
            return {"data": base64.b64encode(b"data"[offset:offset+length]).decode()}
        sequence = 1
        async def command(request):
            nonlocal sequence
            sequence += 1
            return await fixture.runtime.command({"kind":"files", "id":sequence, "nonce":fixture.wire.nonce, "request":request})
        try:
            with patch.object(SMB,"list_page",listing), patch.object(SMB,"stat",stat,create=True), patch.object(SMB,"read_range",read,create=True):
                await fixture.runtime.connect(bootstrap())
                query = {"operation":"search", "keyword":".TXT", "limit":1}
                first = await command(query)
                self.assertEqual(first["entries"][0]["path"],"approved/资料😀.txt")
                self.assertTrue(first["partial"])
                cursor = first["next_cursor"]
                second = await command(dict(query,cursor=cursor))
                self.assertEqual(second["entries"][0]["path"],"approved/second.txt")
                self.assertTrue(second["enumeration_complete"])
                with self.assertRaisesRegex(Exception,"nas_cursor_expired"): await command(dict(query,cursor=cursor))
                entry = first["entries"][0]
                request = {"operation":"read","source_ref":first["source_ref"],"config_generation":first["config_generation"],
                           "connection_epoch":first["connection_epoch"],"object_ref":entry["object_ref"],"revision":entry["revision"],"offset":1,"length":2}
                result = await command(request)
                self.assertEqual(result["data_base64"],"YXQ="); self.assertEqual(result["next_offset"],3)
                with self.assertRaisesRegex(Exception,"nas_invalid_request"): await command(dict(request,offset=5))
                with self.assertRaisesRegex(Exception,"nas_source_changed"): await command(dict(request,connection_epoch="f"*32))
                with self.assertRaisesRegex(Exception,"nas_revision_changed"): await command(dict(request,revision="f"*64))
                with self.assertRaisesRegex(Exception,"nas_invalid_request"): await command(dict(query,limit=True))
                # Late native revocation withholds bytes even when SMB completed.
                fixture.wire.reject="request_reply"
                with self.assertRaises(Exception): await command(request)
                self.assertEqual(fixture.wire.lease_count,1)
        finally:
            await fixture.asyncTearDown()


if __name__ == "__main__":
    unittest.main()
