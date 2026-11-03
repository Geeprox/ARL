import errno,json,os,socket,stat,sys,tempfile,types,unittest
from pathlib import Path
from unittest.mock import patch
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'integrations/nas/runtime'))
import nas_diagnostic as diag

def synthetic_socket_failure(families, outcomes, *, dns_error=None, secret=None):
 """Run unchanged stdlib code with isolated synthetic globals; no global patch."""
 attempts=[];created=[]
 class SyntheticSocket:
  def __init__(self,family,*args):self.family=family;self.closed=False;created.append(self)
  def settimeout(self,value):pass
  def connect(self,address):
   index=len(attempts);attempts.append(self.family)
   if outcomes[index] is not None:raise outcomes[index]
  def close(self):self.closed=True
 def lookup(*args):
  if dns_error is not None:raise dns_error
  return [(family,socket.SOCK_STREAM,6,'SECRET_CANONNAME',secret) for family in families]
 original=socket.create_connection
 scope=dict(original.__globals__,socket=SyntheticSocket,getaddrinfo=lookup)
 dial=types.FunctionType(original.__code__,scope,original.__name__,original.__defaults__)
 dial.__kwdefaults__=original.__kwdefaults__
 try:
  try:dial((secret,445),timeout=secret)
  except OSError as error:raise ValueError('SECRET_USERNAME_PASSWORD_ENDPOINT') from error
 except ValueError as error:
  if not all(item.closed for item in created):raise AssertionError('synthetic socket leaked')
  return error,attempts
 raise AssertionError('synthetic fixture must fail')


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
  diag.failure_record(ValueError('SECRET'),'file_unknown');self.assertFalse((self.root/'login-diagnostic.json').exists());self.root.rmdir();diag.failure_record(ValueError('SECRET'),'server_login');self.assertFalse(self.root.exists())

 def test_file_failure_has_separate_fixed_record_and_atomic_private_write(self):
  diag.failure_record(OSError(errno.ECONNREFUSED,'SECRET'),'file_connect')
  path=self.root/'file-diagnostic.json';r=json.loads(path.read_bytes())
  self.assertEqual(r['stage'],'file_connect');self.assertEqual(r['exception_chain'][0]['errno'],errno.ECONNREFUSED)
  self.assertEqual(stat.S_IMODE(path.stat().st_mode),0o600)
  self.assertFalse((self.root/'login-diagnostic.json').exists())
  self.assertFalse(list(self.root.glob('.diagnostic-*')))

class SocketFamilyDiagnosticTests(unittest.TestCase):
 # Reuse only the private record setup, not dependency-requiring test methods.
 setUp=NASDiagnosticTests.setUp
 tearDown=NASDiagnosticTests.tearDown
 def record_error(self,error):
  diag.failure_record(error,'file_connect')
  return json.loads((self.root/'file-diagnostic.json').read_bytes())

 def test_terminal_ipv4_and_ipv6_failures_are_observed_without_new_attempts(self):
  for families in ([socket.AF_INET6,socket.AF_INET],[socket.AF_INET,socket.AF_INET6],
                   [int(socket.AF_INET6),int(socket.AF_INET)],[int(socket.AF_INET),int(socket.AF_INET6)]):
   with self.subTest(families=families):
    before=(socket.socket,socket.getaddrinfo,socket.create_connection)
    error,attempts=synthetic_socket_failure(families,[TimeoutError('SECRET_TIMEOUT'),OSError(errno.EHOSTUNREACH,'SECRET_HOST')])
    value=self.record_error(error);row=value['exception_chain'][1]
    self.assertEqual(row['socket_family'],'ipv4' if families[-1] == socket.AF_INET else 'ipv6')
    self.assertEqual(row['errno'],errno.EHOSTUNREACH);self.assertEqual(attempts,families)
    self.assertEqual(before,(socket.socket,socket.getaddrinfo,socket.create_connection))
    self.assertNotIn('SECRET',json.dumps(value));self.assertNotIn('attempt',json.dumps(value))

 def test_repeated_traceback_frame_is_not_a_claim_about_attempt_count(self):
  error,attempts=synthetic_socket_failure([socket.AF_INET6,socket.AF_INET],[OSError(errno.EACCES,'SECRET'),OSError(errno.EHOSTUNREACH,'SECRET')])
  frames=[];tb=error.__cause__.__traceback__
  while tb is not None:
   if tb.tb_frame.f_code is socket.create_connection.__code__:frames.append(tb.tb_frame)
   tb=tb.tb_next
  self.assertGreaterEqual(len(frames),2);self.assertTrue(all(frame is frames[0] for frame in frames))
  row=self.record_error(error)['exception_chain'][1]
  self.assertEqual(row['socket_family'],'ipv4');self.assertEqual(len(attempts),2)
  self.assertEqual(set(row)-{'type','frames','errno','errno_name'}, {'socket_family'})

 def test_same_named_socket_function_cannot_supply_family(self):
  def create_connection():
   af=socket.AF_INET
   raise OSError(errno.EHOSTUNREACH,'SECRET_FORGED_FRAME')
  forged=types.FunctionType(create_connection.__code__,dict(create_connection.__globals__,__name__='socket'))
  try:forged()
  except OSError as error:value=self.record_error(error)
  self.assertTrue(any(frame['module']=='socket' and frame['function']=='create_connection' for frame in value['exception_chain'][0]['frames']))
  self.assertNotIn('socket_family',value['exception_chain'][0]);self.assertNotIn('SECRET',json.dumps(value))

 def test_unknown_family_and_malicious_family_objects_are_never_coerced(self):
  class Malicious:
   def __repr__(self):raise AssertionError('must not render locals')
   __str__=__repr__
   def __eq__(self,other):raise AssertionError('must not compare arbitrary family')
   def __int__(self):raise AssertionError('must not coerce arbitrary family')
  class IntegerSubclass(int):pass
  for family in (socket.AF_UNIX,9999,True,'ipv4',None,Malicious(),IntegerSubclass(int(socket.AF_INET))):
   error,_=synthetic_socket_failure([family],[OSError(errno.EHOSTUNREACH,'SECRET')],secret=Malicious())
   value=self.record_error(error)
   self.assertNotIn('socket_family',value['exception_chain'][1]);self.assertNotIn('SECRET',json.dumps(value))

 def test_address_timeout_and_exception_text_are_never_read_or_serialized(self):
  class Secret:
   def __repr__(self):raise AssertionError('must not render address or timeout')
   __str__=__repr__
  error,_=synthetic_socket_failure([socket.AF_INET],[OSError(errno.EHOSTUNREACH,'SECRET_PASSWORD_ENDPOINT')],secret=Secret())
  value=self.record_error(error);row=value['exception_chain'][1]
  self.assertEqual(row['socket_family'],'ipv4')
  self.assertFalse({'locals','sa','address','timeout','message','attempts','attempt_order'} & set(row))
  self.assertNotIn('SECRET',json.dumps(value))

 def test_no_family_before_resolution_or_without_valid_errno(self):
  error,attempts=synthetic_socket_failure([],[],dns_error=OSError(errno.EHOSTUNREACH,'SECRET_DNS'))
  self.assertEqual(attempts,[]);self.assertNotIn('socket_family',self.record_error(error)['exception_chain'][1])
  invalid=OSError(errno.EHOSTUNREACH,'SECRET_ERRNO');invalid.errno=True
  error,_=synthetic_socket_failure([socket.AF_INET],[invalid])
  row=self.record_error(error)['exception_chain'][1]
  self.assertNotIn('errno',row);self.assertNotIn('socket_family',row)

class SMBDialPolicyTests(unittest.TestCase):
 """The bundled library's actual dialer with only DNS and sockets synthetic."""
 def dial(self,families,outcomes):
  from smbprotocol.transport import Tcp
  attempts=[];created=[];elapsed=[0.0]
  class SyntheticSocket:
   def __init__(self,family,kind,protocol):
    self.family=family;self.timeout=None;self.closed=False;created.append(self)
   def settimeout(self,value):self.timeout=value
   def connect(self,address):
    index=len(attempts);attempts.append((self.family,self.timeout))
    outcome=outcomes[index]
    if isinstance(outcome,TimeoutError):elapsed[0]+=self.timeout
    if outcome is not None:raise outcome
    elapsed[0]+=.006
   def shutdown(self,how):pass
   def close(self):self.closed=True
  rows=[(family,socket.SOCK_STREAM,6,'',('2001:db8::1',445,0,0) if family==socket.AF_INET6 else ('192.0.2.1',445)) for family in families]
  error=None;connected=False
  with patch('socket.getaddrinfo',return_value=rows) as lookup,patch('socket.socket',side_effect=SyntheticSocket):
   tcp=Tcp('synthetic.invalid',445,timeout=8)
   try:tcp.connect();connected=tcp.connected
   except ValueError as failure:error=failure
   finally:tcp.close()
   lookup.assert_called_once_with('synthetic.invalid',445,0,socket.SOCK_STREAM)
  self.assertTrue(all(item.closed for item in created))
  return connected,error,attempts,elapsed[0]

 def test_two_ipv6_timeouts_still_try_ipv4_with_original_timeout(self):
  ok,error,attempts,elapsed=self.dial([socket.AF_INET6,socket.AF_INET6,socket.AF_INET],[TimeoutError(),TimeoutError(),None])
  self.assertTrue(ok);self.assertIsNone(error)
  self.assertEqual(attempts,[(socket.AF_INET6,8),(socket.AF_INET6,8),(socket.AF_INET,8)])
  self.assertAlmostEqual(elapsed,16.006);self.assertLess(elapsed,80)

 def test_ipv6_unreachable_falls_back_to_ipv4(self):
  ok,error,attempts,_=self.dial([socket.AF_INET6,socket.AF_INET],[OSError(errno.EHOSTUNREACH,'synthetic'),None])
  self.assertTrue(ok);self.assertIsNone(error);self.assertEqual(len(attempts),2)

 def test_ipv4_first_success_does_not_force_an_ipv6_attempt(self):
  ok,error,attempts,_=self.dial([socket.AF_INET,socket.AF_INET6],[None,None])
  self.assertTrue(ok);self.assertIsNone(error);self.assertEqual(attempts,[(socket.AF_INET,8)])

 def test_last_errno_does_not_identify_an_ipv6_only_failure(self):
  ok,error,attempts,_=self.dial([socket.AF_INET6,socket.AF_INET],[TimeoutError(),OSError(errno.EHOSTUNREACH,'synthetic')])
  self.assertFalse(ok);self.assertEqual(error.__cause__.errno,errno.EHOSTUNREACH)
  self.assertEqual(attempts,[(socket.AF_INET6,8),(socket.AF_INET,8)])

 def test_both_families_denied_preserve_last_errno_without_retrying(self):
  ok,error,attempts,_=self.dial([socket.AF_INET6,socket.AF_INET],[OSError(errno.EHOSTUNREACH,'synthetic'),OSError(errno.EHOSTUNREACH,'synthetic')])
  self.assertFalse(ok);self.assertEqual(error.__cause__.errno,errno.EHOSTUNREACH);self.assertEqual(len(attempts),2)


if __name__=='__main__':unittest.main()
