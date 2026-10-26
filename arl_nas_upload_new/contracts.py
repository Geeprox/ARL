"""Host-private exact upload descriptor; it is never a grant or wire API."""
from dataclasses import asdict, dataclass
import hashlib
import json
import math
import re
import threading
import time
import uuid

MAX_BYTES = 1_048_576  # existing source MAX_RANGE; MVP is one bounded object
CHUNK_BYTES = 65_536
MAX_WRITES = 128
FAULTS = frozenset({
    'unsupported', 'invalid_plan', 'binding_mismatch', 'source_changed', 'source_too_large',
    'target_exists', 'target_reserved', 'target_replaced', 'target_missing', 'stage_exists',
    'cancelled', 'revoked', 'expired', 'operation_consumed', 'journal_uncertain', 'busy',
    'integrity_failed', 'io_uncertain', 'invalid_reply', 'budget_exceeded',
})


class UploadFault(Exception):
    def __init__(self, code):
        self.code = code if type(code) is str and code in FAULTS else 'io_uncertain'
        super().__init__(self.code)


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False).encode()


def relative_target(value):
    # A narrower subset of source relative_path: ASCII portable components,
    # no aliases from Windows trailing dots/reserved device names.
    if type(value) is not str or not 1 <= len(value.encode()) <= 1024:
        raise UploadFault('invalid_plan')
    reserved = {'CON', 'PRN', 'AUX', 'NUL', *{f'COM{i}' for i in range(1, 10)},
                *{f'LPT{i}' for i in range(1, 10)}}
    for part in value.split('/'):
        if (not 1 <= len(part.encode('utf-8')) <= 255
                or any(ord(c)<32 or ord(c)==127 or c in '\\:*?"<>|' for c in part)
                or part in {'.', '..'} or part.endswith(('.', ' ')) or part.split('.')[0].upper() in reserved):
            raise UploadFault('invalid_plan')
    return value


@dataclass(frozen=True)
class UploadPlan:
    operation_id: str
    permit_id: str
    scope_hash: str
    namespace_hash: str  # owner-bound root descriptor, separate from credential generation
    credential_generation: str
    registration_epoch: int
    target: str
    size: int
    sha256: str

    def __post_init__(self):
        try:
            if any(type(v) is not str or str(uuid.UUID(v)) != v
                   for v in (self.operation_id, self.permit_id)):
                raise ValueError()
        except (ValueError, TypeError, AttributeError):
            raise UploadFault('invalid_plan') from None
        if (self.operation_id == self.permit_id or type(self.size) is not int
                or not 0 <= self.size <= MAX_BYTES or type(self.registration_epoch) is not int
                or not 1 <= self.registration_epoch <= 2**63 - 1
                or any(type(v) is not str or re.fullmatch('[0-9a-f]{64}', v) is None
                       for v in (self.scope_hash, self.namespace_hash, self.sha256))
                or type(self.credential_generation) is not str
                or re.fullmatch('[0-9a-f]{32}', self.credential_generation) is None):
            raise UploadFault('invalid_plan')
        relative_target(self.target)

    def metadata(self):
        return asdict(self)

    @property
    def target_key(self):
        # Keep unresolved targets reserved across new IDs and generation/epoch
        # changes. ASCII case aliases are conservatively the same resource.
        return hashlib.sha256(canonical({'namespace_hash': self.namespace_hash,
                                         'target': self.target.lower()})).hexdigest()


@dataclass(frozen=True)
class OwnerBinding:
    scope_hash: str
    namespace_hash: str
    credential_generation: str
    registration_epoch: int

    def __post_init__(self):
        if (any(type(v) is not str or re.fullmatch('[0-9a-f]{64}', v) is None
                for v in (self.scope_hash, self.namespace_hash))
                or type(self.credential_generation) is not str
                or re.fullmatch('[0-9a-f]{32}', self.credential_generation) is None
                or type(self.registration_epoch) is not int or not 1 <= self.registration_epoch <= 2**63 - 1):
            raise UploadFault('binding_mismatch')

    @classmethod
    def for_plan(cls, plan):
        return cls(plan.scope_hash, plan.namespace_hash, plan.credential_generation, plan.registration_epoch)


class OwnerBoundary:
    """Default-closed private callback seam in the existing owner.

    No issuer, credential resolver, runtime, listener or deserializer. Real
    owner must consume separately reviewed write admission using its existing
    ConsumptionJournal and renew actual authority/provider binding at effects.
    Tests inject synthetic callbacks only; Boolean/ID/receipt alone grants none.
    """
    def __init__(self, *, plan=None, action='upload_new', admitted=False, verify=None,
                 current_binding=None, consume_existing=None, lifetime=10., clock=time.monotonic):
        if action not in {'upload_new', 'reconcile'}:
            raise UploadFault('invalid_plan')
        if type(lifetime) not in (int, float) or not 0 < lifetime <= 30:
            raise UploadFault('invalid_plan')
        now = clock()
        if type(now) not in (int, float) or not math.isfinite(now) or not math.isfinite(now + lifetime):
            raise UploadFault('invalid_plan')
        self._plan, self._action, self._enabled = plan, action, admitted is True
        self._verify, self._binding, self._consume = verify, current_binding, consume_existing
        self._clock, self._deadline = clock, now + lifetime
        self._cancelled = self._revoked = self._consumed = False
        self._lock = threading.Lock()

    def cancel(self):
        with self._lock:
            self._cancelled = True

    def revoke(self):
        with self._lock:
            self._revoked = True

    def _live(self, plan):
        if (not self._enabled or not callable(self._verify) or not callable(self._binding)
                or (self._action == 'upload_new' and not callable(self._consume))):
            raise UploadFault('unsupported')
        if plan is not self._plan:
            raise UploadFault('binding_mismatch')
        with self._lock:
            if self._cancelled:
                raise UploadFault('cancelled')
            if self._revoked:
                raise UploadFault('revoked')
        now = self._clock()
        if type(now) not in (int, float) or not math.isfinite(now) or now >= self._deadline:
            raise UploadFault('expired')

    def require_action(self, plan, action):
        self._live(plan)
        if self._action != action:
            raise UploadFault('binding_mismatch')

    def check(self, plan, stage):
        self._live(plan)
        self._verify(stage)
        self._live(plan)
        current = self._binding()
        if type(current) is not OwnerBinding or current != OwnerBinding.for_plan(plan):
            raise UploadFault('source_changed')
        self._verify(stage + '_after_binding')
        self._live(plan)
        current = self._binding()
        if type(current) is not OwnerBinding or current != OwnerBinding.for_plan(plan):
            raise UploadFault('source_changed')
        self._live(plan)

    def _take(self, plan):
        self.check(plan, 'consume')
        with self._lock:
            if self._consumed:
                raise UploadFault('operation_consumed')
            self._consumed = True

    def consume(self, plan):
        self.require_action(plan, 'upload_new')
        self._take(plan)
        # Owner closure uses existing consume(operationID, permitID, subject,
        # epoch, budget), after validating this descriptor under new write policy.
        self._consume(plan)
        self.check(plan, 'consumed')

    def begin_reconcile(self, plan):
        self.require_action(plan, 'reconcile')
        self._take(plan)  # fresh captured read context; original upload IDs stay consumed
        self.check(plan, 'read_admitted')
