"""Synthetic acceptance runner checks, never a live NAS or a platform publisher."""
from copy import deepcopy
import base64
import json
import os
from pathlib import Path
import stat
import tempfile
import unittest
import uuid

from integrations.nas import acceptance as a
from integrations.nas import attachment_bridge as bridge


def reply(value, error=False):
    return dict(content=[dict(type="text", text=json.dumps(value, ensure_ascii=False))],
                structuredContent=deepcopy(value), isError=error)


class Gateway:
    fence = dict(source_ref="synthetic", config_generation=1, connection_epoch="e"*32)

    def __init__(self):
        self.raw = a.samples()
        self.calls = []
        self.entries = [dict(path="ARL-Test/"+name, kind="file", object_ref=f"{index+1:064x}",
                             revision=f"{index+20:064x}", size=len(raw))
                        for index, (name, raw) in enumerate(sorted(self.raw.items()))]

    def listing(self):
        return reply(dict(self.fence, entries=self.entries))

    def __call__(self, tool, args):
        self.calls.append((tool, deepcopy(args)))
        if tool == "mio_nas_read_document":
            item = next(row for row in a.manifest()["files"] if row["name"] == args["name"])
            return reply(dict(args, source_sha256=item["sha256"], source_size=item["size"],
                              format=item["document_format"], complete=True, text="\n".join(item["expected_text"])))
        if tool == "mio_nas_download":
            self.download = dict(args)
            self.data = self.raw[args["name"]]
            return reply(dict(args, schema_version=1, operation="download", transfer_ref="f"*64,
                              sha256=bridge.digest(self.data), expires_in_seconds=120, complete=True,
                              direction="download", downloadable_artifact=False,
                              delivery_code="platform_file_publisher_required"))
        assert tool == "mio_nas_transfer_read"
        raw = self.data[args["offset"]:args["offset"]+args["length"]]
        end = args["offset"] + len(raw)
        return reply(dict(args, schema_version=1, operation="transfer_read", bytes_read=len(raw),
                          data_base64=base64.b64encode(raw).decode(), chunk_sha256=bridge.digest(raw),
                          eof=end == len(self.data), next_offset=None if end == len(self.data) else end,
                          downloadable_artifact=False, delivery_code="platform_file_publisher_required"))


class AcceptanceChecks(unittest.TestCase):
    def fault(self, code, function):
        with self.assertRaises(a.AcceptanceFault) as caught: function()
        self.assertEqual(caught.exception.code, code)

    def test_reproducible_private_pack_and_no_overwrite(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary) / "pack"
            first = a.prepare(home)
            self.assertEqual(first, a.manifest())
            self.assertEqual(stat.S_IMODE(home.stat().st_mode), 0o700)
            for row in first["files"]:
                raw = (home/row["name"]).read_bytes()
                self.assertEqual((len(raw), bridge.digest(raw)), (row["size"],row["sha256"]))
                self.assertTrue(row["name"].startswith(a.PREFIX))
                self.assertEqual(stat.S_IMODE((home/row["name"]).stat().st_mode), 0o600)
            self.assertEqual((home/(a.PREFIX+"large.bin")).stat().st_size, a.LARGE_BYTES)
            with self.assertRaises(FileExistsError): a.prepare(home)

    def test_document_and_large_download_pipeline_uses_original_fence(self):
        gateway = Gateway()
        result = a.read_acceptance(call=gateway, listing=gateway.listing(), verify=lambda:None,
                                   run_id="771d2eb5-a04b-4ed1-bb9b-07ee0f82982b")
        self.assertEqual(result["state"], "read_checks_passed")
        self.assertEqual(len(result["files"]), 6)
        self.assertTrue(all(row["download_verified"] for row in result["files"]))
        self.assertFalse(result["write_performed"])
        self.assertGreater(len(gateway.calls), 100)
        for tool,args in gateway.calls:
            self.assertEqual({k:args[k] for k in gateway.fence}, gateway.fence)
            self.assertNotIn("root", args)

    def test_missing_ambiguous_and_digest_changed_samples_stop(self):
        gateway=Gateway(); listed=gateway.listing(); listed=reply(dict(gateway.fence, entries=[]))
        self.fault("sample_missing", lambda:a.read_acceptance(call=gateway,listing=listed,verify=lambda:None))
        self.assertEqual(gateway.calls, [])
        gateway.entries.append(gateway.entries[0])
        self.fault("ambiguous_sample_name", lambda:a.read_acceptance(call=gateway,listing=gateway.listing(),verify=lambda:None))
        gateway=Gateway(); gateway.raw[a.PREFIX+"large.bin"]=b"x"*a.LARGE_BYTES
        self.fault("sample_digest_mismatch", lambda:a.read_acceptance(call=gateway,listing=gateway.listing(),verify=lambda:None))

    def test_failure_stops_without_reconnect_or_automatic_retry(self):
        gateway=Gateway(); calls=[]
        def failed(tool,args):
            calls.append(tool)
            return reply(dict(schema_version=1,operation="read_document",state="failed",
                              error={"code":"nas_transport_failed"},automatic_replay=False),True)
        self.fault("nas_transport_failed", lambda:a.read_acceptance(call=failed,listing=gateway.listing(),verify=lambda:None))
        self.assertEqual(calls,["mio_nas_read_document"])


class CleanupChecks(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.home=Path(self.temp.name)/"journal"
        self.run=a.CleanupRun(self.home)
        self.operation=str(uuid.uuid4())
        row=a.manifest()["files"][-1]
        self.identity=dict(path="ARL-Test/"+row["name"],object_ref="a"*64,revision="b"*64,
                           size=row["size"],sha256=row["sha256"])

    def tearDown(self): self.temp.cleanup()

    def register(self,**changes):
        values=dict(operation_id=self.operation,baseline_absent=True,identity=self.identity,
                    verified_sha256=self.identity["sha256"])
        values.update(changes);self.run.register_created(**values)

    def fault(self,code,function):
        with self.assertRaises(a.AcceptanceFault) as caught:function()
        self.assertEqual(caught.exception.code,code)

    def test_cleanup_durable_claim_exact_delete_and_readback(self):
        self.register(); present=[True];calls=[]
        def remove(identity):
            state=json.loads((self.home/"cleanup.json").read_text())
            self.assertEqual(state["samples"][self.operation]["state"],"delete_attempted")
            self.assertEqual(identity,self.identity)
            present[0]=False;calls.append(identity)
            return dict(state="deleted",identity=identity)
        result=self.run.cleanup(operation_id=self.operation,
            stat_exact=lambda _:dict(self.identity) if present[0] else None,
            hash_exact=lambda _:self.identity["sha256"],delete_exact=remove,verify=lambda:None)
        self.assertEqual(result["state"],"deleted");self.assertEqual(len(calls),1)
        reloaded=a.CleanupRun(self.home)
        self.fault("cleanup_already_consumed",lambda:reloaded.cleanup(operation_id=self.operation,
            stat_exact=lambda _:None,hash_exact=lambda _:None,delete_exact=remove,verify=lambda:None))
        self.fault("cleanup_already_consumed",self.register)

    def test_preexisting_changed_revision_or_digest_is_never_deleted(self):
        self.fault("confirmed_new_file_required",lambda:self.register(baseline_absent=False))
        self.register();calls=[]
        changed=dict(self.identity,revision="c"*64)
        for observed,sha in ((changed,self.identity["sha256"]),(self.identity,"f"*64)):
            self.fault("cleanup_target_changed",lambda:self.run.cleanup(operation_id=self.operation,
                stat_exact=lambda _:observed,hash_exact=lambda _:sha,
                delete_exact=lambda x:calls.append(x),verify=lambda:None))
        self.assertEqual(calls,[])

    def test_unknown_delete_survives_reopen_without_replay(self):
        self.register();calls=[]
        def uncertain(value):calls.append(value);raise TimeoutError("synthetic uncertain effect")
        with self.assertRaises(TimeoutError):
            self.run.cleanup(operation_id=self.operation,stat_exact=lambda _:self.identity,
                hash_exact=lambda _:self.identity["sha256"],delete_exact=uncertain,verify=lambda:None)
        self.assertEqual(json.loads((self.home/"cleanup.json").read_text())["samples"][self.operation]["state"],"unknown")
        self.fault("cleanup_already_consumed",lambda:a.CleanupRun(self.home).cleanup(operation_id=self.operation,
            stat_exact=lambda _:self.identity,hash_exact=lambda _:self.identity["sha256"],delete_exact=uncertain,verify=lambda:None))
        self.assertEqual(len(calls),1)
        self.fault("target_already_registered",lambda:self.run.register_created(operation_id=str(uuid.uuid4()),
            baseline_absent=True,identity=self.identity,verified_sha256=self.identity["sha256"]))

    def test_symlink_or_nonprivate_journal_refused(self):
        (self.home/"cleanup.json").symlink_to(Path(self.temp.name)/"other")
        with self.assertRaises(OSError):self.register()
        self.home.chmod(0o755)
        self.fault("private_journal_required",lambda:a.CleanupRun(self.home))


if __name__=="__main__":unittest.main()
