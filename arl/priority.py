"""Host policy and resource accounting for the existing Store jobs queue.

No adapter, enrollment, extra queue or external process lives here. Every
function touching SQLite is called under the Store's existing transaction.
"""
from dataclasses import dataclass, asdict
import hashlib
import json
import time
import uuid
from .contracts import Fault, encode

CLASSES = {'background': 0, 'interactive': 1, 'realtime': 2}
METHODS = frozenset({'priority.negotiate.v1', 'priority.negotiate.v2', 'priority.submit.v1'})
MAX_BYPASSES = 8
AGING_SECONDS = 30
ROUTE_METHODS = frozenset({'priority.submit.v1','research.submit.v1','codex.research.submit.v1'})
REQUEST_KEYS = frozenset({'profile_id', 'policy_epoch', 'task_kind', 'requested_class',
    'deadline_at_ms', 'resource_kind', 'estimate_ms', 'allow_interrupt', 'allow_fallback'})


def integer(value, minimum, maximum):
    if type(value) is not int or not minimum <= value <= maximum:
        raise Fault('priority_invalid_arguments')


def text(value, maximum=100):
    if type(value) is not str or not 1 <= len(value) <= maximum:
        raise Fault('priority_invalid_arguments')


def validate_request(value):
    if type(value) is not dict or not REQUEST_KEYS <= set(value) or set(value)-REQUEST_KEYS-{'minimum_class'}:
        raise Fault('priority_invalid_arguments')
    for name in ('profile_id', 'policy_epoch', 'task_kind', 'resource_kind'):
        text(value[name])
    if type(value['requested_class']) is not str or type(value.get('minimum_class','background')) is not str or value['requested_class'] not in CLASSES or value.get('minimum_class', 'background') not in CLASSES:
        raise Fault('priority_invalid_arguments')
    if CLASSES[value.get('minimum_class', 'background')] > CLASSES[value['requested_class']]:
        raise Fault('priority_invalid_arguments')
    integer(value['deadline_at_ms'], 1, 2**53-1)
    integer(value['estimate_ms'], 1, 600000)
    for name in ('allow_interrupt', 'allow_fallback'):
        if type(value[name]) is not bool:
            raise Fault('priority_invalid_arguments')


def validate_profile(value):
    keys={'schema_version','profile_id','policy_epoch','identity_bound','allowed_classes','task_kinds',
          'limits','resources','cancel_ack_releases_slot','preemption','real_time_guarantee','reasons'}
    try:
        if type(value) is not dict or set(value)!=keys or type(value['schema_version']) is not int or value['schema_version']!=1:
            raise Fault('priority_invalid_response')
        text(value['profile_id']);text(value['policy_epoch'])
        if value['identity_bound'] is not True or value['cancel_ack_releases_slot'] is not False or value['real_time_guarantee'] is not False or value['preemption']!='not_qualified':
            raise Fault('priority_invalid_response')
        classes=value['allowed_classes']
        if type(classes) is not list or not 1<=len(classes)<=3 or any(type(c) is not str or c not in CLASSES for c in classes) or len(set(classes))!=len(classes):
            raise Fault('priority_invalid_response')
        kinds=value['task_kinds']
        if type(kinds) is not list or len(kinds)>256 or any(type(k) is not str or not 1<=len(k)<=100 for k in kinds) or len(set(kinds))!=len(kinds):
            raise Fault('priority_invalid_response')
        limits=value['limits']
        bounds={'queue':256,'per_resource_inflight':8,'burst_calls':1000,'burst_window_ms':60000,'max_deadline_ms':600000,'weight':16}
        if type(limits) is not dict or set(limits)!=set(bounds):raise Fault('priority_invalid_response')
        for name,maximum in bounds.items():integer(limits[name],1,maximum)
        resources=value['resources']
        resource_keys=set(ResourcePolicy.__dataclass_fields__)
        if type(resources) is not dict or len(resources)>16:raise Fault('priority_invalid_response')
        for name,resource in resources.items():
            text(name,64)
            if type(resource) is not dict or set(resource)!=resource_keys or resource['kind']!=name:
                raise Fault('priority_invalid_response')
            ResourcePolicy(**resource)
        if type(value['reasons']) is not list or len(value['reasons'])>3 or any(type(r) is not str or r not in {
            'unknown_authenticated_app_background_only','requested_classes_not_granted','conservative_background_profile'} for r in value['reasons']):
            raise Fault('priority_invalid_response')
    except (Fault,KeyError,TypeError,ValueError):
        raise Fault('priority_invalid_response') from None


@dataclass(frozen=True)
class ResourcePolicy:
    kind: str
    slots: int = 1
    realtime_reserved: int = 0
    queue_limit: int = 32
    class_queue_limit: int = 16
    background_start_limit_ms: int = 1000
    cooperative_cancel: bool = False
    capacity_evidence: str = 'host_configured_unqualified'

    def __post_init__(self):
        text(self.kind, 64)
        integer(self.slots, 1, 8)
        integer(self.realtime_reserved, 0, self.slots-1)
        integer(self.queue_limit, 1, 256)
        integer(self.class_queue_limit, 1, self.queue_limit)
        integer(self.background_start_limit_ms, 1, 600000)
        if type(self.cooperative_cancel) is not bool:
            raise Fault('priority_invalid_host_policy')
        text(self.capacity_evidence)


@dataclass(frozen=True)
class AppProfilePolicy:
    allowed_classes: frozenset = frozenset({'background'})
    weight: int = 1
    queue_limit: int = 8
    per_resource_inflight: int = 1
    burst_calls: int = 4
    burst_window_ms: int = 1000
    max_deadline_ms: int = 60000

    def __post_init__(self):
        if type(self.allowed_classes) is not frozenset or not self.allowed_classes or not self.allowed_classes <= CLASSES.keys():
            raise Fault('priority_invalid_host_policy')
        for name, maximum in (('weight', 16), ('queue_limit', 256), ('per_resource_inflight', 8),
                              ('burst_calls', 1000), ('burst_window_ms', 60000), ('max_deadline_ms', 600000)):
            integer(getattr(self, name), 1, maximum)


@dataclass(frozen=True)
class TaskPolicy:
    tool: str
    task_kind: str
    resource_kind: str
    owners: frozenset = frozenset({'*'})
    maximum_class: str = 'background'
    estimate_floor_ms: int = 100
    execution_budget_ms: int = 1000

    def __post_init__(self):
        for name in ('tool', 'task_kind', 'resource_kind'):
            text(getattr(self, name))
        if self.maximum_class not in CLASSES or type(self.owners) is not frozenset or not self.owners:
            raise Fault('priority_invalid_host_policy')
        integer(self.execution_budget_ms, 1, 600000)
        integer(self.estimate_floor_ms, 1, self.execution_budget_ms)


@dataclass(frozen=True)
class RouteContext:
    """Internal validated request route. Never accepted as an RPC parameter."""
    submit_method: str
    provider: str = None
    model: str = None
    model_fingerprint: str = None

    def __post_init__(self):
        text(self.submit_method)
        if (self.provider is None) != (self.model is None):
            raise Fault('priority_invalid_host_policy')
        for value in (self.provider, self.model):
            if value is not None:text(value, 200)
        if self.model_fingerprint is not None:
            if self.model is None:raise Fault('priority_invalid_host_policy')
            text(self.model_fingerprint,128)

    def projection(self):
        return {k:getattr(self,k) for k in ('provider','model','model_fingerprint')}


@dataclass(frozen=True)
class RouteBinding:
    """Current, ready host snapshot, after provider/model capability validation.

    The producer must be bounded and read-only. No discovery, launch, enrollment,
    permission grant, provider call or capacity measurement runs here.
    """
    tool: str
    task_kind: str
    resource_kind: str
    route: RouteContext
    maximum_class: str = 'background'
    estimate_floor_ms: int = 100
    execution_budget_ms: int = 1000
    ready: bool = False

    def __post_init__(self):
        TaskPolicy(self.tool,self.task_kind,self.resource_kind,
            maximum_class=self.maximum_class,estimate_floor_ms=self.estimate_floor_ms,
            execution_budget_ms=self.execution_budget_ms)
        if type(self.route) is not RouteContext or type(self.ready) is not bool:
            raise Fault('priority_invalid_host_policy')


def validate_profile_v2(value):
    try:
        if type(value) is not dict or type(value.get('schema_version')) is not int or value['schema_version']!=2:
            raise Fault('priority_invalid_response')
        base={k:v for k,v in value.items() if k!='task_bindings'}
        base['schema_version']=1
        if type(value.get('reasons')) is not list:raise Fault('priority_invalid_response')
        base['reasons']=[r for r in value['reasons'] if r!='route_bindings_unavailable']
        if len(value['reasons'])>4 or any(r not in base['reasons'] and r!='route_bindings_unavailable' for r in value['reasons']):
            raise Fault('priority_invalid_response')
        validate_profile(base)
        rows=value['task_bindings']
        if type(rows) is not list or len(rows)>16 or len(encode(value))>14000:
            raise Fault('priority_invalid_response')
        seen=set()
        for row in rows:
            if type(row) is not dict or set(row)!={'submit_method','tool','task_kind','route','resource_kind','allowed_classes','estimate_floor_ms','execution_budget_ms'}:
                raise Fault('priority_invalid_response')
            for key in ('submit_method','tool','task_kind','resource_kind'):text(row[key])
            if type(row['route']) is not dict or set(row['route'])!={'provider','model','model_fingerprint'}:
                raise Fault('priority_invalid_response')
            RouteContext(row['submit_method'],**row['route'])
            classes=row['allowed_classes']
            if type(classes) is not list or not classes or any(type(c) is not str or c not in value['allowed_classes'] for c in classes) or len(set(classes))!=len(classes):
                raise Fault('priority_invalid_response')
            integer(row['execution_budget_ms'],1,600000)
            integer(row['estimate_floor_ms'],1,row['execution_budget_ms'])
            if row['resource_kind'] not in value['resources'] or row['task_kind'] not in value['task_kinds']:
                raise Fault('priority_invalid_response')
            identity=encode({k:row[k] for k in ('submit_method','tool','task_kind','route')})
            if identity in seen:raise Fault('priority_invalid_response')
            seen.add(identity)
        if set(value['task_kinds'])!={r['task_kind'] for r in rows} or set(value['resources'])!={r['resource_kind'] for r in rows}:
            raise Fault('priority_invalid_response')
    except (Fault,KeyError,TypeError,ValueError):
        raise Fault('priority_invalid_response') from None


def select_binding_v2(profile, *, submit_method, tool, task_kind, provider=None, model=None, model_fingerprint=None):
    validate_profile_v2(profile)
    route=RouteContext(submit_method,provider,model,model_fingerprint)
    rows=[row for row in profile['task_bindings'] if (row['submit_method'],row['tool'],row['task_kind'],row['route'])==
          (submit_method,tool,task_kind,route.projection())]
    if len(rows)!=1:raise Fault('priority_route_binding_unavailable')
    return json.loads(encode(rows[0]))


class PriorityAuthority:
    """Trusted host-selected grants; profile negotiation grants no tool access."""
    def __init__(self, resources, tasks, app_profiles=None, *, identity_binding=None, route_capabilities=None):
        resources, tasks = tuple(resources), tuple(tasks)
        if not resources or any(type(r) is not ResourcePolicy for r in resources) or any(type(t) is not TaskPolicy for t in tasks):
            raise Fault('priority_invalid_host_policy')
        self.resources = {r.kind:r for r in resources}
        if len(self.resources) != len(resources) or sum(r.slots for r in resources) > 16:
            raise Fault('priority_invalid_host_policy')
        if any(t.resource_kind not in self.resources for t in tasks):
            raise Fault('priority_invalid_host_policy')
        self.tasks = tasks
        self.app_profiles = dict(app_profiles or {})
        if any(type(p) is not AppProfilePolicy for p in self.app_profiles.values()):
            raise Fault('priority_invalid_host_policy')
        self.epoch = None
        self.issued = {}
        self.issued_bindings = {}
        self.app_policies = {}
        self.store = None
        self.policy_digest = None
        if identity_binding is not None and not callable(identity_binding):
            raise Fault('priority_invalid_host_policy')
        self.identity_binding=identity_binding
        if route_capabilities is not None and not callable(route_capabilities):
            raise Fault('priority_invalid_host_policy')
        self.route_capabilities=route_capabilities

    def digest(self):
        facts={'resources':{k:asdict(v) for k,v in self.resources.items()},
            'profiles':{k:dict(asdict(v),allowed_classes=sorted(v.allowed_classes)) for k,v in self.app_profiles.items()},
            'tasks':[dict(asdict(t),owners=sorted(t.owners)) for t in self.tasks],
            'identity_hook_id':id(self.identity_binding),'route_hook_id':id(self.route_capabilities),
            'app_tool_methods':{owner:{'tools':sorted(p.tools),'methods':sorted(p.methods)} for owner,p in self.app_policies.items()}}
        return hashlib.sha256(encode(facts)).hexdigest()

    def ensure_current(self):
        if self.store is None or self.store.priority_authority is not self or self.policy_digest != self.digest():
            raise Fault('priority_policy_epoch_changed')

    def subject(self,owner):
        # Host-supplied current registration generation, never an RPC identity,
        # PID/path enrollment, native authority epoch or caller profile claim.
        if self.identity_binding is None:
            raise Fault('priority_identity_binding_unavailable')
        try:value=self.identity_binding(owner)
        except Exception:raise Fault('priority_identity_binding_unavailable') from None
        if type(value) is not str or not 1<=len(value)<=128:
            raise Fault('priority_identity_binding_unavailable')
        return value

    @property
    def worker_count(self):
        return sum(r.slots for r in self.resources.values())

    def bind(self, store, app_policies=None):
        if self.store is not None and self.store is not store:
            raise Fault('priority_authority_already_bound')
        self.store = store
        self.app_policies = dict(app_policies or {})
        with store.transaction():
            self.epoch = str(uuid.uuid4())
            self.policy_digest = self.digest()
            self.issued.clear()
            self.issued_bindings.clear()
            store.db.execute('INSERT INTO priority_epoch VALUES(1,?) ON CONFLICT(singleton) DO UPDATE SET epoch=excluded.epoch', (self.epoch,))
            store.priority_authority = self

    def policy(self, owner):
        return self.app_profiles.get(owner, AppProfilePolicy())

    def available_tasks(self, owner):
        return [t for t in self.tasks if owner in t.owners or '*' in t.owners]

    def negotiate(self, owner, verified_owner, requested_profile):
        if verified_owner != owner:
            raise Fault('app_identity_unverified')
        if self.epoch is None:
            raise Fault('priority_not_configured')
        self.ensure_current()
        subject=self.subject(owner)
        if type(requested_profile) is not dict or set(requested_profile)-{'classes'}:
            raise Fault('priority_invalid_arguments')
        requested = requested_profile.get('classes', ['background'])
        if type(requested) is not list or not 1 <= len(requested) <= 3 or any(type(v) is not str or v not in CLASSES for v in requested) or len(set(requested)) != len(requested):
            raise Fault('priority_invalid_arguments')
        policy = self.policy(owner)
        effective = policy.allowed_classes & set(requested)
        reasons = []
        if owner not in self.app_profiles:
            reasons.append('unknown_authenticated_app_background_only')
        if set(requested)-policy.allowed_classes:
            reasons.append('requested_classes_not_granted')
        if not effective:
            if 'background' not in policy.allowed_classes:
                raise Fault('priority_profile_not_authorized')
            effective = frozenset({'background'})
            reasons.append('conservative_background_profile')
        classes = sorted(effective, key=CLASSES.get)
        profile_id = hashlib.sha256(encode({'owner':owner,'subject':subject,'epoch':self.epoch,'classes':classes})).hexdigest()
        if profile_id not in self.issued and len(self.issued)>=4096:
            raise Fault('priority_profile_budget_exceeded')
        self.issued[profile_id] = (owner, frozenset(effective),subject)
        kinds = {t.resource_kind for t in self.available_tasks(owner)}
        return {'schema_version':1, 'profile_id':profile_id,'policy_epoch':self.epoch,
            'identity_bound':True,'allowed_classes':classes,
            'task_kinds':sorted({t.task_kind for t in self.available_tasks(owner)}),
            'limits':{'queue':policy.queue_limit,'per_resource_inflight':policy.per_resource_inflight,
                'burst_calls':policy.burst_calls,'burst_window_ms':policy.burst_window_ms,
                'max_deadline_ms':policy.max_deadline_ms,'weight':policy.weight},
            'resources':{kind:asdict(self.resources[kind]) for kind in sorted(kinds)},
            'cancel_ack_releases_slot':False,'preemption':'not_qualified',
            'real_time_guarantee':False,'reasons':reasons}

    def current_bindings(self,owner,classes):
        policy=self.app_policies.get(owner)
        if policy is None or self.route_capabilities is None:return []
        try:snapshot=self.route_capabilities(owner)
        except Exception:raise Fault('priority_route_binding_unavailable') from None
        if type(snapshot) is not tuple or len(snapshot)>32 or any(type(b) is not RouteBinding for b in snapshot):
            raise Fault('priority_route_binding_unavailable')
        rows=[]; identities=set()
        for binding in snapshot:
            method=binding.route.submit_method
            if not binding.ready or method not in ROUTE_METHODS or binding.tool not in policy.tools or not (method in policy.methods or method=='priority.submit.v1' and 'submit' in policy.methods):continue
            tasks=[t for t in self.available_tasks(owner) if (t.tool,t.task_kind,t.resource_kind)==(binding.tool,binding.task_kind,binding.resource_kind)]
            if len(tasks)!=1:raise Fault('priority_route_binding_unavailable')
            task=tasks[0]
            allowed=sorted((c for c in classes if CLASSES[c]<=min(CLASSES[task.maximum_class],CLASSES[binding.maximum_class])),key=CLASSES.get)
            floor=max(task.estimate_floor_ms,binding.estimate_floor_ms)
            budget=min(task.execution_budget_ms,binding.execution_budget_ms)
            if not allowed or floor>budget:continue
            row={'submit_method':method,'tool':binding.tool,'task_kind':binding.task_kind,
                'route':binding.route.projection(),'resource_kind':task.resource_kind,
                'allowed_classes':allowed,'estimate_floor_ms':floor,'execution_budget_ms':budget}
            identity=encode({k:row[k] for k in ('submit_method','tool','task_kind','route')})
            if identity in identities:raise Fault('priority_route_binding_unavailable')
            identities.add(identity); rows.append(row)
        if len(rows)>16:raise Fault('priority_route_binding_unavailable')
        return sorted(rows,key=encode)

    def negotiate_v2(self,owner,verified_owner,requested_profile):
        base=self.negotiate(owner,verified_owner,requested_profile)
        rows=self.current_bindings(owner,base['allowed_classes'])
        profile_id=hashlib.sha256(encode({'v':2,'base':base['profile_id'],'bindings':rows})).hexdigest()
        if profile_id not in self.issued and len(self.issued)>=4096:raise Fault('priority_profile_budget_exceeded')
        self.issued[profile_id]=self.issued[base['profile_id']]
        self.issued_bindings[profile_id]=encode(rows)
        base.update(schema_version=2,profile_id=profile_id,task_bindings=rows,
            task_kinds=sorted({r['task_kind'] for r in rows}),
            resources={k:asdict(self.resources[k]) for k in sorted({r['resource_kind'] for r in rows})})
        if not rows:base['reasons'].append('route_bindings_unavailable')
        validate_profile_v2(base)
        return base

    def authorize(self, owner, tool, request, route=None):
        validate_request(request)
        self.ensure_current()
        if request['policy_epoch'] != self.epoch:
            raise Fault('priority_policy_epoch_changed')
        issued = self.issued.get(request['profile_id'])
        if issued is None or issued[0] != owner:
            raise Fault('priority_profile_not_authorized')
        if issued[2] != self.subject(owner):
            raise Fault('priority_identity_binding_changed')
        binding_classes=issued[1]
        if request['profile_id'] in self.issued_bindings:
            if type(route) is not RouteContext:raise Fault('priority_route_binding_unavailable')
            rows=self.current_bindings(owner,issued[1])
            if encode(rows)!=self.issued_bindings[request['profile_id']]:raise Fault('priority_route_binding_changed')
            matches=[r for r in rows if (r['submit_method'],r['tool'],r['task_kind'],r['route'])==
                (route.submit_method,tool,request['task_kind'],route.projection())]
            if len(matches)!=1:raise Fault('priority_route_binding_unavailable')
            row=matches[0]; binding_classes=frozenset(row['allowed_classes'])
            matches=[TaskPolicy(tool,row['task_kind'],row['resource_kind'],maximum_class=max(binding_classes,key=CLASSES.get),
                estimate_floor_ms=row['estimate_floor_ms'],execution_budget_ms=row['execution_budget_ms'])]
        else:
            matches = [t for t in self.available_tasks(owner) if (t.tool,t.task_kind) == (tool,request['task_kind'])]
        if len(matches) != 1:
            raise Fault('priority_task_not_authorized')
        task = matches[0]
        if request['resource_kind'] != task.resource_kind:
            raise Fault('priority_resource_not_authorized')
        choices = [c for c in binding_classes if CLASSES[c] <= min(CLASSES[task.maximum_class],CLASSES[request['requested_class']])
                   and CLASSES[c] >= CLASSES[request.get('minimum_class','background')]]
        if not choices or (request['requested_class'] not in choices and not request['allow_fallback']):
            raise Fault('priority_class_not_authorized')
        effective = max(choices, key=CLASSES.get)
        return task, effective, sorted(choices,key=CLASSES.get,reverse=True)

    def legacy_request(self, owner, tool, deadline_at_ms):
        tasks = sorted((t for t in self.available_tasks(owner) if t.tool == tool),
                       key=lambda t:(CLASSES[t.maximum_class],t.task_kind))
        if not tasks:
            raise Fault('priority_task_not_authorized')
        grant = self.negotiate(owner,owner,{'classes':['background']})
        task = tasks[0]
        return {'profile_id':grant['profile_id'],'policy_epoch':self.epoch,
            'task_kind':task.task_kind,'requested_class':'background','deadline_at_ms':deadline_at_ms,
            'resource_kind':task.resource_kind,'estimate_ms':task.estimate_floor_ms,
            'allow_interrupt':False,'allow_fallback':False}

    def check_plan(self, owner, tool, plan):
        route=RouteContext(**plan['route']) if plan.get('route') is not None else None
        task, _, choices = self.authorize(owner,tool,plan['request'],route)
        if plan['effective_class'] not in choices or plan['execution_budget_ms'] != task.execution_budget_ms:
            raise Fault('priority_policy_epoch_changed')


def initialize(store):
    store.priority_authority = None
    if 'schedule_v1' not in {r[1] for r in store.db.execute('PRAGMA table_info(jobs)')}:
        store.db.execute('ALTER TABLE jobs ADD COLUMN schedule_v1 TEXT')
    store.db.executescript('''
        CREATE TABLE IF NOT EXISTS priority_epoch(singleton INTEGER PRIMARY KEY CHECK(singleton=1),epoch TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS resource_leases(job TEXT PRIMARY KEY,owner TEXT NOT NULL,kind TEXT NOT NULL,attempt INTEGER NOT NULL,
            started_ms INTEGER NOT NULL,expected_return_ms INTEGER NOT NULL,estimate_ms INTEGER NOT NULL,class TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS priority_burst(owner TEXT PRIMARY KEY,window_ms INTEGER NOT NULL,calls INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS priority_fair(kind TEXT NOT NULL,class TEXT NOT NULL,owner TEXT NOT NULL,
            service REAL NOT NULL,waiting_seq INTEGER NOT NULL,PRIMARY KEY(kind,class,owner));
    ''')


def plan_submission(store, owner, tool, request, now_ms, route=None):
    authority = store.priority_authority
    if authority is None:
        raise Fault('priority_not_configured')
    task, effective, choices = authority.authorize(owner,tool,request,route)
    policy, resource = authority.policy(owner), authority.resources[task.resource_kind]
    remaining = request['deadline_at_ms']-now_ms
    if remaining <= 0:
        raise Fault('deadline_exceeded')
    if remaining > policy.max_deadline_ms:
        raise Fault('deadline_not_authorized')
    estimate = max(task.estimate_floor_ms,request['estimate_ms'])
    if estimate > task.execution_budget_ms:
        raise Fault('priority_estimate_not_supported')
    active = [dict(r) for r in store.db.execute('SELECT * FROM resource_leases WHERE kind=?',(resource.kind,))]
    if resource.slots == 1 and active and active[0]['expected_return_ms'] <= now_ms:
        raise Fault('priority_capacity_unverified')
    wait_ms = max(0,min(r['expected_return_ms'] for r in active)-now_ms) if len(active) >= resource.slots else 0
    if wait_ms+task.execution_budget_ms > remaining:
        raise Fault('priority_deadline_unsatisfiable')
    queued = [json.loads(r[0]) for r in store.db.execute("SELECT schedule_v1 FROM jobs WHERE state='queued' AND schedule_v1 IS NOT NULL")]
    queued = [p for p in queued if p['resource_kind'] == resource.kind]
    if len(queued) >= resource.queue_limit:
        raise Fault('priority_resource_queue_exceeded')
    reasons = []
    effective = next((c for c in choices if sum(p['effective_class']==c for p in queued)<resource.class_queue_limit),None)
    if effective is None or (effective != request['requested_class'] and not request['allow_fallback']):
        raise Fault('priority_class_queue_exceeded')
    if effective != request['requested_class']:
        reasons.append('authorized_class_downgrade')
    if resource.slots == 1 and effective == 'background' and task.execution_budget_ms > resource.background_start_limit_ms:
        raise Fault('priority_background_protection_window')
    if request['estimate_ms'] < task.estimate_floor_ms:
        reasons.append('estimate_clamped_to_host_floor')
    if request['allow_interrupt'] and not resource.cooperative_cancel:
        reasons.append('adapter_interrupt_unqualified')
    pending = store.db.execute("SELECT COUNT(*) FROM jobs WHERE owner=? AND state IN ('queued','running','needs_unlock')",(owner,)).fetchone()[0]
    if pending >= policy.queue_limit:
        raise Fault('priority_app_queue_exceeded')
    burst = store.db.execute('SELECT * FROM priority_burst WHERE owner=?',(owner,)).fetchone()
    if burst and now_ms-burst['window_ms']<policy.burst_window_ms and burst['calls']>=policy.burst_calls:
        raise Fault('priority_burst_exceeded')
    if burst is None or now_ms-burst['window_ms'] >= policy.burst_window_ms:
        store.db.execute('INSERT INTO priority_burst VALUES(?,?,1) ON CONFLICT(owner) DO UPDATE SET window_ms=excluded.window_ms,calls=1',(owner,now_ms))
    else:
        store.db.execute('UPDATE priority_burst SET calls=calls+1 WHERE owner=?',(owner,))
    return {'schema_version':1,'request':dict(request),'effective_class':effective,
        'route':asdict(route) if route is not None else None,
        'resource_kind':resource.kind,'estimate_ms':estimate,'execution_budget_ms':task.execution_budget_ms,
        'policy_epoch':authority.epoch,'weight':policy.weight,'reasons':reasons,
        'allow_interrupt_effective':request['allow_interrupt'] and resource.cooperative_cancel}


def projection(plan):
    facts={k:plan[k] for k in ('schema_version','effective_class','resource_kind','estimate_ms',
        'execution_budget_ms','policy_epoch','reasons','allow_interrupt_effective')}
    facts.update({k:plan['request'][k] for k in ('profile_id','task_kind','requested_class','deadline_at_ms')})
    return facts


def validate_acceptance(request,facts):
    validate_request(request)
    keys={'schema_version','effective_class','resource_kind','estimate_ms','execution_budget_ms',
          'policy_epoch','reasons','allow_interrupt_effective','profile_id','task_kind','requested_class','deadline_at_ms'}
    if type(facts) is not dict or set(facts)!=keys or type(facts['schema_version']) is not int or facts['schema_version']!=1:
        raise Fault('priority_receipt_mismatch')
    for key in ('profile_id','policy_epoch','task_kind','requested_class','resource_kind','deadline_at_ms'):
        if type(facts[key]) is not type(request[key]) or facts[key]!=request[key]:
            raise Fault('priority_receipt_mismatch')
    effective=facts['effective_class']
    if type(effective) is not str or effective not in CLASSES or CLASSES[effective]>CLASSES[request['requested_class']] or CLASSES[effective]<CLASSES[request.get('minimum_class','background')]:
        raise Fault('priority_receipt_mismatch')
    if effective!=request['requested_class'] and not request['allow_fallback']:
        raise Fault('priority_receipt_mismatch')
    integer(facts['estimate_ms'],request['estimate_ms'],600000)
    integer(facts['execution_budget_ms'],facts['estimate_ms'],600000)
    if type(facts['allow_interrupt_effective']) is not bool or facts['allow_interrupt_effective'] and not request['allow_interrupt']:
        raise Fault('priority_receipt_mismatch')
    if type(facts['reasons']) is not list or len(facts['reasons'])>4 or any(type(r) is not str or r not in {
        'authorized_class_downgrade','estimate_clamped_to_host_floor','adapter_interrupt_unqualified'} for r in facts['reasons']):
        raise Fault('priority_receipt_mismatch')


def eligible(store, row, now_ms):
    plan = json.loads(row['schedule_v1'])
    authority = store.priority_authority
    if authority is None:
        raise Fault('priority_not_configured')
    authority.check_plan(row['owner'],row['tool'],plan)
    if now_ms+plan['execution_budget_ms'] > int(row['deadline_at']*1000):
        raise Fault('priority_deadline_unsatisfiable')
    resource = authority.resources[plan['resource_kind']]
    leases = store.db.execute('SELECT owner,class FROM resource_leases WHERE kind=?',(resource.kind,)).fetchall()
    ordinary=sum(r['class']!='realtime' for r in leases)
    if len(leases)>=resource.slots or (plan['effective_class']!='realtime' and ordinary>=resource.slots-resource.realtime_reserved) or sum(r['owner']==row['owner'] for r in leases)>=authority.policy(row['owner']).per_resource_inflight:
        return False
    return True


def select_profiled(store, candidates, now, dispatch_seq):
    """One existing claim selection, filtered by independent resource leases."""
    heads = {}
    for row in candidates:
        try:
            if not eligible(store,row,int(now*1000)):
                continue
        except Fault as exc:
            store.set_state(row['id'],'needs_review' if exc.code=='priority_policy_epoch_changed' else 'failed',error=exc.code)
            store.audit(row['owner'],row['id'],exc.code)
            continue
        p = json.loads(row['schedule_v1'])
        key = (p['resource_kind'],p['effective_class'],row['owner'])
        if key not in heads or (row['deadline_at'],row['created'],row['id']) < (heads[key]['deadline_at'],heads[key]['created'],heads[key]['id']):
            heads[key] = row
    if not heads:
        return None
    fair = {}
    for key, row in heads.items():
        floor = store.db.execute('SELECT COALESCE(MIN(service),0) FROM priority_fair WHERE kind=? AND class=?',key[:2]).fetchone()[0]
        store.db.execute('INSERT OR IGNORE INTO priority_fair VALUES(?,?,?,?,?)',(*key,floor,dispatch_seq))
        fair[key] = dict(store.db.execute('SELECT * FROM priority_fair WHERE kind=? AND class=? AND owner=?',key).fetchone())
    realtime = [key for key in heads if key[1]=='realtime']
    pool = realtime or list(heads)
    overdue = [key for key in heads if key[1]!='realtime' and (dispatch_seq-fair[key]['waiting_seq']>=MAX_BYPASSES or now-heads[key]['created']>=AGING_SECONDS)]
    if overdue:
        chosen = min(overdue,key=lambda key:(fair[key]['waiting_seq'],fair[key]['service'],heads[key]['deadline_at']))
    else:
        chosen = min(pool,key=lambda key:(-CLASSES[key[1]],fair[key]['service'],heads[key]['deadline_at'],heads[key]['created'],heads[key]['id']))
    return heads[chosen]


def claim_lease(store, row, attempt, now_ms, dispatch_seq):
    plan = json.loads(row['schedule_v1'])
    store.db.execute('INSERT INTO resource_leases VALUES(?,?,?,?,?,?,?,?)',
        (row['id'],row['owner'],plan['resource_kind'],attempt,now_ms,
         min(int(row['deadline_at']*1000),now_ms+plan['execution_budget_ms']),plan['estimate_ms'],plan['effective_class']))
    store.db.execute('UPDATE priority_fair SET service=service+?,waiting_seq=? WHERE kind=? AND class=? AND owner=?',
        (plan['estimate_ms']/plan['weight'],dispatch_seq+1,plan['resource_kind'],plan['effective_class'],row['owner']))


def release_lease(store, row):
    """Only called by the owning worker after synchronous adapter return."""
    with store.transaction():
        lease = store.db.execute('SELECT * FROM resource_leases WHERE job=?',(row['id'],)).fetchone()
        if lease is None or lease['attempt'] != row['attempts']:
            return False
        plan = json.loads(row['schedule_v1'])
        extra = max(0,int(time.time()*1000)-lease['started_ms']-lease['estimate_ms'])/plan['weight']
        store.db.execute('UPDATE priority_fair SET service=service+? WHERE kind=? AND class=? AND owner=?',
            (extra,lease['kind'],lease['class'],row['owner']))
        store.db.execute('DELETE FROM resource_leases WHERE job=? AND attempt=?',(row['id'],row['attempts']))
        store.audit(row['owner'],row['id'],'adapter_return_slot_released')
        return True


def check_running(store, row):
    if not row.get('schedule_v1'):
        return
    with store.lock:
        plan = json.loads(row['schedule_v1'])
        if store.priority_authority is None:
            raise Fault('priority_not_configured')
        store.priority_authority.check_plan(row['owner'],row['tool'],plan)
        lease = store.db.execute('SELECT * FROM resource_leases WHERE job=? AND attempt=?',(row['id'],row['attempts'])).fetchone()
        if lease is None:
            raise Fault('priority_lease_not_current')
        if int(time.time()*1000) >= lease['expected_return_ms']:
            raise Fault('deadline_exceeded')
