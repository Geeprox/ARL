"""Ephemeral parent-bound entry; injected bytes only, no network or scope."""
import io,json,os,unittest
from unittest.mock import patch
from arl.attachment_inspection import run
from integrations.nas.attachment_bridge import BridgeFault
class AttachmentWorkerTests(unittest.TestCase):
 def execute(self,raw,inspector=None,parent=None):
  output=io.BytesIO();calls=[]
  def inspect(value,verify):verify();calls.append(value);return {'safe':'metadata'}
  code=run(io.BytesIO(raw),output,os.getppid() if parent is None else parent,inspector=inspector or inspect)
  self.assertEqual(code,0);return json.loads(output.getvalue()),calls
 def test_parent_bound_success_and_one_input(self):
  result,calls=self.execute(b'{"operation_id":"synthetic"}\n')
  self.assertTrue(result['ok']);self.assertEqual(len(calls),1)
 def test_missing_wrong_parent_and_invalid_frame_never_inspect(self):
  for raw,parent in [(b'{}\n',0),(b'{}\n',os.getppid()+100000),(b'{}',None),(b'{}\n{}\n',None),(b'x'*65537,None),(b'{"a":1,"a":2}\n',None)]:
   with self.subTest(raw_size=len(raw),parent=parent):
    result,calls=self.execute(raw,parent=parent);self.assertFalse(result['ok']);self.assertEqual(calls,[])
 def test_finite_fault_only_never_exception_or_signed_url(self):
  def failure(value,verify):raise ValueError('https://files.oaiusercontent.com/?sig=SECRET')
  result,_=self.execute(b'{}\n',failure)
  self.assertNotIn('SECRET',json.dumps(result));self.assertEqual(result['error']['code'],'attachment_inspection_unavailable')
  def unavailable(value,verify):raise BridgeFault('attachment_unavailable')
  result,_=self.execute(b'{}\n',unavailable);self.assertEqual(result['error']['code'],'attachment_unavailable')
if __name__=='__main__':unittest.main()
