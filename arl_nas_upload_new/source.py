"""Exact replayable owner-supplied FD; no path/credential/wire resolver."""
import hashlib
import os
import stat
from .contracts import CHUNK_BYTES, MAX_BYTES, UploadFault


class SealedSource:
    def __init__(self, owned_fd, *, verify_pin):
        self.fd = -1
        try:
            if type(owned_fd) is not int or owned_fd < 0 or not callable(verify_pin):
                raise UploadFault('source_changed')
            self.fd = os.dup(owned_fd)
            self._verify_pin = verify_pin
            record = os.fstat(self.fd)
            if (not stat.S_ISREG(record.st_mode) or record.st_uid != os.getuid()
                    or record.st_mode & 0o022 or record.st_nlink != 1):
                raise UploadFault('source_changed')
            if not 0 <= record.st_size <= MAX_BYTES:
                raise UploadFault('source_too_large')
            self._record = self._identity(record)
            self.size = record.st_size
            self.sha256 = self.digest()
        except BaseException as error:
            self.close()
            if isinstance(error, UploadFault):
                raise
            raise UploadFault('source_changed') from None

    @staticmethod
    def _identity(value):
        return (value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns,
                value.st_ctime_ns, value.st_uid, value.st_mode, value.st_nlink)

    def check(self):
        try:
            self._verify_pin()
            if self.fd < 0 or self._identity(os.fstat(self.fd)) != self._record:
                raise UploadFault('source_changed')
            self._verify_pin()
        except UploadFault:
            raise
        except Exception:
            raise UploadFault('source_changed') from None

    def read(self, offset, length):
        if (type(offset) is not int or type(length) is not int or not 0 <= offset <= self.size
                or not 0 < length <= CHUNK_BYTES):
            raise UploadFault('source_changed')
        self.check()
        try:
            data = os.pread(self.fd, length, offset)
        except OSError:
            raise UploadFault('source_changed') from None
        self.check()
        if len(data) != min(length, self.size - offset):
            raise UploadFault('source_changed')
        return data

    def digest(self):
        result = hashlib.sha256()
        for offset in range(0, self.size, CHUNK_BYTES):
            result.update(self.read(offset, min(CHUNK_BYTES, self.size - offset)))
        self.check()
        return result.hexdigest()

    def validate(self, plan):
        self.check()
        if self.size != plan.size or self.sha256 != plan.sha256 or self.digest() != plan.sha256:
            raise UploadFault('source_changed')

    def close(self):
        fd, self.fd = self.fd, -1
        if fd >= 0:
            try:
                os.close(fd)
            except OSError:
                pass

    def __del__(self):
        self.close()
