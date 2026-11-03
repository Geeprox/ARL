import importlib.util,types,unittest
from pathlib import Path
spec=importlib.util.spec_from_file_location('robin_client',Path(__file__).parents[1]/'nas/robin_client.py');module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
class RobinClientTests(unittest.TestCase):
 def test_only_owned_endpoint_disables_retries_and_extends_wait_without_mutation(self):
  source={'class':object,'constructor_params':{'base_url':module.ENDPOINT,'streaming':False,'model_name':'arl/package/high'}}
  utilities=types.SimpleNamespace(resolve_model_config=lambda *a,**k:source)
  module.configure(utilities);configured=utilities.resolve_model_config('synthetic')
  self.assertEqual(configured['constructor_params']['max_retries'],0);self.assertGreater(configured['constructor_params']['timeout'],725)
  self.assertNotIn('timeout',source['constructor_params']);self.assertFalse(configured['constructor_params']['streaming'])
  first=utilities.resolve_model_config;module.configure(utilities);self.assertIs(first,utilities.resolve_model_config)
 def test_other_providers_and_unresolved_choices_are_unchanged(self):
  for source in (None,{'class':object,'constructor_params':{'base_url':'https://provider.example/v1','max_retries':2}}):
   utilities=types.SimpleNamespace(resolve_model_config=lambda *a,**k:source);module.configure(utilities);self.assertIs(utilities.resolve_model_config('synthetic'),source)
