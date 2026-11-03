"""Explicit host composition for a trusted application's resolved Codex requests.

No default activation, enrollment, account setup or new queue. A native host must
supply its existing scoped CodexService, signed/registered peer and AppPolicy.
The isolated option is for developer acceptance with a real kernel peer only.
"""
from __future__ import annotations

import hashlib
import json

from .application_models import METHODS as MODEL_METHODS, canonical_uuid
from .app_connections import token
from .codex_server import CodexService
from .contracts import AppPolicy, Fault, validate
from .service import Runtime

EXECUTE = 'application.codex.execute.v1'
RECOVER = 'application.codex.recover.v1'
EXECUTION_METHODS = frozenset({EXECUTE, RECOVER})
_REQUIRED = MODEL_METHODS | EXECUTION_METHODS | {'health', 'ready', 'capabilities', 'get', 'cancel', 'heartbeat'}


def scoped_application_policy(service, *, priority_bands=frozenset({'explicit'}), legacy_submit=False):
    """Trusted host opt-in, carrying the same caller/tool and existing call quota.

    Explicit priority is the default. Broader bands must be chosen by the host;
    the RPC request cannot change them. legacy_submit preserves an existing GUI
    consumer's original method when upgrading that same native scoped caller.
    """
    if type(service) is not CodexService or type(legacy_submit) is not bool:
        raise Fault('codex_service_not_admitted')
    return AppPolicy(frozenset({service.name}), providers=frozenset(), max_tokens=0,
        max_pending=1, max_calls=service.max_calls,
        methods=_REQUIRED | ({'submit'} if legacy_submit else set()),
        priority_bands=priority_bands, max_deadline_ms=30000)


class CodexApplicationRuntime(Runtime):
    """Same Runtime/Store worker; derives execution only from a server resolution."""

    application_execution_methods = EXECUTION_METHODS

    def dispatch(self, request, *, verified_app=None, peer_binding=None):
        if type(request) is not dict or request.get('method') not in EXECUTION_METHODS:
            result = super().dispatch(request, verified_app=verified_app, peer_binding=peer_binding)
            if (type(request) is dict and request.get('method') == 'application.models.discover.v1'
                    and request.get('app') == self.codex_service.caller):
                result = dict(result, execution={'method': EXECUTE, 'recover_method': RECOVER,
                    'tool': self.codex_service.name, 'scope_generation': self.codex_service.scope_generation,
                    'explicit_submission_only': True})
            return result
        if set(request) != {'protocol', 'app', 'method', 'params'} or request['protocol'] != 'arl/1':
            raise Fault('invalid_request')
        owner, method, p = request['app'], request['method'], request['params']
        if type(owner) is not str or owner not in self.policies:
            raise Fault('unknown_app')
        policy = self.policies[owner]
        if (owner != self.codex_service.caller or method not in policy.methods
                or self.codex_service.name not in policy.tools):
            raise Fault('method_not_authorized')
        if verified_app != owner or self.identity_verifier is None or peer_binding is None:
            raise Fault('app_identity_unverified')
        if not self.ready.is_set() or self.stopping.is_set() or self.store is None:
            raise Fault('not_ready')
        common = {'schema_version', 'session_id', 'request_id', 'request_sha256'}
        fields = common | ({'resolution_id', 'input', 'max_output_bytes'} if method == EXECUTE else set())
        if (type(p) is not dict or set(p) != fields or type(p['schema_version']) is not int
                or p['schema_version'] != 1 or not canonical_uuid(p['request_id'])
                or not token(p['request_sha256'])):
            raise Fault('application_models_invalid_arguments')
        registry = self.application_models.registry
        with registry.lock:
            self.application_models._session(owner, p['session_id'], peer_binding)
            if method == RECOVER:
                return self._recover(owner, p)
            if not token(p['resolution_id']) or type(p['input']) is not str:
                raise Fault('application_models_invalid_arguments')
            try:
                actual_sha = hashlib.sha256(p['input'].encode('utf-8')).hexdigest()
            except UnicodeError:
                raise Fault('application_models_invalid_arguments') from None
            if actual_sha != p['request_sha256']:
                raise Fault('application_models_request_changed')
            record = self.application_models.requests.get((owner, p['request_id']))
            if (not record or record['params']['session_id'] != p['session_id']
                    or record['params']['request_sha256'] != p['request_sha256']
                    or not record['receipt']['accepted']
                    or record['receipt'].get('resolution_id') != p['resolution_id']):
                raise Fault('application_models_request_changed')
            if 'job_id' not in record:
                if not 0 <= self.application_models.clock()-record['at'] < 30:
                    raise Fault('application_models_request_changed')
                current, _ = self.application_models._discovery(owner, p['session_id'])
                if current['catalog_version'] != record['receipt']['catalog_version']:
                    raise Fault('application_models_catalog_changed')
            selected = record['receipt']['resolved']
            args = {'input': p['input'], 'max_output_bytes': p['max_output_bytes'],
                'model': selected['model'], 'reasoning_effort': selected['effort'],
                'service_tier': selected['service_tier']}
            tool = self.tools[self.codex_service.name]
            validate(args, tool.schema)
            self.codex_service.admit(owner, tool.name, args)
            if self.admission is None:
                raise Fault('codex_scope_unavailable')
            if self.admission != self.codex_service.admit:
                self.admission(owner, tool.name, args)
            # Store enforces the original UUID/body/schedule, identity, pending and
            # durable call budget. Its commit precedes the in-memory observation;
            # a lost reply is reconciled by RECOVER, never a replacement UUID.
            job = self.store.submit(owner, p['request_id'], tool, args, policy, verified=True,
                schedule={k: selected[k] for k in ('priority', 'deadline_ms')})
            record['job_id'] = job['id']
            self.job_signal.set()
            return self._projection(owner, p, job)

    def _recover(self, owner, p):
        with self.store.lock:
            row = self.store.db.execute('SELECT id FROM jobs WHERE owner=? AND key=? AND tool=?',
                (owner, p['request_id'], self.codex_service.name)).fetchone()
            if row is None:
                raise Fault('application_models_execution_unknown')
            # Reuse the normal private-result authorization and progress path.
            job = super().dispatch({'protocol': 'arl/1', 'app': owner, 'method': 'get',
                'params': {'id': row['id']}}, verified_app=owner)
            return self._projection(owner, p, job)

    def _projection(self, owner, p, job):
        with self.store.lock:
            row = self.store.row(owner, job['id'])
            args = json.loads(row['args'])
            actual_sha = hashlib.sha256(args['input'].encode('utf-8')).hexdigest()
            if actual_sha != p['request_sha256']:
                raise Fault('application_models_request_changed')
            return {'schema_version': 1, 'request_id': p['request_id'], 'request_sha256': actual_sha,
                'job': job, 'execution': {'model': args['model'], 'effort': args['reasoning_effort'],
                    'service_tier': args['service_tier'], 'priority': row['priority'],
                    'deadline_ms': row['deadline_span'], 'deadline_at_ms': int(row['deadline_at']*1000)}}


def compose_codex_application(home, *, service, peer_verifier, policy, isolated=False, service_portal=None):
    """Installable native-host seam, activated only with an explicit host policy.

    Production requires the existing code-signature AND registered-kernel peer.
    The policy is a trusted Python object, never an RPC field or config discovery.
    Existing finite/unlimited call limits and the one-pending route are preserved.
    """
    from pathlib import Path
    from .compat_host import CodexCallerPeer, PeerComposition, metadata_policies, state_home
    from .control import AppDescriptor
    from .identity import RegisteredPeerVerifier
    if (type(isolated) is not bool or type(service) is not CodexService or service.runtime is not None or not service.current()
            or not service.allow_model_selection or type(policy) is not AppPolicy
            or type(policy.tools) is not frozenset or policy.tools != frozenset({service.name})
            or type(policy.providers) is not frozenset or policy.providers
            or (policy.max_calls is not None and type(policy.max_calls) is not int)
            or policy.max_calls != service.max_calls or type(policy.max_pending) is not int or policy.max_pending != 1
            or type(policy.max_deadline_ms) is not int or not 1 <= policy.max_deadline_ms <= 30000
            or type(policy.methods) is not frozenset or not _REQUIRED <= policy.methods
            or type(policy.priority_bands) is not frozenset
            or not policy.priority_bands <= {'background', 'explicit', 'interactive'}
            or not policy.priority_bands or policy.default_priority not in policy.priority_bands
            or policy.public_metadata
            or (not isolated and (type(peer_verifier) is not CodexCallerPeer or service.adapter.test_command is not None))
            or (isolated and (type(peer_verifier) is not RegisteredPeerVerifier
                or Path(home).resolve() == state_home().resolve()))):
        raise Fault('codex_service_not_admitted')
    registered = peer_verifier if isolated else peer_verifier.registered
    if service.caller not in registered.app_ids or (not isolated and peer_verifier.caller != service.caller):
        raise Fault('codex_caller_unverified')
    policies = metadata_policies()
    if service.caller in policies:
        raise Fault('codex_caller_conflict')
    policies[service.caller] = policy
    runtime = CodexApplicationRuntime(home, policies=policies, providers={}, local_enabled=False,
        extra_tools=[service.tool()], identity_verifier=PeerComposition((peer_verifier,)),
        execute_jobs=True, codex_service=service, admission=service.admit,
        work_scope=frozenset({(service.caller, service.name)}), service_portal=service_portal,
        application_catalog=lambda app: service.status()['execution_catalog'])
    from .codex_context import TRANSPORT_FRAME_BYTES
    runtime.max_request_frame_bytes = TRANSPORT_FRAME_BYTES
    service.runtime = runtime
    runtime.control.apps.register(AppDescriptor(service.caller, 'Codex application', 'sf:cpu',
        capabilities=(service.name,)))
    return runtime
