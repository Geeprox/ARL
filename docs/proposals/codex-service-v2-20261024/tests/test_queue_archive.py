import json,os,tempfile,time,unittest,uuid
from pathlib import Path
from worker import archive_terminal
class QueueArchiveTests(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name)
  for app in ['pdf2zh','bilinote']:
   for part in ['requests','responses']:(self.root/app/part).mkdir(parents=True,exist_ok=True)
 def tearDown(self):self.temp.cleanup()
 def pair(self,state='succeeded',age=1800):
  name=str(uuid.uuid4())+'.json';d=self.root/'pdf2zh';request=d/'requests'/name;response=d/'responses'/name;request.write_text(json.dumps({'expires_at':time.time()-1200}));answer={'app':'pdf2zh','id':name[:-5],'state':state,'at':time.time()-1800,'text':'synthetic result'};response.write_text(json.dumps(answer));os.utime(response,(time.time()-age,time.time()-age));return request,response,answer
 def test_completed_receipt_is_preserved_outside_active_queue(self):
  request,response,answer=self.pair();archive_terminal(self.root);self.assertFalse(request.exists());self.assertFalse(response.exists());self.assertEqual(json.loads((self.root/'pdf2zh/archive'/response.name).read_text()),answer)
 def test_uncertain_work_stays_visible(self):
  request,response,_=self.pair('needs_review');archive_terminal(self.root);self.assertTrue(request.exists());self.assertTrue(response.exists())
 def test_recently_restored_result_is_not_removed_while_client_reads(self):
  request,response,_=self.pair(age=1);archive_terminal(self.root);self.assertTrue(response.exists())
 def test_conflicting_archive_does_not_discard_original(self):
  request,response,_=self.pair();d=self.root/'pdf2zh/archive';d.mkdir();(d/response.name).write_text('{}');archive_terminal(self.root);self.assertTrue(response.exists());self.assertTrue(request.exists())

 def test_old_archived_success_is_restored_without_a_provider_submission(self):
  from unittest.mock import patch
  import worker
  from contract import normalize,MODEL
  home=self.root/'state';home.mkdir();request=normalize('pdf2zh',{'model':MODEL,'messages':[{'role':'user','content':'synthetic archived intent'}]});request.update(created_at=time.time()-400,expires_at=time.time()-100);name=request['id']+'.json';(self.root/'pdf2zh/requests'/name).write_text(json.dumps(request));archive=self.root/'pdf2zh/archive';archive.mkdir();answer={'app':'pdf2zh','id':request['id'],'state':'succeeded','text':'synthetic archived answer','at':time.time()-1800};(archive/name).write_text(json.dumps(answer))
  class MetadataOnlyClient:
   def __init__(self,*a):pass
   def connect(self,**a):pass
   def open_app_session(self,*a,**kw):return ['codex.text.plan.v1']
   def submit(self,*a):raise AssertionError('must not repeat inference')
  with patch.object(worker,'Client',MetadataOnlyClient),patch.object(worker.time,'sleep',side_effect=StopIteration):
   with self.assertRaises(StopIteration):worker.run({'state_home':str(home),'queue_root':str(self.root),'caller':'synthetic-app'})
  self.assertEqual(json.loads((self.root/'pdf2zh/responses'/name).read_text()),answer)
