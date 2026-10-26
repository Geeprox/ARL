"""Metadata extension of an existing owner-sealed journal FD, never a store.

No home/path discovery, reset, repair or reservation-release API. A target is
reserved permanently, including uncertain outcomes; new IDs cannot replay it.
Reconcile uses an existing shared lock and only reads these records.
"""
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
import re
import stat
import uuid
from .contracts import FAULTS, UploadFault, UploadPlan, canonical

STATES = frozenset({'prepared', 'staging', 'writing', 'ready', 'committing',
                    'committed', 'uncertain', 'rejected'})
MAX_RECORD = 8192


def object_identity(value):
    if type(value) is not str or not re.fullmatch(r'[A-Za-z0-9_.:-]{1,128}', value):
        raise UploadFault('invalid_reply')
    return value


def _unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise UploadFault('journal_uncertain')
        result[key] = value
    return result


class UploadJournal:
    def __init__(self, owned_directory_fd, *, verify_seal):
        self.fd = -1
        try:
            if type(owned_directory_fd) is not int or not callable(verify_seal):
                raise UploadFault('journal_uncertain')
            self.fd = os.dup(owned_directory_fd)
            self._verify_seal = verify_seal
            record = os.fstat(self.fd)
            self._record = (record.st_dev, record.st_ino)
            self.check()
        except BaseException as error:
            self.close()
            if isinstance(error, UploadFault):
                raise
            raise UploadFault('journal_uncertain') from None

    def check(self):
        try:
            self._verify_seal()
            record = os.fstat(self.fd)
            if ((record.st_dev, record.st_ino) != self._record or not stat.S_ISDIR(record.st_mode)
                    or record.st_uid != os.getuid() or record.st_mode & 0o077):
                raise UploadFault('journal_uncertain')
            self._verify_seal()
        except UploadFault:
            raise
        except Exception:
            raise UploadFault('journal_uncertain') from None

    @staticmethod
    def _name(operation):
        try:
            if type(operation) is not str or str(uuid.UUID(operation)) != operation:
                raise ValueError()
        except (ValueError, TypeError, AttributeError):
            raise UploadFault('invalid_plan') from None
        return 'upload_new_op_' + operation + '.json'

    @staticmethod
    def _target_name(plan):
        return 'upload_new_target_' + plan.target_key + '.json'

    @staticmethod
    def _check_file(fd):
        record = os.fstat(fd)
        if (not stat.S_ISREG(record.st_mode) or record.st_uid != os.getuid()
                or record.st_mode & 0o077 or record.st_nlink != 1):
            raise UploadFault('journal_uncertain')
        return record

    @contextmanager
    def transaction(self, *, readonly=False):
        self.check()
        flags = os.O_RDONLY if readonly else os.O_RDWR | os.O_CREAT
        try:
            fd = os.open('upload_new.lock', flags | os.O_NOFOLLOW, 0o600, dir_fd=self.fd)
        except OSError:
            raise UploadFault('journal_uncertain') from None
        try:
            self._check_file(fd)
            try:
                fcntl.flock(fd, (fcntl.LOCK_SH if readonly else fcntl.LOCK_EX) | fcntl.LOCK_NB)
            except BlockingIOError:
                raise UploadFault('busy') from None
            self.check()
            yield
        finally:
            os.close(fd)

    def _load(self, name):
        self.check()
        try:
            fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=self.fd)
        except FileNotFoundError:
            return None
        except OSError:
            raise UploadFault('journal_uncertain') from None
        try:
            before = self._check_file(fd)
            if not 0 < before.st_size <= MAX_RECORD:
                raise UploadFault('journal_uncertain')
            raw = os.pread(fd, MAX_RECORD + 1, 0)
            after = self._check_file(fd)
            if (len(raw) != before.st_size or
                    (before.st_size, before.st_mtime_ns, before.st_ctime_ns) !=
                    (after.st_size, after.st_mtime_ns, after.st_ctime_ns)):
                raise UploadFault('journal_uncertain')
            value = json.loads(raw, object_pairs_hook=_unique,
                               parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
            self.check()
            return value
        except UploadFault:
            raise
        except (OSError, ValueError, TypeError):
            raise UploadFault('journal_uncertain') from None
        finally:
            os.close(fd)

    def load(self, operation):
        value = self._load(self._name(operation))
        if value is not None:
            self._validate(operation, value)
        return value

    @staticmethod
    def _validate(operation, value):
        try:
            if (type(value) is not dict or set(value) != {'schema_version', 'plan', 'state', 'identity',
                                                        'bytes_confirmed', 'content_sha256', 'failure'}
                    or type(value['schema_version']) is not int or value['schema_version'] != 1
                    or type(value['plan']) is not dict):
                raise ValueError()
            plan = UploadPlan(**value['plan'])
            if plan.operation_id != operation or value['state'] not in STATES:
                raise ValueError()
            if value['identity'] is not None:
                object_identity(value['identity'])
            if (type(value['bytes_confirmed']) is not int or not 0 <= value['bytes_confirmed'] <= plan.size
                    or (value['failure'] is not None and value['failure'] not in FAULTS)
                    or (value['content_sha256'] is not None and value['content_sha256'] != plan.sha256)):
                raise ValueError()
            if value['state'] in {'writing', 'ready', 'committing', 'committed'} and value['identity'] is None:
                raise ValueError()
            if value['state'] in {'ready', 'committing', 'committed'}:
                if value['bytes_confirmed'] != plan.size or value['content_sha256'] != plan.sha256:
                    raise ValueError()
            if value['state'] == 'committed' and value['failure'] is not None:
                raise ValueError()
        except (UploadFault, ValueError, TypeError, KeyError):
            raise UploadFault('journal_uncertain') from None

    def reservation(self, plan):
        value = self._load(self._target_name(plan))
        if value is None:
            return None
        try:
            if (type(value) is not dict or set(value) != {'schema_version', 'operation_id',
                    'namespace_hash', 'canonical_target', 'plan_sha256'}
                    or type(value['schema_version']) is not int or value['schema_version'] != 1
                    or type(value['operation_id']) is not str
                    or str(uuid.UUID(value['operation_id'])) != value['operation_id']
                    or value['namespace_hash'] != plan.namespace_hash
                    or value['canonical_target'] != plan.target.lower()
                    or type(value['plan_sha256']) is not str
                    or re.fullmatch('[0-9a-f]{64}', value['plan_sha256']) is None):
                raise ValueError()
        except (ValueError, TypeError, KeyError):
            raise UploadFault('journal_uncertain') from None
        return value

    def check_reservation(self, plan):
        value = self.reservation(plan)
        if (value is None or value['operation_id'] != plan.operation_id
                or value['plan_sha256'] != hashlib.sha256(canonical(plan.metadata())).hexdigest()):
            raise UploadFault('journal_uncertain')

    @staticmethod
    def _write(fd, value):
        raw = canonical(value)
        if len(raw) > MAX_RECORD:
            raise UploadFault('journal_uncertain')
        offset = 0
        while offset < len(raw):
            count = os.write(fd, raw[offset:])
            if count <= 0:
                raise UploadFault('journal_uncertain')
            offset += count
        os.fsync(fd)

    def _create(self, name, value):
        self.check()
        try:
            fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                         0o600, dir_fd=self.fd)
        except FileExistsError:
            raise UploadFault('operation_consumed') from None
        except OSError:
            raise UploadFault('journal_uncertain') from None
        try:
            self._check_file(fd)
            self._write(fd, value)
            os.fsync(self.fd)
            self.check()
        except OSError:
            raise UploadFault('journal_uncertain') from None
        finally:
            os.close(fd)

    def begin(self, plan):
        if self.reservation(plan) is not None:
            raise UploadFault('target_reserved')
        # A crash at either fsync keeps this resource conservatively reserved.
        self._create(self._target_name(plan), {
            'schema_version': 1, 'operation_id': plan.operation_id,
            'namespace_hash': plan.namespace_hash, 'canonical_target': plan.target.lower(),
            'plan_sha256': hashlib.sha256(canonical(plan.metadata())).hexdigest(),
        })
        receipt = {'schema_version': 1, 'plan': plan.metadata(), 'state': 'prepared',
                   'identity': None, 'bytes_confirmed': 0, 'content_sha256': None, 'failure': None}
        self._create(self._name(plan.operation_id), receipt)
        return receipt

    def save(self, operation, receipt):
        self.check()
        self._validate(operation, receipt)
        existing = self.load(operation)
        if existing is None or existing['plan'] != receipt['plan']:
            raise UploadFault('journal_uncertain')
        self.check_reservation(UploadPlan(**receipt['plan']))
        temporary = 'upload_new_tmp_' + str(uuid.uuid4())
        try:
            fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                         0o600, dir_fd=self.fd)
        except OSError:
            raise UploadFault('journal_uncertain') from None
        try:
            self._write(fd, receipt)
            self.check()
            # Only this operation's owned metadata receipt is replaced, never a
            # user target or staging object. No reset/removal path is exported.
            os.rename(temporary, self._name(operation), src_dir_fd=self.fd, dst_dir_fd=self.fd)
            os.fsync(self.fd)
            self.check()
        except OSError:
            raise UploadFault('journal_uncertain') from None
        finally:
            os.close(fd)
            try:
                os.unlink(temporary, dir_fd=self.fd)
            except FileNotFoundError:
                pass

    def close(self):
        fd, self.fd = self.fd, -1
        if fd >= 0:
            try:
                os.close(fd)
            except OSError:
                pass

    def __del__(self):
        self.close()
