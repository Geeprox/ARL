"""Synthetic directory trees and byte reads, plus actual manager integration.
No live NAS, credentials, Keychain, activation or public tool registration.
"""
import asyncio
import base64
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / 'integrations/nas/runtime')]
from homeplane.nas_connection.file_search import ScopedFileReader
from homeplane.nas_connection.contracts import NASConnectionError, NASConnectionConfig
from homeplane.nas_connection.manager import NASConnectionManager


def ref(value): return hashlib.sha256(value.encode()).hexdigest()


def row(path, kind='file', size=0):
    return dict(path=path, object_ref=ref(path), revision=ref('rev:' + path), kind=kind, size=size)


class Peer:
    def __init__(self):
        self.fence = dict(source_ref='synthetic', config_generation=1, connection_epoch='e' * 32)
        self.tree = {None: []}; self.raw = b''; self.calls = []; self.valid = True
        self.now = 0.; self.incomplete = False; self.corrupt = None

    async def validate(self, *fence):
        return self.valid and fence == tuple(self.fence.values())

    def reader(self):
        return ScopedFileReader(**self.fence, operation=self.operation, validate_context=self.validate, clock=lambda: self.now)

    def reference(self): return dict(self.fence, object_ref=ref('test.txt'), revision=ref('rev:test.txt'), size=len(self.raw))

    async def operation(self, value):
        self.calls.append(value)
        if value['operation'] == 'list':
            rows = self.tree.get(value.get('directory_ref'), [])
            offset = int(value.get('cursor', '0'), 16); end = offset + value['limit']
            result = dict(self.fence, operation='list', entries=rows[offset:end],
                          next_cursor=f'{end:032x}' if end < len(rows) else None,
                          enumeration_complete=end >= len(rows) and not self.incomplete)
        else:
            start, length = value['offset'], value['length']; data = self.raw[start:start+length]; end = start + len(data)
            result = dict(self.fence, operation='read', entry=row('test.txt', size=len(self.raw)),
                          data_base64=base64.b64encode(data).decode(), offset=start, length=length,
                          bytes_read=len(data), eof=end==len(self.raw), next_offset=None if end==len(self.raw) else end)
        if self.corrupt: self.corrupt(result)
        return result


class Checks(unittest.IsolatedAsyncioTestCase):
    def setUp(self): self.peer = Peer(); self.reader = self.peer.reader()

    async def fault(self, code, call):
        with self.assertRaises(NASConnectionError) as caught: await call
        self.assertEqual(caught.exception.code, code)

    async def test_search_is_name_only_files_only_and_unicode_normalized(self):
        self.peer.tree[None] = [row('scope/Cafe\u0301.TXT'), row('scope/Café-folder','directory'), row('scope/other.txt')]
        result = await self.reader.search_page(keyword='CAFÉ')
        self.assertEqual([r['path'] for r in result['entries']], ['scope/Cafe\u0301.TXT'])
        self.assertTrue(result['enumeration_complete']); self.assertFalse(result['recursive'])
        self.assertTrue(all(c['operation']=='list' for c in self.peer.calls))

    async def test_recursive_search_and_bound_cursor_no_restart(self):
        folder = row('scope/sub', 'directory')
        self.peer.tree[None] = [folder] + [row(f'scope/hit-{i}.txt') for i in range(40)]
        self.peer.tree[folder['object_ref']] = [row('scope/sub/deep-hit.txt')]
        result = await self.reader.search_page(keyword='hit', recursive=True, limit=7)
        seen = result['entries'][:]; token = result['next_cursor']
        while result['next_cursor']:
            result = await self.reader.search_page(keyword='hit', recursive=True, limit=7, cursor=result['next_cursor'])
            seen.extend(result['entries'])
        self.assertEqual(len(seen),41); self.assertEqual(len({r['object_ref'] for r in seen}),41)
        self.assertTrue(result['enumeration_complete']); self.assertEqual(len(self.peer.calls),3)
        await self.fault('nas_cursor_expired', self.reader.search_page(keyword='hit',recursive=True,limit=7,cursor=token))

    async def test_cursor_scope_query_and_expiry_and_invalidation(self):
        self.peer.tree[None] = [row(f'hit{i}') for i in range(2)]
        result = await self.reader.search_page(keyword='hit',limit=1)
        await self.fault('nas_cursor_expired', self.reader.search_page(keyword='other',limit=1,cursor=result['next_cursor']))
        result = await self.reader.search_page(keyword='hit',limit=1)
        self.peer.now=121
        await self.fault('nas_cursor_expired', self.reader.search_page(keyword='hit',limit=1,cursor=result['next_cursor']))
        count=len(self.peer.calls); self.peer.valid=False
        await self.fault('nas_source_changed', self.reader.search_page(keyword='hit'))
        self.assertEqual(count,len(self.peer.calls))

    async def test_provider_incomplete_never_claims_no_match_complete(self):
        self.peer.incomplete=True
        result=await self.reader.search_page(keyword='absent',recursive=True)
        self.assertEqual(result['entries'],[]); self.assertFalse(result['enumeration_complete'])
        self.assertIsNone(result['next_cursor']); self.assertEqual(result['stopped_reason'],'provider_incomplete')

    async def test_scan_budget_is_finite_and_explicit(self):
        self.peer.tree[None] = [row(f'other{i}') for i in range(2050)]
        result=await self.reader.search_page(keyword='absent',recursive=True)
        self.assertEqual(result['pages'],4); self.assertIsNotNone(result['next_cursor'])
        while result['next_cursor']:
            result=await self.reader.search_page(keyword='absent',recursive=True,cursor=result['next_cursor'])
        self.assertEqual(result['total_pages'],65); self.assertEqual(result['total_scanned_count'],2050)
        self.assertTrue(result['enumeration_complete']); self.assertIsNone(result['stopped_reason'])

    async def test_directory_and_depth_limits_do_not_silently_skip(self):
        self.peer.tree[None]=[row(f'd{i}','directory') for i in range(140)]
        result=await self.reader.search_page(keyword='absent',recursive=True)
        while result['next_cursor']:
            result=await self.reader.search_page(keyword='absent',recursive=True,cursor=result['next_cursor'])
        self.assertEqual(result['stopped_reasons'],[]); self.assertTrue(result['enumeration_complete'])
        self.peer.tree={}; parent=None
        for i in range(10):
            item=row(f'd{i}','directory'); self.peer.tree[parent]=[item]; parent=item['object_ref']
        result=await self.reader.search_page(keyword='absent',recursive=True)
        while result['next_cursor']:
            result=await self.reader.search_page(keyword='absent',recursive=True,cursor=result['next_cursor'])
        self.assertEqual(result['stopped_reasons'],[]); self.assertEqual(result['total_pages'],11)

    async def test_read_complete_utf8_preserves_original_bytes(self):
        self.peer.raw=('汉字🙂\n' * 3500).encode()
        result=await self.reader.read_utf8(self.peer.reference())
        self.assertTrue(result['complete']); self.assertEqual(result['text'],self.peer.raw.decode())
        self.assertEqual(base64.b64decode(result['data_base64']),self.peer.raw)
        self.assertEqual(result['sha256_of_returned_bytes'],hashlib.sha256(self.peer.raw).hexdigest())
        self.assertFalse(result['downloadable_artifact']); self.assertEqual(len(self.peer.calls),2)

    async def test_utf8_partial_codepoint_retained_and_no_replacement(self):
        self.peer.raw='a🙂z'.encode()
        result=await self.reader.read_utf8(self.peer.reference(),max_bytes=3)
        self.assertEqual(result['text'],'a'); self.assertEqual(base64.b64decode(result['undecoded_tail_base64']),b'')
        self.assertEqual(result['next_offset'],1); self.assertTrue(result['truncated']); self.assertFalse(result['complete'])
        self.assertEqual(result['stopped_reason'],'text_byte_budget')

    async def test_binary_invalid_utf8_and_empty_files(self):
        for data in (b'\xff\x00', b'ok\x00binary', b'\xf0\x9f'):
            self.peer.raw=data; result=await self.reader.read_utf8(self.peer.reference())
            self.assertIsNone(result['text']); self.assertEqual(result['stopped_reason'],'binary_or_invalid_utf8')
            self.assertEqual(base64.b64decode(result['data_base64']),data)
        self.peer.raw=b''; result=await self.reader.read_utf8(self.peer.reference())
        self.assertEqual(result['text'],''); self.assertTrue(result['complete'])
        self.assertEqual(self.peer.calls[-1]['length'],1)

    async def test_large_file_prefix_and_escaped_text_output_budget(self):
        self.peer.raw=b'a' * (2 * 1048576)
        result=await self.reader.read_utf8(self.peer.reference())
        self.assertEqual(result['bytes_read'],65536); self.assertTrue(result['truncated'])
        self.assertEqual(result['next_offset'],65536); self.assertFalse(result['complete'])
        self.peer.raw=b'\x01' * 65536
        result=await self.reader.read_utf8(self.peer.reference())
        self.assertIsNotNone(result['text']); self.assertEqual(result['stopped_reason'],'text_byte_budget')
        self.assertEqual(base64.b64decode(result['data_base64']),self.peer.raw[:result['next_offset']])
        self.assertLess(len(json.dumps(result,ensure_ascii=True).encode()),192*1024-16384)

    async def test_chinese_body_and_real_continuation_preserve_every_character(self):
        self.peer.raw=('中文🙂' * 10000).encode()
        text=[];offset=0
        while True:
            result=await self.reader.read_utf8(self.peer.reference(),offset=offset)
            self.assertEqual(result['offset'],offset)
            self.assertIsNotNone(result['text'])
            text.append(result['text'])
            if result['complete']:break
            self.assertGreater(result['next_offset'],offset)
            offset=result['next_offset']
        self.assertEqual(''.join(text).encode(),self.peer.raw)

    async def test_cursor_capacity_and_cancel_consume_without_retry(self):
        self.peer.tree[None]=[row('hit1'),row('hit2')]
        tokens=[]
        for _ in range(8):
            result=await self.reader.search_page(keyword='hit',limit=1); tokens.append(result['next_cursor'])
        await self.fault('nas_budget_exceeded',self.reader.search_page(keyword='hit',limit=1))
        self.assertEqual(len(self.reader._cursors),8)
        original=self.reader._cursors[tokens[0]]
        # Consume pending then require IO on a larger synthetic directory.
        original.pending.clear(); original.queue.append((None,0,None))
        async def cancelled(_): raise asyncio.CancelledError()
        self.reader.operation=cancelled
        with self.assertRaises(asyncio.CancelledError):
            await self.reader.search_page(keyword='hit',limit=1,cursor=tokens[0])
        await self.fault('nas_cursor_expired',self.reader.search_page(keyword='hit',limit=1,cursor=tokens[0]))
        self.assertFalse(self.reader._active)

    async def test_revision_epoch_byte_eof_corruption_rejected_no_retry(self):
        self.peer.raw=b'hello'
        corruptions=[('nas_source_changed',lambda r:r.update(connection_epoch='f'*32)),
            ('nas_revision_changed',lambda r:r['entry'].update(revision='0'*64)),
            ('nas_transport_failed',lambda r:r.update(eof=False)),
            ('nas_transport_failed',lambda r:r.update(data_base64='aGVsbG8=\n')),
            ('nas_transport_failed',lambda r:r.update(bytes_read=True))]
        for code, mutate in corruptions:
            self.peer.corrupt=mutate; count=len(self.peer.calls)
            await self.fault(code,self.reader.read_utf8(self.peer.reference()))
            self.assertEqual(len(self.peer.calls),count+1)

    async def test_revocation_after_io_and_busy_zero_replay(self):
        self.peer.corrupt=lambda _:setattr(self.peer,'valid',False)
        await self.fault('nas_source_changed',self.reader.search_page(keyword='x'))
        self.peer.corrupt=None; self.peer.valid=True
        gate=asyncio.Event(); original=self.reader.operation
        async def delayed(request): await gate.wait(); return await original(request)
        self.reader.operation=delayed
        active=asyncio.create_task(self.reader.search_page(keyword='x')); await asyncio.sleep(0)
        await self.fault('nas_busy',self.reader.search_page(keyword='x'))
        gate.set(); await active

    async def test_invalid_inputs_no_io_and_no_scope_or_path_selectors(self):
        for values in (dict(keyword=''),dict(keyword='x',directory_ref='../outside'),dict(keyword='x',limit=True),dict(keyword='x',recursive=1)):
            await self.fault('nas_invalid_request',self.reader.search_page(**values))
        for values in (dict(self.peer.reference(),host='outside'),dict(self.peer.reference(),size=True)):
            await self.fault('nas_invalid_request',self.reader.read_utf8(values))
        self.assertEqual(self.peer.calls,[])

    async def test_actual_manager_search_read_with_synthetic_transport(self):
        # Exercise manager's real opaque refs, private paths, paging and
        # stat/read/stat revision checks; no file_operation mock in this test.
        raw='ARL 原文🙂\n'.encode(); config=NASConnectionConfig(source_ref='synthetic',transport='smb',host='synthetic.invalid',share='home',root='ARL-Test',credential_ref='unused',enabled=True)
        class Transport:
            async def request(self,op,payload):
                if op=='list':
                    if payload['path']=='': entries=[dict(path='child',kind='directory',size=0,revision=ref('child'))]
                    else: entries=[dict(path='child/原文.txt',kind='file',size=len(raw),revision=ref('raw'))]
                    return dict(entries=entries,complete=True)
                if op=='stat': return dict(path=payload['path'],kind='file',size=len(raw),revision=ref('raw'))
                if op=='read': return dict(data=base64.b64encode(raw[payload['offset']:payload['offset']+payload['length']]).decode())
                raise AssertionError(op)
        with tempfile.TemporaryDirectory(dir='/tmp') as tmp:
            manager=NASConnectionManager(Path(tmp).resolve()/'unused-state',credential_resolver=None)
            manager.config=config; manager.generation=1; manager._epoch='e'*32; manager._state='online'; manager._transport=Transport()
            async def context(source,generation,epoch):
                return manager.config.source_ref==source and manager.generation==generation and manager._epoch==epoch
            reader=ScopedFileReader(**self.peer.fence,operation=manager.file_operation,validate_context=context)
            published=await manager.file_operation(dict(operation='search',keyword='原文',limit=32))
            self.assertEqual(published['entries'],[]); self.assertFalse(published['recursive'])
            self.assertTrue(published['enumeration_complete'])
            result=await reader.search_page(keyword='原文',recursive=True)
            self.assertTrue(result['enumeration_complete']); self.assertEqual(len(result['entries']),1)
            entry=result['entries'][0]; self.assertEqual(entry['path'],'ARL-Test/child/原文.txt')
            directory=next(key for key,value in manager._objects.items() if value[0]=='child')
            published=await manager.file_operation(dict(operation='search',keyword='原文',directory_ref=directory,limit=32))
            self.assertEqual(published['entries'],[entry]); self.assertFalse(published['recursive'])
            reference=dict(self.peer.fence,**{k:entry[k] for k in ('object_ref','revision','size')})
            result=await reader.read_utf8(reference); self.assertEqual(result['text'],raw.decode())
            self.assertEqual(manager._file_bytes,len(raw))
            manager._epoch='f'*32
            await self.fault('nas_source_changed',reader.read_utf8(reference))


if __name__=='__main__': unittest.main(verbosity=2)
