import copy, hashlib, json, os, socket, subprocess, sys, threading, time
from pathlib import Path
sys.dont_write_bytecode = True
BASE = Path(os.environ['ARL_CONTROL_TEST_DIR']).resolve()
SOURCE = Path(os.environ['ARL_CONTROL_SOURCE']).resolve()
FIXED = True
sys.path.insert(0, str(SOURCE))
from arl.service import Runtime
from arl.providers import MockProvider
from arl.client import Client
from arl.contracts import Fault

evidence = {'scope': 'exact copied Swift client/service/model/store; real isolated ARL transport, mock provider discovery only', 'cases': []}
schema = json.loads((SOURCE/'docs/settings-overview.schema.json').read_text())
def schema_check(value, rule, path='$'):
    if 'const' in rule: assert value == rule['const'] and type(value) is type(rule['const']), path
    if 'enum' in rule: assert value in rule['enum'], path
    kind = rule.get('type')
    if kind == 'object':
        assert type(value) is dict, path
        assert set(rule.get('required', [])) <= set(value), path
        if rule.get('additionalProperties') is False: assert set(value) <= set(rule['properties']), path
        for k, v in value.items():
            if k in rule.get('properties', {}): schema_check(v, rule['properties'][k], path+'.'+k)
    elif kind == 'array':
        assert type(value) is list and len(value) <= rule.get('maxItems', float('inf')), path
        for i, v in enumerate(value): schema_check(v, rule['items'], f'{path}[{i}]')
    elif kind == 'string': assert type(value) is str and rule.get('minLength', 0) <= len(value) <= rule.get('maxLength', float('inf')), path
    elif kind == 'integer': assert type(value) is int and rule.get('minimum', -float('inf')) <= value, path
    elif kind == 'boolean': assert type(value) is bool, path

def home(name):
    p = BASE/name; p.mkdir(mode=0o700, exist_ok=True); return p
def call(p, method=None):
    command = [str(BASE/'harness'), str(p)] + ([method] if method else [])
    result = subprocess.run(command, capture_output=True, text=True, timeout=15)
    assert result.returncode == 0, result.stderr[-1000:]
    return json.loads(result.stdout)
def record(name, result, passed, **extra):
    evidence['cases'].append({'name': name, 'passed': bool(passed), 'result': result, **extra})
    print(json.dumps({'name':name, 'passed':bool(passed), 'error':result.get('error'), 'title':result.get('title'), 'elapsed_ms':result.get('elapsed_ms') }), flush=True)

rh=home('r0'); runtime=Runtime(rh, start_delay=8, providers={'mock':MockProvider()}, identity_verifier=lambda connection, app: None)
errors=[]
def run_runtime():
    try: runtime.run()
    except BaseException as e: errors.append(type(e).__name__)
rt=threading.Thread(target=run_runtime); rt.start()
try:
    until=time.monotonic()+3
    while not (rh/'runtime.sock').exists() and time.monotonic()<until: time.sleep(.01)
    result=call(rh); schema_check(result['snapshot'],schema)
    record('real-runtime-not-ready',result,result['snapshot']['health']['ready'] is False and result['title']=='正在准备' and result['error'] is None)
    assert runtime.ready.wait(10)
    result=call(rh); schema_check(result['snapshot'],schema)
    valid=copy.deepcopy(result['snapshot'])
    record('real-runtime-ready',result,result['snapshot']['health']['ready'] and result['title']=='运行时已就绪' and result['error'] is None)
    for method in ['health','ready','overview']:
        result=call(rh,method); record('settings-read-'+method,result,result['ok'])
    before=Client(rh,'settings').rpc('overview')['queue']['counts']
    for method in ['submit','get','cancel','resume','wake','poll_wakes','stop','providers','capabilities']:
        result=call(rh,method); record('settings-deny-'+method,result,result['error']=='app_identity_unverified')
    after=Client(rh,'settings').rpc('overview')['queue']['counts']
    record('no-write-no-private-metadata', {'queue_unchanged':before==after,'disabled_absent':not (rh/'disabled').exists(),'metadata_only':all(s not in json.dumps(valid) for s in [str(rh),'state.sqlite','runtime.sock','http://','https://'])}, before==after and not (rh/'disabled').exists())
finally:
    runtime.shutdown(); rt.join(10); assert not rt.is_alive() and not errors,errors

result=call(rh);record('offline-existing-home',result,result['error']=='disconnected' and result['title']=='未连接' and result['reading'] is False)
result=call(BASE/'missing');record('offline-missing-home',result,result['error']=='disconnected')
dh=home('r1');(dh/'disabled').write_text('');result=call(dh);record('user-disabled',result,result['error']=='user_disabled' and result['title']=='已停用')
uh=home('r2');uh.chmod(0o755);result=call(uh);record('unsafe-home',result,result['error']=='unsafe_home');uh.chmod(0o700)

counter=3
def fake(name, payload, expected_error=None, mutate_schema=False, drip=False, silent=False, method=None):
    global counter
    p=home('r'+str(counter));counter+=1
    srv=socket.socket(socket.AF_UNIX);srv.bind(str(p/'runtime.sock'));srv.listen(1)
    captured=[]
    def serve():
        conn,_=srv.accept()
        with conn:
            req=b''
            while b'\n' not in req: req+=conn.recv(4096)
            captured.append(json.loads(req))
            try:
                if silent: time.sleep(6);return
                if drip:
                    for _ in range(10): conn.sendall(b' ');time.sleep(.8)
                conn.sendall(payload)
            except BrokenPipeError: pass
    thread=threading.Thread(target=serve);thread.start()
    try:
        result=call(p, method)
        ok=result.get('error')==expected_error if expected_error else result.get('error') is None
        if FIXED and (drip or silent): ok = ok and result['elapsed_ms'] < 5500
        record(name,result,ok,captured_request=captured,invalid_schema_accepted=mutate_schema and result.get('error') is None,overall_deadline_exceeded=drip and result['elapsed_ms']>5000)
        assert captured==[{'protocol':'arl/1','app':'settings','method':'ready' if method else 'overview','params':{}}]
    finally:
        thread.join(8);srv.close();(p/'runtime.sock').unlink()
def packet(s, protocol='arl/1'):return json.dumps({'protocol':protocol,'ok':True,'result':s}).encode()+b'\n'
fake('unsupported-envelope-protocol',packet(valid,'arl/999'),'unsupported_protocol')
bad=copy.deepcopy(valid);bad['protocol']='arl/999';fake('unsupported-result-protocol',packet(bad),'unsupported_protocol')
bad=copy.deepcopy(valid);bad['schema_version']=2;fake('unsupported-schema-version',packet(bad),'unsupported_protocol')
fake('malformed-json',b'{oops\n','invalid_response')
bad=copy.deepcopy(valid);del bad['health'];fake('missing-required-object',packet(bad),'invalid_response')
fake('remote-policy-error',json.dumps({'protocol':'arl/1','ok':False,'error':{'code':'app_identity_unverified'}}).encode()+b'\n','app_identity_unverified')
fake('socket-inactivity-timeout',packet(valid),'rpc_deadline_exceeded' if FIXED else 'disconnected',silent=True)
fake('slow-drip-overall-deadline',packet(valid),'rpc_deadline_exceeded' if FIXED else None,drip=True)
bad=copy.deepcopy(valid);bad['queue']['counts']['queued']=-7;bad['policy']['paid_inference_enabled']=True;bad['health']['ui_required']=True
invalid = False
try: schema_check(bad,schema)
except AssertionError: invalid = True
assert invalid, 'negative fixture valid unexpectedly'
fake('schema-invalid-semantics',packet(bad),'invalid_response' if FIXED else None,mutate_schema=True)
bad=copy.deepcopy(valid);bad['queue']['counts']={'queued':0};bad['providers'][0]['availability']='invalid-new-status';bad['unexpected_field']='synthetic-only'
fake('schema-missing-counts-unknown-enum-extra',packet(bad),'invalid_response' if FIXED else None,mutate_schema=True)

# Further fail-closed checks isolate each schema constraint and transport bound.
for label, mutate in [
    ('negative-count', lambda s:s['queue']['counts'].update(queued=-1)),
    ('missing-count', lambda s:s['queue']['counts'].pop('failed')),
    ('paid-enabled', lambda s:s['policy'].update(paid_inference_enabled=True)),
    ('automatic-fallback', lambda s:s['policy'].update(automatic_fallback=True)),
    ('model-downloads', lambda s:s['policy'].update(model_downloads=True)),
    ('ui-required', lambda s:s['health'].update(ui_required=True)),
    ('number-as-bool', lambda s:s['health'].update(live=1)),
    ('negative-budget', lambda s:s['budgets'][0].update(max_calls=-1)),
    ('prompt-constant', lambda s:s['budgets'][0].update(max_prompt_utf8_bytes=1025)),
    ('provider-enum', lambda s:s['providers'][0].update(availability='new-value')),
    ('inference-enum', lambda s:s['providers'][0].update(inference_policy='automatic')),
    ('capability-enum', lambda s:s['capabilities'][0].update(availability='new-value')),
    ('identity-enum', lambda s:s['capabilities'][0].update(identity_gate='trusted-by-json')),
    ('authorization-enum', lambda s:s['capabilities'][0].update(authorization_gate='approved')),
    ('long-string', lambda s:s['providers'][0].update(name='a'*201)),
    ('large-array', lambda s:s['providers'][0].update(models=['m']*101)),
    ('extra-nested', lambda s:s['health'].update(endpoint='synthetic')),
    ('sum-overflow', lambda s:s['queue']['counts'].update(queued=2**62,running=2**62)),
]:
    bad=copy.deepcopy(valid);mutate(bad);fake('reject-'+label,packet(bad),'invalid_response',mutate_schema=True)
bad=copy.deepcopy(valid);bad['providers'][0]['availability']='unknown';bad['capabilities'][0]['availability']='unknown'
fake('allowed-explicit-unknown-state',packet(bad))
fake('reject-null-result',packet(None),'invalid_response')
fake('reject-multiple-frame-newlines',packet(valid)+b'\n','invalid_response')
fake('reject-overlarge-frame',b' '*131073+b'\n','invalid_response')
fake('connect-short-total-deadline',packet(valid),'ready_timeout',silent=True,method='test-connect-deadline')
assert evidence['cases'][-1]['result']['elapsed_ms'] < 600

evidence['runtime_closed']=runtime.closed.is_set() and not (rh/'runtime.sock').exists()
evidence['source_hashes']={str(p.relative_to(SOURCE)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [SOURCE/'examples/ARLClient.swift', *sorted((SOURCE/'macOS/ARLControl').glob('Models/*.swift')), *sorted((SOURCE/'macOS/ARLControl').glob('Services/*.swift'))]}
(BASE/('fixed-evidence.json' if FIXED else 'evidence.json')).write_text(json.dumps(evidence,ensure_ascii=False,indent=2)+'\n')
assert all(c['passed'] for c in evidence['cases'])
print(json.dumps({'cases':len(evidence['cases']),'passed':True,'runtime_closed':evidence['runtime_closed']}),flush=True)
