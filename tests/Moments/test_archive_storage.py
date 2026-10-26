"""Offline migration playback and loss-preservation boundaries."""
import hashlib,json,sys,tempfile,unittest,io
from email.message import Message
from types import SimpleNamespace
from pathlib import Path
from unittest.mock import patch
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'integrations/moments/worker'))
from archive_storage import media_file,remote_media
import viewer_server
class MemoryHandler(viewer_server.Handler):
 def __init__(self,path,headers=()):
  self.path=path;self.command='GET';self.request_version='HTTP/1.1'
  self.server=SimpleNamespace(server_port=18999)
  self.headers=Message();self.headers['Host']='127.0.0.1:18999'
  for key,value in headers:self.headers[key]=value
  self.wfile=io.BytesIO();self.rfile=io.BytesIO();self.response_headers={};self.status=None
 def send_response(self,status,message=None):self.status=status
 def send_header(self,key,value):self.response_headers[key]=value
 def end_headers(self):pass
 def log_message(self,*args):pass

class NASMedia(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
  root=Path(self.temp.name);self.local=root/'mac/data';self.remote=root/'nas/Friday/apps/moments/data/media'
  (self.local/'private').mkdir(parents=True);(self.local/'media').mkdir();self.remote.mkdir(parents=True)
  self.payload=b'fake-offline-video-content-0123456789'
  self.sha=hashlib.sha256(self.payload).hexdigest();self.ref='media/'+self.sha+'.mp4'
  (self.remote/Path(self.ref).name).write_bytes(self.payload)
  self.binding={'schema':1,'media_root':str(self.remote),'files':{self.ref:{'sha256':self.sha,'bytes':len(self.payload)}}}
  self.save()
 def save(self):
  (self.local/'private/nas-storage.json').write_text(json.dumps(self.binding))
 def test_verified_remote_video_streams_with_range_after_local_removed(self):
  self.assertFalse((self.local/self.ref).exists())
  self.assertEqual(media_file(self.local,self.ref),self.remote/Path(self.ref).name)
  with patch.object(viewer_server,'ROOT',self.local.parent):
   handler=MemoryHandler('/data/'+self.ref,[('Range','bytes=5-10')]);handler.do_GET()
  self.assertEqual(handler.status,206);self.assertEqual(handler.wfile.getvalue(),self.payload[5:11])
 def test_corruption_is_not_served_and_no_download_occurs(self):
  self.assertIsNotNone(remote_media(self.local,self.ref))
  (self.remote/Path(self.ref).name).write_bytes(b'x'*len(self.payload))
  self.assertIsNone(media_file(self.local,self.ref))
  with patch.object(viewer_server,'ROOT',self.local.parent):
   handler=MemoryHandler('/data/'+self.ref);handler.do_GET()
  self.assertEqual(handler.status,404)
 def test_unknown_remote_and_symlink_are_never_served(self):
  self.assertIsNone(media_file(self.local,'../secret'))
  target=self.remote/Path(self.ref).name;target.unlink();target.symlink_to(self.local/'private/nas-storage.json')
  self.assertIsNone(media_file(self.local,self.ref))
 def test_disconnected_nas_does_not_delete_valid_local_copy(self):
  (self.local/self.ref).write_bytes(self.payload)
  (self.remote/Path(self.ref).name).unlink()
  self.assertEqual(media_file(self.local,self.ref),self.local/self.ref)
  self.assertTrue((self.local/self.ref).exists())
 def test_unlisted_blob_and_receipt_symlink_rejected(self):
  self.binding['files']={};self.save();self.assertIsNone(media_file(self.local,self.ref))
  receipt=self.local/'private/nas-storage.json';receipt.unlink();receipt.symlink_to(self.remote/Path(self.ref).name)
  self.assertIsNone(media_file(self.local,self.ref))
if __name__=='__main__':unittest.main()
