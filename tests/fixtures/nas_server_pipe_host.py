"""Test bundle only: actual host/pipe/owner, synthetic SMB boundary."""
import asyncio
import importlib.util
from pathlib import Path
import socket
import sys
root=Path(__file__).resolve().parent
sys.path.insert(0,str(root))
spec=importlib.util.spec_from_file_location('nas_host',root/'nas_production_host.py')
host=importlib.util.module_from_spec(spec);sys.modules['nas_host']=host;spec.loader.exec_module(host)
import nas_server_host
class Server:
    def __init__(self,endpoint,username,password):
        assert endpoint['host']=='synthetic.invalid' and endpoint['require_encryption']
        assert 'share' not in endpoint and 'root' not in endpoint
        assert (username,password)==('fixture','fixture-only')
    def shares(self,resume):return ['Data','资料'],None
    def directories(self,share,path,cursor):
        assert share=='Data' and path in ('','selected') and cursor is None
        return {'path':path,'directories':['selected'] if not path else [],'next_cursor':None}
    def close(self):pass
original=nas_server_host.ServerBridge
nas_server_host.ServerBridge=lambda wire:original(wire,server_factory=Server)
original_socket=socket.socket
def guarded_socket(family=socket.AF_INET,*args,**kwargs):
    if family in (socket.AF_INET,socket.AF_INET6):raise AssertionError('fixture_network_forbidden')
    return original_socket(family,*args,**kwargs)
socket.socket=guarded_socket
asyncio.run(host.main())
