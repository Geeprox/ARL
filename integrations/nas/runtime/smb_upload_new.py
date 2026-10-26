"""SMB 3 upload-new medium for the existing bounded storage algorithm.

Private constructor only: the native owner supplies an already scoped SMBReader,
exact UploadPlan, live verify callback and deadline. No resolver, listener, CLI,
retry, overwrite, delete or grant parser is exposed here.
"""
import hashlib
import time
import uuid
from smbprotocol import Dialects
from smbprotocol.exceptions import ObjectNameCollision, ObjectNameNotFound, ObjectPathNotFound
from smbprotocol.file_info import FileBasicInformation, FileInternalInformation, FileStandardInformation, FileRenameInformation
from smbprotocol.open import (Open, CreateDisposition, CreateOptions, FileAttributes,
    FilePipePrinterAccessMask as Access, DirectoryAccessMask as Directory, ImpersonationLevel,
    ShareAccess, SMB2SetInfoRequest, SMB2SetInfoResponse)
from arl_nas_upload_new.contracts import UploadFault, UploadPlan, canonical, CHUNK_BYTES, MAX_BYTES


class SMBUploadNewMedium:
    def __init__(self, *, reader, plan, verify, deadline, clock=time.monotonic):
        if type(plan) is not UploadPlan or not callable(verify) or not clock() < deadline <= clock()+30:
            raise UploadFault("unsupported")
        self.reader, self.plan, self.verify = reader, plan, verify
        self.deadline, self.clock = deadline, clock
        self.parents = []
        self.handles = []
        self.prepared = self.closed = False

    def check(self):
        if self.closed or self.clock() >= self.deadline:
            raise UploadFault("expired")
        self.verify("smb_medium")
        if self.reader.tree is None or self.reader.tree.is_dfs_share:
            raise UploadFault("source_changed")

    def check_namespace(self, namespace):
        self.check()
        if namespace != self.plan.namespace_hash:
            raise UploadFault("binding_mismatch")

    def _effect(self, callback=None):
        self.check()
        if callback is not None:
            callback()
        self.check()

    def _full(self, target):
        if target != self.plan.target:
            raise UploadFault("binding_mismatch")
        return "/".join(x for x in (self.reader.root, target) if x)

    def _open(self, path, *, directory=False, create=False, add_file=False, effect_check=None):
        self._effect(effect_check)
        handle=Open(self.reader.tree,path.replace("/","\\"))
        # FILE_TRAVERSE makes retained directory opens participate in sharing checks.
        access=(Access.FILE_READ_ATTRIBUTES | Directory.FILE_TRAVERSE) if directory else Access.FILE_READ_DATA | Access.FILE_READ_ATTRIBUTES
        if add_file:
            access |= Directory.FILE_ADD_FILE
        if create:
            access |= Access.FILE_WRITE_DATA | Access.DELETE
        options=CreateOptions.FILE_OPEN_REPARSE_POINT | (CreateOptions.FILE_DIRECTORY_FILE if directory else CreateOptions.FILE_NON_DIRECTORY_FILE)
        if create:
            options |= CreateOptions.FILE_WRITE_THROUGH
        try:
            handle.create(ImpersonationLevel.Impersonation,access,FileAttributes.FILE_ATTRIBUTE_NORMAL,
                ShareAccess.FILE_SHARE_READ if not create else 0,
                CreateDisposition.FILE_CREATE if create else CreateDisposition.FILE_OPEN,options)
            self._effect(effect_check)
            if handle.file_attributes & FileAttributes.FILE_ATTRIBUTE_REPARSE_POINT:
                raise UploadFault("source_changed")
            return handle
        except (ObjectNameNotFound,ObjectPathNotFound):
            if handle.connected: handle.close()
            raise FileNotFoundError() from None
        except ObjectNameCollision:
            if handle.connected: handle.close()
            raise FileExistsError() from None
        except BaseException:
            if handle.connected: handle.close()
            raise

    def _probe(self, handle, *, directory=False):
        self.check()
        basic=self.reader._query(handle,FileBasicInformation)
        standard=self.reader._query(handle,FileStandardInformation)
        internal=self.reader._query(handle,FileInternalInformation)
        self.check()
        if (basic["file_attributes"].get_value() & FileAttributes.FILE_ATTRIBUTE_REPARSE_POINT
            or standard["delete_pending"].get_value()
            or standard["directory"].get_value() != directory
            or (not directory and standard["number_of_links"].get_value()!=1)):
            raise UploadFault("source_changed")
        index=internal["index_number"].get_value()
        size=standard["end_of_file"].get_value()
        if type(index) is not int or index <= 0 or not directory and not 0 <= size <= MAX_BYTES:
            raise UploadFault("unsupported")
        # Stable across close/reopen and rename, unlike SMB2 volatile FileId.
        identity=hashlib.sha256(canonical({"namespace":self.plan.namespace_hash,
            "server":str(self.reader.connection.server_guid),"index":index,
            "creation":str(basic["creation_time"].get_value())})).hexdigest()
        revision=hashlib.sha256(canonical({"identity":identity,"size":size,
            "write":str(basic["last_write_time"].get_value()),
            "change":str(basic["change_time"].get_value())})).hexdigest()
        return identity,revision,size

    def require_atomic_new(self):
        self.check()
        if self.prepared: return
        connection=self.reader.connection
        if (connection.dialect < Dialects.SMB_3_0_0 or not self.reader.session.encrypt_data
                or not isinstance(connection.server_guid,uuid.UUID)):
            raise UploadFault("unsupported")
        full=self._full(self.plan.target)
        components=full.split("/")[:-1]
        if len(components)>32: raise UploadFault("unsupported")
        paths=["/".join(components[:n]) for n in range(1,len(components)+1)] or [""]
        try:
            for path in paths:
                # Retain all ancestors without FILE_SHARE_WRITE/DELETE until
                # completion; rename/root replacement cannot race a path walk.
                handle=self._open(path,directory=True,add_file=path==paths[-1])
                self.parents.append((path,handle,self._probe(handle,directory=True)[0]))
            self._effect()
            self.parents[-1][1].flush()  # Unsupported directory FLUSH fails before staging.
            self._effect()
            self.prepared=True
        except BaseException:
            self.close()
            raise

    def _namespace(self):
        self.check()
        if not self.prepared: raise UploadFault("unsupported")
        for _,handle,identity in self.parents:
            if not handle.connected or self._probe(handle,directory=True)[0]!=identity:
                raise UploadFault("source_changed")

    def assert_absent(self,target,*,effect_check):
        self._namespace()
        try: handle=self._open(self._full(target),effect_check=effect_check)
        except FileNotFoundError: return
        handle.close()
        raise FileExistsError()

    def create_stage(self,operation,target,*,effect_check):
        if operation!=self.plan.operation_id: raise UploadFault("binding_mismatch")
        self._namespace()
        full=self._full(target); parent=full.rpartition("/")[0]
        stage="/".join(x for x in (parent,".arl-upload-"+operation+".stage") if x)
        raw=self._open(stage,create=True,effect_check=effect_check)
        try:
            handle=SMBUploadHandle(self,raw,writable=True)
            if handle.size()!=0: raise UploadFault("integrity_failed")
            self.handles.append(handle)
            return handle
        except BaseException:
            raw.close()
            raise

    def commit_new(self,handle,target,*,expected_revision,effect_check):
        self._namespace()
        if handle not in self.handles or not handle.writable or handle.published:
            raise UploadFault("binding_mismatch")
        if handle.revision()!=expected_revision: raise UploadFault("source_changed")
        value=FileRenameInformation()
        value["replace_if_exists"]=False
        value["root_directory"]=0  # Required for network operations.
        value["file_name"]=self._full(target).replace("/","\\")
        request=SMB2SetInfoRequest()
        request["info_type"],request["file_info_class"]=value.INFO_TYPE,value.INFO_CLASS
        request["file_id"],request["buffer"]=handle.raw.file_id,value.pack()
        self._effect(effect_check)
        try:
            token=self.reader.connection.send(request,sid=self.reader.session.session_id,tid=self.reader.tree.tree_connect_id)
            response=SMB2SetInfoResponse()
            response.unpack(self.reader.connection.receive(token)["data"].get_value())
        except ObjectNameCollision: raise FileExistsError() from None
        handle.published=True
        self._effect(effect_check)
        handle.raw.flush()
        self._effect(effect_check)
        self.parents[-1][1].flush()
        self._effect(effect_check)
        if handle.identity!=self._probe(handle.raw)[0]: raise UploadFault("target_replaced")
        # Any error after SET_INFO is uncertain; storage never retries/deletes.

    def open_readonly(self,target,identity,*,effect_check):
        self._namespace()
        raw=self._open(self._full(target),effect_check=effect_check)
        try:
            handle=SMBUploadHandle(self,raw,writable=False)
            if handle.identity!=identity: raise UploadFault("target_replaced")
            self.handles.append(handle)
            return handle
        except BaseException:
            raw.close()
            raise

    def check_identity(self,target,identity,*,revision,effect_check):
        handle=self.open_readonly(target,identity,effect_check=effect_check)
        try:
            if handle.revision()!=revision: raise UploadFault("target_replaced")
            self._effect(effect_check)
        finally: handle.close()

    def close(self):
        if self.closed: return
        self.closed=True
        for handle in self.handles:
            try: handle.close()
            except Exception: pass
        for _,handle,_ in reversed(self.parents):
            try: handle.close()
            except Exception: pass
        self.parents.clear()


class SMBUploadHandle:
    def __init__(self,medium,raw,*,writable):
        self.medium,self.raw,self.writable=medium,raw,writable
        self.closed=self.published=False
        self.identity=medium._probe(raw)[0]
    def check(self):
        self.medium.check()
        if self.closed or not self.raw.connected: raise UploadFault("source_changed")
    def size(self):
        self.check()
        return self.medium._probe(self.raw)[2]
    def revision(self):
        self.check()
        value=self.medium._probe(self.raw)
        if value[0]!=self.identity: raise UploadFault("target_replaced")
        return value[1]
    def read(self,offset,count,*,effect_check):
        if type(offset) is not int or type(count) is not int or not 0<=offset<=MAX_BYTES or not 0<count<=CHUNK_BYTES or offset+count>MAX_BYTES:
            raise UploadFault("invalid_plan")
        self.check(); self.medium._effect(effect_check)
        data=self.raw.read(offset,count)
        self.medium._effect(effect_check)
        return data
    def write(self,offset,data,*,effect_check):
        if (not self.writable or self.published or type(offset) is not int or type(data) is not bytes
            or not 0<=offset<=MAX_BYTES or not 0<len(data)<=CHUNK_BYTES or offset+len(data)>MAX_BYTES):
            raise UploadFault("invalid_plan")
        self.check(); self.medium._effect(effect_check)
        count=self.raw.write(data,offset=offset,write_through=True)
        self.medium._effect(effect_check)
        return count
    def flush(self,*,effect_check):
        if not self.writable or self.published: raise UploadFault("invalid_plan")
        self.check(); self.medium._effect(effect_check)
        self.raw.flush()
        self.medium._effect(effect_check)
    def close(self):
        if self.closed: return
        self.closed=True
        self.raw.close()
