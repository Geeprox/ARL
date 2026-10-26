"""Private upload command implementation. No standalone entrypoint or credential access."""
import asyncio, base64, hashlib, os, stat, time
from dataclasses import asdict
from arl_nas_upload_new.contracts import UploadPlan, OwnerBinding, OwnerBoundary, UploadFault, canonical, MAX_BYTES
from arl_nas_upload_new.source import SealedSource
from arl_nas_upload_new.journal import UploadJournal
from arl_nas_upload_new.storage import UploadNewStorage
from smb_upload_new import SMBUploadNewMedium

def directory_fd(value):
    if type(value) is not dict or set(value)!={"path","dev","ino"} or type(value["path"]) is not str or not value["path"].startswith("/"):
        raise UploadFault("journal_uncertain")
    fd=os.open("/",os.O_RDONLY|os.O_DIRECTORY)
    try:
        for part in value["path"].split("/")[1:]:
            if part in ("",".",".."):raise UploadFault("journal_uncertain")
            child=os.open(part,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=fd)
            os.close(fd);fd=child
        row=os.fstat(fd)
        if row.st_dev!=value["dev"] or row.st_ino!=value["ino"] or row.st_uid!=os.getuid() or stat.S_IMODE(row.st_mode)!=0o700:
            raise UploadFault("journal_uncertain")
        result=fd;fd=-1;return result
    finally:
        if fd>=0:os.close(fd)

async def upload_new(host,frame):
    if set(frame)!={"kind","id","nonce","plan","source","journal"} or frame["nonce"]!=host.wire.nonce:
        raise UploadFault("binding_mismatch")
    if host.connection is None or host.transport is None or host.transport.reader is None:
        raise UploadFault("revoked")
    plan=UploadPlan(**frame["plan"])
    scope=host.connection.credentials.scope;caller=host.authority.caller
    if (plan.scope_hash!=hashlib.sha256(canonical(asdict(scope))).hexdigest()
        or plan.namespace_hash!=scope.root_descriptor_digest or plan.credential_generation!=scope.credential_generation
        or plan.registration_epoch!=caller.registration_epoch):
        raise UploadFault("binding_mismatch")
    raw=base64.b64decode(frame["source"],validate=True)
    if len(raw)>MAX_BYTES or len(raw)!=plan.size or hashlib.sha256(raw).hexdigest()!=plan.sha256:
        raise UploadFault("source_changed")
    plan_digest=hashlib.sha256(canonical(plan.metadata())).hexdigest()
    loop=asyncio.get_running_loop()
    def authorize(stage,*,consume=False):
        if host.authority.revoked or host.connection is None:raise UploadFault("revoked")
        future=asyncio.run_coroutine_threadsafe(host.wire.authorize(stage,scope,caller,
            upload_digest=plan_digest,consume=consume),loop)
        try:future.result(timeout=5)
        except BaseException:
            future.cancel()
            raise UploadFault("revoked") from None
    def run():
        journal=source=medium=None;fd=source_fd=-1
        filename="upload-source-"+plan.operation_id
        try:
            authorize("upload_prepare")
            fd=directory_fd(frame["journal"])
            journal=UploadJournal(fd,verify_seal=lambda:authorize("journal_seal"))
            source_fd=os.open(filename,os.O_RDWR|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
            offset=0
            while offset<len(raw):
                count=os.write(source_fd,raw[offset:])
                if count<=0:raise UploadFault("source_changed")
                offset+=count
            os.fsync(source_fd)
            source=SealedSource(source_fd,verify_pin=lambda:authorize("source_seal"))
            binding=OwnerBinding.for_plan(plan)
            owner=OwnerBoundary(plan=plan,admitted=True,verify=authorize,current_binding=lambda:binding,
                consume_existing=lambda _:authorize("consume",consume=True),lifetime=30)
            medium=SMBUploadNewMedium(reader=host.transport.reader,plan=plan,verify=authorize,deadline=time.monotonic()+30)
            return asdict(UploadNewStorage(journal=journal,medium=medium).upload(plan,source,owner))
        finally:
            if medium is not None:medium.close()
            if source is not None:source.close()
            if journal is not None:journal.close()
            if source_fd>=0:os.close(source_fd)
            if fd>=0:os.close(fd)
            # Own local input only. No remote deletion or journal reset.
            if source_fd>=0:
                try:os.unlink(filename)
                except OSError:pass
    return await asyncio.to_thread(run)
