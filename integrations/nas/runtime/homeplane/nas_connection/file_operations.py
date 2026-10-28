"""Candidate general NAS operations; deliberately unregistered and default closed.

The native owner must resolve refs under the existing saved read scope, capture
an exact plan, obtain separate one-shot write confirmation, and supply callbacks.
No endpoint, credential, scope issuer, local-path importer or URL fetcher exists.
"""
from __future__ import annotations

import base64
from contextlib import contextmanager
from dataclasses import asdict, dataclass
import hashlib
import math
import os
import re
import time
import uuid

from arl_nas_upload_new.contracts import (
    OwnerBinding, OwnerBoundary, UploadFault, UploadPlan, canonical, relative_target, MAX_BYTES,
)
from arl_nas_upload_new.storage import UploadNewStorage
from arl_nas_upload_new.journal import UploadJournal
from arl_nas_upload_new.source import SealedSource

MAX_INLINE_BYTES = 32 * 1024  # Base64 + metadata fits current 64KiB owner request
MAX_TRANSFER_BYTES = MAX_BYTES  # Whole objects stream; per-frame and authority deadlines remain bounded.
READ_CHUNK_BYTES = 32 * 1024


def fail(code='invalid_plan'):
    raise UploadFault(code)


def hex_value(value, length):
    return type(value) is str and re.fullmatch('[0-9a-f]{%d}' % length, value) is not None


def integer(value, minimum, maximum):
    return type(value) is int and minimum <= value <= maximum


def file_name(value):
    relative_target(value)
    if '/' in value or value.lower().startswith('.arl-'):
        fail()
    return value


def attachment_bytes(value, *, clock=time.time):
    """Explicit bytes only. A ChatGPT file ID/URL/local path is not a byte grant."""
    keys = {'transfer_kind', 'name', 'size', 'sha256', 'data_base64', 'expires_at'}
    if type(value) is not dict or set(value) != keys or value['transfer_kind'] != 'inline_base64':
        fail('unsupported')
    file_name(value['name'])
    now, expires = clock(), value['expires_at']
    if (type(expires) not in (int, float) or not math.isfinite(expires)
            or not math.isfinite(now) or not now < expires <= now + 120):
        fail('expired')
    if (not integer(value['size'], 0, MAX_INLINE_BYTES) or not hex_value(value['sha256'], 64)
            or type(value['data_base64']) is not str
            or len(value['data_base64']) > 4 * ((MAX_INLINE_BYTES + 2) // 3)):
        fail()
    try:
        raw = base64.b64decode(value['data_base64'], validate=True)
    except (ValueError, UnicodeError):
        fail()
    if (base64.b64encode(raw).decode() != value['data_base64'] or len(raw) != value['size']
            or hashlib.sha256(raw).hexdigest() != value['sha256']):
        fail('source_changed')
    return raw


@contextmanager
def seal_attachment(value, *, journal, verify):
    """Bridge explicit bytes into existing SealedSource using an owner-sealed FD.

    Only this operation's local staging file is removed on exit. No supplied
    path is opened, and no NAS operation or credential resolution occurs here.
    """
    if type(journal) is not FileOperationJournal or not callable(verify):
        fail('unsupported')
    raw = attachment_bytes(value)
    journal.check(); verify()
    name = 'file_input_' + str(uuid.uuid4())
    fd = os.open(name, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=journal.fd)
    source = None
    pin = os.fstat(fd)
    def check():
        journal.check(); verify()
        row = os.stat(name, dir_fd=journal.fd, follow_symlinks=False)
        if (row.st_dev, row.st_ino) != (pin.st_dev, pin.st_ino):
            fail('source_changed')
    try:
        offset = 0
        while offset < len(raw):
            check()
            count = os.write(fd, raw[offset:])
            if count <= 0:
                fail('source_changed')
            offset += count
        os.fsync(fd); check()
        source = SealedSource(fd, verify_pin=check)
        if source.sha256 != value['sha256'] or source.size != value['size']:
            fail('source_changed')
        yield source
    finally:
        if source is not None:
            source.close()
        os.close(fd)
        # Remove only the local inode created above; never a substituted entry.
        row = os.stat(name, dir_fd=journal.fd, follow_symlinks=False)
        if (row.st_dev, row.st_ino) == (pin.st_dev, pin.st_ino):
            os.unlink(name, dir_fd=journal.fd)


def request(value):
    """Proposed wire shape, not registered as Mio tools by this module."""
    if type(value) is not dict:
        fail()
    common = {'operation', 'operation_id', 'source_ref', 'config_generation', 'connection_epoch'}
    op = value.get('operation')
    fields = {'upload_new': {'directory_ref', 'name'} | ({'transfer_ref', 'size', 'sha256'} if 'transfer_ref' in value else {'attachment'}),
              'mkdir': {'directory_ref', 'name'},
              'move': {'directory_ref', 'name', 'object_ref', 'revision'},
              'download': {'object_ref', 'revision', 'name', 'size'}}
    if type(op) is not str or op not in fields or set(value) != common | fields[op]:
        fail()
    try:
        if type(value['operation_id']) is not str or str(uuid.UUID(value['operation_id'])) != value['operation_id']:
            fail()
    except (ValueError, TypeError, AttributeError):
        fail()
    if (type(value['source_ref']) is not str
            or re.fullmatch('[A-Za-z0-9_-]{1,96}', value['source_ref']) is None
            or not integer(value['config_generation'], 1, 2**63 - 1)
            or not hex_value(value['connection_epoch'], 32)):
        fail()
    file_name(value['name'])
    if 'directory_ref' in value and value['directory_ref'] is not None and not hex_value(value['directory_ref'], 64):
        fail()
    if op in {'move', 'download'} and not all(hex_value(value[k], 64) for k in ('object_ref', 'revision')):
        fail()
    if op == 'download' and not integer(value['size'], 0, MAX_TRANSFER_BYTES):
        fail('source_too_large')
    if op == 'upload_new':
        if 'transfer_ref' in value:
            if (not hex_value(value['transfer_ref'], 64) or not integer(value['size'], 0, MAX_TRANSFER_BYTES)
                    or not hex_value(value['sha256'], 64)):
                fail()
        else:
            attachment_bytes(value['attachment'])
    return dict(value)


@dataclass(frozen=True)
class ScopeFence:
    source_ref: str
    config_generation: int
    connection_epoch: str

    def __post_init__(self):
        if (type(self.source_ref) is not str or re.fullmatch('[A-Za-z0-9_-]{1,96}', self.source_ref) is None
                or not integer(self.config_generation, 1, 2**63-1) or not hex_value(self.connection_epoch, 32)):
            fail()

    def check(self, value):
        if any(type(value.get(k)) is not type(v) or value.get(k) != v for k, v in asdict(self).items()):
            fail('source_changed')


@dataclass(frozen=True)
class MutationPlan:
    """Owner-private resolved paths. No public deserializer or authority issuer."""
    operation: str
    upload: UploadPlan  # reuse existing durable target reservation/consumption ledger
    fence: ScopeFence
    source: str | None = None
    revision: str | None = None

    def __post_init__(self):
        if type(self.upload) is not UploadPlan or type(self.fence) is not ScopeFence:
            fail()
        if self.operation not in {'upload_new', 'mkdir', 'move'}:
            fail()
        if self.operation == 'move':
            relative_target(self.source)
            if (not hex_value(self.revision, 64) or self.source.lower() == self.upload.target.lower()
                    or self.upload.target.lower().startswith(self.source.lower() + '/')):
                fail()
        elif self.source is not None or self.revision is not None:
            fail()

    def metadata(self):
        return asdict(self)


def capture_plan(value, *, fence, binding, resolve, transfer=None):
    """resolve(ref, kind, revision) MUST use the current manager's opaque map.

    None denotes only the already selected root. No caller path is accepted.
    binding comes from the native owner, never request fields or server login.
    """
    value = request(value)
    fence.check(value)
    if type(binding) is not OwnerBinding or value['operation'] == 'download':
        fail()
    directory = '' if value['directory_ref'] is None else resolve(value['directory_ref'], 'directory', None)
    if directory:
        relative_target(directory)
    target = '/'.join(x for x in (directory, value['name']) if x)
    source = revision = None
    if value['operation'] == 'move':
        source = resolve(value['object_ref'], 'file', value['revision'])
        relative_target(source)
        revision = value['revision']
    intent = {'operation': value['operation'], 'target': target, 'source': source,
              'revision': revision, 'fence': asdict(fence)}
    size, sha = 0, hashlib.sha256(canonical(intent)).hexdigest()
    if value['operation'] == 'upload_new':
        if 'transfer_ref' in value:
            if transfer is None:
                fail('unsupported')
            metadata = transfer.metadata(value['transfer_ref'], value['operation_id'], fence)
            if any(metadata[k] != value[k] for k in ('name', 'size', 'sha256')):
                fail('binding_mismatch')
            size, sha = metadata['size'], metadata['sha256']
        else:
            raw = attachment_bytes(value['attachment'])
            size, sha = len(raw), hashlib.sha256(raw).hexdigest()
    upload = UploadPlan(value['operation_id'], str(uuid.uuid4()), binding.scope_hash,
                        binding.namespace_hash, binding.credential_generation,
                        binding.registration_epoch, target, size, sha)
    return MutationPlan(value['operation'], upload, fence, source, revision)


class MutationApproval:
    """One exact plan and fresh owner callbacks; a saved read scope grants no write.

    verify(plan, stage) checks current scope/epoch, caller, user confirmation and
    cancellation. consume(plan) uses the existing native ConsumptionJournal under
    a NEW reviewed mutation subject. Never reuse the upload-test permit.
    """
    def __init__(self, *, plan=None, verify=None, consume=None, clock=time.monotonic, lifetime=30):
        if type(lifetime) not in (int, float) or not 0 < lifetime <= 30:
            fail()
        self.plan, self.verify, self.consume_callback = plan, verify, consume
        now = clock()
        if type(now) not in (int, float) or not math.isfinite(now):
            fail()
        self.clock, self.deadline, self.consumed = clock, now + lifetime, False

    def check(self, plan, stage):
        if type(plan) is not MutationPlan or plan is not self.plan or not callable(self.verify) or not callable(self.consume_callback):
            fail('unsupported')
        if not math.isfinite(self.clock()) or self.clock() >= self.deadline:
            fail('expired')
        self.verify(plan, stage)
        if not math.isfinite(self.clock()) or self.clock() >= self.deadline:
            fail('expired')

    def consume(self, plan):
        self.check(plan, 'consume')
        if self.consumed:
            fail('operation_consumed')
        self.consumed = True
        self.consume_callback(plan)
        self.check(plan, 'consumed')


def result(plan, status, failure=None, *, entry=None, bytes_confirmed=0, sha256=None):
    return {'schema_version': 1, 'operation': plan.operation, 'operation_id': plan.upload.operation_id,
            **asdict(plan.fence), 'status': status, 'failure': failure,
            'entry': entry, 'bytes_confirmed': bytes_confirmed, 'content_sha256': sha256,
            'retry_allowed': False}


def claim_mutation(journal, plan):
    """Reuse sealed FD, lock and NOFOLLOW/fsync primitives, preserve upload schema."""
    descriptor = plan.upload
    name = 'file_mutation_' + descriptor.operation_id + '.json'
    if journal.load(descriptor.operation_id) is not None or journal._load(name) is not None:
        fail('operation_consumed')
    if journal.reservation(descriptor) is not None:
        fail('target_reserved')
    if plan.operation == 'move':
        key = hashlib.sha256(canonical({'namespace_hash': descriptor.namespace_hash,
                                       'source': plan.source.lower()})).hexdigest()
        # Blocks replay via a new ID, even after disconnect/restart or uncertain reply.
        journal._create('file_move_source_' + key + '.json', {'operation_id': descriptor.operation_id})
    journal._create(journal._target_name(descriptor), {
        'schema_version': 1, 'operation_id': descriptor.operation_id,
        'namespace_hash': descriptor.namespace_hash, 'canonical_target': descriptor.target.lower(),
        'plan_sha256': hashlib.sha256(canonical(descriptor.metadata())).hexdigest()})
    journal._create(name, {'schema_version': 1, 'plan': plan.metadata()})


class FileOperationJournal(UploadJournal):
    """Same owner-sealed FD and existing lock; cross-operation ID exclusion."""
    def load(self, operation):
        self._name(operation)  # validate canonical operation ID first
        if self._load('file_mutation_' + operation + '.json') is not None:
            fail('operation_consumed')
        return super().load(operation)


def mutate(plan, *, approval, journal, medium, source=None):
    """No write occurs without fresh native approval. No cleanup or retry API.

    All operations share the existing upload journal lock/target reservations.
    The exact non-upload intent is durably stored before consuming or effects.
    """
    attempted = False
    try:
        if type(approval) is not MutationApproval:
            fail('unsupported')
        approval.check(plan, 'admit')  # before journal, medium or source access
        if type(journal) is not FileOperationJournal:
            fail('unsupported')
        if plan.operation == 'upload_new':
            owner = OwnerBoundary(plan=plan.upload, admitted=True,
                verify=lambda stage: approval.check(plan, stage),
                current_binding=lambda: OwnerBinding.for_plan(plan.upload),
                consume_existing=lambda _: approval.consume(plan))
            uploaded = UploadNewStorage(journal=journal, medium=medium).upload(plan.upload, source, owner)
            return result(plan, uploaded.status, uploaded.failure,
                          bytes_confirmed=uploaded.bytes_confirmed, sha256=uploaded.content_sha256)
        with journal.transaction():
            claim_mutation(journal, plan)
            approval.consume(plan)
            def check():
                approval.check(plan, 'effect')
                journal.check()
            check()
            # Preflight locks/validates paths and revisions; must be read-only.
            medium.prepare(plan, check=check)
            check()
            attempted = True  # may have reached peer even without a reply
            entry = medium.mkdir(plan, check=check) if plan.operation == 'mkdir' else medium.move(plan, check=check)
            check()
            if (type(entry) is not dict or entry.get('kind') != ('directory' if plan.operation == 'mkdir' else 'file')
                    or entry.get('path') != plan.upload.target or not hex_value(entry.get('revision'), 64)):
                fail('invalid_reply')
            journal._create('file_mutation_result_' + plan.upload.operation_id + '.json',
                            {'schema_version': 1, 'status': 'committed', 'entry': entry})
            check()
            return result(plan, 'committed', entry=entry)
    except Exception as error:
        code = error.code if isinstance(error, UploadFault) else 'io_uncertain'
        # Known server collision is no effect; all other attempted writes remain uncertain.
        status = 'rejected' if isinstance(error, FileExistsError) else 'uncertain' if attempted else 'held'
        if isinstance(error, FileExistsError):
            code = 'target_exists'
        return result(plan, status, code)


def checked_download_chunks(value, *, read, verify):
    """Original scope/ref/revision on every bounded range, no automatic rebind."""
    value = request(value)
    if value['operation'] != 'download' or not callable(read) or not callable(verify):
        fail()
    args = {k: value[k] for k in ('source_ref', 'config_generation', 'connection_epoch', 'object_ref', 'revision')}
    offset = 0
    while True:
        verify()
        length = max(1, min(READ_CHUNK_BYTES, value['size'] - offset))
        page = read(dict(args, operation='read', offset=offset, length=length))
        verify()
        if type(page) is not dict:
            fail('invalid_reply')
        ScopeFence(value['source_ref'], value['config_generation'], value['connection_epoch']).check(page)
        entry = page.get('entry')
        if (type(entry) is not dict or any(type(entry.get(k)) is not type(value[k]) or entry.get(k) != value[k] for k in ('object_ref', 'revision', 'size'))
                or entry.get('kind') != 'file' or page.get('operation') != 'read'
                or type(page.get('offset')) is not int or page['offset'] != offset
                or type(page.get('length')) is not int or page['length'] != length
                or type(page.get('data_base64')) is not str
                or len(page['data_base64']) > 4 * ((length + 2) // 3)):
            fail('source_changed')
        try:
            raw = base64.b64decode(page['data_base64'], validate=True)
        except (ValueError, UnicodeError):
            fail('invalid_reply')
        expected = min(length, value['size'] - offset)
        end = offset + len(raw)
        if (base64.b64encode(raw).decode() != page['data_base64']
                or len(raw) != expected or type(page.get('bytes_read')) is not int or page['bytes_read'] != len(raw)
                or type(page.get('eof')) is not bool or page['eof'] != (end == value['size'])
                or end != value['size'] and type(page.get('next_offset')) is not int
                or page.get('next_offset') != (None if end == value['size'] else end)):
            fail('invalid_reply')
        yield raw
        offset = end
        if offset == value['size']:
            break
    verify()


def download(value, *, read, verify):
    """Small inline output only; use checked_download_chunks for larger files.

    No local path, fake URL or claimed platform attachment is returned.
    """
    value = request(value)
    if value.get('size', MAX_TRANSFER_BYTES) > MAX_INLINE_BYTES:
        fail('source_too_large')
    raw = b''.join(checked_download_chunks(value, read=read, verify=verify))
    return {'schema_version': 1, 'operation': 'download', 'operation_id': value['operation_id'],
            **{k: value[k] for k in ('source_ref', 'config_generation', 'connection_epoch', 'object_ref', 'revision')},
            'status': 'read', 'failure': None, 'transfer_kind': 'inline_base64',
            'name': value['name'], 'size': len(raw), 'sha256': hashlib.sha256(raw).hexdigest(),
            'data_base64': base64.b64encode(raw).decode(), 'downloadable_artifact': False,
            'delivery_code': 'platform_file_publisher_required'}
