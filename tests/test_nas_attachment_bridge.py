"""Offline adapter checks; all temporary artifacts stay under main-repo audit."""
from __future__ import annotations
import base64
from copy import deepcopy
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT), str(ROOT/"integrations/nas/runtime")]
from integrations.nas import attachment_bridge as bridge
from homeplane.nas_connection.file_operations import FileOperationJournal, ScopeFence
from homeplane.nas_connection.file_transfer import FileTransfer

AUDIT = ROOT/"build/audit/nas-attachment-bridge-20261022.noindex"
AUDIT.mkdir(mode=0o700, parents=True, exist_ok=True)


def mcp(value, error=False):
    return dict(content=[dict(type="text",text=json.dumps(value,ensure_ascii=False))],
                structuredContent=deepcopy(value),isError=error)


def manifest(data, name="附件.txt"):
    return dict(schema_version=1,operation="download",operation_id=str(uuid.uuid4()),
                source_ref="synthetic",config_generation=1,connection_epoch="e"*32,
                transfer_ref="f"*64,object_ref="a"*64,revision="b"*64,
                name=name,size=len(data),sha256=bridge.digest(data),expires_in_seconds=120,
                complete=True,direction="download",downloadable_artifact=False,
                delivery_code="platform_file_publisher_required")


class SyntheticMio:
    """Models the current shared Swift DTO verbatim; never opens sockets."""
    def __init__(self,data):
        self.data=data
        self.calls=[]
    def __call__(self,tool,args):
        assert tool == "mio_nas_transfer_read"
        self.calls.append(deepcopy(args))
        raw=self.data[args["offset"]:args["offset"]+args["length"]]
        end=args["offset"]+len(raw)
        return mcp(dict(args,schema_version=1,operation="transfer_read",bytes_read=len(raw),
            data_base64=base64.b64encode(raw).decode(),chunk_sha256=bridge.digest(raw),
            eof=end==len(self.data),next_offset=None if end==len(self.data) else end,
            downloadable_artifact=False,delivery_code="platform_file_publisher_required"))


class Checks(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix="case-",dir=AUDIT)
        self.home=Path(self.temp.name);self.home.chmod(0o700)
        self.dirfd=os.open(self.home,os.O_RDONLY|os.O_DIRECTORY)
        self.journal=FileOperationJournal(self.dirfd,verify_seal=lambda:None)
        self.transfers=[];self.fds=[]
    def tearDown(self):
        for transfer in self.transfers: transfer.close()
        for fd in self.fds: os.close(fd)
        self.journal.close();os.close(self.dirfd);self.temp.cleanup()
    def source(self,raw):
        p=self.home/str(uuid.uuid4());p.write_bytes(raw);p.chmod(0o600)
        fd=os.open(p,os.O_RDWR|os.O_NOFOLLOW);self.fds.append(fd)
        return fd
    def transfer(self,raw,**changes):
        args=dict(journal=self.journal,operation_id=str(uuid.uuid4()),
            fence=ScopeFence("synthetic",1,"e"*32),name="input.txt",size=len(raw),
            sha256=bridge.digest(raw),verify=lambda:None)
        args.update(changes);t=FileTransfer(**args);self.transfers.append(t);return t
    def fault(self,code,callback):
        with self.assertRaises(bridge.BridgeFault) as caught:callback()
        self.assertEqual(caught.exception.code,code)
    def download(self,result,**kw):
        expected=kw.pop("expected",None)
        if expected is None:
            value=result["structuredContent"]
            expected={k:value[k] for k in bridge.DOWNLOAD_KEYS}
        return bridge.collect_download(result,expected=expected,**kw)
    def collect(self,raw,**kw):
        return self.download(mcp(manifest(raw)),call=SyntheticMio(raw),verify=lambda:None,**kw)

    def test_one_mib_input_to_existing_transfer_and_output(self):
        raw=bytes(range(256))*4096;t=self.transfer(raw)
        reply=bridge.import_materialized(self.source(raw),transfer=t,verify=lambda:None)
        self.assertEqual(reply["sha256"],bridge.digest(raw));self.assertTrue(t.sealed)
        self.assertFalse(reply["downloadable_artifact"])
        with t.claim_source(ref=t.ref,operation_id=t.operation_id,fence=t.fence) as source:
            recovered=b"".join(source.read(i,min(bridge.CHUNK_BYTES,len(raw)-i)) for i in range(0,len(raw),bridge.CHUNK_BYTES))
        self.assertEqual(recovered,raw)
        peer=SyntheticMio(raw)
        verified=self.download(mcp(manifest(raw)),call=peer,verify=lambda:None)
        self.assertEqual(len(peer.calls),32)
        self.assertEqual([p["offset"] for p in peer.calls],list(range(0,len(raw),32768)))
        self.assertTrue(all(len(json.dumps(p).encode())<65536 for p in peer.calls))
        receipt=bridge.write_exclusive(self.dirfd,verified,verify=lambda:None)
        self.assertEqual((self.home/verified.name).read_bytes(),raw)
        self.assertFalse(receipt["downloadable_artifact"])
        self.assertNotIn("url",receipt)

    def test_empty_and_binary(self):
        for raw in (b"",b"\x00\xff\x80\r\n",b"x"*32769):
            with self.subTest(size=len(raw)):
                t=self.transfer(raw)
                bridge.import_materialized(self.source(raw),transfer=t,verify=lambda:None)
                self.assertEqual(t.sha256,bridge.digest(raw))
                self.assertEqual(self.collect(raw).data,raw)

    def test_input_hash_or_size_mismatch_before_append(self):
        for raw in (b"bad",b"short"):
            t=self.transfer(b"raw")
            self.fault("integrity_failed",lambda:bridge.import_materialized(self.source(raw),transfer=t,verify=lambda:None))
            self.assertEqual(t.offset,0);self.assertFalse(t.sealed)

    def test_input_change_after_append_breaks_transfer(self):
        raw=b"x"*40000;fd=self.source(raw);t=self.transfer(raw)
        original=t.append
        def changed(**kw):
            reply=original(**kw);os.pwrite(fd,b"Y",0);return reply
        t.append=changed
        self.fault("source_changed",lambda:bridge.import_materialized(fd,transfer=t,verify=lambda:None))
        self.assertTrue(t.broken);self.assertFalse(t.sealed)

    def test_input_requires_owner_transfer_and_no_path_or_url(self):
        for v in ("/tmp/file","https://example.invalid/file",{"file_id":"file_x"},None):
            self.fault("owner_required",lambda:bridge.import_materialized(v,transfer=None,verify=lambda:None))
        t=self.transfer(b"x")
        bridge.import_materialized(self.source(b"x"),transfer=t,verify=lambda:None)
        self.fault("invalid_transfer",lambda:bridge.import_materialized(self.source(b"x"),transfer=t,verify=lambda:None))

    def test_source_hardlink_and_oversize_are_refused(self):
        fd=self.source(b"raw");p=next(p for p in self.home.iterdir() if p.is_file() and not p.name.startswith("file_transfer"))
        os.link(p,self.home/"linked")
        self.fault("invalid_source",lambda:bridge.import_materialized(fd,transfer=self.transfer(b"raw"),verify=lambda:None))
        self.fault("invalid_source",lambda:bridge.import_materialized(self.source(b"x"*(bridge.MAX_BYTES+1)),transfer=self.transfer(b"x"),verify=lambda:None))

    def test_output_scope_rebinding_boolean_and_extra_key_rejected(self):
        raw=b"data";v=manifest(raw)
        for field,value in [("source_ref","../NAS"),("config_generation",True),("size",bridge.MAX_BYTES+1),
                            ("complete",1),("operation_id",v["operation_id"].upper()),("host","private")]:
            changed=dict(v);changed[field]=value;calls=[]
            self.fault("invalid_receipt",lambda:self.download(mcp(changed),call=lambda *a:calls.append(a),verify=lambda:None))
            self.assertFalse(calls)
        for key,value in [("connection_epoch","d"*32),("operation_id",str(uuid.uuid4())),
                          ("transfer_ref","0"*64),("size",5),("config_generation",2),("offset",1),("length",1)]:
            def wrong(tool,args):
                result=SyntheticMio(raw)(tool,args);page=result["structuredContent"];page[key]=value;return mcp(page)
            self.fault("invalid_receipt",lambda:self.download(mcp(v),call=wrong,verify=lambda:None))

    def test_output_integrity_eof_and_offsets(self):
        raw=b"data";v=manifest(raw)
        for key,value in [("chunk_sha256","0"*64),("eof",False),("eof",1),("next_offset",4),
                          ("data_base64","!!!!"),("bytes_read",3),("data_base64",base64.b64encode(raw+b"x").decode())]:
            def bad(tool,args):
                page=SyntheticMio(raw)(tool,args)["structuredContent"];page[key]=value;return mcp(page)
            with self.subTest(key=key,value=value):
                with self.assertRaises(bridge.BridgeFault):self.download(mcp(v),call=bad,verify=lambda:None)
        v["sha256"]="0"*64
        self.fault("integrity_failed",lambda:self.download(mcp(v),call=SyntheticMio(raw),verify=lambda:None))

    def test_ttl_expiry_nonfinite_and_clock_rollback(self):
        for ttl in (0,-1,121,True,float("nan"),float("inf")):
            v=manifest(b"x");v["expires_in_seconds"]=ttl
            self.fault("invalid_receipt",lambda:self.download(mcp(v),call=SyntheticMio(b"x"),verify=lambda:None))
        for times in ([0,120],[10,9],[0,float("nan")]):
            clock=iter(times);peer=SyntheticMio(b"x")
            self.fault("expired",lambda:self.download(mcp(manifest(b"x")),call=peer,verify=lambda:None,clock=lambda:next(clock)))
            self.assertFalse(peer.calls)

    def test_revoke_before_and_during_read_no_retry(self):
        peer=SyntheticMio(b"x"*40000);n=[0]
        def verify():
            n[0]+=1
            if n[0]==3:raise bridge.BridgeFault("revoked")
        self.fault("revoked",lambda:self.download(mcp(manifest(peer.data)),call=peer,verify=verify))
        self.assertEqual(len(peer.calls),1)

    def test_actual_mcp_dual_representations_and_failures(self):
        raw=b"x";v=mcp(manifest(raw));v["content"][0]["text"]=v["content"][0]["text"].replace('"size": 1','"size": true')
        self.fault("invalid_receipt",lambda:bridge.mcp_value(v))
        v=mcp(manifest(raw));v["content"][0]["text"]='{"size":1,"size":1}'
        self.fault("invalid_receipt",lambda:bridge.mcp_value(v))
        value=dict(schema_version=1,operation="transfer_read",state="failed",error={"code":"nas_scope_required"},automatic_replay=False)
        peer=SyntheticMio(raw);calls=[]
        def closed(*args):calls.append(args);return mcp(value,error=True)
        self.fault("nas_scope_required",lambda:self.download(mcp(manifest(raw)),call=closed,verify=lambda:None))
        self.assertEqual(len(calls),1)
        self.fault("invalid_receipt",lambda:bridge.mcp_value({"resource_link":"file:///tmp/fake"}))

    def test_manifest_must_match_original_download_request(self):
        raw=b"raw";original=manifest(raw)
        expected={k:original[k] for k in bridge.DOWNLOAD_KEYS}
        for key,value in [("source_ref","other"),("object_ref","c"*64),("revision","d"*64),
                          ("operation_id",str(uuid.uuid4())),("name","other.txt"),("config_generation",2)]:
            changed=dict(original);changed[key]=value;peer=SyntheticMio(raw)
            self.fault("binding_mismatch",lambda:self.download(mcp(changed),expected=expected,call=peer,verify=lambda:None))
            self.assertFalse(peer.calls)
        self.fault("binding_mismatch",lambda:self.download(mcp(original),expected={"url":"file:///local"},call=SyntheticMio(raw),verify=lambda:None))

    def test_transport_uncertainty_is_never_retried(self):
        calls=[]
        def uncertain(tool,args):
            calls.append(args)
            raise TimeoutError("synthetic transport reply lost")
        with self.assertRaises(TimeoutError):
            self.download(mcp(manifest(b"x")),call=uncertain,verify=lambda:None)
        self.assertEqual(len(calls),1)

    def test_owner_rejection_never_calls_io_or_creates_output(self):
        def revoked():raise bridge.BridgeFault("revoked")
        peer=SyntheticMio(b"raw")
        self.fault("revoked",lambda:self.download(mcp(manifest(b"raw")),call=peer,verify=revoked))
        self.assertFalse(peer.calls)
        artifact=bridge.VerifiedFile("closed.txt",b"raw",bridge.digest(b"raw"))
        self.fault("revoked",lambda:bridge.write_exclusive(self.dirfd,artifact,verify=revoked))
        self.assertFalse((self.home/"closed.txt").exists())

    def test_mcp_frame_bounded(self):
        value=mcp(manifest(b"x"));value["content"][0]["text"]="x"*(bridge.FRAME_BYTES+1)
        self.fault("invalid_receipt",lambda:bridge.mcp_value(value))

    def test_names_unicode_traversal_and_invalid_sources(self):
        self.assertEqual(self.collect(b"x").name,"附件.txt")
        for name in ("../file","/tmp/file","a\\b","..","a\x00b","a"*256):
            with self.assertRaises(bridge.BridgeFault):
                self.download(mcp(manifest(b"x",name)),call=SyntheticMio(b"x"),verify=lambda:None)

    def test_exclusive_output_collision_symlink_private_parent_and_hash(self):
        artifact=self.collect(b"raw")
        bridge.write_exclusive(self.dirfd,artifact,verify=lambda:None)
        with self.assertRaises(FileExistsError):bridge.write_exclusive(self.dirfd,artifact,verify=lambda:None)
        (self.home/artifact.name).unlink();os.symlink("missing",self.home/artifact.name)
        with self.assertRaises(FileExistsError):bridge.write_exclusive(self.dirfd,artifact,verify=lambda:None)
        self.home.chmod(0o755)
        self.fault("private_directory_required",lambda:bridge.write_exclusive(self.dirfd,artifact,verify=lambda:None))
        self.home.chmod(0o700)
        bad=bridge.VerifiedFile("bad.txt",b"raw","0"*64)
        self.fault("integrity_failed",lambda:bridge.write_exclusive(self.dirfd,bad,verify=lambda:None))

    def test_exclusive_output_failure_is_not_a_success_receipt(self):
        artifact=self.collect(b"raw");n=[0]
        def revoked():
            n[0]+=1
            if n[0]==2:raise bridge.BridgeFault("revoked")
        self.fault("revoked",lambda:bridge.write_exclusive(self.dirfd,artifact,verify=revoked))
        self.assertEqual((self.home/artifact.name).read_bytes(),b"")
        self.assertEqual((self.home/artifact.name).stat().st_mode&0o777,0o600)
        with self.assertRaises(FileExistsError):bridge.write_exclusive(self.dirfd,artifact,verify=lambda:None)


if __name__=="__main__":unittest.main(verbosity=2)
