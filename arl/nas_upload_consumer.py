"""Opt-in host consumer of upload-new core and the existing Runtime queue.

No default registration, policy, peer enrollment, path/credential decoder,
listener, provider or native journal implementation is installed here. A host
must supply sealed loans and its independently verified write admission. The
read-session credential broker grants no authority to this consumer.
"""
from dataclasses import asdict, dataclass
import hashlib
import json
import re
import threading

from .contracts import AppPolicy, Cancelled, Fault, Tool, object_schema, string, validate
from .identity import RegistrationLease
from .service import JobContext, Runtime
from .storage import Store
from arl_nas_upload_new.contracts import OwnerBinding, OwnerBoundary, UploadFault, UploadPlan, canonical
from arl_nas_upload_new.journal import UploadJournal
from arl_nas_upload_new.source import SealedSource
from arl_nas_upload_new.storage import UploadNewStorage

NAME = 'nas.upload_new.v1'
SCHEMA = object_schema({
    'operation_id': dict(string(36), pattern=r'[0-9a-f-]{36}'),
    'plan_sha256': dict(string(64), pattern=r'[0-9a-f]{64}'),
}, ('operation_id', 'plan_sha256'))


@dataclass(frozen=True)
class JournalPolicy:
    """Trusted host logical-effect policy; never the core's 128 I/O limit."""
    subject: str
    epoch: int
    budget: int

    def __post_init__(self):
        if (type(self.subject) is not str or re.fullmatch(r'[A-Za-z0-9_.-]{1,128}', self.subject) is None
                or type(self.epoch) is not int or not 1 <= self.epoch <= 2**63 - 1
                or type(self.budget) is not int or not 1 <= self.budget <= 16):
            raise Fault('nas_upload_invalid_policy')


@dataclass(frozen=True)
class UploadResources:
    """Borrowed host resources; this consumer closes only its own duplicates.

    verify_write must independently renew write consent, peer/code/profile,
    policy epoch, credential/registration lifetime and exact source/root pins.
    Returning True is not accepted. consume_existing is the existing native
    five-argument journal operation, not a client callback or new journal home.
    Native loan/bridge and vendor qualification remain outside this source slice.
    """
    source_fd: int
    journal_fd: int
    verify_source: object
    verify_journal: object
    current_binding: object
    verify_write: object
    consume_existing: object
    medium: object = None


class RuntimeUploadConsumer:
    def __init__(self, *, plan=None, peer=None, resources=None, journal_policy=None):
        self.plan, self.peer, self.resources, self.journal_policy = plan, peer, resources, journal_policy
        self._runtime = self._policy = self._store = None
        self._captured = None
        self._lock = threading.Lock()
        self._cancelled, self._revoked = threading.Event(), threading.Event()
        self._attempted = False
        self.last_result = None
        self._tool = Tool(NAME, SCHEMA, self.run, idempotent=False,
            permissions=('nas_upload_new_exact', 'host_owned_resources', 'existing_consumption_journal'),
            completion_fence=self.check_completion,
            availability='not_implemented', description='Host-captured exact upload; no public source or credential path.')

    def tool(self):
        return self._tool

    def arguments(self):
        if type(self.plan) is not UploadPlan:
            raise Fault('nas_upload_not_configured')
        return {'operation_id': self.plan.operation_id,
                'plan_sha256': hashlib.sha256(canonical(self.plan.metadata())).hexdigest()}

    def attach(self, runtime):
        """Explicit private host composition; does not change Runtime defaults."""
        if self._runtime is not None or type(runtime) is not Runtime or type(self.peer) is not RegistrationLease:
            raise Fault('nas_upload_not_configured')
        policy = runtime.policies.get(self.peer.subject)
        if (type(policy) is not AppPolicy or NAME not in policy.tools
                or runtime.tools.get(NAME) is not self._tool or runtime.admission != self.admit
                or runtime.identity_verifier is not self.peer._verifier):
            raise Fault('nas_upload_not_configured')
        self._runtime, self._policy = runtime, policy
        self._captured = (self.plan, self.peer, self.resources, self.journal_policy)

    def cancel(self):
        self._cancelled.set()

    def revoke(self):
        self._revoked.set()

    def _configured(self):
        resource = self.resources
        if (type(self.plan) is not UploadPlan or type(self.peer) is not RegistrationLease
                or type(resource) is not UploadResources or type(self.journal_policy) is not JournalPolicy
                or self.journal_policy.subject != self.peer.subject
                or self.plan.registration_epoch != self.peer.epoch or self._runtime is None
                or self._captured is None
                or any(current is not captured for current, captured in zip(
                    (self.plan, self.peer, self.resources, self.journal_policy), self._captured))
                or resource.medium is None
                or any(not callable(getattr(resource, name)) for name in
                       ('verify_source', 'verify_journal', 'current_binding', 'verify_write', 'consume_existing'))
                or any(type(getattr(resource, name)) is not int or getattr(resource, name) < 0
                       for name in ('source_fd', 'journal_fd'))):
            raise UploadFault('unsupported')

    def _check(self, stage, context=None):
        self._configured()
        runtime = self._runtime
        if self._cancelled.is_set():
            raise UploadFault('cancelled')
        if self._revoked.is_set():
            raise UploadFault('revoked')
        if (runtime.stopping.is_set() or not runtime.ready.is_set()
                or runtime.policies.get(self.peer.subject) is not self._policy
                or runtime.tools.get(NAME) is not self._tool or runtime.admission != self.admit
                or runtime.identity_verifier is not self.peer._verifier or not self.peer.is_current()):
            raise UploadFault('revoked')
        if type(runtime.store) is not Store:
            raise UploadFault('unsupported')
        with self._lock:
            if self._store is None:
                self._store = runtime.store
            if runtime.store is not self._store:
                raise UploadFault('revoked')
        if context is not None:
            self._context(context)
        # This is the host's write boundary; read scope or a Boolean is not it.
        if self.resources.verify_write(stage) is not None:
            raise UploadFault('unsupported')
        # Renew after a possibly blocking native/policy verification.
        if (self._cancelled.is_set() or runtime.stopping.is_set()):
            raise UploadFault('cancelled')
        if (self._revoked.is_set() or runtime.policies.get(self.peer.subject) is not self._policy
                or runtime.tools.get(NAME) is not self._tool or runtime.admission != self.admit
                or runtime.identity_verifier is not self.peer._verifier or runtime.store is not self._store
                or not self.peer.is_current()):
            raise UploadFault('revoked')
        # is_current() may itself block in process introspection.
        if self._cancelled.is_set() or runtime.stopping.is_set():
            raise UploadFault('cancelled')
        if self._revoked.is_set() or not runtime.ready.is_set():
            raise UploadFault('revoked')
        self._configured()
        if context is not None:
            self._context(context)
        if self._cancelled.is_set() or runtime.stopping.is_set():
            raise UploadFault('cancelled')
        if (self._revoked.is_set() or not runtime.ready.is_set()
                or runtime.policies.get(self.peer.subject) is not self._policy
                or runtime.tools.get(NAME) is not self._tool or runtime.admission != self.admit
                or runtime.identity_verifier is not self.peer._verifier or runtime.store is not self._store):
            raise UploadFault('revoked')

    def _context(self, context):
        if (type(context) is not JobContext or context.runtime is not self._runtime
                or context.owner != self.peer.subject):
            raise UploadFault('binding_mismatch')
        try:
            context.check_cancelled()
            with self._store.lock:
                row = dict(self._store.row(context.owner, context.row['id']))
            if (row['state'] != 'running' or row['attempts'] != 1 or row['cancel']
                    or row['key'] != self.plan.operation_id or row['tool'] != NAME
                    or row['tool_contract'] != self._tool.contract_digest()
                    or row['idempotent'] != 0 or row['requires_identity'] != 1
                    or row['identity_authorized'] != 1 or json.loads(row['args']) != self.arguments()):
                raise UploadFault('binding_mismatch')
        except Cancelled:
            raise UploadFault('cancelled') from None
        except Fault as error:
            raise UploadFault('expired' if error.code == 'deadline_exceeded' else 'binding_mismatch') from None

    def admit(self, owner, name, args):
        """Installed as Runtime's existing admission hook, renewed by work()."""
        try:
            validate(args, SCHEMA)
            if (type(self.peer) is not RegistrationLease or owner != self.peer.subject
                    or name != NAME or args != self.arguments()):
                raise UploadFault('binding_mismatch')
            self._check('runtime_admission')
        except (UploadFault, Fault) as error:
            raise Fault('nas_upload_' + error.code) from None

    def run(self, args, context):
        source = journal = None
        try:
            if type(context) is not JobContext:
                raise UploadFault('binding_mismatch')
            self.admit(context.owner, NAME, args)
            self._check('runtime_claim', context)
            with self._lock:
                if self._attempted:
                    raise UploadFault('operation_consumed')
                self._attempted = True  # no retry/reset even on preflight failure
            resource, policy, plan = self.resources, self.journal_policy, self.plan
            source = SealedSource(resource.source_fd, verify_pin=resource.verify_source)
            journal = UploadJournal(resource.journal_fd, verify_seal=resource.verify_journal)

            def binding():
                self._check('before_binding', context)
                current = resource.current_binding()
                self._check('after_binding', context)
                if type(current) is not OwnerBinding:
                    raise UploadFault('source_changed')
                return current

            def consume(captured):
                if captured is not plan:
                    raise UploadFault('binding_mismatch')
                self._check('native_consume', context)
                # Host policy epoch/budget; neither comes from public args or MAX_WRITES.
                try:
                    reply = resource.consume_existing(plan.operation_id, plan.permit_id,
                        policy.subject, policy.epoch, policy.budget)
                except Fault as error:
                    mapping = {'effect_budget_exceeded': 'budget_exceeded',
                               'operation_consumed': 'operation_consumed',
                               'unsafe_journal': 'journal_uncertain'}
                    raise UploadFault(mapping.get(error.code, 'journal_uncertain')) from None
                if reply is not None:
                    raise UploadFault('journal_uncertain')
                self._check('native_consumed', context)

            owner = OwnerBoundary(plan=plan, admitted=True,
                verify=lambda stage: self._check(stage, context), current_binding=binding,
                consume_existing=consume, lifetime=context.remaining(30))
            self.last_result = UploadNewStorage(journal=journal, medium=resource.medium).upload(plan, source, owner)
            if self.last_result.status != 'committed':
                raise UploadFault(self.last_result.failure or 'io_uncertain')
            self._check('runtime_publish', context)
            return {'schema_version': 1, **asdict(self.last_result)}
        except UploadFault as error:
            # Existing non-idempotent Runtime work maps this to needs_review; no resume/replay.
            raise Fault('nas_upload_' + error.code) from None
        finally:
            if source is not None:
                source.close()
            if journal is not None:
                journal.close()

    def check_completion(self, result, context):
        """Invoked by Store inside its opt-in terminal publication transaction.

        The returned committed effect is preserved even if authority is now
        held. Store, rather than a handler tail check, serializes durable cancel
        and completion. Native/remote authority qualification remains held.
        """
        try:
            if (type(result) is not dict or result != {'schema_version': 1,
                    'status': 'committed', 'failure': None, 'bytes_confirmed': self.plan.size,
                    'content_sha256': self.plan.sha256}):
                raise UploadFault('binding_mismatch')
            self._check('durable_completion', context)
            self.resources.verify_source()
            self.resources.verify_journal()
            current = self.resources.current_binding()
            self._check('durable_completion_after_binding', context)
            if type(current) is not OwnerBinding or current != OwnerBinding.for_plan(self.plan):
                raise UploadFault('source_changed')
        except UploadFault as error:
            raise Fault('nas_upload_' + error.code) from None
