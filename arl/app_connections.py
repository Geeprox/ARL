"""Identity-bound bidirectional app sessions. Never enrolls or grants tools."""
import secrets
from .contracts import Fault
from .control import AppDescriptor

METHODS = frozenset({'connection.open', 'connection.confirm', 'connection.ping', 'connection.close'})
TTL_MS = 30000
CHALLENGE_MS = 10000


def token(value):
    return type(value) is str and len(value) == 64 and all(c in '0123456789abcdef' for c in value)


class AppConnections:
    def __init__(self, registry):
        self.registry = registry

    def dispatch(self, app, method, params, binding, policy):
        # Binding is transport-owned (kernel peer + exact registration generation).
        if binding is None or not callable(binding[1]) or binding[1]() is not True:
            raise Fault('app_identity_unverified')
        if type(params) is not dict:
            raise Fault('invalid_arguments')
        r = self.registry
        with r.lock:
            entry = r.entries.get(app)
            if entry is None or entry['registration'] != 'registered':
                raise Fault('method_not_authorized')
            guard = entry.get('active_guard')
            if guard is not None and guard() is not True:
                r.revoke(app)
                raise Fault('app_identity_unverified')
            now = r.clock()
            mono = r.monotonic()
            session = r.live_session(entry)
            if method == 'connection.open':
                if set(params) != {'client_nonce','name','icon_ref','version','capabilities'} or not token(params['client_nonce']):
                    raise Fault('invalid_arguments')
                caps = params['capabilities']
                if type(caps) is not list:
                    raise Fault('invalid_arguments')
                descriptor = AppDescriptor(app, params['name'], params['icon_ref'], params['version'], tuple(caps))
                descriptor.validate()
                if session and session['binding'] != binding[0]:
                    raise Fault('app_instance_conflict')
                # A pending refresh never removes the already confirmed session.
                pending = entry.get('pending')
                if pending and (pending['guard']() is not True or not 0 <= mono-pending['at_mono'] <= CHALLENGE_MS):
                    entry['pending'] = pending = None
                if pending and pending['binding'] != binding[0]:
                    raise Fault('app_instance_conflict')
                pending = {'id':secrets.token_hex(32),'challenge':secrets.token_hex(32),
                    'binding':binding[0],'guard':binding[1],'at_mono':mono,'descriptor':descriptor,
                    'tools':sorted(policy.tools.intersection(caps))}
                entry['pending'] = pending
                return {'schema_version':1,'protocol':'arl/1','client_nonce':params['client_nonce'],
                    'session_id':pending['id'],'challenge':pending['challenge'],
                    'accepted_capabilities':pending['tools'],'stale_after_ms':TTL_MS}
            if method == 'connection.confirm':
                if set(params) != {'session_id','challenge'} or not all(token(v) for v in params.values()):
                    raise Fault('invalid_arguments')
                pending = entry.get('pending')
                if (not pending or pending['binding'] != binding[0] or pending['guard']() is not True
                        or not 0 <= mono-pending['at_mono'] <= CHALLENGE_MS
                        or not secrets.compare_digest(params['session_id'],pending['id'])
                        or not secrets.compare_digest(params['challenge'],pending['challenge'])):
                    raise Fault('app_session_changed')
                if pending['tools'] != sorted(policy.tools.intersection(pending['descriptor'].capabilities)):
                    raise Fault('app_session_changed')
                # Re-register/revoke replaces the entry and its pending challenge.
                pending.update(renewed_mono=mono,expires_mono=mono+TTL_MS)
                entry.update(descriptor=pending['descriptor'],session=pending,pending=None,seen=now,verified=now,verified_mono=mono,expired=False,closed=False,capability_checks={})
                r.diagnostics.emit('app_verified',app=app)
                return self._reply(pending['id'], now)
            if set(params) != {'session_id'} or not token(params['session_id']):
                raise Fault('invalid_arguments')
            if (not session or session['binding'] != binding[0]
                    or not secrets.compare_digest(params['session_id'],session['id'])):
                raise Fault('app_session_changed')
            if method == 'connection.close':
                entry.update(session=None,pending=None,seen=None,verified=None,closed=True)
                return {'schema_version':1,'session_id':params['session_id'],'connected':False}
            session.update(renewed_mono=mono,expires_mono=mono+TTL_MS)
            entry.update(seen=now,verified=now,verified_mono=mono)
            return self._reply(session['id'], now)

    @staticmethod
    def _reply(session, now):
        return {'schema_version':1,'session_id':session,'connected':True,'checked_at_ms':now,'stale_after_ms':TTL_MS}
