"""Real UploadNewStorage + journal/source + SMB medium; only SMB server I/O is synthetic."""
import hashlib, os, sys, tempfile, time, unittest, uuid
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
ROOT=Path(__file__).resolve().parents[1]
sys.path[:0]=[str(ROOT/"integrations/nas/runtime"),str(ROOT)]
import smb_upload_new as medium
from arl_nas_upload_new.contracts import UploadPlan,OwnerBinding,OwnerBoundary,UploadFault
from arl_nas_upload_new.journal import UploadJournal
from arl_nas_upload_new.source import SealedSource
from arl_nas_upload_new.storage import UploadNewStorage
class Value:
    def __init__(self,value): self.value=value
    def get_value(self): return self.value
class Server:
    def __init__(self):
        self.files={"approved":{"directory":True,"data":bytearray(),"index":1,"change":1}}
        self.opens=[];self.writes=[];self.flushes=[];self.renames=[]
        self.fail_directory_flush=False;self.race=False;self.fail_postrename=False
        self.revoked=False
        self.swap_on_child_open=False;self.swaps=[];self.outside=False
        self.deny_traverse=False;self.requests=[]
        self.tree=SimpleNamespace(is_dfs_share=False,tree_connect_id=1,server=self)
        self.session=SimpleNamespace(encrypt_data=True,session_id=1)
        self.connection=self;self.dialect=medium.Dialects.SMB_3_1_1;self.server_guid=uuid.UUID(int=3)
        self.root="approved"
    def swap_ancestor(self):
        # Competing DELETE open shares all three rights, so the symmetric
        # sharing checks cannot conflict. Attribute-only handles are excluded.
        access=medium.Access
        participating=(access.FILE_READ_DATA|access.FILE_EXECUTE|access.FILE_WRITE_DATA|access.FILE_APPEND_DATA|access.DELETE)
        blocked=any(h.connected and h.path=="approved" and h.access & participating
                    and not h.share & medium.ShareAccess.FILE_SHARE_DELETE for h in self.opens)
        self.swaps.append(not blocked)
        if not blocked:self.outside=True
        return not blocked
    def _query(self,handle,kind):
        row=handle.row
        if kind==medium.FileInternalInformation:return {"index_number":Value(row["index"])}
        if kind==medium.FileStandardInformation:
            return {k:Value(v) for k,v in {"end_of_file":len(row["data"]),"number_of_links":1,"delete_pending":False,"directory":row["directory"]}.items()}
        return {k:Value(v) for k,v in {"file_attributes":0,"creation_time":row["index"],"last_write_time":row["change"],"change_time":row["change"]}.items()}
    def send(self,request,**kwargs):
        if self.swap_on_child_open:self.swap_ancestor()
        value=medium.FileRenameInformation();value.unpack(request["buffer"].get_value())
        assert value["replace_if_exists"].get_value() is False
        assert value["root_directory"].get_value()==0
        target=value["file_name"].get_value().replace("\\","/")
        source=next(x for x in self.opens if x.file_id==request["file_id"].get_value())
        self.renames.append((source.path,target))
        if self.race or target in self.files:raise FileExistsError()
        self.files[target]=self.files.pop(source.path);source.path=target
        return "setinfo"
    def receive(self,token):
        return {"data":Value(medium.SMB2SetInfoResponse().pack())}
class Open:
    def __init__(self,tree,path):
        self.server=tree.server;self.path=path.replace("\\","/");self.connected=False;self.file_attributes=0
        self.file_id=uuid.uuid4().bytes
    def create(self,impersonation,access,attrs,share,disposition,options):
        s=self.server
        self.access,self.share=access,share
        s.requests.append((self.path,access))
        if s.deny_traverse and access & medium.Directory.FILE_TRAVERSE:
            raise PermissionError("synthetic traverse denied")
        if s.swap_on_child_open and self.path=="approved/sub":s.swap_ancestor()
        assert options & medium.CreateOptions.FILE_OPEN_REPARSE_POINT
        if disposition==medium.CreateDisposition.FILE_CREATE:
            assert share==0 and options & medium.CreateOptions.FILE_WRITE_THROUGH
            if self.path in s.files:raise FileExistsError()
            s.files[self.path]={"directory":False,"data":bytearray(),"index":len(s.files)+1,"change":1}
        elif self.path not in s.files:raise FileNotFoundError()
        self.row=s.files[self.path];self.connected=True;s.opens.append(self)
        if self.row["directory"]:
            assert not share & (medium.ShareAccess.FILE_SHARE_DELETE|medium.ShareAccess.FILE_SHARE_WRITE)
    def flush(self):
        s=self.server;s.flushes.append(self.path)
        if self.row["directory"] and (s.fail_directory_flush or s.fail_postrename and s.renames):raise OSError("synthetic_flush_failure")
    def write(self,data,*,offset,write_through):
        assert write_through;s=self.server;s.writes.append((offset,len(data)))
        self.row["data"][offset:offset+len(data)]=data;self.row["change"]+=1;return len(data)
    def read(self,offset,count):return bytes(self.row["data"][offset:offset+count])
    def close(self):self.connected=False
class Tests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(dir="/private/tmp",prefix="arl-smb-medium-")
        home=Path(self.tmp.name);os.chmod(home,0o700)
        journal=home/"journal";journal.mkdir(mode=0o700)
        self.fd=os.open(journal,os.O_RDONLY|os.O_DIRECTORY)
        self.journal=UploadJournal(self.fd,verify_seal=lambda:None)
        self.data=b"ARL synthetic NAS upload fixture\n"
        source=home/"source";source.write_bytes(self.data);source.chmod(0o600)
        fd=os.open(source,os.O_RDONLY);self.source=SealedSource(fd,verify_pin=lambda:None);os.close(fd)
        self.plan=UploadPlan(str(uuid.uuid4()),str(uuid.uuid4()),"a"*64,"b"*64,"c"*32,1,"fixture.txt",len(self.data),hashlib.sha256(self.data).hexdigest())
        self.server=Server();self.patch=patch.object(medium,"Open",Open);self.patch.start()
        self.checked=0;self.consumed=0
        def verify(stage):
            self.checked+=1
            if self.server.revoked:raise UploadFault("revoked")
        self.medium=medium.SMBUploadNewMedium(reader=self.server,plan=self.plan,verify=verify,deadline=time.monotonic()+25)
        self.owner=OwnerBoundary(plan=self.plan,admitted=True,verify=verify,current_binding=lambda:OwnerBinding.for_plan(self.plan),
            consume_existing=self.consume,lifetime=25)
        self.storage=UploadNewStorage(journal=self.journal,medium=self.medium)
    def consume(self,plan):self.assertIs(plan,self.plan);self.consumed+=1
    def tearDown(self):
        self.medium.close();self.source.close();self.journal.close();os.close(self.fd);self.patch.stop();self.tmp.cleanup()
    def test_real_algorithm_no_replace_flush_readback(self):
        result=self.storage.upload(self.plan,self.source,self.owner)
        self.assertEqual(result.status,"committed");self.assertEqual(result.content_sha256,self.plan.sha256)
        self.assertEqual(bytes(self.server.files["approved/fixture.txt"]["data"]),self.data)
        self.assertEqual(len(self.server.renames),1);self.assertEqual(self.consumed,1)
        self.assertGreaterEqual(self.server.flushes.count("approved"),2)
        self.assertTrue(self.checked>20)
    def test_ancestor_swap_blocked_through_upload(self):
        self.server.root="approved/sub"
        self.server.files["approved/sub"]={"directory":True,"data":bytearray(),"index":2,"change":1}
        self.server.swap_on_child_open=True
        result=self.storage.upload(self.plan,self.source,self.owner)
        self.assertEqual(self.server.swaps,[False,False])
        self.assertFalse(self.server.outside)
        self.assertEqual(result.status,"committed")
        ancestor,parent=self.server.opens[:2]
        self.assertEqual(ancestor.access,medium.Access.FILE_READ_ATTRIBUTES|medium.Directory.FILE_TRAVERSE)
        self.assertEqual(parent.access,ancestor.access|medium.Directory.FILE_ADD_FILE)
        self.assertEqual(bytes(self.server.files["approved/sub/fixture.txt"]["data"]),self.data)
        self.medium.close()
        self.assertTrue(self.server.swap_ancestor())
    def test_traverse_denied_before_any_effect(self):
        self.server.deny_traverse=True
        result=self.storage.upload(self.plan,self.source,self.owner)
        self.assertNotEqual(result.status,"committed")
        self.assertEqual(len(self.server.requests),1)
        self.assertEqual(self.server.opens,[]);self.assertEqual(self.server.writes,[])
        self.assertEqual(self.server.renames,[]);self.assertEqual(self.consumed,0)
    def test_existing_target_is_never_written(self):
        self.server.files["approved/fixture.txt"]={"directory":False,"data":bytearray(b"old"),"index":7,"change":1}
        result=self.storage.upload(self.plan,self.source,self.owner)
        self.assertEqual(result.failure,"target_exists");self.assertEqual(self.server.writes,[])
        self.assertEqual(bytes(self.server.files["approved/fixture.txt"]["data"]),b"old")
    def test_racing_target_stays_rejected(self):
        self.server.race=True
        result=self.storage.upload(self.plan,self.source,self.owner)
        self.assertEqual((result.status,result.failure),("rejected","target_exists"))
        self.assertEqual(len(self.server.renames),1)
    def test_directory_flush_unsupported_before_stage(self):
        self.server.fail_directory_flush=True
        result=self.storage.upload(self.plan,self.source,self.owner)
        self.assertEqual(result.status,"held");self.assertEqual(self.server.writes,[])
        self.assertEqual(len(self.server.files),1);self.assertEqual(self.consumed,0)
    def test_postrename_flush_loss_stays_uncertain_no_retry(self):
        self.server.fail_postrename=True
        result=self.storage.upload(self.plan,self.source,self.owner)
        self.assertEqual(result.status,"uncertain")
        again=self.storage.upload(self.plan,self.source,self.owner)
        self.assertNotEqual(again.status,"committed")
        self.assertEqual(len(self.server.renames),1)
        self.assertIn("approved/fixture.txt",self.server.files)
    def test_revocation_before_any_effect(self):
        self.server.revoked=True
        result=self.storage.upload(self.plan,self.source,self.owner)
        self.assertEqual((result.status,result.failure),("held","revoked"))
        self.assertEqual(self.server.opens,[]);self.assertEqual(self.consumed,0)
if __name__=="__main__":unittest.main()
