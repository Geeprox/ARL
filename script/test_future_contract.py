"""Execute only the Foundation contract harness, never Control or any helper."""
import hashlib, json, subprocess
from pathlib import Path
from frozen_credentials_sdk import verify_frozen_sdk
# Retired together with its frozen external SDK builder.
raise SystemExit('Retired historical contract entrypoint; use script/verify_source_migration.py. No historical input was read.')
R=Path(__file__).resolve().parents[1];O=R/'build/future-oct3';O.mkdir(parents=True,exist_ok=True)
m=json.loads((O/'build-manifest.json').read_text())
assert m['native_actions_default_held'] and m['proposed_review_bundle_id']=='local.arl.control.future.oct3'
SDK=Path(m['credential_sdk']['sdk_directory']) if m.get('credential_sdk') else R/'build/credential-sdk'
if m.get('credential_sdk'):
    assert verify_frozen_sdk(R,SDK)==m['credential_sdk'],'Frozen SDK drift before harness'
for relative,expected in m['code_inputs'].items():
    assert hashlib.sha256((R/relative).read_bytes()).hexdigest()==expected,'Control source drift before harness: '+relative
sources=[R/p for p in m['code_inputs'] if not p.startswith('macOS/ARLControl/App/')]
cmd=['/usr/bin/swiftc','-D','ARL_FUTURE_OCT3','-swift-version','6','-Xfrontend','-disable-sandbox',
     '-target','arm64-apple-macos14.0','-module-cache-path',O/'ModuleCache','-I',SDK,
     '-L',SDK,'-lARLCredentialHostCore','-lz','-Xcc',
     '-fmodule-map-file='+str(SDK/'FlyAICompression/module.modulemap'),*sources,
     R/'tests/FutureIntegrationContract.swift','-o',O/'FutureIntegrationContract']
p=subprocess.run(list(map(str,cmd)),cwd=R,text=True,capture_output=True)
(O/'contract-compile.log').write_text(p.stdout+p.stderr)
assert p.returncode==0,(p.stdout+p.stderr)[-10000:]
if m.get('credential_sdk'):
    assert verify_frozen_sdk(R,SDK)==m['credential_sdk'],'Frozen SDK drift during harness compile'
p=subprocess.run([str(O/'FutureIntegrationContract')],cwd=R,text=True,capture_output=True,timeout=60)
(O/'contract-execution.log').write_text(p.stdout+p.stderr)
assert p.returncode==0,p.stdout+p.stderr
result=json.loads(p.stdout);assert result['passed'] and result['helper_starts']==0
(R/'evidence/future-contract-tests.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
