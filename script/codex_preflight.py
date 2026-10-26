"""No-turn real App Server inspection. Print only approved finite metadata."""
import hashlib,json,tempfile,time,re
from pathlib import Path
from arl.codex_server import Session,DEFAULT_BINARY,CONFIG,thread_preferences,confirmed_preferences
from arl.contracts import Fault

def preflight(binary=DEFAULT_BINARY, *, expected_model=None, timeout=30, workspace_root=None, reasoning_effort='xhigh', service_tier='default'):
 deadline=time.monotonic()+min(30,max(1,timeout))
 with tempfile.TemporaryDirectory(prefix='arl-codex-preflight-',dir=workspace_root) as workspace:
  session=Session(binary,workspace,timeout=30,absolute_deadline=deadline,diagnostic=True)
  try:
   session.initialize()
   # No refresh/login or model selection. Email, origins, raw config and keys are never emitted.
   account=session.response(session.send('account/read',{'refreshToken':False}))
   cfg=session.response(session.send('config/read',{'includeLayers':False,'cwd':workspace}))['config']
   features=cfg.get('features',{})
   servers=cfg.get('mcp_servers',{})
   if any(not re.fullmatch(r'[A-Za-z0-9_-]{1,100}',k) for k in servers):raise Fault('provider_mcp_name_unsupported')
   disabled={'mcp_servers.'+k+'.enabled':False for k in servers}
   # An empty table override merges and does not disable configured servers.
   # Shut down the probe before constructing the hardened text session.
   session.close();session.diagnostic_code()
   session=Session(binary,workspace,timeout=30,absolute_deadline=deadline,diagnostic=True,overrides=disabled)
   session.initialize();model=session.text_controls()
   account=session.response(session.send('account/read',{'refreshToken':False}))
   if expected_model is not None and model != expected_model:raise Fault('provider_model_change_not_authorized')
   thread=session.response(session.send('thread/start',{'cwd':workspace,'model':model,'approvalPolicy':'never','sandbox':'read-only','ephemeral':True,
     'baseInstructions':'Return requested text only. Never use tools or access files.',
     'developerInstructions':'Only synthetic text is supplied. No tool calls, file reads or actions are allowed.', 'serviceName':'arl-text-smoke',**thread_preferences(reasoning_effort,service_tier)}))
   if thread.get('model')!=model or thread.get('approvalPolicy')!='never' or thread.get('sandbox',{}).get('type')!='readOnly' or thread.get('sandbox',{}).get('networkAccess',False) is not False or thread.get('instructionSources') or thread.get('thread',{}).get('ephemeral') is not True:
    raise Fault('provider_controls_unverified')
   preferences=confirmed_preferences(thread,reasoning_effort,service_tier)
   out={'execution_preferences':preferences,'account_type':(account.get('account') or {}).get('type'),
     'requires_auth':account.get('requiresOpenaiAuth'),'model':model,
     'binary_sha256':hashlib.sha256(Path(binary).read_bytes()).hexdigest(),
     'provider':cfg.get('model_provider'),'turns_started':0,
     'feature_controls':{k:features.get(k.removeprefix('features.')) for k in CONFIG if k.startswith('features.')},
     'configured_mcp_count':len(servers),'mcp_disabled_verified':True, 'web_search':cfg.get('web_search'),
     'thread_read_only_verified':True,'thread_ephemeral':True,'instruction_sources_empty':True,
     'has_inherited_instructions':bool(cfg.get('instructions') or cfg.get('developer_instructions'))}
   return out
  except Fault as e:
   session.close()
   return {'error_code':e.code,'diagnostic_code':session.diagnostic_code(),'turns_started':0}
  finally:
   if session.process.poll() is None:session.close()
if __name__=='__main__':
 try:print(json.dumps(preflight(),sort_keys=True))
 except Fault as e:print(json.dumps({'error_code':e.code,'turns_started':0}))
 except Exception as e:print(json.dumps({'error_code':'preflight_local_error','error_type':type(e).__name__,'turns_started':0}))
