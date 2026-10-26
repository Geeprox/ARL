"""Actual inspector HTTP parser over synthetic in-memory sockets only."""
import os
from pathlib import Path
import socket
import sys
import time
from unittest.mock import patch
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT))
mode=sys.argv[1]
if mode=='hang':
    sys.stdin.buffer.read(); time.sleep(10); raise SystemExit(0)
if mode=='oversize':
    sys.stdin.buffer.read(); sys.stdout.write('X'*9000+'\n'); raise SystemExit(0)
if mode=='nonzero':
    sys.stdin.buffer.read(); raise SystemExit(9)
from arl.attachment_inspection import run
from integrations.nas import file_params_importer as imp
from tests.test_nas_file_params_importer import FakeSocket,response
BODY=b'ARL attachment inspection offline receipt: no user files, NAS or network.\n'
class Connection(imp._PinnedHTTPS):
    def connect(self):self.sock=FakeSocket(response(BODY))
with patch.object(imp,'_PinnedHTTPS',Connection),patch.object(imp.socket,'getaddrinfo',return_value=[
    (socket.AF_INET,socket.SOCK_STREAM,socket.IPPROTO_TCP,'',('8.8.8.8',443))]):
    raise SystemExit(run(sys.stdin.buffer,sys.stdout.buffer,os.getppid()))
