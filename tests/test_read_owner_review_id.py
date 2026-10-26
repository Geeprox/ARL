"""Real source/vendor metadata through the production migration; no live app."""
from pathlib import Path
import copy,json,plistlib,tempfile,unittest
from arl.install_platform import reviewed_read_owner_transition
from arl.install_transaction import InstallFault,sha
ROOT=Path(__file__).resolve().parents[1]
OLD=ROOT/'vendor/release/ARL.resources/Contents/Resources/CredentialReadOwner/authority.json'
NEW=ROOT/'integrations/credential_read_owner/authority-v2.json'

class ReviewIDCompatibilityTests(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory(prefix='review-id-');self.root=Path(self.temp.name)
  self.old=OLD.read_bytes();self.new=NEW.read_bytes()
 def tearDown(self):self.temp.cleanup()
 def bundle(self,name,raw):
  app=self.root/name
  for rel in ['', 'Contents/Library/LoginItems/ARLMioAppleBridge.app']:
   bundle=app/rel;p=bundle/'Contents/Resources/CredentialReadOwner/authority.json';p.parent.mkdir(parents=True);p.write_bytes(raw)
   (bundle/'Contents/Info.plist').write_bytes(plistlib.dumps({'ARLCredentialReadOwnerAuthoritySHA256':sha(raw)}))
  return app
 def transition(self,a,b,label):return reviewed_read_owner_transition(self.bundle(label+'-before.app',a),self.bundle(label+'-after.app',b))
 def altered(self,raw,review_id):
  row=json.loads(raw);row['reviewID']=review_id;return json.dumps(row,sort_keys=True).encode()
 def test_exact_vendor_uppercase_and_new_source_lowercase_both_migrate(self):
  result=self.transition(self.old,self.new,'actual')
  self.assertEqual(result,{'before_sha256':sha(self.old),'after_sha256':sha(self.new)})
  self.assertEqual(OLD.read_bytes(),self.old);self.assertEqual(NEW.read_bytes(),self.new)
 def test_letter_case_is_not_identity_and_new_to_new_is_accepted(self):
  old_id=json.loads(self.old)['reviewID'];new_id=json.loads(self.new)['reviewID']
  for i,(a,b) in enumerate([(old_id.lower(),new_id.upper()),(old_id.swapcase(),new_id.swapcase()),(old_id,new_id)]):
   before=self.altered(self.old,a);after=self.altered(self.new,b)
   self.assertEqual(self.transition(before,after,str(i)),{'before_sha256':sha(before),'after_sha256':sha(after)})
  self.assertEqual(self.transition(self.new,self.new,'new'),{'before_sha256':sha(self.new),'after_sha256':sha(self.new)})
 def test_non_uuid_and_non_string_are_still_rejected(self):
  for i,value in enumerate(['not-a-uuid','',None,True,123]):
   with self.subTest(value=value),self.assertRaisesRegex(InstallFault,'read_owner_transition_invalid'):
    self.transition(self.old,self.altered(self.new,value),'invalid'+str(i))
 def test_case_compatibility_keeps_seal_pins_and_capability_checks(self):
  before=self.bundle('old.app',self.old);after=self.bundle('new.app',self.new)
  info=after/'Contents/Info.plist';row=plistlib.loads(info.read_bytes());row['ARLCredentialReadOwnerAuthoritySHA256']='0'*64;info.write_bytes(plistlib.dumps(row))
  with self.assertRaisesRegex(InstallFault,'read_owner_resource_unbound'):reviewed_read_owner_transition(before,after)
  for i,field in enumerate(['owner','capabilities']):
   value=json.loads(self.new)
   if field=='owner':value['owner']['certificateSHA1']='A'*40
   else:value['capabilities'].append('arbitrary_write')
   with self.assertRaisesRegex(InstallFault,'read_owner_transition_invalid'):
    self.transition(self.old,json.dumps(value).encode(),'identity'+str(i))
 def test_both_recipes_still_pin_exact_unmodified_source_resource(self):
  for recipe in ['script/release_recipe.json','build/local-config/release_recipe.json']:
   row=json.loads((ROOT/recipe).read_text())['read_owner_authority'];self.assertEqual(row,{'path':str(NEW.relative_to(ROOT)),'sha256':sha(self.new)})
if __name__=='__main__':unittest.main()
