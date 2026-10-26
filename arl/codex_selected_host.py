"""Explicit host composition only. No grant file, default entry point or startup."""
from __future__ import annotations
from .contracts import AppPolicy, Fault
from .codex_research import CodexResearchGrant, METHODS
from .codex_server import CodexTextAdapter, DEFAULT_BINARY
from .codex_selected import SelectedExplanationAdapter, SelectedRerankAdapter
from .codex_selected_engine import SelectedExplanationEngine, SelectedRerankEngine, SelectedReviewProducer
from . import codex_selected_contract as rank
from . import codex_sourced_contract as sourced
from .formal_peer import FormalTisraPeer, exact_file, HELPER_SHA256, TISRA_EXECUTABLE, TISRA_EXECUTABLE_SHA256
from .formal_research_host import BothPeers, FormalResearchRuntime
from .identity import RegisteredPeerVerifier
from .priority_host import PriorityHostConfig, RegisteredRouteProducer


def authorization_reuse_state(grant, authorization, operation):
    """Pure classification. Never rewrites a v2 grant's contract digest."""
    if operation not in {'explain', 'rerank'}:
        raise Fault('selected_operation_invalid')
    expected = sourced if operation == 'explain' else rank
    if type(grant) is not CodexResearchGrant:
        return 'matching_existing_grant_required'
    if (grant.contract_sha256 != expected.CONTRACT_SHA256 or
            getattr(authorization, 'tool_name', None) != expected.NAME):
        return 'contract_scope_not_authorized'
    return 'exact_per_request_review_and_current_sources_required'


def compose_selected_research(home, *, operation, grant, authorization, signed_peer,
        registered_peer, text_adapter, priority, selection_current, service_portal=None):
    """A single exact profile is registered on the existing codex method family.

    The supplied existing grant is consumed unchanged. Matching formats and
    capability digest select this profile; no RPC may select/change a profile.
    Neither this constructor nor its runtime can issue an exact review or grant.
    """
    if authorization_reuse_state(grant, authorization, operation) != 'exact_per_request_review_and_current_sources_required':
        raise Fault('selected_authorization_missing')
    if (type(signed_peer) is not FormalTisraPeer or type(registered_peer) is not RegisteredPeerVerifier or
            type(text_adapter) is not CodexTextAdapter or type(priority) is not PriorityHostConfig or
            priority.allow_synthetic or not callable(selection_current) or
            not callable(authorization) or not callable(getattr(authorization, 'current', None))):
        raise Fault('selected_host_not_admitted')
    if (grant.provider != 'codex_app_server' or type(grant.models) is not frozenset or len(grant.models) != 1 or
            type(grant.auth_epoch) is not str or not grant.auth_epoch or authorization.current() is not True):
        raise Fault('selected_authorization_missing')
    if (not exact_file(signed_peer.helper, HELPER_SHA256) or not exact_file(TISRA_EXECUTABLE, TISRA_EXECUTABLE_SHA256) or
            not text_adapter.enabled or text_adapter.test_command is not None or
            text_adapter.binary != DEFAULT_BINARY.resolve(strict=True)):
        raise Fault('research_host_identity_changed')
    text_adapter.verify()
    codec = sourced if operation == 'explain' else rank
    tasks = [t for t in priority.tasks if t.tool == codec.NAME and t.owners == frozenset({'tisra'})]
    if len(tasks) != 1 or tasks[0].task_kind != 'model.inference' or tasks[0].resource_kind != priority.resources[0].kind:
        raise Fault('selected_host_not_admitted')
    class PinnedAuthorization:
        tool_name = codec.NAME

        def current(self):
            if (authorization.current() is not True or
                    not exact_file(signed_peer.helper, HELPER_SHA256) or
                    not exact_file(TISRA_EXECUTABLE, TISRA_EXECUTABLE_SHA256)):
                return False
            text_adapter.verify()
            return True

        def __call__(self, owner, tool, args):
            if not self.current():
                raise Fault('research_host_identity_changed')
            return authorization(owner, tool, args)

    review = SelectedReviewProducer(PinnedAuthorization(), registered_peer.registration_subject, selection_current)
    native_type = SelectedExplanationAdapter if operation == 'explain' else SelectedRerankAdapter
    engine_type = SelectedExplanationEngine if operation == 'explain' else SelectedRerankEngine
    native = native_type(grant.models, text_adapter=text_adapter)
    engine = engine_type({'tisra': grant}, {'codex_app_server': native}, review)
    from .host import metadata_policies
    policies = metadata_policies()
    policies['tisra'] = AppPolicy(frozenset({engine.name}), frozenset(), 0, 16, 100,
        methods=frozenset({'health', 'ready', 'capabilities', 'priority.negotiate.v2'}) | METHODS,
        max_deadline_ms=30000)
    runtime = FormalResearchRuntime(home, policies=policies, local_enabled=False, providers={},
        identity_verifier=BothPeers(signed_peer, registered_peer), execute_jobs=True,
        codex_research=engine, admission=review, service_portal=service_portal)
    engine.runtime = runtime
    review.runtime = runtime
    producer = RegisteredRouteProducer(runtime, registered_peer, priority)
    producer.register_native(engine, task_kind=tasks[0].task_kind,
                             resource_kind=tasks[0].resource_kind, backend='codex_app_server')
    # Returning the host-only producer does not issue a review. The product must
    # explicitly attach its trusted human-review controller to approve_exact.
    return runtime, review
