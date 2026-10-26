"""Offline binary-pin admission regression; never starts a provider."""
import tempfile,time,unittest
from pathlib import Path
from unittest.mock import patch
from arl.codex_server import CodexService,CodexTextAdapter,NAME
from arl.compat_host import compose_codex_service
from arl.contracts import Fault
from arl.identity import RegisteredPeerVerifier
from arl.storage import Store
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/tc23-admission'

class BinaryAdmissionTests(unittest.TestCase):
 def setUp(self):
  OUT.mkdir(parents=True,exist_ok=True)
  self.temp=tempfile.TemporaryDirectory(prefix='binary-admission-',dir=OUT)
  self.binary=ROOT/'integrations/codex/fake_server.py'
  self.adapter=CodexTextAdapter(self.binary,enabled=True);self.pin=self.adapter.pin
  self.service=CodexService(self.adapter,caller='offline-pin-review',model='offline-model',
   authorization_current=lambda:True,peer_current=lambda:True,allow_model_selection=True)
  self.service.checked_mono=time.monotonic()
  self.service.catalog=[{'model':'offline-model','default_effort':'high',
   'efforts':[{'id':'high','description':''}],'fast_available':False}]
  self.runtime=compose_codex_service(Path(self.temp.name)/'host',service=self.service,
   peer_verifier=RegisteredPeerVerifier({self.service.caller}),isolated=True)
  self.runtime.store=Store(Path(self.temp.name)/'jobs.sqlite');self.runtime.ready.set()
  self.no_process=patch('arl.codex_server.subprocess.Popen',side_effect=AssertionError('provider forbidden'))
  self.launch=self.no_process.start()
 def tearDown(self):
  try:self.launch.assert_not_called()
  finally:
   self.no_process.stop();self.service.close();self.runtime.store.close()
   self.runtime.control.close();self.runtime.service_portal.close();self.temp.cleanup()
 def submit(self):
  return self.runtime.dispatch({'protocol':'arl/1','app':self.service.caller,'method':'submit',
   'params':{'tool':NAME,'key':'same-original-request','args':{'model':'offline-model',
    'input':'offline synthetic input','max_output_bytes':128,'reasoning_effort':'high',
    'service_tier':'default'}}},verified_app=self.service.caller)
 def assert_no_admission(self):
  self.assertIsNone(self.runtime.store.db.execute('SELECT calls FROM budget WHERE owner=?',(self.service.caller,)).fetchone())
  self.assertEqual(self.runtime.store.db.execute('SELECT COUNT(*) FROM jobs').fetchone()[0],0)
  self.assertEqual(self.adapter.pin,self.pin)
 def changed_bytes(self):
  read_bytes,binary=Path.read_bytes,self.binary
  return patch.object(Path,'read_bytes',lambda path:b'changed-synthetic-provider-file' if path==binary else read_bytes(path))
 def test_unchanged_binary_preserves_duplicate_and_single_budget_charge(self):
  first=self.submit();self.assertEqual(first['state'],'queued')
  self.assertEqual(self.submit()['id'],first['id'])
  self.assertEqual(self.runtime.store.db.execute('SELECT calls FROM budget WHERE owner=?',(self.service.caller,)).fetchone()[0],1)
 def test_changed_binary_rejects_before_job_budget_and_hides_catalog(self):
  with self.changed_bytes(),self.assertRaises(Fault) as error:self.submit()
  self.assertEqual(error.exception.code,'provider_binary_changed');self.assert_no_admission()
  status=self.service.status();self.assertFalse(status['route_enabled'])
  self.assertEqual(status['last_error_code'],'provider_binary_changed')
  self.assertFalse(status['execution_catalog']['selection_enabled'])
  self.assertEqual(status['execution_catalog']['models'],[])
 def test_restored_bytes_do_not_automatically_refresh_or_rebind(self):
  with self.changed_bytes(),self.assertRaises(Fault):self.submit()
  with self.assertRaises(Fault) as error:self.submit()
  self.assertEqual(error.exception.code,'codex_preflight_required');self.assert_no_admission()
  self.assertIsNone(self.service.checked_mono)

if __name__=='__main__':unittest.main()
