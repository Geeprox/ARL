"""Actual private host -> actual manager -> synthetic transport; no NAS socket."""
import asyncio,base64,hashlib,json,sys,tempfile,time,unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'integrations/nas/runtime'))
from nas_host import NativeRuntimeHost
from arl_nas_credential.scope_bridge import ScopedTransport
from nas_file_reader_host import request
from homeplane.nas_connection.contracts import NASConnectionConfig,NASConnectionError
from homeplane.nas_connection.manager import NASConnectionManager

def ref(x):return hashlib.sha256(x.encode()).hexdigest()
class HostReaderTests(unittest.IsolatedAsyncioTestCase):
 async def asyncSetUp(self):
  directory=ROOT/'build/tmp';directory.mkdir(parents=True,exist_ok=True)
  self.tmp=tempfile.TemporaryDirectory(prefix='reader-',dir=directory);self.raw='真实合同的合成正文🙂\n'.encode();self.transport_calls=[];self.checks=[]
  outer=self
  class Transport:
   async def request(self,op,payload):
    outer.transport_calls.append(op)
    if op=='list':
     entries=[dict(path='sub',kind='directory',size=0,revision=ref('sub'))] if payload['path']=='' else [dict(path='sub/note.txt',kind='file',size=len(outer.raw),revision=ref('note'))]
     return dict(entries=entries,complete=True)
    if op=='stat':return dict(path=payload['path'],kind='file',size=len(outer.raw),revision=ref('note'))
    if op=='read':return dict(data=base64.b64encode(outer.raw[payload['offset']:payload['offset']+payload['length']]).decode())
    raise AssertionError(op)
   async def close(self):pass
  self.manager=NASConnectionManager(Path(self.tmp.name)/'unused',credential_resolver=None)
  self.manager.config=NASConnectionConfig(source_ref='synthetic',transport='smb',host='synthetic.invalid',share='home',root='ARL-Test',credential_ref='unused',enabled=True)
  self.manager.generation=1;self.manager._epoch='e'*32;self.manager._state='online';self.manager._transport=Transport()
  async def check(stage):self.checks.append(stage)
  self.host=NativeRuntimeHost(SimpleNamespace(nonce='n'*32))
  self.host.connection=SimpleNamespace(manager=self.manager,credentials=SimpleNamespace(check=check))
  self.host.authority=SimpleNamespace(deadline=time.monotonic()+120,revoked=False)
  self.sequence=1
 async def asyncTearDown(self):self.tmp.cleanup()
 def args(self,operation='search_recursive',**changes):
  result=dict(operation=operation,source_ref='synthetic',config_generation=1,connection_epoch='e'*32)
  if operation=='search_recursive':result.update(keyword='note',recursive=True,limit=32)
  return dict(result,**changes)
 async def call(self,args):
  self.sequence+=1
  return await self.host.command(dict(kind='files',id=self.sequence,nonce='n'*32,request=args))
 async def test_actual_host_recursive_then_strict_text_and_original_stat_read_stat(self):
  found=await self.call(self.args());self.assertTrue(found['enumeration_complete']);self.assertTrue(found['recursive'])
  self.assertEqual(found['operation'],'search_recursive');self.assertEqual(found['location']['root'],'ARL-Test')
  self.assertEqual(len(found['entries']),1);entry=found['entries'][0]
  text=await self.call(self.args('read_text',**{k:entry[k] for k in ('object_ref','revision','size')},max_bytes=65536))
  self.assertEqual(text['text'],self.raw.decode());self.assertTrue(text['complete']);self.assertEqual(text['sha256_of_returned_bytes'],hashlib.sha256(self.raw).hexdigest())
  self.assertEqual(self.transport_calls[-3:],['stat','read','stat']);self.assertEqual(self.manager._file_bytes,len(self.raw))
  self.assertGreater(len(self.checks),4);self.assertFalse(text['downloadable_artifact'])
 async def test_composite_text_allows_native_authorization_round_trips(self):
  found=await self.call(self.args());entry=found['entries'][0]
  self.transport_calls.clear();self.checks.clear()
  async def slow_check(stage):
   self.checks.append(stage)
   await asyncio.sleep(.012) # 1.2 seconds at the test's 1/100 time scale.
  broker=SimpleNamespace(check=slow_check,_check_current=lambda:None)
  scoped=ScopedTransport(broker,lambda:None);scoped._transport=self.manager._transport
  self.manager._transport=scoped;self.host.connection.credentials=broker
  original=asyncio.timeout
  with patch('nas_host.asyncio.timeout',side_effect=lambda seconds:original(seconds*.01)):
   text=await self.call(self.args('read_text',**{k:entry[k] for k in ('object_ref','revision','size')},max_bytes=65536))
  self.assertEqual(text['text'],self.raw.decode())
  self.assertEqual(self.transport_calls,['stat','read','stat'])
  self.assertEqual(len(self.checks),14) # Every original authorization boundary remains.
 async def test_composite_budget_is_still_capped_by_original_authority_deadline(self):
  found=await self.call(self.args());entry=found['entries'][0];self.transport_calls.clear()
  original=asyncio.timeout;budgets=[]
  def scaled(seconds):budgets.append(seconds);return original(seconds*.01)
  self.host.authority.deadline=time.monotonic()+.04
  async def slow_check(stage):await asyncio.sleep(.012)
  self.host.connection.credentials.check=slow_check
  with patch('nas_host.asyncio.timeout',side_effect=scaled):
   with self.assertRaises(NASConnectionError) as caught:
    await self.call(self.args('read_text',**{k:entry[k] for k in ('object_ref','revision','size')}))
  self.assertEqual(caught.exception.code,'nas_timeout')
  self.assertTrue(budgets and 0<budgets[0]<.04)
  self.assertEqual(self.transport_calls,[])
 async def test_individual_provider_timeout_remains_independent(self):
  found=await self.call(self.args());entry=found['entries'][0];self.transport_calls.clear()
  self.manager.config=self.manager.config.model_copy(update={'operation_timeout_seconds':.03})
  original=self.manager._transport.request
  async def slow_provider(op,payload):
   await asyncio.sleep(.1)
   return await original(op,payload)
  self.manager._transport.request=slow_provider
  with self.assertRaises(NASConnectionError) as caught:
   await self.call(self.args('read_text',**{k:entry[k] for k in ('object_ref','revision','size')}))
  self.assertEqual(caught.exception.code,'nas_timeout')
  self.assertEqual(self.transport_calls,[])
 async def test_bad_scope_and_invalid_parameters_have_zero_provider_calls(self):
  for args in [self.args(connection_epoch='f'*32),self.args(root='other'),self.args(recursive=False),self.args(config_generation=True),self.args(keyword='bad\n'),self.args(directory_ref='a'*64+'\n')]:
   with self.subTest(args=args),self.assertRaises(NASConnectionError):await self.call(args)
  self.assertEqual(self.transport_calls,[])
 async def test_cursor_binds_query_and_live_epoch_no_reconnection(self):
  first=await self.call(self.args(limit=1));self.assertIsNone(first['next_cursor'])
  self.manager._epoch='f'*32
  with self.assertRaises(NASConnectionError) as caught:await self.call(self.args())
  self.assertEqual(caught.exception.code,'nas_source_changed');self.assertEqual(self.transport_calls,['list','list'])
 async def test_original_nonrecursive_search_unchanged(self):
  page=await self.call(dict(operation='search',keyword='note',limit=32))
  self.assertFalse(page['recursive']);self.assertEqual(page['entries'],[]);self.assertEqual(self.transport_calls,['list'])
 async def test_no_connection_or_revoked_authority_never_reconnects(self):
  self.host.authority.revoked=True
  with self.assertRaises(NASConnectionError):await self.call(self.args())
  self.assertEqual(self.transport_calls,[])
if __name__=='__main__':unittest.main()
