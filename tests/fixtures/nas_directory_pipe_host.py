
"""Only the test bundle uses this entrypoint. Production has no fixture CLI switch."""
import asyncio, importlib.util, pathlib, socket
root=pathlib.Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location("nas_production_host",root/"nas_production_host.py")
host=importlib.util.module_from_spec(spec);spec.loader.exec_module(host)
fixture_spec=importlib.util.spec_from_file_location("synthetic_smb_protocol",root/"synthetic_smb_protocol.py")
fixture=importlib.util.module_from_spec(fixture_spec);fixture_spec.loader.exec_module(fixture)
import smb_upload_new
smb_upload_new.Open=fixture.Open
class SyntheticSMB(fixture.Server):
    def __init__(self, config, credentials):
        super().__init__()
        self.root=config.root
        self.files["approved/test"]={"directory":True,"data":bytearray(),"index":2,"change":1}
        assert credentials.payload()=={"username":"fixture","password":"fixture-only"}
        assert config.host=="synthetic.invalid" and config.require_encryption
    def health(self):
        return {"reachable":True,"authenticated":True,"readable":True}
    def list_page(self,path,cursor,limit):
        assert path in {"", "test"} and cursor is None and 0<limit<=128
        entries = [] if path else [{"path":"synthetic.txt","kind":"file","revision":"b"*64,"size":4,"modified_ns":0},
                                  {"path":"test","kind":"directory","revision":"c"*64,"size":0,"modified_ns":0}]
        return {"entries":entries,"cursor":None,"complete":True}
    def stat(self,path):
        assert path == "synthetic.txt"
        return {"path":path,"kind":"file","revision":"b"*64,"size":4,"modified_ns":0}
    def read_range(self,path,revision,offset,length):
        assert path == "synthetic.txt" and revision == "b"*64
        return {"data":__import__('base64').b64encode(b'data'[offset:offset+length]).decode()}
    def close(self): pass
host.SMBReader=SyntheticSMB
# Block any accidental network transport; asyncio may still create an AF_UNIX self-pipe.
original_socket=socket.socket
def guarded_socket(family=socket.AF_INET,*args,**kwargs):
    if family in (socket.AF_INET,socket.AF_INET6): raise AssertionError("fixture_network_forbidden")
    return original_socket(family,*args,**kwargs)
socket.socket=guarded_socket
asyncio.run(host.main())
