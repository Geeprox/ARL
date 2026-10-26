"""TEST ONLY: controlled POSIX bytes, never a NAS/vendor/peer implementation.

Directories are created by the fixture. Atomic link creates the final name
without replacing any entry; staged files stay private and are never deleted by
the core. Device/inode identity here is evidence only within this local fixture.
"""
import hashlib
import os
import stat
from arl_nas_upload_new.contracts import CHUNK_BYTES, UploadFault, relative_target


def identity(record):
    return f'controlled-posix:{record.st_dev}:{record.st_ino}'


def file_revision(record):
    value = (record.st_dev, record.st_ino, record.st_size, record.st_mtime_ns,
             record.st_ctime_ns, record.st_nlink)
    return hashlib.sha256(repr(value).encode()).hexdigest()


def directory_record(fd):
    record = os.fstat(fd)
    if not stat.S_ISDIR(record.st_mode) or record.st_uid != os.getuid() or record.st_mode & 0o077:
        raise UploadFault('source_changed')
    return record.st_dev, record.st_ino


class ControlledMedium:
    def __init__(self, root, staging, *, namespace_hash):
        self.root, self.staging, self.namespace_hash = root, staging, namespace_hash
        self.root_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        self.stage_fd = os.open(staging, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        self.root_pin, self.stage_pin = directory_record(self.root_fd), directory_record(self.stage_fd)
        if self.root_pin[0] != self.stage_pin[0]:
            raise UploadFault('unsupported')
        self.calls = dict(create=0, write=0, flush=0, commit=0, read=0, reopen=0, identity=0, absent=0)
        self.hooks = {}
        self.handles = []
        self.partial_limit = None
        self.write_reply = 'actual'
        self.lost_write_reply = False
        self.lost_create_reply = False
        self.lost_commit_reply = False
        self.commit_available = True
        self.read_reply = 'actual'

    def event(self, name, handle=None):
        hook = self.hooks.get(name)
        if hook is not None:
            hook(handle)

    def check(self):
        for path, fd, expected in ((self.root, self.root_fd, self.root_pin),
                                   (self.staging, self.stage_fd, self.stage_pin)):
            record = os.lstat(path)
            if (stat.S_ISLNK(record.st_mode) or (record.st_dev, record.st_ino) != expected
                    or directory_record(fd) != expected):
                raise UploadFault('source_changed')

    def check_namespace(self, expected):
        if expected != self.namespace_hash:
            raise UploadFault('source_changed')
        self.check()

    def require_atomic_new(self):
        self.check()
        if not self.commit_available:
            raise UploadFault('unsupported')

    def parent(self, target):
        parts = relative_target(target).split('/')
        fd = os.dup(self.root_fd)
        try:
            for part in parts[:-1]:
                next_fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                os.close(fd)
                fd = next_fd
                directory_record(fd)
            return fd, parts[-1]
        except BaseException:
            os.close(fd)
            raise

    def verify_parent(self, target, expected):
        fd, _ = self.parent(target)
        try:
            if directory_record(fd) != expected:
                raise UploadFault('source_changed')
        finally:
            os.close(fd)

    def assert_absent(self, target, *, effect_check):
        self.check()
        parent, name = self.parent(target)
        try:
            self.event('before_absence')
            effect_check()
            self.calls['absent'] += 1
            try:
                os.stat(name, dir_fd=parent, follow_symlinks=False)
            except FileNotFoundError:
                return
            raise FileExistsError()
        finally:
            os.close(parent)

    def create_stage(self, operation, target, *, effect_check):
        self.check()
        parent, _ = self.parent(target)
        try:
            self.event('before_create')
            effect_check()
            name = 'stage_' + operation
            self.calls['create'] += 1
            fd = os.open(name, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=self.stage_fd)
            handle = ControlledHandle(self, fd, parent, target, name, True)
            parent = -1
            self.handles.append(handle)
            os.fsync(self.stage_fd)
            self.event('after_create', handle)
            if self.lost_create_reply:
                handle.close()
                raise OSError('synthetic create acknowledgement lost')
            return handle
        finally:
            if parent >= 0:
                os.close(parent)

    def commit_new(self, handle, target, *, expected_revision, effect_check):
        if not self.commit_available:
            raise UploadFault('unsupported')  # no unsafe rename/direct-write fallback
        if type(handle) is not ControlledHandle or handle.medium is not self or target != handle.target:
            raise UploadFault('binding_mismatch')
        self.event('before_commit', handle)
        handle.check()
        if handle.revision() != expected_revision:
            raise UploadFault('integrity_failed')
        effect_check()  # renewed after possible blocking checks, at actual link effect
        _, name = target.rsplit('/', 1) if '/' in target else ('', target)
        self.calls['commit'] += 1
        os.link(handle.name, name, src_dir_fd=self.stage_fd, dst_dir_fd=handle.parent_fd, follow_symlinks=False)
        self.event('after_link', handle)
        effect_check()
        os.fsync(handle.parent_fd)
        self.event('after_commit', handle)
        if self.lost_commit_reply:
            raise OSError('synthetic commit acknowledgement lost')

    def open_readonly(self, target, expected_identity, *, effect_check):
        self.check()
        parent, name = self.parent(target)
        try:
            self.event('before_reopen')
            effect_check()
            self.calls['reopen'] += 1
            fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=parent)
            handle = ControlledHandle(self, fd, parent, target, name, False)
            parent = -1
            self.handles.append(handle)
            if handle.identity != expected_identity:
                handle.close()
                raise UploadFault('target_replaced')
            return handle
        finally:
            if parent >= 0:
                os.close(parent)

    def check_identity(self, target, expected_identity, *, revision, effect_check):
        self.check()
        parent, name = self.parent(target)
        try:
            self.event('before_identity')
            effect_check()
            self.calls['identity'] += 1
            record = os.stat(name, dir_fd=parent, follow_symlinks=False)
            if not stat.S_ISREG(record.st_mode) or identity(record) != expected_identity:
                raise UploadFault('target_replaced')
            if file_revision(record) != revision:
                raise UploadFault('integrity_failed')
        finally:
            os.close(parent)

    def close(self):
        for handle in self.handles:
            handle.close()
        for attr in ('root_fd', 'stage_fd'):
            fd = getattr(self, attr)
            if fd >= 0:
                os.close(fd)
                setattr(self, attr, -1)


class ControlledHandle:
    def __init__(self, medium, fd, parent, target, name, writable):
        self.medium, self.fd, self.parent_fd = medium, fd, parent
        self.target, self.name, self.writable = target, name, writable
        self.parent_pin = directory_record(parent)
        self.identity = identity(os.fstat(fd))

    def check(self):
        self.medium.check()
        self.medium.verify_parent(self.target, self.parent_pin)
        record = os.fstat(self.fd)
        if (not stat.S_ISREG(record.st_mode) or identity(record) != self.identity
                or record.st_uid != os.getuid() or record.st_mode & 0o077 or not 1 <= record.st_nlink <= 2):
            raise UploadFault('target_replaced')
        parent = self.medium.stage_fd if self.writable else self.parent_fd
        path_record = os.stat(self.name, dir_fd=parent, follow_symlinks=False)
        if not stat.S_ISREG(path_record.st_mode) or identity(path_record) != self.identity:
            raise UploadFault('target_replaced')

    def size(self):
        self.check()
        return os.fstat(self.fd).st_size

    def revision(self):
        self.check()
        return file_revision(os.fstat(self.fd))

    def write(self, offset, data, *, effect_check):
        if not self.writable:
            raise UploadFault('unsupported')
        self.medium.event('before_write', self)
        self.check()
        effect_check()
        self.medium.calls['write'] += 1
        sending = data if self.medium.partial_limit is None else data[:self.medium.partial_limit]
        count = os.pwrite(self.fd, sending, offset)
        self.medium.event('after_write', self)
        if self.medium.lost_write_reply:
            raise OSError('synthetic write acknowledgement lost')
        return count if self.medium.write_reply == 'actual' else self.medium.write_reply

    def flush(self, *, effect_check):
        self.medium.event('before_flush', self)
        self.check()
        effect_check()
        self.medium.calls['flush'] += 1
        os.fsync(self.fd)
        self.medium.event('after_flush', self)

    def read(self, offset, count, *, effect_check):
        if not 0 < count <= CHUNK_BYTES:
            raise UploadFault('invalid_reply')
        self.medium.event('before_read', self)
        self.check()
        effect_check()
        self.medium.calls['read'] += 1
        raw = os.pread(self.fd, count, offset)
        self.medium.event('after_read', self)
        return raw if self.medium.read_reply == 'actual' else self.medium.read_reply

    def close(self):
        fd, self.fd = self.fd, -1
        parent, self.parent_fd = self.parent_fd, -1
        try:
            if fd >= 0:
                os.close(fd)
                self.medium.event('after_close', self)
        finally:
            if parent >= 0:
                os.close(parent)
