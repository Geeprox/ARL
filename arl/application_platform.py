"""Local application registration and package task admission for the installed base.

Same-account kernel process identity is the SDK trust boundary. Display metadata
is self-declared, never publisher attestation. Registration admits only the
already-enabled model service; Apple/NAS/credential tools remain separately gated.
"""
from __future__ import annotations
import hashlib,os,re,socket,struct,sys,threading,time
from pathlib import Path
from .application_contract import MAX_TASK_DEADLINE_MS, TASK_GET, TASK_METHODS, TASK_SUBMIT, validate_scenarios
from .application_models import ApplicationModels, METHODS
from .contracts import AppPolicy,Fault,encode,validate
from .control import AppDescriptor
from .identity import process_identity
from .codex_packages import PackageRegistry,read_private,validate_packages
from .app_connections import token,CHALLENGE_MS
from .scheduling import BANDS

def kernel_peer(connection):
    if sys.platform=='darwin':
        pid=struct.unpack('i',connection.getsockopt(0,2,4))[0]
        identity=process_identity(pid)
    elif sys.platform.startswith('linux'):
        pid,uid,_=struct.unpack('3i',connection.getsockopt(socket.SOL_SOCKET,socket.SO_PEERCRED,12))
        raw=Path('/proc',str(pid),'stat').read_text().rsplit(')',1)[1].split()
        identity={'uid':uid,'birth':raw[19],'executable':os.readlink(f'/proc/{pid}/exe')}
    else:raise Fault('identity_platform_unsupported')
    if identity['uid']!=os.geteuid():raise Fault('peer_not_authorized')
    def current():
        try:
            if sys.platform=='darwin':return process_identity(pid)==identity
            raw=Path('/proc',str(pid),'stat').read_text().rsplit(')',1)[1].split()
            return raw[19]==identity['birth'] and os.readlink(f'/proc/{pid}/exe')==identity['executable'] and Path('/proc',str(pid)).stat().st_uid==identity['uid']
        except (OSError,ValueError,Fault):return False
    return hashlib.sha256(encode([pid,identity])).hexdigest(),current

class ApplicationPlatform:
    def __init__(self,runtime,*,peer=kernel_peer):
        self.runtime=runtime;self.peer=peer;self.dynamic={};self.lock=threading.RLock()
        self.concurrency=2;self.last_settings=0
        self.refresh_settings()
        if runtime.application_models is None:
            runtime.application_models=ApplicationModels(runtime.control.apps,runtime.policies,
                lambda _: {'schema_version':1,'source':'app_server_model_list','selection_enabled':False,'models':[],'current':{}})
        if runtime.application_models is not None and runtime.codex_service is not None:
            runtime.application_models.package_configuration = lambda _: PackageRegistry(runtime.codex_service.package_home).load()["packages"]
    def refresh_settings(self):
        try:
            value=read_private(self.runtime.home/'model-scheduler-v1.json',4096)
            if type(value) is not dict or set(value)!={'schema_version','max_parallel'} or value['schema_version']!=1 or type(value['max_parallel']) is not int or not 1<=value['max_parallel']<=8:raise Fault('invalid_scheduler_configuration')
            self.concurrency=value['max_parallel']
        except FileNotFoundError:self.concurrency=2
        except (OSError,ValueError,Fault):pass # Retain the last valid setting.
        self.last_settings=time.monotonic()
    def prepare(self,connection,request):
        owner=request.get('app');method=request.get('method')
        if type(owner) is not str or re.fullmatch(r'[A-Za-z0-9_.-]{1,64}',owner) is None:return None,None
        r=self.runtime;policy=r.policies.get(owner)
        if owner not in self.dynamic and policy is not None and (policy.tools or policy.methods):return None,None
        if owner not in self.dynamic and method!='connection.open':return None,None
        binding=self.peer(connection)
        with self.lock,r.control.apps.lock:
            old=self.dynamic.get(owner)
            entry=r.control.apps.entries.get(owner,{})
            pending=entry.get('pending')
            if pending and not 0<=r.control.apps.monotonic()-pending['at_mono']<=CHALLENGE_MS:
                entry['pending']=pending=None
            owns_lease=bool(r.control.apps.live_session(entry) or
                pending and not entry.get('closed'))
            if old and old[0]!=binding[0] and old[1]() and owns_lease:raise Fault('app_instance_conflict')
            if method=='connection.open':
                p=request.get('params')
                if type(p) is not dict or set(p)-{'client_nonce','name','icon_ref','version','capabilities','scenarios'} or not {'client_nonce','name','icon_ref','version','capabilities'}<=set(p):raise Fault('invalid_arguments')
                if not token(p['client_nonce']) or type(p['capabilities']) is not list:raise Fault('invalid_arguments')
                AppDescriptor(owner,p['name'],p['icon_ref'],p['version'],tuple(p['capabilities'])).validate()
                validate_scenarios(p.get('scenarios',[]))
                if owner not in self.dynamic:
                    if len(self.dynamic)>=64:
                        for app,(_,current) in list(self.dynamic.items()):
                            entry=r.control.apps.entries.get(app,{})
                            ended=not current() or entry.get('closed') or entry.get('expired')
                            if ended and not r.store.has_active_jobs(app):
                                self.dynamic.pop(app);r.control.apps.entries.pop(app,None);r.policies.pop(app,None)
                                r.control.apps.app_ids=r.control.apps.app_ids-{app}
                                r.control.diagnostics.app_ids=r.control.diagnostics.app_ids-{app}
                                if r.work_scope is not None:r.work_scope=frozenset(x for x in r.work_scope if x[0]!=app)
                    if len(self.dynamic)>=64:raise Fault('application_registration_capacity')
                route=r.codex_service
                model_enabled=route is not None and route.current() and route.name in p['capabilities']
                tools=frozenset({route.name}) if model_enabled else frozenset()
                r.policies[owner]=AppPolicy(tools,frozenset(),0,16,route.max_calls if model_enabled else 0,
                    methods=frozenset({'health','ready','capabilities','heartbeat','runtime.describe','get','cancel'})|METHODS|TASK_METHODS,
                    priority_bands=frozenset(BANDS),max_deadline_ms=MAX_TASK_DEADLINE_MS)
                registry=r.control.apps
                registry.app_ids=registry.app_ids|{owner};registry.diagnostics.app_ids=registry.diagnostics.app_ids|{owner}
                if not old or old[0]!=binding[0] or registry.entries.get(owner,{}).get('registration')!='registered':
                    registry.entries[owner]={'descriptor':AppDescriptor(owner,p['name'],p['icon_ref'],p['version'],tuple(p['capabilities'])),'registration':'registered','seen':None,'verified':None,'capability_checks':{},'active_guard':binding[1]}
                self.dynamic[owner]=binding
                if model_enabled:r.work_scope=(r.work_scope or frozenset())|{(owner,route.name)}
            elif old is None or old[0]!=binding[0]:return None,None
        return owner,binding
    def snapshot(self):
        r=self.runtime
        if time.monotonic()-self.last_settings>=5:self.refresh_settings()
        tool_name = r.codex_service.name if r.codex_service is not None else None
        activity = r.store.task_activity(tool_name)
        return {'schema_version': 1, 'max_parallel': self.concurrency, **activity}
    def active(self,owner):
        binding=self.dynamic.get(owner);entry=self.runtime.control.apps.entries.get(owner)
        return bool(binding and binding[1]() and entry and self.runtime.control.apps.live_session(entry))
    def dispatch(self,request,binding):
        r=self.runtime;owner=request['app'];p=request['params'];method=request['method'];route=r.codex_service
        if not isinstance(p,dict) or p.get('schema_version')!=1 or type(p.get('schema_version')) is not int:raise Fault('invalid_arguments')
        with r.control.apps.lock:
            r.application_models._session(owner,p.get('session_id'),binding)
            if route is None or route.name not in r.policies[owner].tools:raise Fault('model_service_not_enabled')
            if method!=TASK_SUBMIT:
                if set(p)!={'schema_version','session_id','job_id'}:raise Fault('invalid_arguments')
                operation='get' if method==TASK_GET else 'cancel'
                return r.dispatch({'protocol':'arl/1','app':owner,'method':operation,'params':{'id':p['job_id']}},verified_app=owner)
            if set(p)!={'schema_version','session_id','request_id','scenario_id','input'} or type(p['request_id']) is not str or re.fullmatch(r'[a-z0-9-]{1,128}',p['request_id']) is None or type(p['input']) is not str:raise Fault('invalid_arguments')
            scenario=next((x for x in r.control.apps.entries[owner].get('scenarios',[]) if x['id']==p['scenario_id']),None)
            if scenario is None:raise Fault('application_scenario_not_registered')
            digest=hashlib.sha256(encode({'scenario_id':p['scenario_id'],'input':p['input']})).hexdigest()
            request_id = p['request_id']
            previous = r.store.lookup_application_task(owner, request_id, digest)
            if previous is not None:
                return previous
            registry=PackageRegistry(route.package_home)
            with registry.locked():
                config=registry.load();validate_packages(config['packages'],route.catalog);selected=config['packages'][scenario['package_id']]
                args={'model':selected['model'],'reasoning_effort':selected['reasoning_effort'],'service_tier':selected.get('service_tier','default'),'input':p['input'],'max_output_bytes':scenario['max_output_bytes']}
            route.admit(owner,route.name,args)
            resolved={'model':args['model'],'reasoning_effort':args['reasoning_effort'],'service_tier':args['service_tier'],'priority':scenario['priority']}
            selection = {'package_id': scenario['package_id'], 'scenario_id': scenario['id'], 'resolved': resolved}
            job, created = r.store.submit_application_task(
                owner, request_id, digest, r.tools[route.name], args, r.policies[owner],
                schedule={'priority': scenario['priority'], 'deadline_ms': scenario['deadline_ms']},
                selection=selection, max_calls=route.max_calls)
            if created:
                r.job_signal.set()
                r.control.diagnostics.emit('model_task_queued', app=owner, context={
                    'task_id': job['id'], 'package_id': selection['package_id'],
                    'model': args['model'], 'reasoning_effort': args['reasoning_effort'],
                })
            return job
