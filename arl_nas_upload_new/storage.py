"""Bounded private upload-new algorithm; no NAS medium/runtime is supplied.

Required medium semantics: private exclusive stage, acknowledged writes/flush,
strong object/revision checks, atomic durable NO-REPLACE publication, read-only
reopen, bounded I/O under the same owner authority. The controlled POSIX medium
in tests demonstrates bytes only; it is not exported or a NAS adapter.
"""
from dataclasses import dataclass
import hashlib
from .contracts import CHUNK_BYTES, MAX_BYTES, OwnerBoundary, UploadFault, UploadPlan
from .journal import object_identity


@dataclass(frozen=True)
class Result:
    status: str
    failure: str | None
    bytes_confirmed: int = 0  # stage bytes; not proof of target publication
    content_sha256: str | None = None


def _fault(error):
    if isinstance(error, UploadFault):
        return error.code
    return 'io_uncertain'  # never exception text, byte fragments, path or credentials


class UploadNewStorage:
    def __init__(self, *, journal, medium):
        self._journal, self._medium = journal, medium

    @staticmethod
    def _validate_plan(plan):
        if type(plan) is not UploadPlan:
            raise UploadFault('invalid_plan')
        UploadPlan(**plan.metadata())

    def _guard(self, plan, owner, stage, source=None, handle=None):
        owner.check(plan, stage)
        if source is not None:
            source.check()
        self._journal.check()
        self._medium.check()
        self._medium.check_namespace(plan.namespace_hash)
        if handle is not None:
            handle.check()
        owner.check(plan, stage + '_after_seals')

    def _readback(self, plan, owner, handle, source=None):
        self._guard(plan, owner, 'before_size', source, handle)
        size = handle.size()
        self._guard(plan, owner, 'after_size', source, handle)
        if type(size) is not int or size != plan.size or not 0 <= size <= MAX_BYTES:
            raise UploadFault('integrity_failed')
        revision = object_identity(handle.revision())
        self._guard(plan, owner, 'read_revision', source, handle)
        digest = hashlib.sha256()
        for offset in range(0, size, CHUNK_BYTES):
            count = min(CHUNK_BYTES, size - offset)
            self._guard(plan, owner, 'before_read', source, handle)
            data = handle.read(offset, count,
                               effect_check=lambda: self._guard(plan, owner, 'read_effect', source, handle))
            self._guard(plan, owner, 'after_read', source, handle)
            if type(data) is not bytes or len(data) != count:
                raise UploadFault('invalid_reply')
            digest.update(data)
        self._guard(plan, owner, 'before_readback_end', source, handle)
        final_size, final_revision = handle.size(), handle.revision()
        self._guard(plan, owner, 'after_readback_end', source, handle)
        if type(final_size) is not int or final_size != size or final_revision != revision:
            raise UploadFault('integrity_failed')
        content = digest.hexdigest()
        if content != plan.sha256:
            raise UploadFault('integrity_failed')
        return content, revision

    def _closed_target_guard(self, plan, owner, stage, identity, revision, source=None):
        self._guard(plan, owner, stage, source)
        self._medium.check_identity(plan.target, identity, revision=revision,
                                    effect_check=lambda: self._guard(plan, owner, 'identity_effect', source))
        self._guard(plan, owner, stage + '_after_identity', source)

    def _verify_final(self, plan, owner, identity, source=None):
        handle = None
        try:
            self._guard(plan, owner, 'before_reopen', source)
            try:
                handle = self._medium.open_readonly(plan.target, identity,
                    effect_check=lambda: self._guard(plan, owner, 'reopen_effect', source))
            except FileNotFoundError:
                raise UploadFault('target_missing') from None
            if handle is None:
                raise UploadFault('invalid_reply')
            if object_identity(handle.identity) != identity:
                raise UploadFault('target_replaced')
            self._guard(plan, owner, 'after_reopen', source, handle)
            content, revision = self._readback(plan, owner, handle, source)
            self._guard(plan, owner, 'before_read_close', source, handle)
            closing, handle = handle, None
            if closing.close() is not None:
                raise UploadFault('invalid_reply')
            self._closed_target_guard(plan, owner, 'after_read_close', identity, revision, source)
            return content, revision
        finally:
            if handle is not None:
                try:
                    handle.close()
                except Exception:
                    pass

    def upload(self, plan, source, owner):
        handle, receipt = None, None
        stage_attempted = known_conflict = False
        try:
            self._validate_plan(plan)
            if type(owner) is not OwnerBoundary:
                raise UploadFault('unsupported')
            owner.require_action(plan, 'upload_new')
            owner.check(plan, 'admit_upload')  # default closed before all source/journal/medium calls
            source.validate(plan)
            self._guard(plan, owner, 'preflight', source)
            if self._medium.require_atomic_new() is not None:
                raise UploadFault('unsupported')
            self._guard(plan, owner, 'atomic_preflight', source)
            with self._journal.transaction():
                if self._journal.load(plan.operation_id) is not None:
                    raise UploadFault('operation_consumed')
                receipt = self._journal.begin(plan)
                try:
                    owner.consume(plan)  # existing five-argument consumption journal, not this metadata ledger
                    self._guard(plan, owner, 'before_absence', source)
                    try:
                        self._medium.assert_absent(plan.target,
                            effect_check=lambda: self._guard(plan, owner, 'absence_effect', source))
                    except FileExistsError:
                        known_conflict = True
                        raise UploadFault('target_exists') from None
                    self._guard(plan, owner, 'before_stage', source)
                    receipt['state'] = 'staging'
                    self._journal.save(plan.operation_id, receipt)
                    self._guard(plan, owner, 'stage_sealed', source)
                    stage_attempted = True  # unacknowledged create may have happened; never repeat it
                    try:
                        handle = self._medium.create_stage(plan.operation_id, plan.target,
                            effect_check=lambda: self._guard(plan, owner, 'create_effect', source))
                    except FileExistsError:
                        raise UploadFault('stage_exists') from None
                    receipt['identity'] = object_identity(handle.identity)
                    self._guard(plan, owner, 'after_stage', source, handle)
                    receipt['state'] = 'writing'
                    self._journal.save(plan.operation_id, receipt)
                    offset, sent = 0, hashlib.sha256()
                    while offset < plan.size:
                        self._guard(plan, owner, 'before_source_read', source, handle)
                        data = source.read(offset, min(CHUNK_BYTES, plan.size - offset))
                        if type(data) is not bytes or not 0 < len(data) <= min(CHUNK_BYTES, plan.size - offset):
                            raise UploadFault('invalid_reply')
                        self._guard(plan, owner, 'before_write', source, handle)
                        count = handle.write(offset, data,
                            effect_check=lambda: self._guard(plan, owner, 'write_effect', source, handle))
                        self._guard(plan, owner, 'after_write', source, handle)
                        if type(count) is not int or not 0 < count <= len(data):
                            raise UploadFault('invalid_reply')
                        sent.update(data[:count])
                        offset += count
                        receipt['bytes_confirmed'] = offset
                        self._journal.save(plan.operation_id, receipt)
                    if sent.hexdigest() != plan.sha256:
                        raise UploadFault('integrity_failed')
                    self._guard(plan, owner, 'before_flush', source, handle)
                    if handle.flush(effect_check=lambda: self._guard(plan, owner, 'flush_effect', source, handle)) is not None:
                        raise UploadFault('invalid_reply')
                    self._guard(plan, owner, 'after_flush', source, handle)
                    content, stage_revision = self._readback(plan, owner, handle, source)
                    source.validate(plan)
                    receipt.update(state='ready', content_sha256=content)
                    self._journal.save(plan.operation_id, receipt)
                    self._guard(plan, owner, 'before_commit', source, handle)
                    if handle.revision() != stage_revision:
                        raise UploadFault('integrity_failed')
                    receipt['state'] = 'committing'
                    self._journal.save(plan.operation_id, receipt)
                    self._guard(plan, owner, 'commit_sealed', source, handle)
                    try:
                        ack = self._medium.commit_new(handle, plan.target, expected_revision=stage_revision,
                            effect_check=lambda: self._guard(plan, owner, 'commit_effect', source, handle))
                    except FileExistsError:
                        known_conflict = True
                        raise UploadFault('target_exists') from None
                    if ack is not None:
                        raise UploadFault('invalid_reply')
                    self._guard(plan, owner, 'after_commit', source, handle)
                    closing, handle = handle, None
                    if closing.close() is not None:
                        raise UploadFault('invalid_reply')
                    content, revision = self._verify_final(plan, owner, receipt['identity'], source)
                    receipt.update(state='committed', failure=None)
                    self._journal.save(plan.operation_id, receipt)
                    self._closed_target_guard(plan, owner, 'publish', receipt['identity'], revision, source)
                    return Result('committed', None, plan.size, content)
                except Exception as error:
                    code = _fault(error)
                    uncertain = stage_attempted and not known_conflict
                    receipt.update(state='uncertain' if uncertain else 'rejected', failure=code)
                    try:
                        self._journal.save(plan.operation_id, receipt)
                    except Exception:
                        code = 'journal_uncertain'
                    return Result('uncertain' if uncertain else ('rejected' if known_conflict else 'held'),
                                  code, receipt['bytes_confirmed'])
        except Exception as error:
            return Result('uncertain' if stage_attempted else 'held', _fault(error),
                          receipt['bytes_confirmed'] if receipt else 0)
        finally:
            if handle is not None:
                try:
                    handle.close()
                except Exception:
                    pass  # close cannot authorize a retry, cleanup or positive result

    def reconcile(self, plan, owner):
        """Read-only observation under a fresh captured read context.

        No create/write/flush/commit/delete or journal save/reset/release. A
        matching full hash/length and original object identity proves existing
        bytes now; it does not re-execute or retrospectively acknowledge commit.
        """
        try:
            self._validate_plan(plan)
            if type(owner) is not OwnerBoundary:
                raise UploadFault('unsupported')
            owner.require_action(plan, 'reconcile')
            owner.begin_reconcile(plan)
            self._guard(plan, owner, 'admit_reconcile')
            with self._journal.transaction(readonly=True):
                receipt = self._journal.load(plan.operation_id)
                if receipt is None or receipt['plan'] != plan.metadata():
                    raise UploadFault('binding_mismatch')
                self._journal.check_reservation(plan)
                if receipt['state'] == 'rejected' or receipt['identity'] is None:
                    return Result('unresolved', receipt['failure'] or 'io_uncertain')
                content, revision = self._verify_final(plan, owner, receipt['identity'])
                self._closed_target_guard(plan, owner, 'publish_reconcile', receipt['identity'], revision)
                return Result('verified_existing_bytes', None, plan.size, content)
        except Exception as error:
            return Result('unresolved', _fault(error))
