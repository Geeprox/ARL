import asyncio
import base64
import copy
import hashlib
import json
import os
from pathlib import Path
import struct
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
sys.path[:0]=[str(ROOT/'integrations/nas/runtime'),str(ROOT)]
from nas_server_host import ServerBridge
from nas_host import CredentialFault,Failure
from smb_server_metadata import enum_request,enum_response,body,pdu,NASConnectionError

class Wire:
    nonce=None
    kernel_check=False
    def __init__(self):self.stages=[];self.leases=0;self.reject=None
    async def authorize(self,stage,scope,caller,*,lease=False):
        self.stages.append((stage,copy.deepcopy(scope.__dict__)))
        if stage==self.reject:raise CredentialFault(Failure.REVOKED)
        result={'remaining_seconds':30}
        if lease:
            self.leases+=1
            result['credential']=base64.b64encode(json.dumps({'schema':2,'endpoint_fingerprint':scope.endpoint_fingerprint,'username':'fixture','password':'synthetic-only'}).encode()).decode()
        return result

class Server:
    opened=closed=0
    def __init__(self,endpoint,username,password):
        assert 'share' not in endpoint and 'root' not in endpoint and endpoint['require_encryption']
        assert (username,password)==('fixture','synthetic-only')
        type(self).opened+=1
    def shares(self,resume):return (['Data','资料'],None)
    def directories(self,share,path,cursor):
        assert share=='Data'
        return {'path':path,'directories':['selected'] if not path else [],'next_cursor':None}
    def close(self):type(self).closed+=1

def bootstrap():
    fingerprint=hashlib.sha256(json.dumps(['nas-server-v2','smb','synthetic.invalid','445','encryption-required'],separators=(',',':')).encode()).hexdigest()
    return {'kind':'server_connect','id':1,'nonce':'c'*32,'caller':{'subject':'local.arl.control','uid':os.getuid(),'pid':os.getpid(),'executable_sha256':'1'*64,'designated_requirement_sha256':'2'*64,'profile_sha256':'3'*64,'registration_epoch':1},
        'endpoint':{'source_ref':'fixture','host':'synthetic.invalid','port':445,'timeout_seconds':2,'generation':1,'endpoint_fingerprint':fingerprint,'require_encryption':True},
        'scope':{'purpose':'server_metadata_only','source_ref':'fixture','credential_ref':'11111111-1111-1111-1111-111111111111','credential_generation':'4'*32,'config_generation':1,'endpoint_fingerprint':fingerprint,'metadata_target':{}}}

class SetupTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        # Production diagnostics deliberately ignore HOME. Isolate the actual
        # account-directory seam so expected rejection tests never touch live logs.
        directory = ROOT/'build/tmp'
        directory.mkdir(parents=True, exist_ok=True)
        temporary = tempfile.TemporaryDirectory(prefix='nas-server-test-', dir=directory)
        self.addCleanup(temporary.cleanup)
        home = Path(temporary.name)
        (home/'Library/Application Support/ARL/nas').mkdir(parents=True)
        diagnostic_home = patch('nas_diagnostic.pwd.getpwuid', return_value=types.SimpleNamespace(pw_dir=str(home)))
        diagnostic_home.start()
        self.addCleanup(diagnostic_home.stop)
        Server.opened=Server.closed=0;self.wire=Wire();self.host=ServerBridge(self.wire,server_factory=Server);self.seed=bootstrap();self.i=1
    async def asyncTearDown(self):await self.host.stop()
    def frame(self,kind,**fields):
        self.i+=1
        target={'operation':'shares','cursor':fields.get('cursor') or ''} if kind=='shares' else {'operation':'directories','share':fields.get('share'),'path':fields.get('path'),'cursor':fields.get('cursor') or ''} if kind=='preview_directories' else {'operation':'status'} if kind=='server_status' else {}
        return {'kind':kind,'id':self.i,'nonce':self.wire.nonce,'scope':{**self.seed['scope'],'metadata_target':target},**fields}
    async def test_login_without_share_then_real_shares_and_selected_directory(self):
        state=await self.host.connect(self.seed)
        self.assertTrue(state['authenticated']);self.assertEqual(state['shares'],[]);self.assertEqual(self.wire.leases,1)
        shares=await self.host.command(self.frame('shares',cursor=None));self.assertEqual(shares['shares'],['Data','资料'])
        page=await self.host.command(self.frame('preview_directories',share='Data',path='',cursor=None));self.assertEqual(page['directories'],['selected'])
        nested=await self.host.command(self.frame('preview_directories',share='Data',path='selected',cursor=None));self.assertEqual(nested['path'],'selected')
        self.assertTrue(all(scope['purpose']=='server_metadata_only' and 'root_descriptor_digest' not in scope for _,scope in self.wire.stages))
    async def test_unknown_share_path_and_file_operations_rejected(self):
        await self.host.connect(self.seed);await self.host.command(self.frame('shares',cursor=None))
        with self.assertRaises(CredentialFault):await self.host.command(self.frame('preview_directories',share='invented',path='',cursor=None))
        with self.assertRaises(NASConnectionError):await self.host.command(self.frame('preview_directories',share='Data',path='unseen',cursor=None))
        for action in ['read','list','upload_new']:
            with self.assertRaises(CredentialFault):await self.host.command(self.frame(action))
    async def test_denial_before_lease_and_network(self):
        self.wire.reject='reserve'
        with self.assertRaises(CredentialFault):await self.host.connect(self.seed)
        self.assertEqual(self.wire.leases,0);self.assertEqual(Server.opened,0)
    async def test_late_revocation_suppresses_success_and_closes_server(self):
        self.wire.reject='reply'
        with self.assertRaises(CredentialFault):await self.host.connect(self.seed)
        self.assertEqual(Server.opened,Server.closed);self.assertFalse(self.host.snapshot()['authenticated'])
    async def test_changed_endpoint_or_metadata_scope_rejected(self):
        bad=copy.deepcopy(self.seed);bad['endpoint']['host']='other.invalid'
        with self.assertRaises(CredentialFault):await self.host.connect(bad)
        self.assertEqual(Server.opened,0)
        await self.host.connect(self.seed)
        frame=self.frame('shares',cursor=None);frame['scope']['metadata_target']['share']='widened'
        with self.assertRaises(CredentialFault):await self.host.command(frame)
    async def test_share_request_authorization_timeout_is_diagnosed_before_provider(self):
        await self.host.connect(self.seed)
        original=self.wire.authorize
        timeout=TimeoutError('SECRET_CALLBACK_CONTEXT')
        async def authorize(stage,*args,**kwargs):
            if stage=='request':raise timeout
            return await original(stage,*args,**kwargs)
        self.wire.authorize=authorize
        with patch('nas_diagnostic.failure_record') as diagnostic, patch.object(Server,'shares') as provider:
            with self.assertRaises(NASConnectionError) as failure:
                await self.host.command(self.frame('shares',cursor=None))
            self.assertEqual(failure.exception.code,'nas_timeout')
            provider.assert_not_called()
            diagnostic.assert_called_once_with(timeout,'share_list')

    async def test_directory_authorization_timeout_keeps_directory_stage(self):
        await self.host.connect(self.seed)
        await self.host.command(self.frame('shares',cursor=None))
        original=self.wire.authorize
        timeout=TimeoutError('SECRET_DIRECTORY_CALLBACK')
        async def authorize(stage,*args,**kwargs):
            if stage=='request':raise timeout
            return await original(stage,*args,**kwargs)
        self.wire.authorize=authorize
        with patch('nas_diagnostic.failure_record') as diagnostic, patch.object(Server,'directories') as provider:
            with self.assertRaises(NASConnectionError) as failure:
                await self.host.command(self.frame('preview_directories',share='Data',path='',cursor=None))
            self.assertEqual(failure.exception.code,'nas_timeout')
            provider.assert_not_called()
            diagnostic.assert_called_once_with(timeout,'directory_list')

    async def test_raw_share_provider_error_is_captured_before_public_mapping(self):
        await self.host.connect(self.seed)
        original=OSError(65,'SECRET_PROVIDER_DETAILS')
        with patch('nas_diagnostic.failure_record') as diagnostic, patch.object(Server,'shares',side_effect=original) as provider:
            with self.assertRaises(NASConnectionError) as failure:
                await self.host.command(self.frame('shares',cursor=None))
            self.assertEqual(failure.exception.code,'nas_transport_failed')
            provider.assert_called_once_with(0)
            diagnostic.assert_called_once_with(original,'share_list')
            self.assertNotIn('SECRET',str(failure.exception))

    async def test_share_reply_revocation_still_denies_without_replaying_provider(self):
        await self.host.connect(self.seed)
        self.wire.reject='request_reply'
        with patch('nas_diagnostic.failure_record') as diagnostic, patch.object(Server,'shares',return_value=(['Data'],None)) as provider:
            with self.assertRaises(CredentialFault) as failure:
                await self.host.command(self.frame('shares',cursor=None))
            self.assertEqual(failure.exception.code,Failure.REVOKED)
            provider.assert_called_once_with(0)
            self.assertEqual(diagnostic.call_count,1)
            self.assertEqual(diagnostic.call_args.args[1],'share_list')

    async def test_expiry_and_replay_rejected(self):
        await self.host.connect(self.seed);frame=self.frame('server_status');await self.host.command(frame)
        with self.assertRaises(CredentialFault):await self.host.command(frame)
        self.host.deadline=0
        with self.assertRaises(CredentialFault):await self.host.command(self.frame('server_status'))

class NDRTests(unittest.TestCase):
    def response(self,names,status=0,resume=0):
        raw=bytearray(struct.pack('<6I',1,1,1,len(names),2,len(names)))
        for name,kind in names:raw.extend(struct.pack('<3I',3,kind,0))
        for name,_ in names:
            raw.extend(b'\0'*((-len(raw))%4));text=(name+'\0').encode('utf-16-le');count=len(text)//2
            raw.extend(struct.pack('<3I',count,0,count));raw.extend(text)
        raw.extend(b'\0'*((-len(raw))%4));raw.extend(struct.pack('<4I',len(names),4,resume,status));return bytes(raw)
    def test_exact_fixed_request_and_disk_only_response(self):
        self.assertEqual(struct.unpack('<9I',enum_request()),(0,1,1,0x20000,0,0,4096,0x20004,0))
        self.assertEqual(enum_response(self.response([('Data',0),('资料',0),('IPC$',0x80000003)])),(['Data','资料'],None))
        self.assertEqual(enum_response(self.response([('Data',0)],234,7)),(['Data'],7))
    def test_malformed_counts_paths_truncation_and_pdu_rejected(self):
        valid=self.response([('Data',0)])
        for raw in [valid[:-1],valid+b'junk',self.response([('../escape',0)]),struct.pack('<6I',1,1,1,129,2,129)]:
            with self.assertRaises(NASConnectionError):enum_response(raw)
        packet=pdu(2,2,b'example');self.assertEqual(body(packet,2,2),b'example')
        for raw in [packet[:-1],packet[:3]+b'\x01'+packet[4:]]:
            with self.assertRaises(NASConnectionError):body(raw,2,2)
