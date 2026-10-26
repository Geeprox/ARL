"""Real http.client parser + synthetic sockets/DNS only; no actual networking."""
from __future__ import annotations
from contextlib import ExitStack
from copy import deepcopy
import io
import json
import os
from pathlib import Path
import socket
import sys
import tempfile
import unittest
import uuid
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
sys.path[:0]=[str(ROOT),str(ROOT/"integrations/nas/runtime")]
from integrations.nas import file_params_importer as imp
from integrations.nas import attachment_bridge as bridge
from homeplane.nas_connection.file_operations import FileOperationJournal, ScopeFence
from homeplane.nas_connection.file_transfer import FileTransfer
OUT=ROOT/"build/audit/nas-attachment-bridge-20261022.noindex/fileparams"
OUT.mkdir(parents=True,mode=0o700,exist_ok=True)


def payload(**kw):
    result=dict(operation_id=str(uuid.uuid4()),source_ref="synthetic",config_generation=1,
                connection_epoch="e"*32,name="attachment.txt",
                file=dict(file_id="file_synthetic",download_url="https://files.oaiusercontent.com/file_synthetic?sig=synthetic",
                          file_name="附件.txt",mime_type="text/plain"))
    result.update(kw);return result


def response(data=b"fixture",status=200,headers=None,chunked=False):
    headers=list(headers) if headers is not None else [("Content-Length",str(len(data)))]
    if chunked:
        body=b"".join(format(len(data[i:i+32768]),"x").encode()+b"\r\n"+data[i:i+32768]+b"\r\n"
                      for i in range(0,len(data),32768))+b"0\r\n\r\n"
    else:body=data
    return ("HTTP/1.1 "+str(status)+" Synthetic\r\n"+"".join(k+": "+v+"\r\n" for k,v in headers)+"Connection: close\r\n\r\n").encode()+body


class FakeSocket:
    def __init__(self,raw):
        self.raw=raw;self.sent=[];self.timeouts=[];self.closed=False
    def makefile(self,*a,**kw):return io.BytesIO(self.raw)
    def sendall(self,data):self.sent.append(data)
    def settimeout(self,seconds):self.timeouts.append(seconds)
    def close(self):self.closed=True


class Checks(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix="import-",dir=OUT);self.home=Path(self.temp.name);self.home.chmod(0o700)
        self.fd=os.open(self.home,os.O_RDONLY|os.O_DIRECTORY);self.journal=FileOperationJournal(self.fd,verify_seal=lambda:None)
        self.transfers=[];self.sockets=[];self.connections=[];self.factory_calls=[]
    def tearDown(self):
        for t in self.transfers:t.close()
        self.journal.close();os.close(self.fd);self.temp.cleanup()
    def fault(self,code,callback):
        with self.assertRaises(bridge.BridgeFault) as c:callback()
        self.assertEqual(c.exception.code,code)
        self.assertNotIn("sig=",str(c.exception))
    def transport(self,raw,ips=("8.8.8.8",)):
        outer=self
        class Connection(imp._PinnedHTTPS):
            def __init__(self,host,ip,timeout):
                super().__init__(host,ip,timeout);outer.connections.append(self)
            def connect(self):
                self.sock=FakeSocket(raw);outer.sockets.append(self.sock)
        stack=ExitStack()
        stack.enter_context(patch.object(imp,"_PinnedHTTPS",Connection))
        stack.enter_context(patch.object(imp.socket,"getaddrinfo",return_value=[
            (socket.AF_INET6 if ":" in ip else socket.AF_INET,socket.SOCK_STREAM,socket.IPPROTO_TCP,"",(ip,443)) for ip in ips]))
        return stack
    def factory(self,**kw):
        self.factory_calls.append(kw)
        t=FileTransfer(journal=self.journal,verify=lambda:None,**kw);self.transfers.append(t);return t
    def fetch(self,value=None,**kw):
        return imp.fetch(imp.file_param((value or payload())["file"]),verify=kw.pop("verify",lambda:None),**kw)

    def test_schema_declares_all_four_only_two_file_required(self):
        d=imp.descriptor();f=d["inputSchema"]["properties"]["file"]
        self.assertEqual(d["_meta"]["openai/fileParams"],["file"])
        self.assertEqual(set(f["properties"]),{"download_url","file_id","mime_type","file_name"})
        self.assertEqual(set(f["required"]),{"download_url","file_id"});self.assertFalse(f["additionalProperties"])
        self.assertNotIn("ui",d["_meta"]);self.assertFalse(d["annotations"]["destructiveHint"])
        self.assertEqual(set(d["outputSchema"]["properties"]),set(d["outputSchema"]["required"]))
        self.assertLess(len(json.dumps(d)),65536)

    def test_inspection_is_scope_independent_and_uses_same_real_http_fetch(self):
        original=payload();value={key:original[key] for key in ("operation_id","file")}
        d=imp.inspection_descriptor()
        self.assertEqual(set(d["inputSchema"]["required"]),{"operation_id","file"})
        self.assertNotIn("source_ref",d["inputSchema"]["properties"])
        self.assertEqual(d["_meta"]["openai/fileParams"],["file"])
        with self.transport(response(b"scope-independent")):
            receipt=imp.inspect_attachment(value,verify=lambda:None)
        self.assertEqual(set(receipt),set(d["outputSchema"]["properties"]))
        self.assertEqual(receipt["sha256"],bridge.digest(b"scope-independent"))
        self.assertFalse(receipt["stored"]);self.assertFalse(receipt["nas_write_performed"])
        self.assertFalse(self.factory_calls)

    def test_inspection_does_not_borrow_nas_scope_or_skip_caller(self):
        original=payload();value={key:original[key] for key in ("operation_id","file")}
        self.fault("verified_caller_required",lambda:imp.inspect_attachment(value,verify=None))
        self.fault("invalid_import_request",lambda:imp.inspect_attachment(dict(value,source_ref="synthetic"),verify=lambda:None))
        calls=[]
        def revoked():raise bridge.BridgeFault("caller_unverified")
        with patch.object(imp,"_addresses",side_effect=lambda *a:calls.append(a)):
            self.fault("caller_unverified",lambda:imp.inspect_attachment(value,verify=revoked))
        self.assertFalse(calls)

    def test_optional_file_metadata_is_optional(self):
        v=payload();v["file"]={k:v["file"][k] for k in ("file_id","download_url")}
        with self.transport(response(b"raw")):a=self.fetch(v)
        self.assertEqual((a.name,a.data),("attachment.bin",b"raw"))

    def test_url_and_local_path_cannot_replace_platform_shape(self):
        for v in ({"url":"https://files.oaiusercontent.com/file_x"},{"local_path":"/tmp/file"},
                  {"file_id":"chat_upload"},{"download_url":"/tmp/file","file_id":"file_x"},
                  {"download_url":"https://files.oaiusercontent.com/f","file_id":"file_x","headers":{}}):
            with self.assertRaises(bridge.BridgeFault):imp.file_param(v)
        for ref in ("https://example.com/f","http://files.oaiusercontent.com/f","file:///tmp/f",
                    "https://files.oaiusercontent.com.evil/f","https://user@files.oaiusercontent.com/f",
                    "https://files.oaiusercontent.com:443/f","https://files.oaiusercontent.com./f",
                    "https://127.0.0.1/f","https://files.oaiusercontent.com/f#fragment",
                    "https://files.oaiusercontent.com/a\r\nb","https://files.oaiusercontent.com/ü"):
            with self.subTest(ref=ref):self.fault("attachment_origin_unsupported",lambda:imp.file_param(dict(file_id="file_x",download_url=ref)))

    def test_metadata_controls_paths_and_invalid_id_rejected(self):
        for k,v in (("file_name","../secret"),("mime_type","text/plain\r\nAuthorization: bad"),("file_id","/tmp/file")):
            value=payload()["file"];value[k]=v
            with self.assertRaises(bridge.BridgeFault):imp.file_param(value)
        self.assertNotIn("sig=",repr(imp.file_param(payload()["file"])))

    def test_original_owner_request_rejects_extra_or_wrong_fence(self):
        for changes in ({"local_path":"/tmp/f"},{"config_generation":True},{"connection_epoch":"bad"},{"operation_id":"bad"},{"name":"../f"}):
            with self.assertRaises(bridge.BridgeFault):imp.request(payload(**changes))
        v=payload();captured,source=imp.request(v);v["file"]["download_url"]="https://example.com/changed";v["name"]="changed"
        self.assertEqual(captured["name"],"attachment.txt");self.assertIn("files.oaiusercontent.com",source.download_url)

    def test_small_file_reaches_original_sealed_transfer(self):
        raw=b"ARL fileParams synthetic\x00\xff";v=payload()
        with self.transport(response(raw)):
            receipt=imp.import_attachment(v,verify=lambda:None,create_transfer=self.factory)
        self.assertEqual(set(receipt),set(imp.descriptor()["outputSchema"]["properties"]))
        self.assertEqual((receipt["state"],receipt["size"],receipt["sha256"]),("staged",len(raw),bridge.digest(raw)))
        self.assertFalse(receipt["nas_write_performed"]);self.assertTrue(receipt["write_approval_required"])
        self.assertNotIn("download_url",receipt)
        t=self.transfers[-1]
        with t.claim_source(ref=t.ref,operation_id=t.operation_id,fence=t.fence) as source:
            self.assertEqual(source.read(0,len(raw)),raw)
        self.assertEqual(len(self.factory_calls),1)

    def test_one_mib_http_to_32_original_transfer_chunks(self):
        raw=bytes(range(256))*4096;counts=[];original=FileTransfer.append
        def append(t,**kw):counts.append(kw);return original(t,**kw)
        with self.transport(response(raw)),patch.object(FileTransfer,"append",append):
            r=imp.import_attachment(payload(),verify=lambda:None,create_transfer=self.factory)
        self.assertEqual(r["sha256"],bridge.digest(raw));self.assertEqual(len(counts),32)
        self.assertEqual([c["offset"] for c in counts],list(range(0,len(raw),32768)))
        self.assertTrue(all(len(c["data_base64"])<=43692 for c in counts))

    def test_inspection_streams_larger_than_upload_mvp_without_retaining_bytes(self):
        raw=b'x'*(2*1024*1024)
        v=payload()
        with self.transport(response(raw)):
            receipt=imp.inspect_attachment({'operation_id':v['operation_id'],'file':v['file']},verify=lambda:None)
        self.assertEqual((receipt['size'],receipt['sha256']),(len(raw),bridge.digest(raw)))
        self.assertFalse(receipt['stored'])
        self.assertEqual(self.factory_calls,[])

    def test_empty_file_checks_complete_response(self):
        with self.transport(response(b"")):
            r=imp.import_attachment(payload(),verify=lambda:None,create_transfer=self.factory)
        self.assertEqual((r["size"],r["sha256"]),(0,bridge.digest(b"")))

    def test_no_content_length_and_chunked_supported_with_cap(self):
        for headers,chunked in (([],False),([("Transfer-Encoding","chunked")],True)):
            with self.transport(response(b"x"*40001,headers=headers,chunked=chunked)):
                self.assertEqual(self.fetch().data,b"x"*40001)

    def test_too_large_declared_or_streamed_rejected_before_staging(self):
        cases=[response(b"x",headers=[("Content-Length",str(bridge.MAX_BYTES+1))]),
               response(b"x"*(bridge.MAX_BYTES+1),headers=[]),
               response(b"x"*(bridge.MAX_BYTES+1),headers=[("Transfer-Encoding","chunked")],chunked=True)]
        for raw in cases:
            with self.transport(raw):
                self.fault("attachment_too_large",lambda:imp.import_attachment(payload(),verify=lambda:None,create_transfer=self.factory))
        self.assertFalse(self.factory_calls)

    def test_duplicate_ambiguous_compressed_headers_rejected(self):
        for headers in ([("Content-Length","1"),("Content-Length","1")],
                        [("Content-Length","-1")],[("Content-Length","nan")],
                        [("Content-Encoding","gzip")],
                        [("Transfer-Encoding","gzip")],
                        [("Transfer-Encoding","chunked"),("Content-Length","1")]):
            with self.transport(response(b"x",headers=headers)):
                self.fault("attachment_response_invalid",lambda:self.fetch())

    def test_truncated_response_rejected(self):
        with self.transport(response(b"x",headers=[("Content-Length","2")])):
            self.fault("attachment_truncated",lambda:self.fetch())

    def test_redirect_and_expired_url_never_follow_or_retry(self):
        for status in (301,302,307,308,401,403,404,500):
            before=len(self.sockets)
            with self.transport(response(b"",status=status,headers=[("Location","http://127.0.0.1/private")])):
                self.fault("attachment_unavailable",lambda:self.fetch())
            self.assertEqual(len(self.sockets),before+1)

    def test_private_dns_mixed_answers_and_mapped_ips_rejected(self):
        for ips in (("127.0.0.1",),("169.254.169.254",),("10.0.0.1",),("::1",),
                    ("8.8.8.8","10.1.1.1"),("::ffff:8.8.8.8",),()):
            with self.transport(response(),ips=ips):
                self.fault("attachment_dns_rejected",lambda:self.fetch())
        self.assertFalse(self.connections)

    def test_real_http_parser_request_no_proxy_auth_cookies_or_redirect(self):
        with self.transport(response(b"x")),patch.dict(os.environ,{"HTTPS_PROXY":"http://127.0.0.1:1","HTTP_PROXY":"http://127.0.0.1:1"}):
            self.assertEqual(self.fetch().data,b"x")
        sent=b"".join(self.sockets[-1].sent)
        self.assertIn(b"GET /file_synthetic?sig=synthetic HTTP/1.1",sent)
        self.assertIn(b"Host: files.oaiusercontent.com",sent)
        self.assertIn(b"Accept-Encoding: identity",sent)
        self.assertNotIn(b"Authorization",sent);self.assertNotIn(b"Cookie",sent)
        self.assertEqual(self.connections[-1]._ip,"8.8.8.8")
        self.assertTrue(self.sockets[-1].closed)

    def test_real_pinned_socket_uses_original_sni_and_tls_verification(self):
        source=imp._PinnedHTTPS(imp.FILE_HOST,"8.8.8.8",3)
        raw=FakeSocket(b"");tls=FakeSocket(b"")
        class TLSContext:
            def wrap_socket(self,sock,server_hostname):
                self_hostname.append(server_hostname);self_sock.append(sock);return tls
        self_hostname=[];self_sock=[];source._context=TLSContext()
        with patch.object(imp.socket,"create_connection",return_value=raw) as connect:
            source.connect()
        connect.assert_called_once_with(("8.8.8.8",443),timeout=3)
        self.assertEqual(self_hostname,[imp.FILE_HOST]);self.assertEqual(self_sock,[raw])
        source.close()

    def test_revocation_before_dns_and_missing_verifier_are_closed(self):
        calls=[]
        def revoked():raise bridge.BridgeFault("revoked")
        with patch.object(imp,"_addresses",side_effect=lambda *a:calls.append(a)):
            self.fault("revoked",lambda:self.fetch(verify=revoked))
            self.fault("verified_caller_required",lambda:imp.import_attachment(payload(),verify=None,create_transfer=self.factory))
        self.assertFalse(calls);self.assertFalse(self.factory_calls)

    def test_deadline_clock_rollback_and_nonfinite(self):
        for times in ([0,20],[10,9],[float("nan")],[0,float("inf")]):
            clock=iter(times)
            with self.transport(response(b"x")):
                self.fault("attachment_expired",lambda:self.fetch(clock=lambda:next(clock)))
        self.assertFalse(self.connections)

    def test_transport_failure_is_finite_and_never_retried(self):
        with self.transport(response()),patch.object(imp._PinnedHTTPS,"request",side_effect=TimeoutError("sig=secret")):
            self.fault("attachment_fetch_failed",lambda:self.fetch())
        self.assertEqual(len(self.connections),1);self.assertFalse(self.factory_calls)

    def test_wrong_owner_transfer_is_not_modified_or_closed(self):
        v=payload();wrong=self.factory(operation_id=str(uuid.uuid4()),fence=ScopeFence("synthetic",1,"e"*32),
            name="other.txt",size=1,sha256=bridge.digest(b"x"))
        with self.transport(response(b"x")):
            self.fault("binding_mismatch",lambda:imp.import_attachment(v,verify=lambda:None,create_transfer=lambda **kw:wrong))
        self.assertFalse(wrong.broken);self.assertGreaterEqual(wrong.fd,0);self.assertEqual(wrong.offset,0)

    def test_stage_revocation_closes_only_new_original_transfer(self):
        def factory(**kw):
            t=self.factory(**kw)
            original=t.append
            def revoked(**args):
                original(**args);raise bridge.BridgeFault("revoked")
            t.append=revoked;return t
        with self.transport(response(b"x"*40000)):
            self.fault("revoked",lambda:imp.import_attachment(payload(),verify=lambda:None,create_transfer=factory))
        t=self.transfers[-1];self.assertTrue(t.broken);self.assertEqual(t.fd,-1)
        self.assertFalse(any(p.name.startswith("file_transfer_") for p in self.home.iterdir()))


if __name__=="__main__":unittest.main(verbosity=2)
