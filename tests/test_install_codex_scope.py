"""Signed-owner proposal format only. No app, model, launchd or real user state."""
import base64,json,plistlib,tempfile,unittest,subprocess,uuid
from pathlib import Path
from unittest.mock import patch
from arl.install_platform import MacPlatform
from arl.install_transaction import Layout,encode,sha,InstallFault

class CodexScopePlanTests(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory(prefix='codex-scope-install-');self.root=Path(self.temp.name).resolve();self.layout=Layout(self.root);self.layout.state.mkdir(parents=True,mode=0o700)
  self.app=self.root/'candidate/ARL.app';self.app.joinpath('Contents/Resources/CredentialReadOwner').mkdir(parents=True)
  self.authority={'owner':{'identifier':'local.arl.control','certificateSHA1':'A'*40}}
  raw=encode(self.authority);seal=sha(raw);(self.app/'Contents/Resources/CredentialReadOwner/authority.json').write_bytes(raw)
  self.info={'ARLCodexServicePolicyVersion':1,'ARLCoreRuntimeManifestSHA256':'b'*64,'ARLCredentialReadOwnerAuthoritySHA256':seal}
  (self.app/'Contents/Info.plist').write_bytes(plistlib.dumps(self.info))
  requirement='identifier "local.arl.control" and certificate leaf = H"'+('A'*40)+'" and info[ARLCredentialReadOwnerAuthoritySHA256] = "'+seal+'"'
  self.config={'schema_version':1,'caller':'arl-control','provider':'codex_app_server','model':'gpt-6.1-sol','reasoning_effort':'xhigh','service_tier':'default','scope_generation':str(uuid.uuid4()),'max_calls':32,'max_output_bytes':32768,'core_manifest_sha256':'b'*64,'caller_requirement':requirement,'explicit_submission_only':True}
  self.platform=MacPlatform(self.layout,self.app/'Contents/MacOS/ARL')
 def tearDown(self):self.temp.cleanup()
 def response(self,config=None,previous=None):
  raw=encode(self.config if config is None else config)
  value={'schema_version':1,'configuration_base64':base64.b64encode(raw).decode(),'configuration_sha256':sha(raw),'previous_sha256':previous,'production_changed':False,'inference_started':False}
  return subprocess.CompletedProcess([],0,json.dumps(value).encode(),b'')
 def test_readonly_proposal_is_bound_to_exact_package_and_previous_scope(self):
  with patch.object(self.platform,'command',return_value=self.response()) as command:
   raw,before=self.platform.codex_scope_candidate(self.app)
  self.assertEqual(json.loads(raw),self.config);self.assertIsNone(before);self.assertFalse(self.layout.targets['codex_scope'].exists())
  self.assertEqual(command.call_args.args[0],[self.app/'Contents/MacOS/ARL','--internal-codex-plan'])
 def test_changed_authority_or_model_is_rejected(self):
  for field,value in [('model','other'),('caller','mio'),('reasoning_effort','high'),('service_tier','fast'),('caller_requirement','other'),('core_manifest_sha256','c'*64),('max_calls',True)]:
   config={**self.config,field:value}
   with self.subTest(field=field),patch.object(self.platform,'command',return_value=self.response(config)),self.assertRaisesRegex(InstallFault,'codex_scope_plan_invalid'):
    self.platform.codex_scope_candidate(self.app)
 def test_scope_race_does_not_admit_proposal(self):
  path=self.layout.targets['codex_scope'];path.write_bytes(b'changed');path.chmod(0o600)
  with patch.object(self.platform,'command',return_value=self.response()),self.assertRaisesRegex(InstallFault,'codex_scope_preimage_changed'):
   self.platform.codex_scope_candidate(self.app)
if __name__=='__main__':unittest.main()
