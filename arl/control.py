"""Read-only control plane. Registration/observations are trusted host APIs only."""
from __future__ import annotations

import json
import re
import threading
import time
import uuid
from dataclasses import dataclass

from . import PROTOCOL, VERSION
from .contracts import Fault, encode
from .diagnostics import Diagnostics, MAX_AGE_MS
from .metrics import ResourceSampler
from .overview import label

def bounded_text(value, limit=200):
    return (type(value) is str and 0 < len(value) <= limit and
            all(ord(c) >= 32 and not 0xD800 <= ord(c) <= 0xDFFF for c in value))

def identifier(value, limit=64):
    return type(value) is str and re.fullmatch(r'[A-Za-z0-9_.-]{1,'+str(limit)+'}', value) is not None

@dataclass(frozen=True)
class AppDescriptor:
    id: str
    name: str
    icon_ref: str
    version: str | None = None
    capabilities: tuple = ()

    def validate(self):
        if not identifier(self.id) or not bounded_text(self.name) or not (
                type(self.icon_ref) is str and len(self.icon_ref) <= 80 and
                re.fullmatch(r'sf:[a-z0-9.]+',self.icon_ref)):
            raise Fault('invalid_app_descriptor')
        if self.version is not None and not identifier(self.version,80):
            raise Fault('invalid_app_descriptor')
        if type(self.capabilities) is not tuple or len(self.capabilities) > 100 or any(
                not identifier(cap,80) for cap in self.capabilities) or len(set(self.capabilities)) != len(self.capabilities):
            raise Fault('invalid_app_descriptor')

class AppRegistry:
    def __init__(self, app_ids, diagnostics, clock=None, monotonic=None):
        self.clock = clock or (lambda:int(time.time()*1000))
        self.monotonic = monotonic or (lambda:time.monotonic()*1000)
        self.app_ids, self.diagnostics = frozenset(app_ids), diagnostics
        self.lock = threading.RLock()
        self.entries = {}
        for app in sorted(self.app_ids)[:100]:
            name, icon = app, 'sf:app'
            descriptor = AppDescriptor(app,name,icon)
            descriptor.validate()
            self.entries[app] = {'descriptor':descriptor,'registration':'unregistered',
                                 'seen':None,'verified':None,'capability_checks':{}}

    def register(self, descriptor, *, active_guard=None):
        """Trusted manifest registration. Does not grant methods or authenticate."""
        descriptor.validate()
        if descriptor.id not in self.entries:
            raise Fault('unknown_app')
        with self.lock:
            self.entries[descriptor.id] = {'descriptor':descriptor,'registration':'registered',
                'seen':None,'verified':None,'capability_checks':{},'active_guard':active_guard}

    def revoke(self, app):
        with self.lock:
            if app not in self.entries:
                raise Fault('unknown_app')
            entry = self.entries[app]
            entry.update(registration='revoked',seen=None,verified=None,capability_checks={},session=None,pending=None)
            self.diagnostics.emit('app_revoked',app=app)

    def observe_verified(self, app):
        # Service calls this only with transport verifier result, never app claim.
        with self.lock:
            entry = self.entries.get(app)
            if entry is None or entry['registration'] != 'registered':
                return False
            now = self.clock()
            changed = entry['verified'] is None or now-entry['verified'] > 30000
            entry.update(verified=now,verified_mono=self.monotonic())
            if changed:
                self.diagnostics.emit('app_verified',app=app)
            return True

    def observe_capability(self, app, capability, ready):
        """Host-owned adapter health observation, not heartbeat advertisement."""
        with self.lock:
            entry = self.entries.get(app)
            if (entry is None or entry['registration'] != 'registered' or
                    capability not in entry['descriptor'].capabilities or type(ready) is not bool):
                raise Fault('invalid_capability_observation')
            entry['capability_checks'][capability] = (ready,self.clock())

    def live_session(self, entry):
        session = entry.get('session')
        if session:
            mono = self.monotonic()
            try: live = session['guard']() is True and session['renewed_mono'] <= mono < session['expires_mono']
            except Exception: live = False
            if not live:
                entry.update(session=None, expired=True)
                session = None
        return session

    def snapshot(self, policies):
        with self.lock:
            now, rows = self.clock(), []
            for app, entry in sorted(self.entries.items()):
                guard = entry.get('active_guard')
                if entry['registration'] == 'registered' and guard is not None:
                    try: active = guard() is True
                    except Exception: active = False
                    if not active:
                        self.revoke(app)
                session = self.live_session(entry)
                d, seen, registered = entry['descriptor'], entry['seen'], entry['registration']
                stale = entry.get('expired',False)
                connection = ('disconnected' if registered == 'revoked' or entry.get('closed') else 'never_seen' if seen is None else 'stale' if stale else 'connected' if session else 'disconnected')
                verified = entry['verified']
                verified_mono = entry.get('verified_mono')
                authentication = 'unverified' if verified is None or verified_mono is None else 'stale' if not 0 <= self.monotonic()-verified_mono < 30000 else 'verified'
                tools = sorted(set(session['tools']).intersection(policies[app].tools)) if session and not stale and authentication == 'verified' else []
                rows.append({'id':app,'name':d.name,'icon_ref':d.icon_ref,'version':d.version,
                    'registration':registered,'connection':connection,'authentication':authentication,
                    'authorization':'limited' if tools else 'none','last_verified_at_ms':verified,
                    'last_seen_at_ms':seen,'stale_after_ms':30000,
                    'advertised_capabilities':list(d.capabilities) if session else [],'authorized_tools':tools,
                    'handshake_session':session['id'] if session and not stale else None,
                    'session_remaining_ms':max(0,int(session['expires_mono']-self.monotonic())) if session else None})
            return rows

    def household(self, apps):
        owners = [a for a in apps if a['connection'] == 'connected' and a.get('handshake_session') and
                  any(c.startswith('household.') for c in a['advertised_capabilities'])]
        if len(owners) != 1:
            return {'owner_app':None,'state':'not_registered','read_capabilities':[],'actuation_capabilities':[]}
        owner = owners[0]
        reads = [c for c in owner['advertised_capabilities'] if c in {'household.state.read','household.events.read','household.media.read'}]
        acts = [c for c in owner['advertised_capabilities'] if c == 'household.actuate']
        with self.lock:
            checks = self.entries[owner['id']]['capability_checks']
            available = reads and all(c in checks and checks[c][0] and 0 <= self.clock()-checks[c][1] <= 30000 for c in reads)
        return {'owner_app':owner['id'],'state':'available' if available else 'unavailable',
                'read_capabilities':reads,'actuation_capabilities':acts}

class ProviderStatus:
    STATES = frozenset({'discovered','starting','ready','degraded','unavailable','disabled','unknown'})
    def __init__(self, runtime, diagnostics, clock=None, monotonic=time.monotonic):
        self.runtime, self.diagnostics = runtime, diagnostics
        self.clock = clock or (lambda:int(time.time()*1000))
        self.monotonic = monotonic
        self.lock = threading.RLock()
        self.records = {}
        self.thread = None
        self.last_attempt = None
        self.closed = False
        self.inflight = None

    def _probe(self):
        for name, provider in list(self.runtime.router.providers.items())[:100]:
            if not identifier(name):
                continue
            with self.lock:
                if self.closed: return
                self.inflight = (name,self.monotonic())
            try:
                data = provider.discover()
                availability = data.get('availability')
                evidence = data.get('evidence')
                evidence = evidence if evidence in {'local_http','test_double','host_observation'} else 'none'
                state = {'ready':'discovered' if name == 'ollama' else 'ready',
                    'not_ready':'starting','unavailable':'unavailable','disabled':'disabled'}.get(availability,'unknown')
                models = data.get('models',[])
                if type(models) is not list: models=[]
                row = {'id':name,'state':state,'checked_at_ms':self.clock(),'stale_after_ms':10000,
                    'evidence':evidence,'catalog_models':[m for m in models[:100] if label(m)],
                    'model_load_state':'not_applicable' if name == 'mock' else 'unknown',
                    'inference_enabled':bool(self.runtime.execute_jobs and not provider.paid and (name == 'mock' or self.runtime.local_enabled)
                        and any(name in p.providers and 'model.complete' in p.tools for p in self.runtime.policies.values()))}
                code = 'provider_unavailable' if state == 'unavailable' else None
            except Exception:
                row = self._empty(name); row.update(state='degraded',checked_at_ms=self.clock())
                code = 'probe_failed'
            with self.lock:
                if self.closed: return
                self.records[name] = row
                self.inflight = None
                self.diagnostics.emit('provider_check',code=code,level='warning' if code else 'info')

    def _empty(self,name):
        return {'id':name,'state':'unknown','checked_at_ms':None,'stale_after_ms':10000,
            'evidence':'none','catalog_models':[],'model_load_state':'unknown','inference_enabled':False}

    def observe(self,name,state):
        if name not in self.runtime.router.providers or state not in self.STATES:
            raise Fault('invalid_provider_observation')
        with self.lock:
            row = self.records.setdefault(name,self._empty(name))
            row.update(state=state,checked_at_ms=self.clock(),evidence='host_observation')

    def snapshot(self):
        with self.lock:
            now = self.monotonic()
            if not self.closed and (self.thread is None or not self.thread.is_alive()) and (self.last_attempt is None or now-self.last_attempt >= 5):
                self.last_attempt = now
                self.thread = threading.Thread(target=self._probe,daemon=True)
                self.thread.start()
            rows = []
            for name in list(self.runtime.router.providers)[:100]:
                if not identifier(name): continue
                row = dict(self.records.get(name,self._empty(name)))
                if row['checked_at_ms'] is not None and self.clock()-row['checked_at_ms'] > 10000 and row['state'] != 'disabled':
                    row['state'] = 'degraded'
                if self.inflight and self.inflight[0] == name and now-self.inflight[1] > 2.5:
                    row['state'] = 'degraded'
                rows.append(row)
            route = getattr(self.runtime, 'codex_service', None)
            if route is not None:
                rows = [row for row in rows if row['id'] != 'codex_app_server']
                rows.append(route.provider_status())
            return json.loads(json.dumps(rows))

    def close(self):
        with self.lock: self.closed=True

APPLE_APPS = (
    ('calendar','Calendar','sf:calendar',('list','create','update','remove')),
    ('reminders','Reminders','sf:list.bullet.rectangle',('list','create','update','complete')),
    ('notes','Notes','sf:note.text',('list','read','create','append','edit')),
    ('imessage','iMessage','sf:bubble.left.and.bubble.right',('history','send','watch')))

class CredentialReferences:
    """Opaque local aliases only. No Keychain operation, secret, account or endpoint."""
    def __init__(self):
        self.entries = {}
        self.lock = threading.Lock()

    def fixture(self, service, purpose):
        if not identifier(service) or not bounded_text(purpose):
            raise Fault('invalid_credential_descriptor')
        with self.lock:
            if len(self.entries) >= 100: raise Fault('credential_descriptor_limit')
            identity = uuid.uuid4().hex
            self.entries[identity] = {'id':identity,'service':service,'purpose':purpose,
                'state':'fixture','reference_id':uuid.uuid4().hex,'reference_status':'fixture',
                'provider_revocation':'not_performed'}
            return identity

    def remove(self, identity):
        with self.lock:
            if identity not in self.entries: raise Fault('unknown_credential_reference')
            self.entries[identity].update(state='removed',reference_id=None,reference_status='unresolved')

    def snapshot(self):
        with self.lock: return json.loads(json.dumps(list(self.entries.values())))

class ControlPlane:
    def __init__(self, runtime, *, resources=None, clock=None):
        self.runtime = runtime
        self.clock = clock or (lambda:int(time.time()*1000))
        self.diagnostics = Diagnostics(runtime.policies,clock=self.clock)
        self.apps = AppRegistry(runtime.policies,self.diagnostics,clock=self.clock)
        self.resources = resources or ResourceSampler()
        self.providers = ProviderStatus(runtime,self.diagnostics,clock=self.clock)
        self.credentials = CredentialReferences()
        self.started_at = None
        self.apple_observations = {}
        self.lock = threading.Lock()

    def start(self):
        self.started_at = self.clock()
        self.diagnostics.emit('runtime_starting')

    def observe_apple(self, action, *, permission, lock):
        if action not in {'apple.calendar.list','apple.reminders.list'} or permission not in {
                'not_checked','not_determined','denied','restricted','authorized','not_applicable'} or lock not in {'unknown','unlocked','locked','not_applicable'}:
            raise Fault('invalid_apple_observation')
        with self.lock:
            self.apple_observations[action] = {'permission':permission,'lock':lock,'checked_at_ms':self.clock()}

    def apple_snapshot(self):
        result = []
        with self.lock:
            observations = dict(self.apple_observations)
        for app,name,icon,actions in APPLE_APPS:
            rows=[]
            for operation in actions:
                action = 'apple.'+app+'.'+operation
                implemented = action in {'apple.calendar.list','apple.reminders.list'} and action in self.runtime.tools
                observation = observations.get(action)
                permission, lock, checked = ('not_checked','unknown',None) if observation is None else (observation['permission'],observation['lock'],observation['checked_at_ms'])
                stale = checked is not None and self.clock()-checked > 30000
                configured = implemented and self.runtime.apple.transport is not None
                granted = (self.runtime.identity_verifier is not None and any(action in p.tools for p in self.runtime.policies.values()))
                authorized = bool(configured and granted and permission == 'authorized' and not stale)
                state = 'not_implemented' if not implemented else 'unavailable' if not configured else 'unknown' if observation is None or stale else 'needs_permission' if permission in {'not_determined','denied','restricted'} else 'locked' if lock == 'locked' else 'ready' if authorized and lock in {'unlocked','not_applicable'} else 'unknown'
                rows.append({'id':action,'state':state,'implementation':'adapter' if implemented else 'absent',
                    'permission':permission,'lock':lock,'authorized':authorized,'checked_at_ms':checked})
            result.append({'id':app,'name':name,'icon_ref':icon,'actions':rows})
        return result

    def snapshot(self):
        now = self.clock()
        state = ('stopped' if self.runtime.closed.is_set() else 'stopping' if self.runtime.stopping.is_set()
                 else 'ready' if self.runtime.ready.is_set() else 'starting')
        apps = self.apps.snapshot(self.runtime.policies)
        gateway = getattr(self.runtime, 'application_models', None)
        if gateway is not None:
            for app in apps:
                icon = gateway.icon_snapshot(app['id'])
                if icon is not None:app['application_icon'] = icon
        result = {'schema_version':2,'protocol':PROTOCOL,'version':VERSION,'checked_at_ms':now,
            'runtime':{'state':state,'started_at_ms':self.started_at,
                'uptime_seconds':max(0,(now-self.started_at)/1000) if self.started_at is not None else None,
                'ui_required':False,'task_execution_enabled':self.runtime.execute_jobs},
            'apps':apps,'providers':self.providers.snapshot(),'resources':self.resources.sample(),
            'diagnostics':{'redaction_version':1,'retention':'current_process','max_records':1024,'max_age_ms':MAX_AGE_MS},
            'credentials':self.credentials.snapshot(),'apple_apps':self.apple_snapshot(),
            'household':self.apps.household(apps)}
        if len(encode(result)) > 120000:
            raise Fault('metadata_response_too_large')
        return result

    def close(self):
        self.providers.close()
