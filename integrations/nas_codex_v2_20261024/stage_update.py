"""Stage an intact existing private NAS bridge; never install or launch it."""
from pathlib import Path
import argparse,ast,hashlib,json,shutil
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--base',required=True,type=Path);parser.add_argument('--output',required=True,type=Path)
args=parser.parse_args();root=Path(__file__).resolve().parents[2]
base=args.base.resolve(strict=True);stage=args.output.absolute()
if stage.exists():raise ValueError('new_staging_directory_required')
manifest=json.loads((base/'manifest.json').read_text())
if any((base/name).is_symlink() or hashlib.sha256((base/name).read_bytes()).hexdigest()!=digest for name,digest in manifest.items()):raise ValueError('base_closure_changed')
shutil.copytree(base,stage)
def block(source,kind,name,cls=None):
 nodes=ast.parse(source).body
 if cls:nodes=next(n for n in nodes if isinstance(n,ast.ClassDef) and n.name==cls).body
 node=next(n for n in nodes if isinstance(n,kind) and (getattr(n,'name',None)==name or isinstance(n,ast.Assign) and any(isinstance(t,ast.Name) and t.id==name for t in n.targets)))
 return ''.join(source.splitlines(keepends=True)[node.lineno-1:node.end_lineno])
def method(source,current,cls,name,transform=lambda x:x):
 fresh=transform(block(current,ast.FunctionDef,name,cls))
 try:old=block(source,ast.FunctionDef,name,cls)
 except StopIteration:
  anchor=' def observe(self, job,' if cls=='CodexService' else ' def metadata(self):'
  pos=source.index(anchor);return source[:pos]+fresh+'\n'+source[pos:]
 return source.replace(old,fresh,1)
current=(root/'arl/codex_server.py').read_text();p=stage/'core/arl/codex_server.py';s=p.read_text()
imports='from .codex_context import TRANSPORT_FRAME_BYTES, INPUT_POLICY, context_error, token_receipt\n'
if imports not in s:s=s.replace("NAME='codex.text.plan.v1'",imports+"NAME='codex.text.plan.v1'",1)
s=s.replace(block(s,ast.Assign,'SCHEMA'),block(current,ast.Assign,'SCHEMA'),1)
try:block(s,ast.Assign,'PROVIDER_FRAME_BYTES')
except StopIteration:s=s.replace('class Session:',block(current,ast.Assign,'PROVIDER_FRAME_BYTES')+'\n\nclass Session:',1)
for name in ('__init__','write','send','receive','response'):s=method(s,current,'Session',name)
s=s.replace('1 <= max_wall_seconds <= 180','1 <= max_wall_seconds <= 600')
if 'from .codex_diagnostics import Timing, rpc_error' not in s:s=s.replace('class Session:','from .codex_diagnostics import Timing, rpc_error\n\nclass Session:',1)
for name in ('refresh_official_binary','verify_official_binary','refresh_catalog'):s=method(s,current,'CodexTextAdapter',name)
def nas_deadline(value):
 return value.replace('context.remaining(30)','context.remaining(self.max_wall_seconds)').replace(' else 30)',' else self.max_wall_seconds)').replace('timeout=30,context=context','timeout=self.max_wall_seconds,context=context')
s=method(s,current,'CodexTextAdapter','_run',nas_deadline)
s=s.replace(block(s,ast.FunctionDef,'confirmed_preferences'),block(current,ast.FunctionDef,'confirmed_preferences'),1)
if 'package_home=None' not in s:s=s.replace('allow_test_command=False, allow_model_selection=False):','allow_test_command=False, allow_model_selection=False, package_home=None):',1)
if 'self.package_home = package_home' not in s:s=s.replace('  self.catalog = []','  self.catalog = []\n  self.package_home = package_home',1)
for name in ('preflight','admit','check_running','fence','observe','finish_failure'):s=method(s,current,'CodexService',name)
s=s.replace("'max_input_bytes':8192","'max_input_bytes':None,'input_policy':INPUT_POLICY,'transport_max_frame_bytes':TRANSPORT_FRAME_BYTES")
s=s.replace("  if size > 8192 or args['max_output_bytes'] > self.max_output_bytes:","  if size > TRANSPORT_FRAME_BYTES:raise Fault('transport_frame_too_large')\n  if args['max_output_bytes'] > self.max_output_bytes:")
ast.parse(s);p.write_text(s)
for name in ('codex_packages.py','codex_service_v2.py'):shutil.copy2(root/'integrations/nas_codex_v2_20261024/core'/name,stage/'core/arl'/name)
shutil.copy2(root/'arl/codex_context.py',stage/'core/arl/codex_context.py')
shutil.copy2(root/'arl/codex_diagnostics.py',stage/'core/arl/codex_diagnostics.py')
shutil.copy2(root/'arl/codex_context.py',stage/'model_context.py')
for name in ('host.py','contract.py','worker.py','local_api.py'):shutil.copy2(root/'integrations/nas_codex_v2_20261024/nas'/name,stage/name)
# Retain the frozen v2 identity/session dispatch additions. Only widen this
# explicitly composed Codex runtime; the default runtime remains 16 KiB.
p=stage/'core/arl/service.py';s=p.read_text()
s=method(s,(root/'arl/service.py').read_text(),'JobContext','check_cancelled')
if 'frame_limit=getattr(runtime' not in s:
 s=s.replace('            deadline, raw = time.monotonic()+5, bytearray()','            frame_limit=getattr(runtime,"max_request_frame_bytes",MAX_FRAME)\n            deadline, raw = time.monotonic()+5, bytearray()',1)
 s=s.replace('MAX_FRAME+1-len(raw)','frame_limit+1-len(raw)').replace('len(raw) > MAX_FRAME','len(raw) > frame_limit')
p.write_text(s)
p=stage/'core/arl/compat_host.py';s=p.read_text()
if 'runtime.max_request_frame_bytes' not in s:s=s.replace('    service.runtime = runtime','    from .codex_context import TRANSPORT_FRAME_BYTES\n    runtime.max_request_frame_bytes = TRANSPORT_FRAME_BYTES\n    service.runtime = runtime',1)
p.write_text(s)
p=stage/'core/arl/client.py';s=p.read_text();current=(root/'arl/client.py').read_text()
for name in ('__init__','rpc'):s=method(s,current,'Client',name)
p.write_text(s)
for p in stage.rglob('*.py'):ast.parse(p.read_text())
manifest={str(p.relative_to(stage)):hashlib.sha256(p.read_bytes()).hexdigest() for p in stage.rglob('*') if p.is_file() and p.name!='manifest.json'}
(stage/'manifest.json').write_text(json.dumps(manifest,sort_keys=True,separators=(',',':')))
for p in stage.rglob('*'):
 if p.is_file():p.chmod(0o700 if p.name=='PeerSignatureHelper' else 0o600)
print('Staged',len(manifest),'private closure members.')
