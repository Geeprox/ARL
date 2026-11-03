"""Fixed six-file acceptance behind the existing native credential pipe.

No generic name/body/path/delete interface exists. Both phases require the
frozen manifest hash, exact existing home/ARL-Test scope, live native callbacks
and one native-pinned private journal. Files are created without replacement.
"""
import asyncio
import fcntl
import hashlib
import json
import os
from pathlib import Path
import stat
import time
import uuid
from dataclasses import asdict

from arl_nas_upload_new.contracts import UploadPlan, UploadFault, canonical
from homeplane.nas_connection.contracts import NASConnectionError
from nas_acceptance_samples import MANIFEST, MANIFEST_SHA256, files
from nas_upload_host import directory_fd
from smb_upload_new import SMBUploadNewMedium, SMBUploadHandle

ACCEPTANCE_SECONDS = 90.0
CHECKPOINT_SECONDS = 30.0


def fail(code):
    raise UploadFault(code)


def finite(error):
    code=getattr(error,'code',None)
    return code if type(code) is str and 1 <= len(code) <= 96 and all(c in 'abcdefghijklmnopqrstuvwxyz_' for c in code) else 'nas_transport_failed'


class Journal:
    def __init__(self, fd, binding):
        self.fd=fd;self.binding=binding
        self.lock=os.open('acceptance.lock',os.O_RDWR|os.O_CREAT|os.O_NOFOLLOW,0o600,dir_fd=fd)
        info=os.fstat(self.lock)
        if not stat.S_ISREG(info.st_mode) or info.st_uid!=os.getuid() or info.st_nlink!=1 or stat.S_IMODE(info.st_mode)!=0o600:
            fail('journal_uncertain')
        try:fcntl.flock(self.lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except OSError:os.close(self.lock);fail('journal_uncertain')
        self.value=self.read()

    def read(self):
        try:fd=os.open('acceptance.json',os.O_RDONLY|os.O_NOFOLLOW,dir_fd=self.fd)
        except FileNotFoundError:return dict(schema_version=1,binding=self.binding,files={})
        try:
            info=os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid!=os.getuid() or info.st_nlink!=1 or stat.S_IMODE(info.st_mode)!=0o600 or info.st_size>65536:
                fail('journal_uncertain')
            raw=os.read(fd,65537)
            if len(raw)!=info.st_size:fail('journal_uncertain')
            value=json.loads(raw)
        finally:os.close(fd)
        if (type(value) is not dict or set(value)!={'schema_version','binding','files'} or value['schema_version']!=1
                or type(value['schema_version']) is not int or value['binding']!=self.binding or type(value['files']) is not dict):
            fail('journal_uncertain')
        expected={r['name']:r for r in MANIFEST['files']}
        for name,row in value['files'].items():
            if (name not in expected or type(row) is not dict
                    or set(row)!={'state','identity','revision','object_ref','error'}
                    or row['state'] not in {'creating','created_verified','deleting','deleted','not_created','unknown','target_changed'}):
                fail('journal_uncertain')
            for key in ('identity','revision','object_ref'):
                item=row[key]
                if item is not None and (type(item) is not str or len(item)!=64 or any(c not in '0123456789abcdef' for c in item)):
                    fail('journal_uncertain')
            if row['state'] in {'created_verified','deleted','deleting','target_changed'} and any(row[k] is None for k in ('identity','revision','object_ref')):
                fail('journal_uncertain')
        return value

    def save(self):
        raw=json.dumps(self.value,sort_keys=True,separators=(',',':')).encode()
        name='acceptance-'+uuid.uuid4().hex+'.tmp'
        fd=os.open(name,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600,dir_fd=self.fd)
        try:
            offset=0
            while offset<len(raw):
                size=os.write(fd,raw[offset:])
                if size<=0:fail('journal_uncertain')
                offset+=size
            os.fsync(fd)
            os.rename(name,'acceptance.json',src_dir_fd=self.fd,dst_dir_fd=self.fd)
            os.fsync(self.fd)
        finally:
            os.close(fd)
            try:os.unlink(name,dir_fd=self.fd)
            except FileNotFoundError:pass

    def close(self):os.close(self.lock)


class Medium(SMBUploadNewMedium):
    def __init__(self, *, reader, plan, authorize):
        super().__init__(reader=reader,plan=plan,
            verify=lambda _:authorize('acceptance_check',medium_deadline=self.deadline),deadline=time.monotonic()+30)
        self.require_atomic_new()

    def existing(self):
        from smbprotocol.open import Open,ImpersonationLevel,FilePipePrinterAccessMask as Access,FileAttributes,ShareAccess,CreateDisposition,CreateOptions
        self._namespace()
        raw=Open(self.reader.tree,self._full(self.plan.target).replace('/','\\'))
        try:
            self._effect()
            raw.create(ImpersonationLevel.Impersonation,Access.DELETE|Access.FILE_READ_DATA|Access.FILE_READ_ATTRIBUTES,
                FileAttributes.FILE_ATTRIBUTE_NORMAL,ShareAccess.FILE_SHARE_READ,CreateDisposition.FILE_OPEN,
                CreateOptions.FILE_NON_DIRECTORY_FILE|CreateOptions.FILE_OPEN_REPARSE_POINT)
            self._effect();self._probe(raw)
            handle=SMBUploadHandle(self,raw,writable=False);self.handles.append(handle)
            return handle
        except BaseException:
            if raw.connected:raw.close()
            raise

    def create(self):
        self._namespace()
        raw=self._open(self._full(self.plan.target),create=True)
        handle=SMBUploadHandle(self,raw,writable=True);self.handles.append(handle)
        return handle

    def information(self, handle):
        identity,_,size=self._probe(handle.raw)
        entry=self.reader._stat_handle(self.plan.target,handle.raw)
        self._namespace()
        return identity,entry,size

    def contents(self, handle):
        result=bytearray()
        for offset in range(0,self.plan.size,32768):
            raw=handle.read(offset,min(32768,self.plan.size-offset),effect_check=lambda:None)
            if len(raw)!=min(32768,self.plan.size-offset):fail('integrity_failed')
            result.extend(raw)
        return bytes(result)

    def delete(self,handle):
        from smbprotocol.file_info import FileDispositionInformation
        from smbprotocol.open import SMB2SetInfoRequest,SMB2SetInfoResponse
        self._namespace();self._effect()
        value=FileDispositionInformation();value['delete_pending']=True
        request=SMB2SetInfoRequest();request['info_type'],request['file_info_class']=value.INFO_TYPE,value.INFO_CLASS
        request['file_id'],request['buffer']=handle.raw.file_id,value.pack()
        self._effect()
        token=self.reader.connection.send(request,sid=self.reader.session.session_id,tid=self.reader.tree.tree_connect_id)
        response=SMB2SetInfoResponse();response.unpack(self.reader.connection.receive(token)['data'].get_value())
        handle.close()  # Disposition targets the retained exact open object.
        self.handles.remove(handle)
        for _,parent,_ in self.parents:parent.flush()
        self._effect()
        try:self.reader.stat(self.plan.target)
        except BaseException as error:
            from homeplane.nas_connection.worker import error_code
            if error_code(error)!='nas_missing':raise
        else:fail('cleanup_unconfirmed')


class Engine:
    """Constructor-only injected transport seam for offline validation."""
    def __init__(self,journal,medium,parse,object_ref,authorize):
        self.journal,self.medium,self.parse,self.object_ref,self.authorize=journal,medium,parse,object_ref,authorize
        self.raw=files();self.consumed=False

    def consume(self):
        if not self.consumed:self.authorize('acceptance_consume',consume=True);self.consumed=True

    def run(self,phase):
        if phase not in {'create','cleanup'}:fail('invalid_plan')
        rows=self.journal.value['files'];specs=MANIFEST['files']
        if phase=='create':
            if rows:return self.report(phase,'blocked')
            # All six names are checked before the first possible creation.
            for spec in specs:
                try:
                    with self.medium(spec) as medium:medium.assert_absent(spec['name'],effect_check=lambda:None)
                except BaseException as error:
                    rows[spec['name']]=dict(state='not_created',identity=None,revision=None,object_ref=None,
                        error='target_exists' if isinstance(error,FileExistsError) else finite(error))
                    # No creation was attempted; this in-memory refusal is not a
                    # consumed mutation. A later explicit command may recheck.
                    return self.report(phase,'blocked')
        for spec in specs:
            name=spec['name'];row=rows.get(name)
            if phase=='cleanup' and row is None:continue
            if phase=='cleanup' and row['state']=='deleted':
                try:
                    with self.medium(spec) as medium:medium.assert_absent(name,effect_check=lambda:None)
                except BaseException:
                    row.update(state='target_changed',error='target_reappeared');self.journal.save()
                continue
            if phase=='cleanup' and row['state']!='created_verified':continue
            try:
                with self.medium(spec) as medium:
                    if phase=='create':
                        row=rows[name]=dict(state='creating',identity=None,revision=None,object_ref=None,error=None)
                        self.journal.save();self.consume()
                        try:handle=medium.create()
                        except FileExistsError:
                            row.update(state='not_created',error='target_exists');self.journal.save();break
                        for offset in range(0,spec['size'],32768):
                            chunk=self.raw[name][offset:offset+32768]
                            if handle.write(offset,chunk,effect_check=lambda:None)!=len(chunk):fail('io_uncertain')
                        handle.flush(effect_check=lambda:None)
                        identity,entry,size=medium.information(handle)
                        actual=medium.contents(handle)
                        if size!=spec['size'] or hashlib.sha256(actual).hexdigest()!=spec['sha256']:fail('integrity_failed')
                        after_identity,after,size=medium.information(handle)
                        if after_identity!=identity or after['revision']!=entry['revision']:fail('source_changed')
                        row.update(state='created_verified',identity=identity,revision=entry['revision'],object_ref=self.object_ref(entry),error=None)
                        self.journal.save()
                        if spec['document_format'] is not None:self.parse(spec,actual)
                    else:
                        handle=medium.existing()
                        identity,entry,size=medium.information(handle)
                        if identity!=row['identity'] or entry['revision']!=row['revision'] or size!=spec['size']:
                            row.update(state='target_changed',error='source_changed');self.journal.save();continue
                        if hashlib.sha256(medium.contents(handle)).hexdigest()!=spec['sha256']:
                            row.update(state='target_changed',error='integrity_failed');self.journal.save();continue
                        after_identity,after,_=medium.information(handle)
                        if after_identity!=row['identity'] or after['revision']!=row['revision']:fail('source_changed')
                        self.consume();row['state']='deleting';self.journal.save()
                        medium.delete(handle)
                        row.update(state='deleted',error=None);self.journal.save()
            except BaseException as error:
                if row is not None and row['state'] in {'creating','deleting'}:
                    row.update(state='unknown',error=finite(error));self.journal.save()
                elif row is not None:row['error']=finite(error);self.journal.save()
                break
        expected='created_verified' if phase=='create' else 'deleted'
        complete=len(rows)==len(specs) and all(row['state']==expected and row['error'] is None for row in rows.values())
        return self.report(phase,'complete' if complete else 'needs_review')

    def report(self,phase,state):
        result=[]
        for spec in MANIFEST['files']:
            row=self.journal.value['files'].get(spec['name'])
            result.append(dict(name=spec['name'],size=spec['size'],sha256=spec['sha256'],
                state='not_started' if row is None else ('unknown' if row['state'] in {'creating','deleting'} else row['state']),
                object_ref=row['object_ref'] if row else None,revision=row['revision'] if row else None,
                object_identity=row['identity'] if row else None,error=row['error'] if row else None))
        return dict(schema_version=1,operation='nas_acceptance',phase=phase,manifest_sha256=MANIFEST_SHA256,
                    state=state,files=result,automatic_replay=False,read_scope_changed=False)


async def execute(host,frame):
    if (set(frame)!={'kind','id','nonce','phase','manifest_sha256','journal'} or frame['kind']!='acceptance'
            or frame['nonce']!=host.wire.nonce or type(frame['id']) is not int
            or frame['phase'] not in {'create','cleanup'} or frame['manifest_sha256']!=MANIFEST_SHA256
            or host.connection is None or host.transport is None or host.transport.reader is None):
        raise NASConnectionError('nas_invalid_request')
    config=host.connection.manager.config
    if config.share!='home' or config.root!='ARL-Test':raise NASConnectionError('nas_access_denied')
    connection,transport=host.connection,host.transport
    reader=transport.reader
    scope=connection.credentials.scope;caller=host.authority.caller;phase=frame['phase']
    plan_digest=hashlib.sha256((MANIFEST_SHA256+'\0'+phase).encode()).hexdigest()
    loop=asyncio.get_running_loop()
    deadline=min(host.authority.deadline,time.monotonic()+ACCEPTANCE_SECONDS)
    active_medium_deadline=None
    def remaining():
        if (host.authority.revoked or host.connection is not connection
                or host.transport is not transport or transport.reader is not reader):fail('revoked')
        value=deadline-time.monotonic()
        if value<=0:fail('expired')
        return value
    def authorize(stage,consume=False,*,medium_deadline=None):
        nonlocal deadline
        # Strict native signature/resource validation can exceed five seconds.
        # Bound this one wait by the original phase/pipe lease, never retry it.
        current_medium=active_medium_deadline
        if medium_deadline is not None:
            current_medium=medium_deadline if current_medium is None else min(current_medium,medium_deadline)
        def checkpoint_remaining():
            value=remaining()
            if current_medium is not None:value=min(value,current_medium-time.monotonic())
            if value<=0:fail('expired')
            return value
        budget=min(CHECKPOINT_SECONDS,checkpoint_remaining())
        future=asyncio.run_coroutine_threadsafe(host.wire.authorize(stage,scope,caller,
            upload_digest=plan_digest,consume=consume,timeout_seconds=budget),loop)
        try:reply=future.result(timeout=budget)
        except TimeoutError:future.cancel();fail('expired')
        except BaseException:future.cancel();fail('revoked')
        checkpoint_remaining()
        native_remaining=reply.get('remaining_seconds') if type(reply) is dict else None
        if type(native_remaining) not in (int,float) or not 0<native_remaining<=120:fail('revoked')
        deadline=min(deadline,time.monotonic()+native_remaining)
        checkpoint_remaining()
    def run():
        fd=-1;journal=None
        try:
            authorize('acceptance_prepare')
            fd=directory_fd(frame['journal'])
            journal=Journal(fd,dict(manifest=MANIFEST_SHA256,scope=asdict(scope)))
            def make_medium(spec):
                plan=UploadPlan(operation_id=str(uuid.uuid5(uuid.NAMESPACE_URL,MANIFEST_SHA256+spec['name'])),
                    permit_id=str(uuid.uuid5(uuid.NAMESPACE_DNS,MANIFEST_SHA256+spec['name'])),
                    scope_hash=hashlib.sha256(canonical(asdict(scope))).hexdigest(),namespace_hash=scope.root_descriptor_digest,
                    credential_generation=scope.credential_generation,registration_epoch=caller.registration_epoch,
                    target=spec['name'],size=spec['size'],sha256=spec['sha256'])
                medium=Medium(reader=reader,plan=plan,authorize=authorize)
                class Managed:
                    def __enter__(self):
                        nonlocal active_medium_deadline
                        self.previous=active_medium_deadline
                        active_medium_deadline=medium.deadline if self.previous is None else min(self.previous,medium.deadline)
                        return medium
                    def __exit__(self,*_):
                        nonlocal active_medium_deadline
                        try:medium.close()
                        finally:active_medium_deadline=self.previous
                return Managed()
            def parse(spec,raw):
                from integrations.nas.attachment_bridge import VerifiedFile
                from integrations.nas.document_text import extract_document
                helper=Path(__file__).resolve().parent.parent/'Tools/NASPDFTextExtractor'
                result=extract_document(VerifiedFile(spec['name'],raw,spec['sha256']),pdf_helper=helper)
                if result['complete'] is not True or result['source_sha256']!=spec['sha256'] or not all(text in result['text'] for text in spec['expected_text']):
                    fail('document_acceptance_mismatch')
            return Engine(journal,make_medium,parse,lambda entry:connection.manager._entry(entry).object_ref,authorize).run(phase)
        finally:
            if journal is not None:journal.close()
            if fd>=0:os.close(fd)
    return await asyncio.to_thread(run)
