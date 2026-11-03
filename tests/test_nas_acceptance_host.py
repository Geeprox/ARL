"""Private fixed-manifest runner with real durable records and synthetic SMB."""
from contextlib import contextmanager
from copy import deepcopy
from dataclasses import dataclass
import asyncio
import hashlib
import importlib
import json
import os
from pathlib import Path
import sys
import tempfile
import time
import types
import unittest
from unittest.mock import AsyncMock,patch

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'integrations/nas/runtime'))
from nas_acceptance_host import Engine,Journal
from nas_acceptance_samples import MANIFEST,MANIFEST_SHA256,files
from integrations.nas.acceptance import manifest as development_manifest,samples as development_samples
from arl_nas_upload_new.contracts import UploadFault
from homeplane.nas_connection.contracts import NASConnectionError


class Handle:
    def __init__(self,server,name):self.server,self.name=server,name
    def write(self,offset,raw,effect_check):
        self.server[self.name]['raw'][offset:offset+len(raw)]=raw
        return len(raw)
    def flush(self,effect_check):pass


class FixedHostTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.home=Path(self.temp.name)
        self.fd=os.open(self.home,os.O_RDONLY|os.O_DIRECTORY)
        self.journal=Journal(self.fd,{'scope':'synthetic-same-existing-scope','manifest':MANIFEST_SHA256})
        self.server={};self.effects=[];self.authorizations=[];self.parse_failure=False;self.delete_unknown=False

    def tearDown(self):
        self.journal.close();os.close(self.fd);self.temp.cleanup()

    @contextmanager
    def medium(self,spec):
        fixture=self;name=spec['name']
        class Medium:
            def assert_absent(self,target,effect_check):
                if target in fixture.server:raise FileExistsError()
            def create(self):
                if name in fixture.server:raise FileExistsError()
                fixture.effects.append(('create',name))
                fixture.server[name]={'raw':bytearray(),'identity':hashlib.sha256((name+':identity').encode()).hexdigest()}
                return Handle(fixture.server,name)
            def existing(self):return Handle(fixture.server,name)
            def information(self,handle):
                row=fixture.server[name];revision=hashlib.sha256(bytes(row['raw'])+row['identity'].encode()).hexdigest()
                return row['identity'],{'path':name,'kind':'file','size':len(row['raw']),'revision':revision},len(row['raw'])
            def contents(self,handle):return bytes(fixture.server[name]['raw'])
            def delete(self,handle):
                persisted=json.loads((fixture.home/'acceptance.json').read_bytes())
                fixture.assertEqual(persisted['files'][name]['state'],'deleting')
                fixture.effects.append(('delete',name));fixture.server.pop(name)
                if fixture.delete_unknown:raise TimeoutError('synthetic uncertain deletion')
        yield Medium()

    def engine(self):
        def parse(spec,raw):
            self.assertEqual(hashlib.sha256(raw).hexdigest(),spec['sha256'])
            if self.parse_failure:raise UploadFault('document_acceptance_mismatch')
        return Engine(self.journal,self.medium,parse,lambda entry:hashlib.sha256(entry['path'].encode()).hexdigest(),
                      lambda stage,consume=False:self.authorizations.append((stage,consume)))

    def test_frozen_manifest_and_all_bytes_match_prepared_pack(self):
        self.assertEqual(MANIFEST,development_manifest());self.assertEqual(files(),development_samples())
        raw=json.dumps(MANIFEST,ensure_ascii=False,sort_keys=True,separators=(',',':')).encode()
        self.assertEqual(hashlib.sha256(raw).hexdigest(),MANIFEST_SHA256)

    def test_six_create_readback_then_conditional_cleanup(self):
        created=self.engine().run('create')
        self.assertEqual(created['state'],'complete');self.assertEqual(len(self.server),6)
        self.assertEqual(len(self.effects),6)
        self.assertEqual(self.authorizations,[('acceptance_consume',True)])
        self.assertTrue(all(r['state']=='created_verified' and len(r['object_identity'])==64 for r in created['files']))
        self.assertEqual(self.engine().run('create')['state'],'blocked')
        self.assertEqual(len(self.effects),6)
        cleaned=self.engine().run('cleanup');self.assertEqual(cleaned['state'],'complete');self.assertEqual(self.server,{})
        self.assertEqual(len(self.effects),12)
        self.assertEqual(self.engine().run('cleanup')['state'],'complete');self.assertEqual(len(self.effects),12)

    def test_preexisting_last_name_blocks_all_creates_without_deletion(self):
        name=MANIFEST['files'][-1]['name'];self.server[name]={'raw':bytearray(b'PREEXISTING'),'identity':'d'*64}
        result=self.engine().run('create')
        self.assertEqual(result['state'],'blocked');self.assertEqual(self.effects,[])
        self.assertEqual(bytes(self.server[name]['raw']),b'PREEXISTING')
        self.assertFalse((self.home/'acceptance.json').exists())

    def test_replaced_identity_or_changed_payload_is_not_deleted(self):
        self.engine().run('create')
        first,second=MANIFEST['files'][:2]
        self.server[first['name']]['identity']='a'*64
        self.server[second['name']]['raw'][0]=0
        result=self.engine().run('cleanup')
        self.assertEqual(result['state'],'needs_review')
        self.assertEqual(set(self.server),{first['name'],second['name']})
        self.assertTrue(all(r['state']=='target_changed' for r in result['files'][:2]))

    def test_known_created_file_can_be_cleaned_after_parser_failure(self):
        self.parse_failure=True
        result=self.engine().run('create')
        self.assertEqual(result['state'],'needs_review');self.assertEqual(len(self.server),1)
        self.assertEqual(result['files'][0]['state'],'created_verified')
        self.parse_failure=False
        cleaned=self.engine().run('cleanup')
        self.assertEqual(cleaned['files'][0]['state'],'deleted');self.assertEqual(self.server,{})

    def test_unknown_deletion_not_replayed_after_journal_reopen(self):
        self.engine().run('create');self.delete_unknown=True
        result=self.engine().run('cleanup');first=MANIFEST['files'][0]['name']
        self.assertEqual(result['files'][0]['state'],'unknown')
        self.journal.close();self.journal=Journal(self.fd,{'scope':'synthetic-same-existing-scope','manifest':MANIFEST_SHA256})
        self.delete_unknown=False
        result=self.engine().run('cleanup')
        self.assertEqual(result['files'][0]['state'],'unknown')
        self.assertEqual(sum(effect==('delete',first) for effect in self.effects),1)

    def test_new_file_at_deleted_name_is_reported_without_redelete(self):
        self.engine().run('create');self.engine().run('cleanup')
        first=MANIFEST['files'][0]['name'];self.server[first]={'raw':bytearray(b'NEW UNRELATED'),'identity':'a'*64}
        count=len(self.effects);result=self.engine().run('cleanup')
        self.assertEqual(result['files'][0]['state'],'target_changed');self.assertEqual(len(self.effects),count)


class PrivateBoundaryTests(unittest.IsolatedAsyncioTestCase):
    async def acceptance_runtime(self,delay,seconds=15,*,revoke=False):
        @dataclass
        class Scope:
            root_descriptor_digest:str='a'*64
            credential_generation:str='b'*32
        @dataclass
        class Caller:
            registration_epoch:int=1
        calls=[]
        authority=types.SimpleNamespace(caller=Caller(),revoked=False,deadline=time.monotonic()+seconds)
        async def authorize(stage,*args,**kwargs):
            calls.append((stage,kwargs['timeout_seconds']))
            await asyncio.sleep(delay)
            if revoke:authority.revoked=True
            return {'remaining_seconds':seconds}
        runtime=types.SimpleNamespace(wire=types.SimpleNamespace(nonce='n',authorize=authorize),authority=authority,
            connection=types.SimpleNamespace(credentials=types.SimpleNamespace(scope=Scope()),
                manager=types.SimpleNamespace(config=types.SimpleNamespace(share='home',root='ARL-Test'))),
            transport=types.SimpleNamespace(reader=object()))
        return runtime,calls

    async def test_native_validation_over_five_seconds_remains_bounded_and_writes_no_nas_files(self):
        import nas_acceptance_host as host
        runtime,calls=await self.acceptance_runtime(5.05)
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory).resolve();root.chmod(0o700);info=root.stat()
            frame=dict(kind='acceptance',id=2,nonce='n',phase='cleanup',manifest_sha256=MANIFEST_SHA256,
                journal=dict(path=str(root),dev=info.st_dev,ino=info.st_ino))
            with patch.object(host,'Medium') as medium:
                result=await host.execute(runtime,frame)
                medium.assert_not_called()
            self.assertEqual(result['state'],'needs_review')
            self.assertTrue(all(row['state']=='not_started' for row in result['files']))
            self.assertFalse((root/'acceptance.json').exists())
        self.assertEqual(len(calls),1);self.assertEqual(calls[0][0],'acceptance_prepare')
        self.assertGreater(calls[0][1],5);self.assertLessEqual(calls[0][1],15)

    async def test_total_deadline_or_native_revocation_prevents_journal_and_all_effects(self):
        import nas_acceptance_host as host
        frame=dict(kind='acceptance',id=2,nonce='n',phase='create',manifest_sha256=MANIFEST_SHA256,journal={})
        for delay,seconds,revoke,expected in [(.08,.02,False,'expired'),(.02,1,True,'revoked')]:
            runtime,calls=await self.acceptance_runtime(delay,seconds,revoke=revoke)
            with self.subTest(code=expected),patch.object(host,'Journal') as journal,patch.object(host,'Medium') as medium:
                with self.assertRaises(UploadFault) as failure:await host.execute(runtime,frame)
                self.assertEqual(failure.exception.code,expected)
                journal.assert_not_called();medium.assert_not_called();self.assertEqual(len(calls),1)

    async def test_checkpoint_has_its_own_limit_without_renewing_the_total_deadline(self):
        import nas_acceptance_host as host
        runtime,calls=await self.acceptance_runtime(.08,1)
        frame=dict(kind='acceptance',id=2,nonce='n',phase='create',manifest_sha256=MANIFEST_SHA256,journal={})
        with patch.object(host,'CHECKPOINT_SECONDS',.02),patch.object(host,'Journal') as journal,patch.object(host,'Medium') as medium:
            with self.assertRaises(UploadFault) as failure:await host.execute(runtime,frame)
            self.assertEqual(failure.exception.code,'expired');journal.assert_not_called();medium.assert_not_called()
        self.assertEqual(len(calls),1);self.assertEqual(calls[0][1],.02)

    async def test_private_wire_honors_the_acceptance_checkpoint_bound_before_read(self):
        import nas_host
        @dataclass
        class Descriptor:
            value:str='synthetic'
        wire=nas_host.PrivateWire(None,None,os.getpid(),kernel_check=False);wire.nonce='n'
        wire.send=AsyncMock()
        async def read():
            await asyncio.sleep(.06)
            return dict(kind='authorization',sequence=wire.sequence,nonce='n',ok=True,remaining_seconds=1)
        wire.read=read
        result=await wire.authorize('acceptance_prepare',Descriptor(),Descriptor(),upload_digest='a'*64,timeout_seconds=.2)
        self.assertEqual(result['remaining_seconds'],1)
        with self.assertRaises(TimeoutError):
            await wire.authorize('acceptance_prepare',Descriptor(),Descriptor(),upload_digest='a'*64,timeout_seconds=.02)
        self.assertEqual(wire.send.await_count,2)
        from arl_nas_credential import CredentialFault,Failure
        for invalid in [True,0,-1,91,float('inf'),float('nan')]:
            with self.subTest(timeout=invalid),self.assertRaises(CredentialFault) as failure:
                await wire.authorize('acceptance_prepare',Descriptor(),Descriptor(),timeout_seconds=invalid)
            self.assertEqual(failure.exception.code,Failure.EXPIRED)
        self.assertEqual(wire.send.await_count,2)

    async def test_current_medium_remaining_time_clamps_checkpoint_before_any_nas_effect(self):
        import nas_acceptance_host as host
        runtime,calls=await self.acceptance_runtime(.06)
        effects=[]
        class ShortMedium:
            def __init__(self,*,reader,plan,authorize):self.deadline=time.monotonic()+.02;self.authorize=authorize
            def assert_absent(self,*args,**kwargs):self.authorize('acceptance_check')
            def close(self):pass
            def create(self):effects.append('create');raise AssertionError('expired medium wrote')
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory).resolve();root.chmod(0o700);info=root.stat()
            frame=dict(kind='acceptance',id=2,nonce='n',phase='create',manifest_sha256=MANIFEST_SHA256,
                journal=dict(path=str(root),dev=info.st_dev,ino=info.st_ino))
            with patch.object(host,'Medium',ShortMedium):result=await host.execute(runtime,frame)
            self.assertEqual(result['state'],'blocked');self.assertEqual(result['files'][0]['error'],'expired')
            self.assertFalse((root/'acceptance.json').exists())
        self.assertEqual(effects,[]);self.assertEqual(len(calls),2)
        self.assertGreater(calls[0][1],5);self.assertLessEqual(calls[1][1],.02)

    async def test_consumption_wait_is_medium_bounded_and_unknown_attempt_is_not_replayed(self):
        import nas_acceptance_host as host
        runtime,calls=await self.acceptance_runtime(0);effects=[]
        async def authorize(stage,*args,**kwargs):
            calls.append((stage,kwargs['timeout_seconds']))
            if stage=='acceptance_consume':await asyncio.sleep(.06)
            return {'remaining_seconds':15}
        runtime.wire.authorize=authorize
        class ShortMedium:
            def __init__(self,**kwargs):self.deadline=time.monotonic()+.02
            def assert_absent(self,*args,**kwargs):pass
            def close(self):pass
            def create(self):effects.append('create');raise AssertionError('expired consumption wrote')
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory).resolve();root.chmod(0o700);info=root.stat()
            frame=dict(kind='acceptance',id=2,nonce='n',phase='create',manifest_sha256=MANIFEST_SHA256,
                journal=dict(path=str(root),dev=info.st_dev,ino=info.st_ino))
            with patch.object(host,'Medium',ShortMedium):
                first=await host.execute(runtime,frame)
                self.assertEqual(first['files'][0]['state'],'unknown')
                self.assertEqual(first['files'][0]['error'],'expired')
                self.assertEqual((await host.execute(runtime,frame))['state'],'blocked')
        consumed=[budget for stage,budget in calls if stage=='acceptance_consume']
        self.assertEqual(len(consumed),1);self.assertLessEqual(consumed[0],.02);self.assertEqual(effects,[])

    async def test_real_acceptance_medium_passes_its_deadline_during_construction(self):
        import nas_acceptance_host as host
        from arl_nas_upload_new.contracts import UploadPlan
        import uuid
        spec=MANIFEST['files'][0];seen=[]
        plan=UploadPlan(str(uuid.uuid4()),str(uuid.uuid4()),'a'*64,'b'*64,'c'*32,1,
            spec['name'],spec['size'],spec['sha256'])
        def authorize(stage,**kwargs):seen.append((stage,kwargs['medium_deadline']))
        with patch.object(host.Medium,'require_atomic_new',lambda item:item.check()):
            medium=host.Medium(reader=types.SimpleNamespace(tree=types.SimpleNamespace(is_dfs_share=False)),plan=plan,authorize=authorize)
        self.assertEqual(seen,[('acceptance_check',medium.deadline)])
        medium.close()

    async def test_unknown_arguments_and_wrong_scope_never_reach_smb_or_credentials(self):
        import nas_acceptance_host as host
        frame=dict(kind='acceptance',id=2,nonce='n',phase='create',manifest_sha256=MANIFEST_SHA256,journal={})
        runtime=types.SimpleNamespace(wire=types.SimpleNamespace(nonce='n'),connection=None,transport=None)
        for extra in ({'path':'/private'},{'name':'arbitrary.txt'},{'source':'arbitrary-bytes'},{'approved':True}):
            with self.assertRaises(NASConnectionError) as caught:await host.execute(runtime,dict(frame,**extra))
            self.assertEqual(caught.exception.code,'nas_invalid_request')
        runtime.connection=types.SimpleNamespace(manager=types.SimpleNamespace(config=types.SimpleNamespace(share='home',root='private')))
        runtime.transport=types.SimpleNamespace(reader=object())
        with self.assertRaises(NASConnectionError) as caught:await host.execute(runtime,frame)
        self.assertEqual(caught.exception.code,'nas_access_denied')

    async def test_actual_production_transport_records_original_finite_failure(self):
        import errno,nas_host
        transport=nas_host.OwnedSMBTransport()
        error=OSError(errno.ECONNREFUSED,'SECRET_ENDPOINT_PASSWORD')
        with patch.object(nas_host,'SMBReader',side_effect=error),patch.object(nas_host,'record_failure') as record:
            with self.assertRaises(NASConnectionError):
                await transport.connect(types.SimpleNamespace(transport='smb',require_encryption=True),object())
            record.assert_called_once_with(error,'connect')
        transport=nas_host.OwnedSMBTransport()
        def failed():raise error
        transport.reader=types.SimpleNamespace(health=failed)
        with patch.object(nas_host,'record_failure') as record:
            with self.assertRaises(OSError):await transport.request('health',{})
            record.assert_called_once_with(error,'health')
        self.assertTrue(transport.closed);self.assertFalse(transport.busy)


class ExactSMBDeletionTests(unittest.TestCase):
    def test_real_setinfo_packet_targets_retained_handle_then_confirms_absence(self):
        from nas_acceptance_host import Medium
        from smbprotocol.open import SMB2SetInfoResponse
        from smbprotocol.file_info import FileDispositionInformation
        calls=[];expected_id=b's'*16;seen=[]
        def send(request,**kwargs):
            seen.append(request)
            self.assertEqual(request['file_id'].get_value(),expected_id)
            self.assertEqual(request['file_info_class'].get_value(),FileDispositionInformation.INFO_CLASS)
            disposition=FileDispositionInformation();disposition.unpack(request['buffer'].get_value())
            self.assertTrue(disposition['delete_pending'].get_value());calls.append('send');return 1
        def missing(path):calls.append('stat');raise NASConnectionError('nas_missing')
        medium=object.__new__(Medium)
        medium._namespace=lambda:None;medium._effect=lambda:None;medium.parents=[]
        medium.plan=types.SimpleNamespace(target='ARL-Test-20261030-write.txt')
        medium.reader=types.SimpleNamespace(connection=types.SimpleNamespace(send=send,
            receive=lambda _: {'data':types.SimpleNamespace(get_value=lambda:SMB2SetInfoResponse().pack())}),
            session=types.SimpleNamespace(session_id=1),tree=types.SimpleNamespace(tree_connect_id=2),stat=missing)
        handle=types.SimpleNamespace(raw=types.SimpleNamespace(file_id=expected_id),close=lambda:calls.append('close'))
        medium.handles=[handle]
        medium.delete(handle)
        self.assertEqual(calls,['send','close','stat']);self.assertEqual(medium.handles,[])


if __name__=='__main__':unittest.main()
