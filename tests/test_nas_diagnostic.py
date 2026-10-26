import errno,json,os,stat,sys,tempfile,types,unittest
from pathlib import Path
from unittest.mock import patch
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'integrations/nas/runtime'))
import nas_diagnostic as diag

class NASDiagnosticTests(unittest.TestCase):
 def setUp(self):
  base=ROOT/'build/audit/nas-login-diagnosis-20261022.noindex';base.mkdir(parents=True,exist_ok=True)
  self.temp=tempfile.TemporaryDirectory(dir=base);self.home=Path(self.temp.name);self.root=self.home/'Library/Application Support/ARL/nas';self.root.mkdir(parents=True)
  self.patch=patch.object(diag.pwd,'getpwuid',return_value=types.SimpleNamespace(pw_dir=str(self.home)));self.patch.start()
 def tearDown(self):self.patch.stop();self.temp.cleanup()
 def result(self):return json.loads((self.root/'login-diagnostic.json').read_bytes())
 def wrapped(self,number):
  def fail(*args,**kwargs):raise OSError(number,'SECRET_USERNAME_PASSWORD_SIGNED_URL')
  from smbprotocol.transport import Tcp
  with patch('smbprotocol.transport.socket.create_connection',side_effect=fail):
   try:Tcp('private-endpoint.invalid',445,timeout=1).connect()
   except ValueError as e:return e
  self.fail('library must fail before network')
 def test_real_library_preserves_errno_and_exact_callsite_without_secret_text(self):
  e=self.wrapped(errno.EHOSTUNREACH);diag.failure_record(e,'server_login');r=self.result();c=r['exception_chain']
  self.assertEqual([x['type'] for x in c],['ValueError','OSError']);self.assertEqual(c[1]['errno'],errno.EHOSTUNREACH);self.assertEqual(c[1]['errno_name'],'EHOSTUNREACH')
  self.assertTrue(any(f['module']=='smbprotocol.transport' and f['function']=='connect' for f in c[0]['frames']))
  raw=json.dumps(r);self.assertNotIn('SECRET_',raw);self.assertNotIn('private-endpoint',raw);self.assertNotIn(str(self.home),raw)
  self.assertNotIn('locals',raw);self.assertNotIn('source',raw)
 def test_real_library_concrete_subclasses_are_not_misreported(self):
  for number,expected in [(errno.ECONNREFUSED,'ConnectionRefusedError'),(errno.EACCES,'PermissionError'),(errno.ETIMEDOUT,'TimeoutError')]:
   diag.failure_record(self.wrapped(number),'server_login');c=self.result()['exception_chain'];self.assertEqual(c[1]['type'],expected);self.assertEqual(c[1]['errno'],number)
 def test_implicit_exception_context_and_cycle_are_bounded(self):
  try:raise OSError(errno.ENETUNREACH,'SECRET_CONTEXT')
  except OSError:
   try:raise ValueError('SECRET_WRAPPER')
   except ValueError as e:diag.failure_record(e,'server_login')
  self.assertEqual(self.result()['exception_chain'][1]['errno'],errno.ENETUNREACH)
  a=ValueError('a');b=OSError(errno.EHOSTUNREACH,'b');a.__cause__=b;b.__cause__=a;diag.failure_record(a,'server_login');self.assertEqual(len(self.result()['exception_chain']),2)
 def test_noninteger_error_codes_are_omitted_and_ntstatus_kept(self):
  e=OSError('SECRET');e.errno=True;e.status=0xc000006d;diag.failure_record(e,'server_login');r=self.result()['exception_chain'][0];self.assertNotIn('errno',r);self.assertEqual(r['smb_status'],0xc000006d)
 def test_private_record_replacement_has_no_trailing_bytes(self):
  diag.failure_record(self.wrapped(errno.EHOSTUNREACH),'server_login');diag.failure_record(ValueError('SECRET_SHORT'),'server_login');self.assertEqual(len(self.result()['exception_chain']),1)
  self.assertEqual(stat.S_IMODE((self.root/'login-diagnostic.json').stat().st_mode),0o600)
 def test_symlink_file_is_not_followed(self):
  target=self.home/'unrelated';target.write_text('KEEP');(self.root/'login-diagnostic.json').symlink_to(target);diag.failure_record(ValueError('SECRET'),'server_login');self.assertEqual(target.read_text(),'KEEP')
 def test_unknown_stage_and_missing_directory_do_not_write(self):
  diag.failure_record(ValueError('SECRET'),'file_read');self.assertFalse((self.root/'login-diagnostic.json').exists());self.root.rmdir();diag.failure_record(ValueError('SECRET'),'server_login');self.assertFalse(self.root.exists())

if __name__=='__main__':unittest.main()
