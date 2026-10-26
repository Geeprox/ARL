"""Unregistered SMB mkdir/move medium using the existing scoped SMB session.

No connection, credential lookup, mount, retry, overwrite, delete or listener.
Only exact owner-resolved paths below reader.root; move supports files <=1MiB.
"""
import uuid
from smbprotocol import Dialects
from smbprotocol.exceptions import ObjectNameCollision
from smbprotocol.file_info import FileRenameInformation
from smbprotocol.open import (
    Open, CreateDisposition, CreateOptions, FileAttributes,
    FilePipePrinterAccessMask as Access, DirectoryAccessMask as Directory,
    ImpersonationLevel, ShareAccess, SMB2SetInfoRequest, SMB2SetInfoResponse,
)
from smb_upload_new import SMBUploadNewMedium
from arl_nas_upload_new.contracts import UploadFault, relative_target


class SMBFileMutationMedium(SMBUploadNewMedium):
    def prepare(self, plan, *, check):
        self._effect(check)
        if plan.upload is not self.plan or plan.operation not in {'mkdir', 'move'} or self.prepared:
            raise UploadFault('binding_mismatch')
        if (self.reader.connection.dialect < Dialects.SMB_3_0_0 or not self.reader.session.encrypt_data
                or not isinstance(self.reader.connection.server_guid, uuid.UUID)):
            raise UploadFault('unsupported')
        paths = set()
        targets = [self._full(self.plan.target)]
        if plan.source is not None:
            relative_target(plan.source)
            targets.append('/'.join(x for x in (self.reader.root, plan.source) if x))
        for full in targets:
            components = full.split('/')[:-1]
            if len(components) > 32:
                raise UploadFault('unsupported')
            paths.update('/'.join(components[:n]) for n in range(1, len(components) + 1))
        for path in sorted(paths or {''}, key=lambda x: (x.count('/'), x)):
            # Retain traversal handles without SHARE_WRITE/DELETE through effect
            # and readback, rejecting reparse points at every ancestor.
            raw = self._open(path, directory=True, effect_check=check)
            self.parents.append((path, raw, self._probe(raw, directory=True)[0]))
        self.prepared = True
        self._namespace()
        self.assert_absent(plan.upload.target, effect_check=check)
        for _, raw, _ in self.parents:
            self._effect(check)
            raw.flush()  # unsupported durability fails BEFORE a mutation
            self._effect(check)
        self.source_raw = None
        if plan.operation == 'move':
            full = '/'.join(x for x in (self.reader.root, plan.source) if x)
            raw = Open(self.reader.tree, full.replace('/', '\\'))
            try:
                self._effect(check)
                raw.create(ImpersonationLevel.Impersonation,
                    Access.DELETE | Access.FILE_READ_DATA | Access.FILE_READ_ATTRIBUTES,
                    FileAttributes.FILE_ATTRIBUTE_NORMAL, ShareAccess.FILE_SHARE_READ,
                    CreateDisposition.FILE_OPEN,
                    CreateOptions.FILE_NON_DIRECTORY_FILE | CreateOptions.FILE_OPEN_REPARSE_POINT)
                self.handles.append(raw)
                self._effect(check)
                identity, _, _ = self._probe(raw)
                entry = self.reader._stat_handle(plan.source, raw)
                if entry['kind'] != 'file' or entry['revision'] != plan.revision:
                    raise UploadFault('source_changed')
                self.source_raw, self.source_identity = raw, identity
            except BaseException:
                if raw.connected:
                    raw.close()
                raise

    def mkdir(self, plan, *, check):
        self._namespace()
        self._effect(check)
        if plan.upload is not self.plan or plan.operation != 'mkdir':
            raise UploadFault('binding_mismatch')
        raw = Open(self.reader.tree, self._full(plan.upload.target).replace('/', '\\'))
        try:
            self._effect(check)
            try:
                raw.create(ImpersonationLevel.Impersonation,
                    Directory.FILE_TRAVERSE | Access.FILE_READ_ATTRIBUTES,
                    FileAttributes.FILE_ATTRIBUTE_DIRECTORY, 0, CreateDisposition.FILE_CREATE,
                    CreateOptions.FILE_DIRECTORY_FILE | CreateOptions.FILE_OPEN_REPARSE_POINT)
            except ObjectNameCollision:
                raise FileExistsError() from None
            self._effect(check)
            self._probe(raw, directory=True)
            raw.flush()
            for _, parent, _ in self.parents:
                parent.flush()
            self._effect(check)
            entry = self.reader._stat_handle(plan.upload.target, raw)
            self._namespace()
            return entry
        finally:
            if raw.connected:
                raw.close()

    def move(self, plan, *, check):
        self._namespace()
        if plan.upload is not self.plan or plan.operation != 'move' or self.source_raw is None:
            raise UploadFault('binding_mismatch')
        raw = self.source_raw
        self._effect(check)
        if (self.reader._stat_handle(plan.source, raw)['revision'] != plan.revision
                or self._probe(raw)[0] != self.source_identity):
            raise UploadFault('source_changed')
        value = FileRenameInformation()
        value['replace_if_exists'], value['root_directory'] = False, 0
        value['file_name'] = self._full(plan.upload.target).replace('/', '\\')
        request = SMB2SetInfoRequest()
        request['info_type'], request['file_info_class'] = value.INFO_TYPE, value.INFO_CLASS
        request['file_id'], request['buffer'] = raw.file_id, value.pack()
        self._effect(check)
        try:
            token = self.reader.connection.send(request, sid=self.reader.session.session_id,
                                                tid=self.reader.tree.tree_connect_id)
            response = SMB2SetInfoResponse()
            response.unpack(self.reader.connection.receive(token)['data'].get_value())
        except ObjectNameCollision:
            raise FileExistsError() from None
        self._effect(check)
        raw.flush()
        for _, parent, _ in self.parents:
            parent.flush()
        self._effect(check)
        if self._probe(raw)[0] != self.source_identity:
            raise UploadFault('target_replaced')
        # Reopen by final name and compare stable identity, not just the handle
        # retained across rename. Metadata revision legitimately changes on move.
        raw.close()  # DELETE access would conflict with final read-only sharing.
        self.handles.remove(raw)
        self.source_raw = None
        self._effect(check)
        final = self._open(self._full(plan.upload.target), effect_check=check)
        try:
            if self._probe(final)[0] != self.source_identity:
                raise UploadFault('target_replaced')
            entry = self.reader._stat_handle(plan.upload.target, final)
            self._effect(check)
            self._namespace()
            return entry
        finally:
            final.close()
