"""Real private NAS wire/dispatcher with synthetic native replies and no SMB."""
from dataclasses import dataclass
import asyncio
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
import nas_host
from nas_authorization_timing import FILENAME,ReadonlyAuthorizationTimings,readonly_operation


@dataclass
class Descriptor:
    value:str='SECRET_ENDPOINT_USERNAME_FRAME'


class AuthorizationWireTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name).resolve();self.root.chmod(0o700)
        self.timings=ReadonlyAuthorizationTimings(root=self.root,clock=lambda:1000)
        self.wire=nas_host.PrivateWire(None,None,os.getpid(),kernel_check=False);self.wire.nonce='SECRET_NONCE'
        self.wire.authorization_timings=self.timings;self.wire.send=AsyncMock()
        async def read():
            await asyncio.sleep(.005)
            frame=self.wire.send.call_args.args[0]
            result=dict(kind='authorization',sequence=self.wire.sequence,nonce=self.wire.nonce,ok=True,remaining_seconds=120)
            if frame['kind']=='lease':result['credential']='SECRET_CREDENTIAL_BASE64'
            return result
        self.wire.read=read
    async def asyncTearDown(self):self.temp.cleanup()
    async def call(self,stage='request',**kwargs):return await self.wire.authorize(stage,Descriptor(),Descriptor(),**kwargs)
    def saved(self):return json.loads((self.root/FILENAME).read_bytes())

    async def test_wire_returns_original_credential_reply_but_records_only_timing_primitives(self):
        self.timings.begin('connect');result=await self.call('lease',lease=True)
        self.assertEqual(result['credential'],'SECRET_CREDENTIAL_BASE64');self.assertFalse((self.root/FILENAME).exists())
        self.assertTrue(self.timings.finish());row=self.saved()['stages'][0]
        self.assertGreaterEqual(row['min_microseconds'],1000);self.assertEqual(row['outcomes']['ok'],1)
        self.assertNotIn('SECRET',json.dumps(self.saved()));self.assertEqual(self.wire.send.await_count,1)

    async def test_actual_files_list_and_legacy_list_dispatch_both_produce_readonly_callbacks(self):
        wire=self.wire
        async def check(stage):await wire.authorize(stage,Descriptor(),Descriptor())
        operations=[]
        async def file_operation(request):operations.append(request['operation']);return {'operation':request['operation'],'entries':[]}
        async def inventory():await check('request');await check('inventory_metadata');return {'entries':[]}
        runtime=nas_host.NativeRuntimeHost(wire)
        runtime.connection=types.SimpleNamespace(credentials=types.SimpleNamespace(check=check),
            manager=types.SimpleNamespace(file_operation=file_operation),
            bounded_inventory=lambda:types.SimpleNamespace(run=inventory))
        runtime.authority=types.SimpleNamespace(deadline=time.monotonic()+90)
        for frame in [dict(kind='files',id=2,nonce=wire.nonce,request={'operation':'list','limit':20}),
                      dict(kind='list',id=3,nonce=wire.nonce)]:
            self.timings.begin(readonly_operation(frame));await runtime.command(frame);self.assertTrue(self.timings.finish())
        self.assertEqual(operations,['list']);self.assertEqual(self.wire.send.await_count,4)
        counts={row['stage']:row['count'] for row in self.saved()['stages']}
        self.assertEqual(counts,{'request':2,'request_reply':1,'inventory_metadata':1})
        before=(self.root/FILENAME).read_bytes()
        frame=dict(kind='files',id=4,nonce=wire.nonce,request={'operation':'list','path':'SECRET'})
        self.timings.begin(readonly_operation(frame))
        with self.assertRaises(nas_host.NASConnectionError):await runtime.command(frame)
        self.assertFalse(self.timings.finish());self.assertEqual((self.root/FILENAME).read_bytes(),before)
        self.assertEqual(self.wire.send.await_count,4) # Original admission still precedes callbacks.
        request=dict(operation='read',source_ref='fixture',config_generation=1,connection_epoch='e'*32,
            object_ref='a'*64,revision='b'*64,offset=0,length=1)
        frame=dict(kind='files',id=5,nonce=wire.nonce,request=request)
        self.timings.begin(readonly_operation(frame));await runtime.command(frame)
        self.assertFalse(self.timings.finish());self.assertEqual((self.root/FILENAME).read_bytes(),before)
        self.assertEqual(operations,['list','read']);self.assertEqual(self.wire.send.await_count,6)

    async def test_upload_digest_never_enters_a_readonly_sample(self):
        self.timings.begin('list');await self.call('request',upload_digest='a'*64)
        await self.call('acceptance_check',upload_digest='a'*64)
        self.assertFalse(self.timings.finish());self.assertEqual(self.wire.send.await_count,2)

    async def test_timeout_cancellation_and_invalid_native_reply_preserve_original_failure(self):
        self.timings.begin('list')
        async def slow():await asyncio.sleep(.06)
        self.wire.read=slow
        with self.assertRaises(TimeoutError):await self.call(timeout_seconds=.01)
        async def cancelled():raise asyncio.CancelledError()
        self.wire.read=cancelled
        with self.assertRaises(asyncio.CancelledError):await self.call()
        async def invalid():return {'SECRET_FRAME':True}
        self.wire.read=invalid
        with self.assertRaises(nas_host.CredentialFault):await self.call()
        self.assertTrue(self.timings.finish())
        self.assertEqual(self.saved()['stages'][0]['outcomes'],dict(ok=0,reply_timeout=1,cancelled=1,wire_error=1))

    async def test_diagnostic_failure_cannot_change_reply_or_repeat_authorization(self):
        self.timings.begin('connect')
        with patch.object(self.timings,'add',side_effect=RuntimeError('SECRET')):
            self.assertTrue((await self.call())['ok'])
        self.assertEqual(self.wire.send.await_count,1);self.assertFalse(self.timings.finish())
        self.timings.begin('list')
        with patch('nas_authorization_timing.os.write',side_effect=OSError('SECRET')) as write:
            result=await self.call();write.assert_not_called();self.assertFalse(self.timings.finish())
        self.assertTrue(result['ok']);self.assertEqual(self.wire.send.await_count,2)

    async def test_main_flushes_before_final_result_can_trigger_worker_stop(self):
        # The real native owner stops a failed connect worker after its result.
        # Synthetic pipes keep this ordering check free of process or SMB I/O.
        for connect_fails in [False,True]:
            with self.subTest(connect_fails=connect_fails):
                path=self.root/FILENAME
                if path.exists():path.unlink()
                timing=ReadonlyAuthorizationTimings(root=self.root,clock=lambda:1000)
                frames=iter([dict(kind='connect'),dict(kind='stop',id=2)])
                sends=[]
                async def read():return next(frames)
                async def send(frame):sends.append((frame['ok'],path.exists()))
                wire=types.SimpleNamespace(authorization_timings=timing,nonce='synthetic',read=read,send=send)
                async def connect(frame):
                    timing.add('reserve',1_000,'ok')
                    if connect_fails:raise nas_host.NASConnectionError('nas_transport_failed')
                    return {}
                async def command(frame):return {}
                async def stop():pass
                async def read_pipe(*args):return (None,None)
                async def write_pipe(*args):return (None,None)
                loop=types.SimpleNamespace(connect_read_pipe=read_pipe,connect_write_pipe=write_pipe)
                host=types.SimpleNamespace(connect=connect,command=command,stop=stop)
                with patch.object(nas_host.asyncio,'get_running_loop',return_value=loop), \
                     patch.object(nas_host.asyncio,'StreamReader',return_value=object()), \
                     patch.object(nas_host.asyncio,'StreamWriter',return_value=types.SimpleNamespace(close=lambda:None)), \
                     patch.object(nas_host,'PrivateWire',return_value=wire), \
                     patch.object(nas_host,'NativeRuntimeHost',return_value=host):
                    await nas_host.main()
                self.assertEqual(sends[0],(not connect_fails,True))
                self.assertEqual(len(sends),1 if connect_fails else 2)
                self.assertEqual(self.saved()['stages'][0]['count'],1)


if __name__=='__main__':unittest.main()
