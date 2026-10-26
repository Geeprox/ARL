"""Offline candidate E2E: exact requests -> approval -> real journals/algorithms
-> real SMB wire DTOs with synthetic peer only -> checked range bytes.
No sockets, Keychain, saved user configuration, Moments, mounts or real NAS.
"""
import base64
from dataclasses import replace
import hashlib
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest
import uuid
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / 'integrations/nas/runtime'), str(ROOT), str(ROOT / 'tests')]
from homeplane.nas_connection import file_operations as files
from homeplane.nas_connection import file_mutation_smb as smb
from homeplane.nas_connection.file_transfer import FileTransfer, CHUNK_BYTES, collect_download
import smb_upload_new
from arl_nas_upload_new.source import SealedSource
from arl_nas_upload_new.contracts import UploadFault, OwnerBinding
from test_smb_upload_new_medium import Server as UploadServer, Open as UploadOpen

OBSERVATIONS = []


def attachment(raw=b'ARL general NAS offline fixture\n'):
    return dict(transfer_kind='inline_base64', name='fixture.txt', size=len(raw),
                sha256=hashlib.sha256(raw).hexdigest(), data_base64=base64.b64encode(raw).decode(),
                expires_at=time.time() + 90)


def wire(op='mkdir', **values):
    result = dict(operation=op, operation_id=str(uuid.uuid4()), source_ref='synthetic',
                  config_generation=1, connection_epoch='e' * 32, name='fixture.txt')
    if op != 'download': result['directory_ref'] = None
    if op == 'upload_new': result['attachment'] = attachment()
    if op in {'move', 'download'}: result.update(object_ref='a' * 64, revision='b' * 64)
    if op == 'download': result['size'] = 0
    result.update(values)
    return result


class Server(UploadServer):
    def _stat_handle(self, path, handle):
        row = handle.row
        return dict(path=path, kind='directory' if row['directory'] else 'file',
                    size=len(row['data']), modified_ns=row['change'],
                    revision=hashlib.sha256(repr((row['index'], len(row['data']), row['change'])).encode()).hexdigest())


class Open(UploadOpen):
    def create(self, impersonation, access, attrs, share, disposition, options):
        # Model symmetric share checks, including DELETE on the source handle.
        for other in self.server.opens:
            if not other.connected or other.path != self.path: continue
            for mask, right in ((smb.Access.FILE_READ_DATA | smb.Access.FILE_EXECUTE, smb.ShareAccess.FILE_SHARE_READ),
                                (smb.Access.FILE_WRITE_DATA | smb.Access.FILE_APPEND_DATA, smb.ShareAccess.FILE_SHARE_WRITE),
                                (smb.Access.DELETE, smb.ShareAccess.FILE_SHARE_DELETE)):
                if access & mask and not other.share & right or other.access & mask and not share & right:
                    raise PermissionError('synthetic share conflict')
        if disposition == smb.CreateDisposition.FILE_CREATE and options & smb.CreateOptions.FILE_DIRECTORY_FILE:
            if self.path in self.server.files: raise FileExistsError()
            self.server.files[self.path] = dict(directory=True, data=bytearray(), index=len(self.server.files)+1, change=1)
            # Call common fixture's OPEN path; directory creation has no write-through file option.
            disposition = smb.CreateDisposition.FILE_OPEN
        return super().create(impersonation, access, attrs, share, disposition, options)


class Checks(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='arl-nas-files-offline-', dir='/tmp')
        self.home = Path(self.tmp.name)
        self.home.chmod(0o700)
        jhome = self.home / 'journal'; jhome.mkdir(mode=0o700)
        fd = os.open(jhome, os.O_RDONLY | os.O_DIRECTORY)
        self.journal = files.FileOperationJournal(fd, verify_seal=lambda: None); os.close(fd)
        self.server = Server()
        self.binding = OwnerBinding('a'*64, 'b'*64, 'c'*32, 1)
        self.fence = files.ScopeFence('synthetic', 1, 'e'*32)
        self.media = []
        self.sources = []
        self.calls = []
        self.revoked = False
        self.patch = patch.multiple(smb, Open=Open); self.patch.start()
        self.upload_patch = patch.object(smb_upload_new, 'Open', Open); self.upload_patch.start()

    def tearDown(self):
        for medium in self.media: medium.close()
        for source in self.sources: source.close()
        self.journal.close(); self.patch.stop(); self.upload_patch.stop(); self.tmp.cleanup()

    def plan(self, value):
        def resolve(ref, kind, revision):
            if kind == 'directory': return 'child'
            return 'fixture.txt'
        return files.capture_plan(value, fence=self.fence, binding=self.binding, resolve=resolve)

    def approval(self, plan):
        def verify(captured, stage):
            self.assertIs(captured, plan)
            if self.revoked: raise UploadFault('revoked')
        return files.MutationApproval(plan=plan, verify=verify, consume=lambda p: self.calls.append(p.operation))

    def medium(self, plan):
        medium = (smb_upload_new.SMBUploadNewMedium if plan.operation == 'upload_new' else smb.SMBFileMutationMedium)(
            reader=self.server, plan=plan.upload, verify=lambda _: None, deadline=time.monotonic()+25)
        self.media.append(medium)
        return medium

    def source(self, raw):
        path = self.home / ('source-' + str(uuid.uuid4()))
        path.write_bytes(raw); path.chmod(0o600)
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        source = SealedSource(fd, verify_pin=lambda: None); os.close(fd)
        self.sources.append(source)
        return source

    def run_plan(self, plan, **kwargs):
        medium = self.medium(plan)
        try:
            return files.mutate(plan, approval=self.approval(plan), journal=self.journal, medium=medium, **kwargs)
        finally: medium.close()

    def assertFault(self, code, callback):
        with self.assertRaises(UploadFault) as caught: callback()
        self.assertEqual(caught.exception.code, code)

    def test_contract_rejects_selectors_paths_bool_and_unsupported_ops(self):
        for bad in (wire(host='outside.invalid'), wire(name='../outside'), wire(name='CON.txt'),
                    wire(name='name.'), wire(name='.arl-upload-secret'), wire(name='folder/name'),
                    wire(config_generation=True), wire(operation='delete'), wire(directory_ref='/tmp/local'),
                    wire(connection_epoch='f'*64), wire(operation_id='not-uuid')):
            self.assertFault('invalid_plan', lambda bad=bad: files.request(bad))

    def test_attachment_bytes_hash_expiry_and_platform_boundary(self):
        raw = b'\x00\xff\x01'
        self.assertEqual(files.attachment_bytes(attachment(raw)), raw)
        self.assertFault('source_changed', lambda: files.attachment_bytes(dict(attachment(raw), sha256='0'*64)))
        self.assertFault('expired', lambda: files.attachment_bytes(dict(attachment(), expires_at=time.time()-1)))
        self.assertFault('expired', lambda: files.attachment_bytes(dict(attachment(), expires_at=float('inf'))))
        self.assertFault('invalid_plan', lambda: files.attachment_bytes(dict(attachment(), size=True)))
        for value in ({'local_path':'/tmp/file'}, {'url':'https://example.invalid/file'}, {'file_id':'chatgpt-file'}):
            self.assertFault('unsupported', lambda value=value: files.attachment_bytes(value))

    def test_scope_fence_checked_before_resolving_and_no_path_escape(self):
        calls=[]
        self.assertFault('source_changed', lambda: files.capture_plan(wire(config_generation=2), fence=self.fence,
            binding=self.binding, resolve=lambda *args:calls.append(args)))
        self.assertEqual(calls, [])
        self.assertFault('invalid_plan', lambda: files.capture_plan(wire(directory_ref='d'*64), fence=self.fence,
            binding=self.binding, resolve=lambda *args:'../Moments'))

    def test_default_closed_even_with_selected_read_scope(self):
        plan=self.plan(wire())
        result=files.mutate(plan, approval=files.MutationApproval(), journal=None, medium=None)
        self.assertEqual((result['status'], result['failure']), ('held','unsupported'))
        self.assertEqual(self.server.opens, [])

    def test_offline_upload_mkdir_move_download_small_loop(self):
        raw=b'ARL attachment to NAS to checked download\x00\xff'
        up=self.plan(wire('upload_new', attachment=attachment(raw)))
        with files.seal_attachment(attachment(raw), journal=self.journal, verify=lambda:None) as source:
            uploaded=self.run_plan(up, source=source)
        self.assertFalse(any(p.name.startswith('file_input_') for p in (self.home/'journal').iterdir()))
        self.assertEqual((uploaded['status'],uploaded['content_sha256']),('committed',hashlib.sha256(raw).hexdigest()))
        made=self.run_plan(self.plan(wire(name='child')))
        self.assertEqual(made['status'],'committed')
        source_open=Open(self.server.tree,'approved/fixture.txt')
        source_open.row=self.server.files['approved/fixture.txt']
        revision=self.server._stat_handle('fixture.txt',source_open)['revision']
        move=self.plan(wire('move',directory_ref='d'*64,name='moved.txt',revision=revision))
        moved=self.run_plan(move)
        self.assertEqual(moved['status'],'committed')
        self.assertNotIn('approved/fixture.txt',self.server.files)
        self.assertEqual(bytes(self.server.files['approved/child/moved.txt']['data']),raw)
        download_request=wire('download',revision=moved['entry']['revision'],name='moved.txt',size=len(raw))
        def read(args):
            data=bytes(self.server.files['approved/child/moved.txt']['data'])[args['offset']:args['offset']+args['length']]
            return dict(operation='read',**{k:args[k] for k in ('source_ref','config_generation','connection_epoch')},
                entry=dict(object_ref=args['object_ref'],revision=args['revision'],size=len(raw),kind='file'),
                offset=args['offset'],length=args['length'],bytes_read=len(data),data_base64=base64.b64encode(data).decode(),
                eof=True,next_offset=None)
        got=files.download(download_request,read=read,verify=lambda:None)
        self.assertEqual(base64.b64decode(got['data_base64']),raw)
        self.assertEqual(got['sha256'],uploaded['content_sha256'])
        self.assertFalse(got['downloadable_artifact'])
        self.assertNotIn('url',got)
        self.assertEqual(self.calls,['upload_new','mkdir','move'])

    def test_mkdir_collision_never_overwrites(self):
        first=self.plan(wire(name='child'))
        self.assertEqual(self.run_plan(first)['status'],'committed')
        self.assertEqual(self.run_plan(self.plan(wire(name='child')))['failure'],'target_reserved')
        self.assertTrue(self.server.files['approved/child']['directory'])

    def test_existing_destination_file_preserved(self):
        self.server.files['approved/fixture.txt']=dict(directory=False,data=bytearray(b'existing'),index=7,change=1)
        got=self.run_plan(self.plan(wire()))
        self.assertEqual((got['status'],got['failure']),('rejected','target_exists'))
        self.assertEqual(bytes(self.server.files['approved/fixture.txt']['data']),b'existing')

    def test_revoked_before_io_and_failed_directory_flush_before_effect(self):
        plan=self.plan(wire())
        self.revoked=True
        self.assertEqual(self.run_plan(plan)['failure'],'revoked')
        self.assertEqual(self.server.opens,[])
        self.revoked=False;self.server.fail_directory_flush=True
        self.assertEqual(self.run_plan(self.plan(wire()))['status'],'held')
        self.assertEqual(set(self.server.files),{'approved'})

    def test_stale_revision_before_move_and_no_directory_move(self):
        self.server.files['approved/fixture.txt']=dict(directory=False,data=bytearray(b'old'),index=7,change=1)
        got=self.run_plan(self.plan(wire('move',name='new.txt')))
        self.assertEqual((got['status'],got['failure']),('held','source_changed'))
        self.assertEqual(self.server.renames,[])

    def test_uncertain_create_never_replayed_even_new_operation_id(self):
        plan=self.plan(wire(name='child'))
        medium=self.medium(plan)
        original=medium.mkdir
        def lost_reply(*args,**kwargs):
            original(*args,**kwargs)
            raise ConnectionError('synthetic reply lost')
        medium.mkdir=lost_reply
        got=files.mutate(plan,approval=self.approval(plan),journal=self.journal,medium=medium)
        medium.close()
        self.assertEqual(got['status'],'uncertain')
        self.assertTrue(self.server.files['approved/child']['directory'])
        self.assertEqual(self.run_plan(plan)['failure'],'operation_consumed')
        self.assertEqual(self.run_plan(self.plan(wire(name='child')))['failure'],'target_reserved')
        self.assertFalse(got['retry_allowed'])

    def test_uncertain_move_source_reserved_across_new_ids(self):
        self.server.files['approved/fixture.txt']=dict(directory=False,data=bytearray(b'old'),index=7,change=1)
        opened=Open(self.server.tree,'approved/fixture.txt');opened.row=self.server.files['approved/fixture.txt']
        revision=self.server._stat_handle('fixture.txt',opened)['revision']
        plan=self.plan(wire('move',name='new.txt',revision=revision))
        self.server.fail_postrename=True
        got=self.run_plan(plan)
        self.assertEqual(got['status'],'uncertain')
        again=self.run_plan(self.plan(wire('move',name='other.txt',revision=revision)))
        self.assertEqual(again['failure'],'operation_consumed')
        self.assertEqual(len(self.server.renames),1)

    def test_download_empty_multichunk_and_changed_epoch(self):
        for raw in (b'',bytes(range(256))*128):
            value=wire('download',size=len(raw)); calls=[]
            def read(args):
                calls.append(args)
                data=raw[args['offset']:args['offset']+args['length']]
                end=args['offset']+len(data)
                return dict(operation='read',source_ref=value['source_ref'],config_generation=1,connection_epoch='e'*32,
                    entry=dict(object_ref=value['object_ref'],revision=value['revision'],size=len(raw),kind='file'),
                    offset=args['offset'],length=args['length'],bytes_read=len(data),data_base64=base64.b64encode(data).decode(),
                    eof=end==len(raw),next_offset=None if end==len(raw) else end)
            got=files.download(value,read=read,verify=lambda:None)
            self.assertEqual(base64.b64decode(got['data_base64']),raw)
            self.assertEqual(len(calls),max(1,len(raw)//files.READ_CHUNK_BYTES))
            self.assertFault('source_changed',lambda:files.download(value,read=lambda args:dict(read(args),connection_epoch='f'*32),verify=lambda:None))
            self.assertFault('invalid_reply',lambda:files.download(value,read=lambda args:dict(read(args),bytes_read=True),verify=lambda:None))

    def test_ancestor_swap_blocked_during_mutation(self):
        self.server.root='approved/sub';self.server.swap_on_child_open=True
        self.server.files['approved/sub']=dict(directory=True,data=bytearray(),index=2,change=1)
        got=self.run_plan(self.plan(wire(name='child')))
        self.assertEqual(got['status'],'committed')
        self.assertFalse(self.server.outside)
        self.assertTrue(self.server.swaps)
        self.assertTrue(all(value is False for value in self.server.swaps))

    def test_one_mebibyte_chunk_ref_upload_and_download(self):
        raw=bytes(range(256))*4096
        sha=hashlib.sha256(raw).hexdigest()
        value=wire('upload_new');value.pop('attachment')
        transfer=FileTransfer(journal=self.journal,operation_id=value['operation_id'],fence=self.fence,
            name=value['name'],size=len(raw),sha256=sha,verify=lambda:None)
        self.addCleanup(transfer.close)
        context=dict(ref=transfer.ref,operation_id=value['operation_id'],fence=self.fence)
        max_frame=0
        for offset in range(0,len(raw),CHUNK_BYTES):
            chunk=raw[offset:offset+CHUNK_BYTES]
            frame=dict(offset=offset,data_base64=base64.b64encode(chunk).decode(),sha256=hashlib.sha256(chunk).hexdigest())
            # Full MCP -> OwnerReadWire request wrapper remains below 65536.
            envelope={'tool':'mio_nas_transfer_chunk','arguments':dict(frame,transfer_ref=transfer.ref,operation_id=value['operation_id'])}
            max_frame=max(max_frame,len(files.canonical(envelope)))
            self.assertLess(len(files.canonical(envelope)),65536)
            transfer.append(**context,**frame)
        metadata=transfer.finish(**context)
        self.assertTrue(metadata['complete']);self.assertFalse(metadata['downloadable_artifact'])
        value.update(transfer_ref=transfer.ref,size=len(raw),sha256=sha)
        plan=files.capture_plan(value,fence=self.fence,binding=self.binding,resolve=lambda *args:'',transfer=transfer)
        with transfer.claim_source(**context) as source:
            uploaded=self.run_plan(plan,source=source)
        self.assertEqual(uploaded['status'],'committed')
        self.assertFault('operation_consumed',lambda:transfer.metadata(transfer.ref,value['operation_id'],self.fence))
        self.assertEqual(bytes(self.server.files['approved/fixture.txt']['data']),raw)
        down=wire('download',size=len(raw))
        reads=[]
        def read(args):
            reads.append(args)
            part=raw[args['offset']:args['offset']+args['length']];end=args['offset']+len(part)
            return dict(operation='read',source_ref='synthetic',config_generation=1,connection_epoch='e'*32,
                entry=dict(object_ref=down['object_ref'],revision=down['revision'],size=len(raw),kind='file'),
                offset=args['offset'],length=args['length'],bytes_read=len(part),data_base64=base64.b64encode(part).decode(),
                eof=end==len(raw),next_offset=None if end==len(raw) else end)
        output=collect_download(down,journal=self.journal,read=read,verify=lambda:None)
        self.addCleanup(output.close)
        outgoing=dict(ref=output.ref,operation_id=down['operation_id'],fence=self.fence)
        self.assertEqual(output.sha256,sha)
        returned=[]
        for offset in range(0,len(raw),CHUNK_BYTES):
            page=output.read_chunk(**outgoing,offset=offset)
            self.assertLess(len(files.canonical(page)),65536)
            returned.append(base64.b64decode(page['data_base64']))
        self.assertEqual(hashlib.sha256(b''.join(returned)).hexdigest(),sha)
        self.assertEqual(len(reads),32)
        self.assertLess(max_frame,65536)
        OBSERVATIONS.append({'check':'one_mib_chunk_transfer','file_bytes':len(raw),
            'chunk_bytes':CHUNK_BYTES,'input_chunk_count':len(raw)//CHUNK_BYTES,'download_range_count':len(reads),
            'maximum_owner_request_frame_bytes':max_frame,'owner_request_limit':65536,
            'uploaded_status':uploaded['status'],'upload_sha256':uploaded['content_sha256'],
            'download_sha256':hashlib.sha256(b''.join(returned)).hexdigest(),
            'synthetic_smb_peer':True,'chatgpt_artifact_published':False})

    def test_transfer_expiry_scope_offset_hash_and_whole_file_caps(self):
        raw=b'abc';now=[10.]
        transfer=FileTransfer(journal=self.journal,operation_id=str(uuid.uuid4()),fence=self.fence,
            name='small.txt',size=3,sha256=hashlib.sha256(raw).hexdigest(),verify=lambda:None,clock=lambda:now[0])
        self.addCleanup(transfer.close)
        args=dict(ref=transfer.ref,operation_id=transfer.operation_id,fence=self.fence)
        self.assertFault('source_changed',lambda:transfer.finish(**args))
        chunk=dict(offset=0,data_base64=base64.b64encode(raw).decode(),sha256=hashlib.sha256(raw).hexdigest())
        self.assertFault('invalid_plan',lambda:transfer.append(**args,**dict(chunk,offset=1)))
        self.assertFault('source_changed',lambda:transfer.append(**args,**dict(chunk,sha256='f'*64)))
        self.assertFault('binding_mismatch',lambda:transfer.append(**dict(args,fence=replace(self.fence,config_generation=2)),**chunk))
        transfer.append(**args,**chunk);transfer.finish(**args)
        os.pwrite(transfer.fd,b'xyz',0)
        self.assertFault('source_changed',lambda:transfer.read_chunk(**args,offset=0))
        now[0]=131.
        self.assertFault('expired',lambda:transfer.read_chunk(**args,offset=0))
        self.assertFault('invalid_plan',lambda:FileTransfer(journal=self.journal,operation_id=str(uuid.uuid4()),fence=self.fence,
            name='large.txt',size=1024*1024+1,sha256='a'*64,verify=lambda:None))


if __name__=='__main__': unittest.main()
