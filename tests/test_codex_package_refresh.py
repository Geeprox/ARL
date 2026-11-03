"""Offline package/catalog/update boundaries; no account or inference."""
import tempfile,unittest
from pathlib import Path
from unittest.mock import patch
from arl.codex_packages import PackageRegistry
from arl.codex_server import CodexTextAdapter,CodexService
from arl.contracts import Fault

class PackageRefreshTests(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.registry=PackageRegistry(Path(self.tmp.name)/'packages')
  self.catalog=[{'model':'offline','display_name':'Offline','description':'','default_effort':'high','efforts':[{'id':'high','description':''}],'fast_available':True,'fast_description':''}]
  self.current={'model':'offline','reasoning_effort':'high','service_tier':'default'}
  self.registry.publish(self.catalog,self.current)
 def tearDown(self):self.tmp.cleanup()
 def save(self,row):
  return self.registry.save({'schema_version':2,'base_revision':row['revision'],'catalog_version':self.registry.version(self.catalog),'packages':row['packages']},self.catalog)
 def test_fast_round_trip_legacy_default_and_removed_model_preserves_choice(self):
  row=self.registry.load();row['packages']['medium']['service_tier']='fast'
  row['packages']['low'].pop('service_tier')
  saved=self.save(row)
  self.assertEqual(saved['packages']['medium']['service_tier'],'fast')
  replacement=[dict(self.catalog[0],model='replacement')]
  self.registry.publish(replacement,self.current)
  self.assertEqual(self.registry.load()['packages'],saved['packages'])
  self.assertEqual(self.registry.load()['revision'],saved['revision'])
 def test_unsupported_fast_save_does_not_mutate(self):
  old=self.registry.load();row=self.registry.load();row['packages']['medium']['service_tier']='fast'
  self.catalog[0]['fast_available']=False
  with self.assertRaises(Fault):self.save(row)
  self.assertEqual(self.registry.load(),old)
 def test_fast_acknowledgement_accepts_only_explicit_provider_tiers(self):
  from arl.codex_server import confirmed_preferences
  for tier in ('fast','priority'):
   proof=confirmed_preferences({'reasoningEffort':'low','serviceTier':tier},'low','fast')
   self.assertEqual(proof['service_tier'],'fast');self.assertEqual(proof['provider_service_tier'],tier)
  for expected,actual in (('fast','default'),('default','priority'),('fast','unknown')):
   with self.assertRaises(Fault):confirmed_preferences({'reasoningEffort':'low','serviceTier':actual},'low',expected)
 def test_binary_refresh_requires_official_signature_and_stable_bytes(self):
  executable=Path(self.tmp.name)/'provider';executable.write_bytes(b'old')
  adapter=CodexTextAdapter(executable,enabled=True);old=adapter.pin
  executable.write_bytes(b'updated')
  with patch.object(adapter,'verify_official_binary',side_effect=Fault('provider_update_unverified')):
   with self.assertRaises(Fault):adapter.refresh_official_binary()
  self.assertEqual(adapter.pin,old)
  with patch.object(adapter,'verify_official_binary') as verify:adapter.refresh_official_binary();verify.assert_called_once()
  self.assertNotEqual(adapter.pin,old);adapter.verify()
  executable.write_bytes(b'raced')
  with patch.object(adapter,'verify_official_binary',side_effect=lambda:executable.write_bytes(b'changed-during-check')):
   with self.assertRaises(Fault):adapter.refresh_official_binary()
 def test_service_recovers_after_verified_upgrade_refreshes_catalog_and_keeps_user_packages(self):
  import hashlib
  executable=Path(self.tmp.name)/'provider';executable.write_bytes(b'old-official-build')
  adapter=CodexTextAdapter(executable,enabled=True)
  service=CodexService(adapter,caller='upgrade-fixture',model='offline',reasoning_effort='high',
   authorization_current=lambda:True,peer_current=lambda:True,allow_model_selection=True,package_home=self.registry.home)
  row=self.registry.load();row['packages']['medium']['display_name']='User choice';saved=self.save(row)
  refreshed=[dict(self.catalog[0],efforts=[{'id':'high','description':''},{'id':'new-effort','description':''}]),
   dict(self.catalog[0],model='new-provider-model')]
  executable.write_bytes(b'new-official-build')
  with patch.object(adapter,'verify_official_binary') as verify, \
       patch.object(adapter,'refresh_catalog',return_value=refreshed) as read, \
       patch.object(adapter,'preflight_model',return_value={'catalog':refreshed}), \
       patch('arl.codex_server.subprocess.Popen') as process:
   service.preflight()
  verify.assert_called_once();read.assert_called_once();process.assert_not_called()
  self.assertEqual(adapter.pin,hashlib.sha256(executable.read_bytes()).hexdigest())
  self.assertEqual(service.status()['state'],'ready')
  self.assertEqual(service.status()['execution_catalog']['models'],refreshed)
  self.assertEqual(self.registry.load()['packages'],saved['packages'])
  self.assertEqual(self.registry.load()['revision'],saved['revision'])
  self.assertEqual(__import__('json').loads((self.registry.home/'catalog-v2.json').read_text())['models'],refreshed)
if __name__=='__main__':unittest.main()
