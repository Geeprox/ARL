"""Host-registered real domain projection into existing priority negotiation.

No grants, discovery, process launch, credential resolution, RPC enrollment,
capacity inference, extra queue or provider fallback. Defaults produce no route.
"""
from dataclasses import dataclass
import hashlib,json,threading,time,uuid
from pathlib import Path
import stat
from .contracts import Fault,encode
from .identity import RegisteredPeerVerifier
from .priority import (PriorityAuthority,ResourcePolicy,TaskPolicy,AppProfilePolicy,
                       RouteBinding,RouteContext,CLASSES,integer,text)
from .codex_server import CodexTextAdapter
from . import codex_server
from .codex_research import CodexResearchEngine
from .friday_planning import FridayRemovalPlanner,checked_request
from .providers import OllamaProvider,MockProvider

def digest(value):return hashlib.sha256(encode(value)).hexdigest()

def confirmed_preflight(proof, model, synthetic):
    # Validate authority-bearing fields; harmless metadata additions are compatible.
    return (type(proof) is dict and proof.get('model') == model and
            proof.get('ephemeral') is True and proof.get('read_only') is True and
            proof.get('synthetic') is synthetic)

@dataclass(frozen=True)
class PriorityHostConfig:
    resources: tuple
    tasks: tuple
    app_profiles: dict
    ready_ttl_ms: int
    allow_synthetic: bool=False

    def __post_init__(self):
        integer(self.ready_ttl_ms,1,60000)
        if type(self.resources) is not tuple or type(self.tasks) is not tuple or type(self.app_profiles) is not dict or type(self.allow_synthetic) is not bool:
            raise Fault('priority_invalid_host_policy')
        if len(self.resources)!=1 or any(type(r) is not ResourcePolicy or r.slots!=1 or r.realtime_reserved!=0 or r.cooperative_cancel for r in self.resources):
            raise Fault('priority_host_capacity_unqualified')
        if any(type(t) is not TaskPolicy for t in self.tasks) or any(type(p) is not AppProfilePolicy for p in self.app_profiles.values()):
            raise Fault('priority_invalid_host_policy')
        if any(t.resource_kind!=self.resources[0].kind for t in self.tasks):
            raise Fault('priority_backend_pool_conflict')
        if len(self.tasks)>32 or len(self.app_profiles)>100:raise Fault('priority_invalid_host_policy')

@dataclass(frozen=True)
class Domain:
    id: str
    kind: str
    target: object
    adapter: object
    task: TaskPolicy
    backend: str
    codec: str
    transport: str

@dataclass(frozen=True)
class Attempt:
    id: str
    domain: str
    owner: str
    model: str
    view: str
    job: str
    attempt: int
    binding: str

@dataclass(frozen=True)
class Observation:
    token: Attempt
    expires: float

@dataclass(frozen=True)
class PreflightObservation:
    view: str
    expires: float

@dataclass(frozen=True)
class GenericDomain:
    provider: str
    model: str
    target: object
    task: TaskPolicy

class RegisteredRouteProducer:
    """Installed only by an explicit already-granted host composition.

    Ready observations originate in the existing adapter's validated execution
    branch and retain registration/grant/job scope. A boolean cannot register one.
    """
    def __init__(self,runtime,verifier,config,*,clock=time.monotonic):
        if type(verifier) is not RegisteredPeerVerifier or type(config) is not PriorityHostConfig:
            raise Fault('priority_invalid_host_policy')
        if runtime.priority_authority is not None:raise Fault('priority_host_already_bound')
        self.runtime,self.verifier,self.config,self.clock=runtime,verifier,config,clock
        self.lock=threading.RLock();self.domains=[];self.generic=[];self.attempts={};self.observations={};self.preflights={}
        self.authority=PriorityAuthority(config.resources,config.tasks,dict(config.app_profiles),
            identity_binding=self.subject,route_capabilities=self.snapshot)
        runtime.priority_authority=self.authority
        runtime.priority_producer=self

    def subject(self,owner):return self.verifier.registration_subject(owner)

    def _task(self,tool,kind,resource):
        rows=[t for t in self.authority.tasks if (t.tool,t.task_kind,t.resource_kind)==(tool,kind,resource)]
        if len(rows)!=1:raise Fault('priority_route_binding_unavailable')
        return rows[0]

    @staticmethod
    def _file_sha(path):
        """Bounded read of the exact local transport bytes; no execution."""
        try:
            path=Path(path).resolve(strict=True)
            info=path.stat()
            if not stat.S_ISREG(info.st_mode) or not 0<info.st_size<=512*1024*1024:
                raise Fault('priority_route_binding_unavailable')
            h=hashlib.sha256();total=0
            with path.open('rb') as source:
                while True:
                    chunk=source.read(1024*1024)
                    if not chunk:break
                    total+=len(chunk)
                    if total>512*1024*1024:raise Fault('priority_route_binding_unavailable')
                    h.update(chunk)
            if total!=info.st_size:raise Fault('priority_route_binding_unavailable')
            return h.hexdigest()
        except (OSError,ValueError,TypeError):
            raise Fault('priority_route_binding_unavailable') from None

    def _transport(self,adapter):
        command=adapter.test_command
        if command is None:
            binary=self._file_sha(adapter.binary)
            if binary!=adapter.pin:raise Fault('priority_route_binding_unavailable')
            fixture=None
        else:
            if type(command) not in (tuple,list) or not 1<=len(command)<=16 or any(
                    type(part) is not str or not part or len(part)>1024 for part in command):
                raise Fault('priority_route_binding_unavailable')
            binary=self._file_sha(command[0])
            fixture=self._file_sha(command[2]) if len(command)>2 and command[1]=='-I' else digest(list(command))
        return digest({'command':list(command) if command is not None else None,
                       'binary_sha256':binary,'fixture_sha256':fixture}),binary,fixture

    def _register(self,kind,target,adapter,tool,task_kind,resource_kind,backend,codec):
        # All current domains share the same account/config/backend scope.
        # An alias or different executable hash cannot create another slot.
        if backend!='codex_app_server' or resource_kind!=self.config.resources[0].kind:
            raise Fault('priority_backend_pool_conflict')
        if not isinstance(adapter,CodexTextAdapter):raise Fault('priority_route_binding_unavailable')
        task=self._task(tool,task_kind,resource_kind)
        transport,_,_=self._transport(adapter)
        with self.lock:
            if len(self.domains)>=32 or any(d.target is target and d.task==task for d in self.domains):
                raise Fault('priority_route_binding_unavailable')
            if adapter._priority_readiness not in (None,self):raise Fault('priority_host_already_bound')
            domain=Domain(uuid.uuid4().hex,kind,target,adapter,task,backend,codec,transport)
            self.domains.append(domain)
            adapter._priority_readiness=self
            return domain.id

    def register_native(self,engine,*,task_kind,resource_kind,backend):
        if not isinstance(engine,CodexResearchEngine) or self.runtime.research_engines.get(engine.name) is not engine:
            raise Fault('priority_route_binding_unavailable')
        adapter=engine.adapters.get('codex_app_server')
        if adapter is None:raise Fault('priority_route_binding_unavailable')
        codec='codex.appserver.sourced.v2' if engine.structured_generated_citations else 'codex.appserver.text.v1'
        if engine.name == 'tisra.codex.rerank.v1':
            from .codex_selected_contract import FORMATS, CONTRACT_SHA256
            if engine.formats != FORMATS or engine.contract_sha256 != CONTRACT_SHA256:
                raise Fault('priority_route_binding_unavailable')
            codec = 'codex.appserver.rerank.v1'
        return self._register('native',engine,adapter.text_adapter,engine.name,task_kind,resource_kind,backend,codec)

    def register_planner(self,planner,*,task_kind,resource_kind,backend):
        if type(planner) is not FridayRemovalPlanner:raise Fault('priority_route_binding_unavailable')
        tool=planner.tool(); current=self.runtime.tools.get(tool.name)
        if current is None or getattr(current.handler,'__self__',None) is not planner:raise Fault('priority_route_binding_unavailable')
        return self._register('planner',planner,planner.adapter,tool.name,task_kind,resource_kind,backend,'codex.appserver.text.v1')

    def register_generic(self,provider,model,*,task_kind,resource_kind):
        """Explicit host registration against an existing Router/policy grant."""
        if type(model) is not str or not 1<=len(model)<=200 or self.runtime.router.providers.get(provider.name) is not provider:
            raise Fault('priority_route_binding_unavailable')
        if provider.paid or (isinstance(provider,MockProvider) and not self.config.allow_synthetic):
            raise Fault('priority_route_binding_unavailable')
        if not isinstance(provider,(OllamaProvider,MockProvider)) or resource_kind!=self.config.resources[0].kind:
            raise Fault('priority_backend_pool_conflict')
        task=self._task('model.complete',task_kind,resource_kind)
        with self.lock:
            if any(d.provider==provider.name and d.model==model for d in self.generic):
                raise Fault('priority_route_binding_unavailable')
            self.generic.append(GenericDomain(provider.name,model,provider,task))

    def _generic_binding(self,domain,owner):
        r=self.runtime;p=r.policies.get(owner)
        if owner!='friday' or not r.ready.is_set() or r.stopping.is_set() or not r.execute_jobs or r.store is None or p is None:
            raise Fault('priority_route_binding_unavailable')
        if ('model.complete' not in p.tools or 'submit' not in p.methods or domain.provider not in p.providers or
                owner not in domain.task.owners and '*' not in domain.task.owners):
            raise Fault('priority_route_binding_unavailable')
        provider=r.router.providers.get(domain.provider)
        if provider is not domain.target or provider.paid or (domain.provider!='mock' and not r.local_enabled):
            raise Fault('priority_route_binding_unavailable')
        if domain.provider=='mock' and not self.config.allow_synthetic:raise Fault('priority_route_binding_unavailable')
        self.subject(owner)
        with r.control.providers.lock:
            row=dict(r.control.providers.records.get(domain.provider,{}))
        now=r.control.providers.clock()
        if (row.get('state')!='ready' or row.get('inference_enabled') is not True or
                row.get('evidence') not in ({'test_double'} if domain.provider=='mock' else {'local_http'}) or
                type(row.get('checked_at_ms')) is not int or now-row['checked_at_ms']<0 or
                now-row['checked_at_ms']>min(row.get('stale_after_ms',0),self.config.ready_ttl_ms) or
                domain.model not in row.get('catalog_models',())):
            raise Fault('priority_route_binding_unavailable')
        task=domain.task;ceiling=min(CLASSES[task.maximum_class],CLASSES['interactive'])
        maximum=next(c for c,n in CLASSES.items() if n==ceiling)
        return RouteBinding(task.tool,task.task_kind,task.resource_kind,
            RouteContext('priority.submit.v1',domain.provider,domain.model),maximum,
            task.estimate_floor_ms,min(task.execution_budget_ms,30000),True)

    def auto_generic_request(self,owner,args,key):
        """Server-only mapping for Friday's existing plain submit(model.complete)."""
        from .client import Client
        with self.lock:
            matches=[d for d in self.generic if (d.provider,d.model)==(args['provider'],args['model'])]
        if len(matches)!=1:raise Fault('priority_route_binding_unavailable')
        domain=matches[0];self._generic_binding(domain,owner)
        route=RouteContext('priority.submit.v1',domain.provider,domain.model)
        old=self.runtime.store.db.execute('SELECT schedule_v1 FROM jobs WHERE owner=? AND key=?',(owner,key)).fetchone()
        if old is not None:
            if not old['schedule_v1']:raise Fault('idempotency_conflict')
            plan=json.loads(old['schedule_v1'])
            if not plan.get('protocol_optin'):raise Fault('idempotency_conflict')
            request=plan['request']
            self.authority.authorize(owner,'model.complete',request,route)
            return request,route
        profile=self.authority.negotiate_v2(owner,owner,{'classes':['background','interactive']})
        rows=[row for row in profile['task_bindings'] if row['tool']=='model.complete' and
              row['task_kind']==domain.task.task_kind and row['route']==route.projection()]
        if len(rows)!=1:raise Fault('priority_route_binding_unavailable')
        row=rows[0];requested='interactive' if 'interactive' in row['allowed_classes'] else 'background'
        budget=min(profile['limits']['max_deadline_ms'],self.runtime.policies[owner].max_deadline_ms,30000)
        if row['execution_budget_ms']+100>budget:raise Fault('priority_route_binding_unavailable')
        request=Client.priority_request_v2(profile,submit_method=route.submit_method,tool='model.complete',
            task_kind=domain.task.task_kind,requested_class=requested,deadline_at_ms=int(time.time()*1000)+budget,
            estimate_ms=row['estimate_floor_ms'],provider=domain.provider,model=domain.model)
        return request,route

    def planner_required(self,owner,tool):
        with self.lock:return owner=='friday' and any(d.kind=='planner' and d.task.tool==tool for d in self.domains)

    def probe_planner(self,owner,model):
        """Explicit host call; no review-specific bootstrap job and no inference turn."""
        with self.lock:domains=[d for d in self.domains if d.kind=='planner' and d.task.tool=='friday.rule-removal.plan.v1']
        if len(domains)!=1:raise Fault('priority_route_binding_unavailable')
        domain=domains[0]
        before,_=self._view(domain,owner,model)
        proof=domain.adapter.preflight_model(model)
        if not confirmed_preflight(proof, model, domain.adapter.test_command is not None):
            raise Fault('priority_route_binding_unavailable')
        after,_=self._view(domain,owner,model)
        if before!=after:raise Fault('priority_route_binding_changed')
        with self.lock:self.preflights[(domain.id,owner,model)]=PreflightObservation(after,self.clock()+self.config.ready_ttl_ms/1000)

    def probe_native(self,owner,model):
        """Host-only read-only readiness; never manufacture an inference job."""
        with self.lock:
            domains=[d for d in self.domains if d.kind=='native' and
                     d.task.tool==self.runtime.codex_research_name]
        if len(domains)!=1:raise Fault('priority_route_binding_unavailable')
        domain=domains[0]
        if self.config.allow_synthetic or domain.adapter.test_command is not None:
            raise Fault('priority_route_binding_unavailable')
        before,_=self._view(domain,owner,model)
        proof=domain.adapter.preflight_model(model)
        if not confirmed_preflight(proof, model, domain.adapter.test_command is not None):
            raise Fault('priority_route_binding_unavailable')
        after,_=self._view(domain,owner,model)
        if before!=after:raise Fault('priority_route_binding_changed')
        with self.lock:
            self.preflights[(domain.id,owner,model)]=PreflightObservation(
                after,self.clock()+self.config.ready_ttl_ms/1000)

    def _view(self,domain,owner,model):
        r=self.runtime; task=domain.task
        if not r.ready.is_set() or r.stopping.is_set() or not r.execute_jobs or r.store is None:
            raise Fault('priority_route_binding_unavailable')
        policy=r.policies.get(owner)
        method='codex.research.submit.v1' if domain.kind=='native' else 'priority.submit.v1'
        if policy is None or task.tool not in policy.tools or not (method in policy.methods or method=='priority.submit.v1' and 'submit' in policy.methods) or (owner not in task.owners and '*' not in task.owners):
            raise Fault('priority_route_binding_unavailable')
        subject=self.subject(owner); adapter=domain.adapter
        if adapter.enabled is not True or adapter._priority_readiness is not self or (adapter.test_command is not None and not self.config.allow_synthetic):
            raise Fault('priority_route_binding_unavailable')
        transport,binary,fixture=self._transport(adapter)
        if transport!=domain.transport:raise Fault('priority_route_binding_unavailable')
        if domain.kind=='native':
            engine=domain.target
            if r.research_engines.get(task.tool) is not engine or r.tools.get(task.tool) is not engine.tool or engine.store is not r.store:
                raise Fault('priority_route_binding_unavailable')
            grant,native=engine.grant(owner)
            if len(grant.models)>32:raise Fault('priority_route_binding_unavailable')
            if native.text_adapter is not adapter or model not in grant.models or model not in native.model_fingerprints:
                raise Fault('priority_route_binding_unavailable')
            if binary!=native.binary_sha256 or fixture!=native.fixture_pin:
                raise Fault('priority_route_binding_unavailable')
            control=native.control_contract if native.fixture_pin is None else dict(native.control_contract,test_double_sha256=native.fixture_pin)
            if digest(control)!=native.control_sha256:raise Fault('priority_route_binding_unavailable')
            caps=engine.capability_result(owner)
            if caps['models'].get(model)!=native.model_fingerprints[model]:raise Fault('priority_route_binding_unavailable')
            fingerprint=caps['models'][model]; grant_scope=(grant.auth_epoch,grant.contract_sha256,sorted(grant.models))
        else:
            from .friday_profile import PlanningAdmission
            planner=domain.target; current=r.tools.get(task.tool); admission=r.admission
            if owner!='friday' or planner.adapter is not adapter or current is None or getattr(current.handler,'__self__',None) is not planner or type(admission) is not PlanningAdmission:
                raise Fault('priority_route_binding_unavailable')
            if admission.args['model']!=model:raise Fault('priority_route_binding_unavailable')
            checked_request(admission.args['request_json'])
            # Review/action authorization remains at submit, claim, adapter and
            # publication. Readiness is scoped to host/model, not review bytes.
            fingerprint=None;grant_scope=('exact_current_planning_admission',model)
        facts={'domain':domain.id,'subject':subject,'owner':owner,'model':model,'fingerprint':fingerprint,
            'grant':grant_scope,'backend':domain.backend,'resource':task.resource_kind,'codec':domain.codec,
            'adapter':id(adapter),'transport':transport,'pin':adapter.pin,'synthetic_command':adapter.test_command,
            'current_text_controls':digest({'config':codex_server.CONFIG,'thread':codex_server.THREAD_CONTROLS,'turn':codex_server.TURN_CONTROLS}),
            'policy_tools':sorted(policy.tools),'policy_methods':sorted(policy.methods)}
        return digest(facts),RouteContext(method,'codex_app_server',model,fingerprint)

    def _job_binding(self,domain,context,model):
        return self._job_binding_row(domain,context.row,model)

    def _job_binding_row(self,domain,row,model):
        owner=row['owner'];r=self.runtime
        job=dict(r.store.row(owner,row['id']))
        if job['tool']!=domain.task.tool or job['attempts']!=row['attempts'] or job['key']!=row['key'] or job['state']!='running' or job['cancel'] or job['deadline_at']<=time.time():
            raise Fault('priority_route_binding_unavailable')
        if not job['schedule_v1']:raise Fault('priority_route_binding_unavailable')
        plan=json.loads(job['schedule_v1'])
        lease=r.store.db.execute('SELECT kind,expected_return_ms FROM resource_leases WHERE job=? AND attempt=?',
                                (job['id'],job['attempts'])).fetchone()
        if (plan['request']['task_kind']!=domain.task.task_kind or
                plan['resource_kind']!=domain.task.resource_kind or lease is None or
                lease['kind']!=domain.task.resource_kind or
                lease['expected_return_ms']<=int(time.time()*1000)):
            raise Fault('priority_route_binding_unavailable')
        if domain.kind=='native':
            run=domain.target.run(job['id']);p=json.loads(run['args']);g,_=domain.target.grant(owner,p)
            if p['model']!=model or run['invalidated'] or run['auth_epoch']!=g.auth_epoch:
                raise Fault('priority_route_binding_unavailable')
            binding=domain.target.original_binding(run)
        else:
            args=json.loads(job['args']); self.runtime.admission(owner,job['tool'],args)
            if args['model']!=model:raise Fault('priority_route_binding_unavailable')
            binding={'owner':owner,'job':job['id'],'key':job['key'],'digest':job['digest'],'args':digest(args)}
        return owner,job['id'],job['attempts'],digest(binding)

    def begin_model_run(self,adapter,context,model,codec):
        with self.lock:domains=tuple(d for d in self.domains if d.adapter is adapter and d.codec==codec)
        matches=[]
        for d in domains:
            try:
                owner,job,attempt,binding=self._job_binding(d,context,model)
                view,_=self._view(d,owner,model);matches.append((d,owner,job,attempt,binding,view))
            except (Fault,KeyError,TypeError,AttributeError):continue
        if len(matches)!=1:return None
        d,owner,job,attempt,binding,view=matches[0]
        token=Attempt(uuid.uuid4().hex,d.id,owner,model,view,job,attempt,binding)
        with self.lock:
            if len(self.attempts)>=32 or (job,attempt) in self.attempts:return None
            self.attempts[(job,attempt)]=token
        return token

    def confirm_model_run(self,adapter,token,context,model,codec):
        if type(token) is not Attempt:return False
        with self.lock:
            pending=self.attempts.get((token.job,token.attempt))
            domains=[d for d in self.domains if d.id==token.domain and d.adapter is adapter and d.codec==codec]
        if pending is not token or len(domains)!=1 or token.model!=model:return False
        d=domains[0]
        try:
            context.check_cancelled()
            owner,job,attempt,binding=self._job_binding(d,context,model);view,_=self._view(d,owner,model)
            if (owner,job,attempt,binding,view)!=(token.owner,token.job,token.attempt,token.binding,token.view):return False
            if d.kind=='native':
                n=d.target.native_row(job)
                observed=json.loads(n['model_evidence']) if n['model_evidence'] else {}
                if n['thread_id'] is None or observed.get('confirmed_identifier')!=model:return False
            with self.lock:
                if self.attempts.get((job,attempt)) is not token:return False
                self.observations={key:value for key,value in self.observations.items() if value.expires>self.clock()}
                if len(self.observations)>=256 and (d.id,owner,model) not in self.observations:return False
                self.observations[(d.id,owner,model)]=Observation(token,self.clock()+self.config.ready_ttl_ms/1000)
            return True
        except (Fault,KeyError,TypeError,AttributeError):return False
        finally:
            with self.lock:
                if self.attempts.get((token.job,token.attempt)) is token:self.attempts.pop((token.job,token.attempt))

    def abandon_model_run(self,token):
        if type(token) is Attempt:
            with self.lock:
                if self.attempts.get((token.job,token.attempt)) is token:self.attempts.pop((token.job,token.attempt))

    def snapshot(self,owner):
        with self.lock:
            domains=tuple(self.domains); observations=dict(self.observations);preflights=dict(self.preflights);generic=tuple(self.generic)
        rows=[]
        for d in domains:
            for (domain_id,app,model),observation in observations.items():
                if domain_id!=d.id or app!=owner or observation.expires<=self.clock():continue
                try:
                    view,route=self._view(d,owner,model)
                    if view!=observation.token.view:continue
                    job=self.runtime.store.row(owner,observation.token.job)
                    if job['cancel'] or job['state'] not in {'running','succeeded'} or job['attempts']!=observation.token.attempt:continue
                    if job['state']=='running':
                        current=self._job_binding_row(d,job,model)
                        if current!=(observation.token.owner,observation.token.job,
                                    observation.token.attempt,observation.token.binding):continue
                    if d.kind=='native':
                        run=d.target.run(job['id'])
                        if run['invalidated'] or digest(d.target.original_binding(run))!=observation.token.binding:continue
                    else:
                        args=json.loads(job['args'])
                        binding={'owner':owner,'job':job['id'],'key':job['key'],'digest':job['digest'],'args':digest(args)}
                        if digest(binding)!=observation.token.binding:continue
                    ceiling=min(CLASSES[d.task.maximum_class],CLASSES['interactive'])
                    maximum=next(c for c,n in CLASSES.items() if n==ceiling)
                    budget=min(d.task.execution_budget_ms,30000)
                    if d.task.estimate_floor_ms>budget:continue
                    rows.append(RouteBinding(d.task.tool,d.task.task_kind,d.task.resource_kind,route,
                        maximum,d.task.estimate_floor_ms,budget,True))
                    if len(rows)>32:raise Fault('priority_route_binding_unavailable')
                except (Fault,KeyError,TypeError,AttributeError):continue
        for d in domains:
            if d.kind not in {'planner','native'}:continue
            for (domain_id,app,model),observation in preflights.items():
                if domain_id!=d.id or app!=owner or observation.expires<=self.clock():continue
                try:
                    view,route=self._view(d,owner,model)
                    if view!=observation.view:continue
                    ceiling=min(CLASSES[d.task.maximum_class],CLASSES['interactive'])
                    maximum=next(c for c,n in CLASSES.items() if n==ceiling)
                    candidate=RouteBinding(d.task.tool,d.task.task_kind,d.task.resource_kind,route,maximum,
                        d.task.estimate_floor_ms,min(d.task.execution_budget_ms,30000),True)
                    if candidate not in rows:rows.append(candidate)
                except (Fault,KeyError,TypeError,AttributeError):continue
        for d in generic:
            try:rows.append(self._generic_binding(d,owner))
            except (Fault,KeyError,TypeError,AttributeError):continue
        if len(rows)>32:raise Fault('priority_route_binding_unavailable')
        return tuple(rows)
