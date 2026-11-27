"""Private upload command implementation. No standalone entrypoint or credential access."""
import asyncio, base64, hashlib, os, stat, tempfile, time, uuid
from dataclasses import asdict
from arl_nas_upload_new.contracts import UploadPlan, OwnerBinding, OwnerBoundary, UploadFault, canonical, MAX_BYTES
from arl_nas_upload_new.source import SealedSource
from arl_nas_upload_new.journal import UploadJournal
from arl_nas_upload_new.storage import UploadNewStorage
from smb_upload_new import SMBUploadNewMedium
from integrations.nas.file_params_importer import file_param, fetch, BridgeFault


async def stage_attachment(host, frame):
    if (set(frame) != {"kind","id","nonce","operation_id","file"} or frame["nonce"] != host.wire.nonce
            or type(frame["id"]) is not int or host.connection is None):
        raise UploadFault("binding_mismatch")
    operation = frame["operation_id"]
    if type(operation) is not str or str(uuid.UUID(operation)) != operation:
        raise UploadFault("invalid_plan")
    if host.upload_source is not None:
        host.upload_source[3].close()
        host.upload_source = None
    connection, authority = host.connection, host.authority
    await connection.credentials.check("request")
    def verify():
        host.wire.verify()
        if (host.connection is not connection or host.authority is not authority
                or authority.revoked or time.monotonic() >= authority.deadline):
            raise UploadFault("revoked")
    def receive():
        source = file_param(frame["file"])
        spool = tempfile.TemporaryFile(prefix="arl-mio-upload-")
        try:
            size, sha256 = fetch(source, verify=verify, output=spool)
            if not 0 <= size <= MAX_BYTES:
                raise UploadFault("source_too_large")
            spool.flush()
            return size, sha256, spool
        except BaseException:
            spool.close()
            raise
    job = asyncio.create_task(asyncio.to_thread(receive))
    try:
        size, sha256, spool = await asyncio.shield(job)
    except BridgeFault as error:
        return {"error": error.code}
    except asyncio.CancelledError:
        def discard(task):
            if not task.cancelled() and task.exception() is None:
                task.result()[2].close()
        job.add_done_callback(discard)
        raise
    try:
        verify()
        await connection.credentials.check("request_reply")
        verify()
    except BaseException:
        spool.close()
        raise
    host.upload_source = (operation, size, sha256, spool)
    return {"size": size, "sha256": sha256}

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
    attachment = "staged" in frame
    if set(frame)!={"kind","id","nonce","plan","staged" if attachment else "source","journal"} or frame["nonce"]!=host.wire.nonce:
        raise UploadFault("binding_mismatch")
    if host.connection is None or host.transport is None or host.transport.reader is None:
        raise UploadFault("revoked")
    plan=UploadPlan(**frame["plan"])
    scope=host.connection.credentials.scope;caller=host.authority.caller
    if (plan.scope_hash!=hashlib.sha256(canonical(asdict(scope))).hexdigest()
        or plan.namespace_hash!=scope.root_descriptor_digest or plan.credential_generation!=scope.credential_generation
        or plan.registration_epoch!=caller.registration_epoch):
        raise UploadFault("binding_mismatch")
    staged = None
    if attachment:
        staged = host.upload_source
        if frame["staged"] is not True or staged is None or staged[:3] != (plan.operation_id, plan.size, plan.sha256):
            raise UploadFault("source_changed")
        host.upload_source = None
    else:
        raw=base64.b64decode(frame["source"],validate=True)
        if len(raw)>MAX_BYTES or len(raw)!=plan.size or hashlib.sha256(raw).hexdigest()!=plan.sha256:
            raise UploadFault("source_changed")
    plan_digest=hashlib.sha256(canonical(plan.metadata())).hexdigest()
    loop=asyncio.get_running_loop()
    connection, authority = host.connection, host.authority
    last_authorized = float("-inf")
    def authorize(stage,*,consume=False):
        nonlocal last_authorized
        host.wire.verify()
        if (host.connection is not connection or host.authority is not authority
                or authority.revoked or time.monotonic() >= authority.deadline):
            raise UploadFault("revoked")
        # The sealed attachment still checks the live pipe, source FD, and SMB
        # identity at every guard. Ask Swift for a fresh full verification at
        # irreversible boundaries and periodically during the private stage.
        # Layered read/digest/fsync guards within one phase otherwise repeat
        # the same signature and Keychain checks thousands of times per file.
        if (staged is not None and not consume
                and stage not in {"upload_prepare", "create_effect", "commit_effect", "publish_after_identity_after_seals"}
                and time.monotonic()-last_authorized < 1):
            return
        future=asyncio.run_coroutine_threadsafe(host.wire.authorize(stage,scope,caller,
            upload_digest=plan_digest,consume=consume),loop)
        try:
            future.result(timeout=5)
            last_authorized = time.monotonic()
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
            if staged is not None:
                source=SealedSource(staged[3].fileno(),verify_pin=lambda:authorize("source_seal"),unlinked=True)
            else:
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
            if staged is not None:staged[3].close()
            # Own local input only. No remote deletion or journal reset.
            if source_fd>=0:
                try:os.unlink(filename)
                except OSError:pass
    return await asyncio.to_thread(run)
