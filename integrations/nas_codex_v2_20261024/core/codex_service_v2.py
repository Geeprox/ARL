"""Identity-bound Codex v2 resolutions and atomic, persistent job admission."""
import hashlib,json,secrets,time,uuid
from pathlib import Path
from .codex_server import CodexService
from .codex_packages import PackageRegistry,canonical,digest,validate_packages
from .codex_execution_options import selection
from .contracts import Fault,object_schema,string,validate
NAME='codex.text.generate.v2'
METHODS=frozenset({'application.models.discover.v2','application.models.request.v2','codex.requests.lookup.v2','codex.account.usage.v2'})
MESSAGES={'type':'array','minItems':1,'items':object_schema({'role':{'type':'string','enum':['system','developer','user','assistant']},'content':string(8192)},['role','content'])}
SCHEMA=object_schema({'schema_version':{'type':'integer','enum':[2]},'resolution_id':string(64),'messages':MESSAGES},['schema_version','resolution_id','messages'])
def decode_request(raw):
    value=json.loads(raw)
    if type(value)==dict and (value.get('method') in METHODS or value.get('method')=='submit' and type(value.get('params'))==dict and value['params'].get('tool')==NAME):
        from .wire import strict_json
        return strict_json(raw)
    return value
def prompt(messages):
    return canonical(messages).decode()
def checked_uuid(value):
    try:
        if str(uuid.UUID(value))!=value:raise ValueError()
    except (ValueError,TypeError,AttributeError):raise Fault('invalid_request_id') from None
    return value
class CodexServiceV2(CodexService):
    name=NAME
    def __init__(self,*args,package_home,**kwargs):
        super().__init__(*args,allow_model_selection=True,**kwargs)
        self.schema=SCHEMA;self.registry=PackageRegistry(package_home);self.gateway=None
    def preflight(self):
        proof=super().preflight()
        self.registry.publish(self.catalog,{'model':self.model,'reasoning_effort':self.reasoning_effort,'service_tier':'default'})
        return proof
    def admit(self,owner,tool,args,*,completion=False):
        if tool!=NAME:return
        if owner!=self.caller or not self.current() or self.gateway is None:raise Fault('codex_scope_unavailable')
        validate(args,SCHEMA)
        row=self.gateway.resolution(args['resolution_id'],owner)
        if digest({'messages':args['messages']})!=row['content_sha256']:raise Fault('content_hash_mismatch')
        # The lease applies until admission only. Package edits do not invalidate
        # the frozen choice. Current provider catalog/identity are still checked.
        if not row.get('job_id') and time.time()>row['expires_at']:raise Fault('resolution_expired')
        resolved=row['resolved']
        base={'model':resolved['model'],'reasoning_effort':resolved['reasoning_effort'],'service_tier':resolved['service_tier'],'input':prompt(args['messages']),'max_output_bytes':row['output']['max_bytes']}
        # Parent validation uses the v1 flat argument shape. Never change shared
        # schema while concurrent RPCs may be validating another request.
        from .codex_server import SCHEMA as BASE_SCHEMA
        base_schema=dict(BASE_SCHEMA,properties=dict(BASE_SCHEMA['properties'],reasoning_effort=string(40),service_tier=string(20)))
        validate(base,base_schema)
        if not completion:selection(self.catalog,base['model'],base['reasoning_effort'],base['service_tier'])
        if len(base['input'].encode())>8192 or base['max_output_bytes']>self.max_output_bytes:raise Fault('model_budget_exceeded')
        if not completion and (self.checked_mono is None or not 0<=time.monotonic()-self.checked_mono<=90):raise Fault('codex_preflight_required')
        self.adapter.verify()
        return row,base
    def run(self,args,context):
        row,base=self.admit(context.owner,NAME,args)
        self.observe(context.row['id'],'begin')
        result=self.adapter.run({k:base[k] for k in ('model','input','max_output_bytes')},context,reasoning_effort=base['reasoning_effort'],service_tier=base['service_tier'],selectable=True)
        result['selection_receipt']={k:row[k] for k in ('resolution_id','request_id','content_sha256','selector','resolved','package_revision','package_config_digest','catalog_version')}
        return result
    def fence(self,result,context):
        row,base=self.admit(context.owner,NAME,json.loads(context.row['args']),completion=True)
        context.check_cancelled();self.adapter.verify()
        if (result.get('model')!=base['model'] or result.get('simulated')!=(self.adapter.test_command is not None) or (result.get('execution_preferences') or {}).get('reasoning_effort')!=base['reasoning_effort'] or (result.get('execution_preferences') or {}).get('service_tier')!=base['service_tier'] or self.progress({'id':context.row['id']})['native']['terminal']!='completed' or result.get('selection_receipt',{}).get('resolution_id')!=row['resolution_id']):raise Fault('completion_unverified')
    def finish_failure(self,store,row,code):
        p=self.progress({'id':row['id'],'state':'queued'});native=p['native']
        state='cancelled' if code=='cancelled' and (not p['turn_sent'] or native['terminal']=='interrupted') else 'failed' if not p['turn_sent'] or native['terminal']=='failed' else 'needs_review'
        r=self.gateway.resolution(json.loads(row['args'])['resolution_id'],row['owner'])
        store.finish(row,state,{'schema_version':2,'provider':'codex_app_server','model':r['resolved']['model'],'selection_receipt':r,'native':native,'simulated':self.adapter.test_command is not None},error=code)
class CodexGatewayV2:
    def __init__(self,runtime,service):
        self.runtime=runtime;self.service=service;service.gateway=self
        # Created before any worker/thread starts; all later operations use the
        # Store's same transaction/lock, including freeze + job + budget update.
    def initialize(self):
        with self.runtime.store.transaction():
            self.runtime.store.db.execute('CREATE TABLE IF NOT EXISTS codex_resolutions_v2 (id TEXT PRIMARY KEY,owner TEXT NOT NULL,request_id TEXT NOT NULL,request_digest TEXT NOT NULL,value TEXT NOT NULL,UNIQUE(owner,request_id))')
    def resolution(self,identity,owner):
        with self.runtime.store.lock:
            row=self.runtime.store.db.execute('SELECT value FROM codex_resolutions_v2 WHERE id=? AND owner=?',(identity,owner)).fetchone()
            if not row:raise Fault('resolution_not_found')
            return json.loads(row[0])
    def session(self,owner,params,binding):
        if binding is None or binding[1]() is not True:raise Fault('app_identity_unverified')
        apps=self.runtime.control.apps
        with apps.lock:
            entry=apps.entries.get(owner);s=apps.live_session(entry) if entry else None
            if not s or s['binding']!=binding[0] or s['guard']() is not True or not secrets.compare_digest(s['id'],params.get('session_id','')):raise Fault('app_session_changed')
        return s
    def discovery(self):
        status=self.service.status()
        if not status['route_enabled']:raise Fault('codex_preflight_required')
        catalog=self.service.catalog
        version=self.service.registry.publish(catalog,{'model':self.service.model,'reasoning_effort':self.service.reasoning_effort,'service_tier':'default'})
        packages=self.service.registry.load()
        rows=[]
        for model in catalog:
            rows.append({'id':model['model'],'object':'model','owned_by':'arl','reasoning_efforts':[e['id'] for e in model['efforts']],'default_effort':model['default_effort']})
        for key,row in packages['packages'].items():
            try:selection(catalog,row['model'],row['reasoning_effort'],'default');available=True
            except Fault:available=False
            rows.append({'id':'arl/package/'+key,'object':'model','owned_by':'arl','display_name':row['display_name'],'available':available})
        return {'schema_version':2,'catalog_version':version,'models':rows,'package_revision':packages['revision'],'quota_policy':'inherit_account','local_lifetime_call_limit':None,'admitted_requests_total':status['admitted_requests_total'],'limits':{'max_input_bytes':8192,'max_output_bytes':32768,'max_wall_ms':180000,'priority':['explicit'],'service_tiers':['default']},'token_hard_cap_supported':False}
    def dispatch(self,owner,method,params,binding):
        if owner!=self.service.caller or type(params)!=dict:raise Fault('method_not_authorized')
        self.session(owner,params,binding)
        if method=='application.models.discover.v2':
            if set(params)!={'session_id'}:raise Fault('invalid_arguments')
            return self.discovery()
        if method=='codex.account.usage.v2':
            if set(params)!={'session_id'}:raise Fault('invalid_arguments')
            return {'schema_version':2,'quota_policy':'inherit_account','local_lifetime_call_limit':None,'admitted_requests_total':self.service.status()['admitted_requests_total'],'upstream_windows':None,'upstream_snapshot_state':'not_read','purchased_credits_used':False}
        if method=='codex.requests.lookup.v2':
            if set(params)!={'session_id','request_id'}:raise Fault('invalid_arguments')
            checked_uuid(params['request_id'])
            with self.runtime.store.lock:
                row=self.runtime.store.db.execute('SELECT value FROM codex_resolutions_v2 WHERE owner=? AND request_id=?',(owner,params['request_id'])).fetchone()
                if not row:return {'schema_version':2,'found':False}
                r=json.loads(row[0]);job=self.runtime.store.get(owner,r['job_id']) if r.get('job_id') else None
                return {'schema_version':2,'found':True,'resolution':self.public_resolution(r),'job':job}
        if method!='application.models.request.v2':raise Fault('unknown_method')
        fields={'schema_version','session_id','request_id','catalog_version','content_sha256','task_kind','selector','schedule','output','service_tier'}
        if set(params)!=fields or params['schema_version']!=2 or params['task_kind'] not in {'text.generate','text.translate','text.summarize'}:raise Fault('invalid_arguments')
        checked_uuid(params['request_id'])
        if type(params['content_sha256'])!=str or len(params['content_sha256'])!=64 or any(c not in '0123456789abcdef' for c in params['content_sha256']):raise Fault('invalid_content_hash')
        if params['service_tier']!='default' or params['schedule']!={'priority':'explicit','execution_timeout_ms':180000,'queue_timeout_ms':0} or params['output']!={'max_bytes':32768}:raise Fault('unsupported_execution_options')
        selector=params['selector']
        if type(selector)!=dict:raise Fault('invalid_selector')
        normalized={k:v for k,v in params.items() if k!='session_id'};request_digest=digest(normalized)
        store=self.runtime.store
        with self.service.registry.locked(),store.transaction():
            old=store.db.execute('SELECT value,request_digest FROM codex_resolutions_v2 WHERE owner=? AND request_id=?',(owner,params['request_id'])).fetchone()
            if old:
                if old[1]!=request_digest:raise Fault('idempotency_conflict')
                return self.public_resolution(json.loads(old[0]))
            if params['catalog_version']!=self.service.registry.version(self.service.catalog):raise Fault('catalog_changed')
            config=self.service.registry.load();package_revision=package_digest=None
            if selector.get('kind')=='package' and set(selector)=={'kind','package_id'} and selector['package_id'] in config['packages']:
                chosen=config['packages'][selector['package_id']];model=chosen['model'];effort=chosen['reasoning_effort'];package_revision=config['revision'];package_digest=digest(config)
            elif selector.get('kind')=='model' and set(selector) in ({'kind','model'},{'kind','model','reasoning_effort'}):
                model=selector['model'];row=next((m for m in self.service.catalog if m['model']==model),None)
                if row is None:raise Fault('model_unavailable')
                effort=selector.get('reasoning_effort',row['default_effort'])
            else:raise Fault('invalid_selector')
            selection(self.service.catalog,model,effort,'default')
            r=dict(normalized,resolution_id=secrets.token_hex(32),expires_at=time.time()+30,owner=owner,binding=binding[0],resolved={'model':model,'reasoning_effort':effort,'service_tier':'default'},package_revision=package_revision,package_config_digest=package_digest,job_id=None)
            store.db.execute('INSERT INTO codex_resolutions_v2 VALUES (?,?,?,?,?)',(r['resolution_id'],owner,r['request_id'],request_digest,canonical(r).decode()))
            return self.public_resolution(r)
    @staticmethod
    def public_resolution(r):
        return {k:v for k,v in r.items() if k not in {'owner','binding'}}
    def submit(self,owner,params,binding):
        if set(params)!={'tool','args','key'} or params['tool']!=NAME:raise Fault('invalid_arguments')
        checked_uuid(params['key']);validate(params['args'],SCHEMA)
        store=self.runtime.store
        with self.service.registry.locked(),store.transaction():
            r=self.resolution(params['args']['resolution_id'],owner)
            self.session(owner,{'session_id':self.runtime.control.apps.entries[owner]['session']['id']},binding)
            if r['request_id']!=params['key'] or r['binding']!=binding[0]:raise Fault('resolution_binding_mismatch')
            self.service.admit(owner,NAME,params['args'])
            # New admissions must resolve against current packages. Work already
            # admitted keeps its original revision and may finish after edits.
            if not r.get('job_id') and r['package_revision'] is not None and digest(self.service.registry.load())!=r['package_config_digest']:raise Fault('package_changed_before_admission')
            job=store.submit(owner,params['key'],self.runtime.tools[NAME],params['args'],self.runtime.policies[owner],verified=True,in_transaction=True)
            if r.get('job_id') and r['job_id']!=job['id']:raise Fault('idempotency_conflict')
            r['job_id']=job['id'];store.db.execute('UPDATE codex_resolutions_v2 SET value=? WHERE id=?',(canonical(r).decode(),r['resolution_id']))
        self.runtime.job_signal.set();return job
