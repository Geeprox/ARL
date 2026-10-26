"""Run actual staged NAS host and parsers with an injected synthetic SMB transport."""
import asyncio
import base64
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import time
from types import SimpleNamespace

runtime = Path(sys.argv[1]).resolve()
fixtures = Path(sys.argv[2]).resolve()
expected = {r["format"]: r for r in json.loads((fixtures.parent/"CASE-RESULTS.json").read_text())}
sys.path.insert(0, str(runtime/"Runtime"))
from nas_host import NativeRuntimeHost
from homeplane.nas_connection.contracts import NASConnectionConfig
from homeplane.nas_connection.manager import NASConnectionManager
import nas_document_host
from integrations.nas import document_text, attachment_bridge

async def main():
    reports = []
    for kind in ("pdf", "docx", "xlsx", "pptx"):
        filename = "arl-document-fixture."+kind
        raw = (fixtures/filename).read_bytes()
        calls = []
        revision = hashlib.sha256(raw).hexdigest()
        class Transport:
            async def request(self, op, payload):
                calls.append(op)
                if op == "list":
                    entries = ([dict(path="sub",kind="directory",size=0,revision="a"*64)]
                               if payload["path"] == "" else
                               [dict(path="sub/"+filename,kind="file",size=len(raw),revision=revision)])
                    return dict(entries=entries,complete=True)
                if op == "stat":
                    return dict(path=payload["path"],kind="file",size=len(raw),revision=revision)
                if op == "read":
                    return dict(data=base64.b64encode(raw[payload["offset"]:payload["offset"]+payload["length"]]).decode())
                raise AssertionError(op)
            async def close(self): pass
        with tempfile.TemporaryDirectory(prefix="arl-packaged-document-") as tmp:
            manager = NASConnectionManager(Path(tmp).resolve()/"unused",credential_resolver=None)
            manager.config = NASConnectionConfig(source_ref="synthetic",transport="smb",host="synthetic.invalid",share="home",root="ARL-Test",credential_ref="unused",enabled=True)
            manager.generation=1;manager._epoch="e"*32;manager._state="online";manager._transport=Transport()
            async def check(stage): pass
            host = NativeRuntimeHost(SimpleNamespace(nonce="n"*32))
            host.connection=SimpleNamespace(manager=manager,credentials=SimpleNamespace(check=check))
            host.authority=SimpleNamespace(deadline=time.monotonic()+120,revoked=False)
            fence=dict(source_ref="synthetic",config_generation=1,connection_epoch="e"*32)
            found=await host.command(dict(kind="files",id=2,nonce="n"*32,request=dict(fence,operation="search_recursive",keyword=filename,recursive=True,limit=32)))
            entry=found["entries"][0]
            request=dict(fence,operation="read_document",name=filename,**{k:entry[k] for k in ("object_ref","revision","size")})
            calls.clear()
            result=await host.command(dict(kind="files",id=3,nonce="n"*32,request=request))
            assert result["text"]==expected[kind]["text"],(kind,result)
            assert result["source_sha256"]==hashlib.sha256(raw).hexdigest()
            assert result["complete"] is True and result["downloadable_artifact"] is False
            assert calls==["stat","read","stat"] and manager._file_bytes==len(raw)
            reports.append(dict(format=kind,source_size=len(raw),source_sha256=result["source_sha256"],text=result["text"],transport_calls=calls,default_packaged_worker=True))
    modules=[Path(m.__file__).resolve() for m in (nas_document_host,document_text,attachment_bridge)]
    assert all(p.is_relative_to(runtime) for p in modules)
    print(json.dumps(dict(status="PASS",formats=reports,module_paths=list(map(str,modules)),real_NAS=False,credentials=False,network=False),ensure_ascii=False,indent=2))

asyncio.run(main())
