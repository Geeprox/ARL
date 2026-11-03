import tempfile,json,unittest,uuid
from pathlib import Path
from unittest.mock import patch
from moments_backup import atomic_json,now
from local_service import Service
class RefreshTests(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.root=Path(self.tmp.name);self.data=self.root/'data';self.data.mkdir();self.home=self.root/'owner';self.home.mkdir()
  source=self.root/'sns.db';source.write_bytes(b'fixture');atomic_json(self.data/'moments.json',{'posts':[]})
  atomic_json(self.data/'image-queue.json',{'schema_version':1,'assets':{},'halted':True,'error_code':'repeated_resource_http_errors'})
  self.calls=0
  def refresh(_):self.calls+=1;return {'at':now(),'latest_post_at':now(),'posts_after':2,'new_posts':1}
  self.s=Service({'output':str(self.data),'sns_db':str(source),'bridge_home':str(self.home),'images_enabled':True},refresh_runner=refresh)
 def tearDown(self):self.s.close();self.tmp.cleanup()
 def test_download_halt_preserved_but_local_export_runs(self):
  with patch.object(self.s,'viewer'),patch.object(self.s.queue,'start') as start:
   self.s.tick();self.assertEqual(self.calls,1);start.assert_not_called()
  self.assertTrue(self.s.queue._edit()['halted']);self.assertEqual(self.s.status['phase'],'watching_downloads_paused')
 def test_explicit_local_stop_blocks_export(self):
  (self.data/'.local-service.stop').touch()
  with patch.object(self.s,'viewer'):self.s.tick()
  self.assertEqual(self.calls,0)
 def test_refresh_inbox_and_safe_public_receipt(self):
  identity=str(uuid.uuid4());atomic_json(self.home/'requests'/(identity+'.json'),{'id':identity,'created_at':now(),'kind':'refresh'})
  with patch.object(self.s,'viewer'):self.s.tick()
  reply=json.loads((self.home/'responses'/(identity+'.json')).read_text());self.assertEqual(reply['status'],'refreshed');self.assertEqual(reply['new_posts'],1)
  public=(self.home/'bridge-status.json').read_text();self.assertNotIn(str(self.root),public);self.assertTrue(json.loads(public)['halted'])
 def test_images_inbox_does_not_resume_or_retry(self):
  identity=str(uuid.uuid4());atomic_json(self.home/'requests'/(identity+'.json'),{'id':identity,'created_at':now(),'kind':'images','asset_ids':['a:b']})
  with patch.object(self.s,'viewer'),patch.object(self.s.queue,'start') as start:self.s.tick();start.assert_not_called()
  self.assertTrue(self.s.queue._edit()['halted'])
if __name__=='__main__':unittest.main()

class ResumeTests(unittest.TestCase):
 def test_repeated_400_requires_exact_review_and_explicit_authorization(self):
  from async_media import Queue
  with tempfile.TemporaryDirectory() as directory:
   output=Path(directory)/'data';output.mkdir();(output/'.video-batch.stop').touch()
   atomic_json(output/'moments.json',{'posts':[]})
   q=Queue(output);q._edit(lambda x:x.update(halted=True,error_code='repeated_resource_http_errors',risk_control_suspected=False,assets={str(i):{'status':'failed','error_code':'http_400'} for i in range(3)}))
   inode=(output/'.video-batch.stop').stat().st_ino
   with self.assertRaises(ValueError):q.authorize_image_resume(reviewed_asset_failures=['0','1','2'],skip_resource_errors=True)
   with self.assertRaises(ValueError):q.authorize_image_resume(user_authorized=True,reviewed_asset_failures=['0','1'],skip_resource_errors=True)
   q._edit(lambda x:x.update(risk_control_suspected=True))
   with self.assertRaises(ValueError):q.authorize_image_resume(user_authorized=True,reviewed_asset_failures=['0','1','2'],skip_resource_errors=True)
   q._edit(lambda x:x.update(risk_control_suspected=False))
   grant=q.authorize_image_resume(user_authorized=True,reviewed_asset_failures=['0','1','2'],skip_resource_errors=True)
   self.assertEqual(inode,(output/'.video-batch.stop').stat().st_ino);self.assertEqual(grant['min_interval_seconds'],30)
   self.assertTrue(all(x['status']=='failed' for x in q._edit()['assets'].values()));self.assertFalse(grant['failed_asset_retries_permitted'])

class SafeRecoveryTests(unittest.TestCase):
 def setUp(self):
  from async_media import Queue
  self.tmp=tempfile.TemporaryDirectory();self.output=Path(self.tmp.name)/'data';self.output.mkdir()
  self.q=Queue(self.output);(self.output/'.video-batch.stop').touch()
  atomic_json(self.output.parent/'risk-stop.json',{'image_downloads_permitted':True})
  atomic_json(self.output/'private/image-resume.json',{'scope':['ordinary_images'],'stop_fingerprint':self.q._stop_fingerprint(),'account_operations_permitted':False,'failed_asset_retries_permitted':False})
  self.locator={'kind':'2','url':'https://fixture.qpic.cn/synthetic-old'}
  atomic_json(self.output/'private/locators.json',{'assets':{'fixture':self.locator}})
  atomic_json(self.output/'moments.json',{'posts':[{'media':[{'asset_id':'fixture','type':'2'}]}]})
  atomic_json(self.output/'media-state.json',{'assets':{'fixture':{'status':'failed','error_code':'http_400'}}})
  self.q._edit(lambda value:value['assets'].update(fixture={'status':'failed','error_code':'http_400'}))
 def tearDown(self):self.q.close();self.tmp.cleanup()
 def test_old_400_baseline_is_offline_and_only_changed_locator_qualifies(self):
  with patch('async_media.fetch_once',side_effect=AssertionError('unexpected network')):
   self.assertTrue(self.q.recover_failed()['blocked'])
   self.assertEqual(self.q.recover_failed(user_authorized=True)['requeued'],0)
   self.assertEqual(self.q.recover_failed(user_authorized=True)['requeued'],0)
   self.locator['url']='https://fixture.qpic.cn/synthetic-new'
   atomic_json(self.output/'private/locators.json',{'assets':{'fixture':self.locator}})
   self.assertEqual(self.q.recover_failed(user_authorized=True)['requeued'],1)
  import base64
  png=base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jYt0AAAAASUVORK5CYII=')
  with patch('async_media.fetch_once',return_value=(png,'png')) as fetch:self.q._process_locked();self.assertEqual(fetch.call_count,1)
  self.assertEqual(self.q._edit()['assets']['fixture']['status'],'downloaded')
  self.assertTrue((self.output/'.video-batch.stop').exists())
  self.assertFalse(self.q._image_resume_grant()['account_operations_permitted'])
 def test_backoff_budget_and_risk_stop_are_preserved(self):
  import time
  self.q._edit(lambda value:value['assets']['fixture'].update(error_code='network_error_TimeoutError',recovery_not_before=time.time()+3600))
  self.assertEqual(self.q.recover_failed(user_authorized=True)['requeued'],0)
  self.q._edit(lambda value:value['assets']['fixture'].update(recovery_not_before=0,recovery_attempts=3))
  self.assertEqual(self.q.recover_failed(user_authorized=True)['requeued'],0)
  self.q._edit(lambda value:value.update(halted=True,risk_control_suspected=True,error_code='http_429'))
  before=self.q.path.read_bytes();grant=(self.output/'private/image-resume.json').read_bytes()
  self.assertTrue(self.q.recover_failed(user_authorized=True)['blocked'])
  self.assertEqual(self.q.path.read_bytes(),before);self.assertEqual((self.output/'private/image-resume.json').read_bytes(),grant)
 def test_new_transient_failure_waits_and_does_not_clear_image_grant(self):
  import urllib.error
  self.q._edit(lambda value:value['assets']['fixture'].update(error_code='network_error_TimeoutError'))
  self.assertEqual(self.q.recover_failed(user_authorized=True)['requeued'],1)
  with patch('async_media.fetch_once',side_effect=urllib.error.URLError(TimeoutError())):self.q._process_locked()
  row=self.q._edit();self.assertFalse(row['halted']);self.assertIsNotNone(self.q._image_resume_grant())
  self.assertEqual(row['assets']['fixture']['status'],'failed')
  self.assertEqual(self.q.recover_failed(user_authorized=True)['requeued'],0)

class ProjectionTests(unittest.TestCase):
 def test_offloaded_metadata_refresh_does_not_read_nas_payloads(self):
  from moments_backup import merge_media_state
  with tempfile.TemporaryDirectory() as directory:
   output=Path(directory);sha='a'*64;relative='media/'+sha+'.jpg'
   atomic_json(output/'private/nas-storage.json',{'schema':1,'snapshot':'b'*64,'media_root':'/nonexistent/nas/media','files':{relative:{'sha256':sha,'bytes':12}}})
   atomic_json(output/'media-state.json',{'schema_version':1,'assets':{'asset':{'status':'downloaded','local_path':relative,'sha256':sha,'bytes':12}}})
   post={'id':'1','media':[{'asset_id':'asset'}]}
   with patch('archive_storage.media_file',side_effect=AssertionError('NAS payload read')):
    merge_media_state({'1':post},output)
   self.assertEqual(post['media'][0]['local_path'],relative)
 def test_unbound_or_mismatched_receipt_never_skips_file_check(self):
  from archive_storage import retained_reference
  with tempfile.TemporaryDirectory() as directory:
   output=Path(directory);sha='a'*64;relative='media/'+sha+'.jpg'
   binding={'schema':1,'snapshot':'b'*64,'media_root':'/nonexistent/nas/media','files':{relative:{'sha256':sha,'bytes':12}}}
   self.assertFalse(retained_reference(output,relative,'c'*64,12,binding=binding))
   self.assertFalse(retained_reference(output,relative,sha,13,binding=binding))
   self.assertFalse(retained_reference(output,'../escape',sha,12,binding=binding))
   self.assertFalse(retained_reference(output,relative,None,12,binding=binding))
