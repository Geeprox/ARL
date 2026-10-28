"""Small ephemeral transfer-reference seam; no server, network fetch or publisher.

Native owner retains at most its approved active transfers and serializes calls.
Every call revalidates the captured owner/fence/operation, not an MCP `_meta` ID.
32KiB chunks fit current 64KiB owner requests. Whole objects are disk-backed;
size uses the shared exact JSON integer range, independent of frame size. References expire after 120s and never survive owner restart.
"""
from __future__ import annotations
import base64
from contextlib import contextmanager
from dataclasses import asdict
import hashlib
import math
import os
import time
import uuid

from arl_nas_upload_new.contracts import MAX_BYTES, UploadFault
from arl_nas_upload_new.source import SealedSource
from .file_operations import FileOperationJournal, ScopeFence, file_name, hex_value, integer, fail

CHUNK_BYTES = 32 * 1024


class FileTransfer:
    def __init__(self, *, journal, operation_id, fence, name, size, sha256, verify, direction='upload', clock=time.monotonic):
        if (type(journal) is not FileOperationJournal or type(fence) is not ScopeFence or not callable(verify)
                or not integer(size, 0, MAX_BYTES) or direction not in {'upload', 'download'}
                or not hex_value(sha256, 64) and not (sha256 is None and direction == 'download')):
            fail()
        journal._name(operation_id)  # canonical UUID validation
        file_name(name)
        now = clock()
        if type(now) not in (int, float) or not math.isfinite(now):
            fail()
        journal.check(); verify()
        self.ref = uuid.uuid4().hex + uuid.uuid4().hex
        self.name, self.size, self.sha256 = name, size, sha256
        self.direction = direction
        self.operation_id, self.fence = operation_id, fence
        self.journal, self.verify, self.clock, self.deadline = journal, verify, clock, now + 120
        self.filename = 'file_transfer_' + self.ref
        self.directory_fd = os.dup(journal.fd)  # own local cleanup lifetime, independent of journal shutdown
        try:
            self.fd = os.open(self.filename, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=self.directory_fd)
        except BaseException:
            os.close(self.directory_fd)
            raise
        self.pin = os.fstat(self.fd)
        self.offset, self.sealed, self.claimed, self.broken = 0, False, False, False
        self.sealed_record = None

    def check(self, ref, operation_id, fence):
        if ref != self.ref or operation_id != self.operation_id or fence != self.fence:
            fail('binding_mismatch')
        if self.fd < 0 or self.broken or self.claimed:
            fail('operation_consumed')
        if not math.isfinite(self.clock()) or self.clock() >= self.deadline:
            fail('expired')
        self.journal.check(); self.verify()
        opened = os.fstat(self.fd)
        named = os.stat(self.filename, dir_fd=self.journal.fd, follow_symlinks=False)
        if ((opened.st_dev, opened.st_ino) != (self.pin.st_dev, self.pin.st_ino)
                or (named.st_dev, named.st_ino) != (self.pin.st_dev, self.pin.st_ino)
                or opened.st_size != self.offset or opened.st_nlink != 1
                or opened.st_mode != self.pin.st_mode or opened.st_uid != self.pin.st_uid):
            fail('source_changed')
        if self.sealed_record is not None and (opened.st_mtime_ns, opened.st_ctime_ns) != self.sealed_record:
            fail('source_changed')
        if not math.isfinite(self.clock()) or self.clock() >= self.deadline:
            fail('expired')

    def append(self, *, ref, operation_id, fence, offset, data_base64, sha256):
        self.check(ref, operation_id, fence)
        if (self.sealed or not integer(offset, 0, self.size) or offset != self.offset
                or type(data_base64) is not str or len(data_base64) > 4 * ((CHUNK_BYTES + 2)//3)
                or not hex_value(sha256, 64)):
            fail()
        try:
            raw = base64.b64decode(data_base64, validate=True)
        except (ValueError, UnicodeError):
            fail()
        if (not 0 < len(raw) <= min(CHUNK_BYTES, self.size-self.offset)
                or base64.b64encode(raw).decode() != data_base64
                or hashlib.sha256(raw).hexdigest() != sha256):
            fail('source_changed')
        try:
            count = os.pwrite(self.fd, raw, self.offset)
            if count != len(raw):
                fail('io_uncertain')
            self.offset += count
            os.fsync(self.fd)
            self.check(ref, operation_id, fence)
            return {'transfer_ref': self.ref, 'bytes_received': self.offset, 'complete': False}
        except BaseException:
            self.broken = True  # never retry a local write with uncertain outcome
            raise

    def finish(self, *, ref, operation_id, fence):
        self.check(ref, operation_id, fence)
        if self.offset != self.size:
            fail('source_changed')
        with SealedFD(self) as source:
            if self.sha256 is not None and source.sha256 != self.sha256:
                self.broken = True
                fail('integrity_failed')
            self.sha256 = source.sha256
            source.check()
            row = os.fstat(self.fd)
            source.check()
            self.sealed_record = (row.st_mtime_ns, row.st_ctime_ns)
            self.sealed = True
            self.check(ref, operation_id, fence)
        return {'schema_version': 1, 'operation_id': self.operation_id, **asdict(self.fence),
                'transfer_ref': self.ref, 'name': self.name, 'size': self.size, 'sha256': self.sha256,
                'expires_in_seconds': max(0, self.deadline-self.clock()), 'complete': True,
                'direction': self.direction, 'downloadable_artifact': False}

    def metadata(self, ref, operation_id, fence):
        self.check(ref, operation_id, fence)
        if not self.sealed:
            fail('source_changed')
        return {'size': self.size, 'sha256': self.sha256, 'name': self.name}

    @contextmanager
    def claim_source(self, *, ref, operation_id, fence):
        if self.direction != 'upload':
            fail('binding_mismatch')
        self.metadata(ref, operation_id, fence)
        source = SealedSource(self.fd, verify_pin=lambda: self.check(ref, operation_id, fence))
        try:
            yield source
        finally:
            self.claimed = True  # ref is one-shot even if upload fails/loses reply
            source.close()

    def read_chunk(self, *, ref, operation_id, fence, offset, length=CHUNK_BYTES):
        self.metadata(ref, operation_id, fence)
        if not integer(offset, 0, self.size) or not integer(length, 1, CHUNK_BYTES):
            fail()
        raw = os.pread(self.fd, min(length, self.size-offset), offset)
        self.check(ref, operation_id, fence)
        if len(raw) != min(length, self.size-offset):
            fail('source_changed')
        return {'transfer_ref': self.ref, 'offset': offset, 'bytes_read': len(raw),
                'data_base64': base64.b64encode(raw).decode(), 'sha256': hashlib.sha256(raw).hexdigest(),
                'eof': offset+len(raw)==self.size, 'next_offset': None if offset+len(raw)==self.size else offset+len(raw)}

    def close(self):
        if self.fd < 0:
            return
        fd, self.fd = self.fd, -1
        try:
            try:
                named = os.stat(self.filename, dir_fd=self.directory_fd, follow_symlinks=False)
            except FileNotFoundError:
                return
            if (named.st_dev, named.st_ino) == (self.pin.st_dev, self.pin.st_ino):
                os.unlink(self.filename, dir_fd=self.directory_fd)
        finally:
            os.close(fd)
            os.close(self.directory_fd)


@contextmanager
def SealedFD(transfer):
    source = SealedSource(transfer.fd, verify_pin=lambda: transfer.check(transfer.ref, transfer.operation_id, transfer.fence))
    try:
        yield source
    finally:
        source.close()


def collect_download(value, *, journal, read, verify):
    """Read checked NAS ranges into an ephemeral outgoing ref, without a publisher."""
    from .file_operations import request, checked_download_chunks
    value = request(value)
    if value['operation'] != 'download':
        fail()
    transfer = FileTransfer(journal=journal, operation_id=value['operation_id'],
        fence=ScopeFence(value['source_ref'], value['config_generation'], value['connection_epoch']),
        name=value['name'], size=value['size'], sha256=None, direction='download', verify=verify)
    context = dict(ref=transfer.ref, operation_id=transfer.operation_id, fence=transfer.fence)
    try:
        for raw in checked_download_chunks(value, read=read, verify=verify):
            if raw:  # an empty file still gets one checked EOF response
                transfer.append(**context, offset=transfer.offset,
                    data_base64=base64.b64encode(raw).decode(), sha256=hashlib.sha256(raw).hexdigest())
        transfer.finish(**context)
        return transfer
    except BaseException:
        transfer.close()
        raise
