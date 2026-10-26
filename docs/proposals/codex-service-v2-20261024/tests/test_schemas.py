import copy,hashlib,json,unittest
from pathlib import Path
from jsonschema import Draft202012Validator,FormatChecker,ValidationError
ROOT=Path(__file__).resolve().parents[1]
class ProtocolSchemaTests(unittest.TestCase):
 def validator(self,name):
  schema=json.loads((ROOT/(name+'.schema.json')).read_text());Draft202012Validator.check_schema(schema);return Draft202012Validator(schema,format_checker=FormatChecker())
 def example(self,name):return json.loads((ROOT/'examples'/(name+'.json')).read_text())
 def test_examples_match_all_three_schemas(self):
  for schema,name in [('selection-request','package-request'),('selection-request','explicit-request'),('package-config','package-config'),('submit','submit')]:self.validator(schema).validate(self.example(name))
 def test_selector_cannot_mix_package_with_explicit_model_or_effort(self):
  for key,value in [('model','demo-model-a'),('reasoning_effort','high')]:
   r=self.example('package-request');r['selector'][key]=value
   with self.assertRaises(ValidationError):self.validator('selection-request').validate(r)
 def test_direct_mode_may_resolve_catalog_default_effort(self):
  r=self.example('explicit-request');r['selector'].pop('reasoning_effort');self.validator('selection-request').validate(r)
 def test_five_package_slots_are_stable_but_combinations_are_editable(self):
  r=self.example('package-config');r['packages']['low']['model']='demo-model-b';r['packages']['low']['reasoning_effort']='max';self.validator('package-config').validate(r)
  for change in ['missing','extra']:
   v=copy.deepcopy(r)
   if change=='missing':v['packages'].pop('highest')
   else:v['packages']['sixth']=copy.deepcopy(v['packages']['low'])
   with self.assertRaises(ValidationError):self.validator('package-config').validate(v)
 def test_endpoints_tools_and_claimed_quota_cannot_be_smuggled_into_selection(self):
  for key,value in [('base_url','https://other.invalid'),('tools',[{}]),('quota_policy','unlimited')]:
   r=self.example('explicit-request');r[key]=value
   with self.assertRaises(ValidationError):self.validator('selection-request').validate(r)
 def test_role_and_text_only_payload_are_explicit(self):
  for bad in [{'role':'tool','content':'data'},{'role':'user','content':[{'type':'image_url','image_url':'x'}]}]:
   r=self.example('submit');r['params']['args']['messages']=[bad]
   with self.assertRaises(ValidationError):self.validator('submit').validate(r)
 def test_submit_uses_unchanged_arl_transport_and_new_versioned_tool(self):
  r=self.example('submit');r['params']['tool']='codex.text.plan.v1'
  with self.assertRaises(ValidationError):self.validator('submit').validate(r)
 def test_content_digest_matches_both_selectors(self):
  content={'messages':self.example('submit')['params']['args']['messages']};digest=hashlib.sha256(json.dumps(content,sort_keys=True,separators=(',',':'),ensure_ascii=False,allow_nan=False).encode()).hexdigest()
  for name in ['package-request','explicit-request']:self.assertEqual(self.example(name)['content_sha256'],digest)
 def test_malformed_ids_negative_deadlines_and_unknown_fields_rejected(self):
  for change in ['uuid','digest','deadline','unknown']:
   r=self.example('package-request')
   if change=='uuid':r['request_id']='not-a-uuid'
   elif change=='digest':r['content_sha256']='x'*64
   elif change=='deadline':r['schedule']['execution_timeout_ms']=-1
   else:r['selector']['extra']=True
   with self.assertRaises(ValidationError):self.validator('selection-request').validate(r)
if __name__=='__main__':unittest.main()
