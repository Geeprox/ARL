"""Native owner policy compatibility; Security still decides peer signatures."""
from pathlib import Path
import json,subprocess,tempfile,unittest
from unittest.mock import patch
from arl.contracts import Fault
from arl.supervisor import SignedPeerVerifier

class NativeRequirementTests(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory(prefix='signed-policy-');self.helper=Path(self.temp.name)/'helper';self.helper.write_bytes(b'constructor-only fixture')
  self.native='identifier "local.arl.control" and certificate leaf = H"'+('A'*40)+'" and info[ARLCredentialReadOwnerAuthoritySHA256] = "'+('b'*64)+'"'
 def tearDown(self):self.temp.cleanup()
 def test_native_pin_is_accepted_and_forwarded_unchanged(self):
  verifier=SignedPeerVerifier(self.helper,{'arl-control':self.native});self.assertEqual(verifier.requirements,{'arl-control':self.native})
  class Connection:
   def getsockopt(self,*args):return bytes(range(32))
  with patch('arl.supervisor.subprocess.run',return_value=subprocess.CompletedProcess([],0,b'{"valid":true}',b'')) as run:
   self.assertEqual(verifier(Connection(),'arl-control'),'arl-control')
  self.assertEqual(json.loads(run.call_args.kwargs['input'])['requirement'],self.native)
  self.assertEqual(json.loads(run.call_args.kwargs['input'])['audit_token'],bytes(range(32)).hex())
 def test_missing_identity_certificate_seal_or_extra_alternative_are_rejected(self):
  for value in ['identifier "local.arl.control"','anchor apple generic',self.native.split(' and info[')[0],
                'identifier "local.arl.control" and info[ARLCredentialReadOwnerAuthoritySHA256] = "'+('b'*64)+'"',
                self.native.replace('ARLCredentialReadOwnerAuthoritySHA256','untrusted_field'),self.native+' or true',self.native+'\nanything']:
   with self.subTest(value=value),self.assertRaises(Fault) as error:SignedPeerVerifier(self.helper,{'arl-control':value})
   self.assertEqual(error.exception.code,'signature_policy_unpinned')
 def test_original_cdhash_and_team_forms_are_unchanged(self):
  for value in ['cdhash H"'+('a'*40)+'"','identifier "local.arl.control" and anchor apple generic and certificate leaf[subject.OU] = "LGZF25R84Z"']:
   self.assertEqual(SignedPeerVerifier(self.helper,{'original':value}).requirements['original'],value)
 def test_shape_acceptance_does_not_replace_native_signature_result(self):
  verifier=SignedPeerVerifier(self.helper,{'arl-control':self.native})
  class Connection:
   def getsockopt(self,*args):return bytes(range(32))
  for raw in [b'{"valid":false}',b'{}',b'not json']:
   with patch('arl.supervisor.subprocess.run',return_value=subprocess.CompletedProcess([],0,raw,b'')):
    self.assertIsNone(verifier(Connection(),'arl-control'))
  self.assertIsNone(verifier(Connection(),'other-caller'))
if __name__=='__main__':unittest.main()
