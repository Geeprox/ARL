"""Composed acceptance: real Tisra app, actual host; no fake/skipped success."""
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import unittest
import uuid
from unittest.mock import patch
from arl.contracts import encode, Fault
from arl.host import make_runtime
from arl.tisra_capture_profiles import production_profiles, attachment_for_profiles, CaptureSourceProfile
from tests.capture_application_host import NativeApplication
from tests.test_capture_process_end_to_end import ProcessFixture, ROOT, process_pin, read_line, request, sha, FIRST_WRITER

BUNDLE = Path(os.environ.get('TISRA_CAPTURE_TEST_BUNDLE', '/nonexistent/Tisra.app'))
EVIDENCE = Path(os.environ.get('TISRA_CAPTURE_ACCEPTANCE_EVIDENCE', '/tmp/tisra-capture-evidence'))

def evidence(name, value, files=None):
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    (EVIDENCE/(name+'.json')).write_bytes(encode(value)+b'\n')
    for filename, raw in (files or {}).items(): (EVIDENCE/filename).write_bytes(raw)

class ApplicationHost:
    upload = ProcessFixture.upload
    submit = ProcessFixture.submit
    wait = ProcessFixture.wait
    result = ProcessFixture.result
    journal = ProcessFixture.journal
    wait_journal_phase = ProcessFixture.wait_journal_phase
    def __init__(self, root, mode='granted'):
        self.root = Path(root).resolve(); self.native_root = self.root/'native'
        self.mode = mode; self.runs = []; self.start()
    def start(self):
        self.stderr_path = self.root/('host-'+str(uuid.uuid4())+'.stderr')
        with self.stderr_path.open('wb') as errors:
            self.host = subprocess.Popen([str(Path(process_pin(os.getpid())['executable'])), '-B', '-m',
                'tests.capture_application_host', '--isolated-test', str(self.root), str(ROOT if self.mode == 'disabled' else BUNDLE), self.mode],
                cwd=ROOT, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errors,
                text=True, bufsize=1, env={'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','PYTHONPATH':str(ROOT),'PYTHONDONTWRITEBYTECODE':'1'})
        try: self.ready = read_line(self.host,55)
        except Exception: raise AssertionError('Host/application launch failed: '+self.stderr_path.read_text()[-8192:])
        if self.ready.get('event') != 'ready':
            self.host.wait(10)
            detail=self.stderr_path.read_text()[-8192:]
            evidence('failed-host-startup', dict(reply=self.ready, stderr=detail))
            for stream in (self.host.stdin, self.host.stdout): stream.close()
            raise AssertionError('Actual-host readiness: '+str(self.ready)+' '+detail)
        self.library_id = self.ready['library_id']; self.instance_id = self.ready['instance_id']; self.runs.append(self.ready)
    def command(self,value):
        try:
            self.host.stdin.write(json.dumps(value)+'\n'); self.host.stdin.flush(); return read_line(self.host,55)
        except BaseException as error:
            evidence('failed-command-'+str(uuid.uuid4()),dict(error_type=type(error).__name__,
                host_exit=self.host.poll(), command_keys=sorted(value)),
                {p.name:p.read_bytes() for p in self.root.glob('*.stderr')})
            raise
    def rpc_reply(self,method,params): return self.command({'method':method,'params':params})
    def rpc(self,method,params):
        reply = self.rpc_reply(method,params)
        if reply.get('ok') is not True: raise AssertionError('Registered RPC rejected: '+str(reply))
        return reply['result']
    def record_count(self):
        with sqlite3.connect(f'file:{self.native_root}/library/ledger.sqlite?mode=ro',uri=True) as db:
            return db.execute('SELECT COUNT(*) FROM records WHERE is_tail=0').fetchone()[0]
    def stop(self):
        if self.host.poll() is None:
            summary = self.command({'command':'stop'}); self.host.wait(25)
            if summary.get('event') != 'stopped' or summary['errors'] or summary['provider_calls'] != 0:
                raise AssertionError('Host shutdown: '+str(summary))
            if not all(summary[k] for k in ('closed','worker_stopped','fd_closed')): raise AssertionError('Capture ownership not safely closed')
            if summary['native_stop'] is not None and summary['native_stop']['forced_termination']:
                raise AssertionError('Native application required forced termination')
            self.runs.append(summary)
        for stream in (self.host.stdin,self.host.stdout): stream.close()
    def restart(self): self.stop(); self.start()
    def preserve(self,name):
        evidence(name+'-lifecycle', self.runs, {p.name:p.read_bytes() for p in self.root.glob('*.stderr')})

class CaptureProfilesTests(unittest.TestCase):
    def test_actual_host_default_profiles_have_no_source_native_worker(self):
        with tempfile.TemporaryDirectory(prefix='tisra-slice-', dir='/private/tmp') as directory:
            f = ApplicationHost(directory, 'disabled')
            try:
                self.assertFalse(f.ready['capture']); self.assertFalse(f.ready['worker'])
                self.assertIsNone(f.ready['source_pid']); self.assertIsNone(f.ready['native_pid'])
                self.assertEqual(f.ready['providers'], [])
            finally: f.stop(); f.preserve('default-production-profiles')
    def test_production_profiles_disabled_without_process_observation_or_models(self):
        self.assertEqual({p.app for p in production_profiles()},{'tisra','mio','friday'})
        self.assertTrue(all(not p.enabled and p.config is None for p in production_profiles()))
        with tempfile.TemporaryDirectory(prefix='cap-profile-',dir='/tmp') as directory:
            attachment = attachment_for_profiles()
            with patch('arl.tisra_capture_host.RegisteredPeerVerifier',side_effect=AssertionError('unexpected observation')):
                runtime = make_runtime(Path(directory),capture_attachment=attachment); attachment.start(runtime)
            self.assertIsNone(runtime.capture); self.assertFalse(runtime.execute_jobs); self.assertIsNone(attachment.supervisor)
            self.assertTrue(all(not runtime.policies[p.app].providers for p in production_profiles()))
            attachment.close()
        with self.assertRaises(Fault):
            attachment_for_profiles((CaptureSourceProfile('tisra',enabled=True),CaptureSourceProfile('mio'),CaptureSourceProfile('friday')))

class CaptureApplicationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not (BUNDLE/'Contents/MacOS/Tisra').is_file(): raise AssertionError('Build real isolated TisraDesktop .app before acceptance; no skips')
    def temporary(self): return tempfile.TemporaryDirectory(prefix='tisra-slice-',dir='/private/tmp')
    def test_disabled_real_application_opens_no_channel_or_journal(self):
        with self.temporary() as directory:
            root = Path(directory)
            app = NativeApplication(root,BUNDLE,dict(mode='create',enabled=False,host=process_pin(os.getpid()),
                library_id=str(uuid.uuid4()),instance_id=str(uuid.uuid4()),registrations=[]))
            try:
                self.assertFalse(app.metadata['capture_enabled']); self.assertTrue(app.metadata['workspace_ready'])
                self.assertFalse((root/'native/capture.sock').exists()); self.assertFalse((root/'native/journal').exists())
                evidence('disabled-real-application',dict(identity=app.identity,metadata=app.metadata))
            finally:
                stopped=app.stop(); evidence('disabled-real-application-shutdown',stopped)
                self.assertFalse(stopped['forced_termination'])
    def test_disabled_actual_host_launches_no_source_native_or_worker(self):
        with self.temporary() as directory:
            f = ApplicationHost(directory,'disabled')
            try:
                self.assertFalse(f.ready['capture']); self.assertFalse(f.ready['worker'])
                self.assertIsNone(f.ready['source_pid']); self.assertIsNone(f.ready['native_pid'])
            finally: f.stop(); f.preserve('disabled-host')
    def test_capture_retry_acknowledged_app_and_host_restart_preserve_exact_bytes(self):
        with self.temporary() as directory:
            f = ApplicationHost(directory)
            try:
                capture_id,raw = str(uuid.uuid4()),request(); admitted = f.submit(capture_id,raw)
                status = f.wait(capture_id,admitted['binding']['admission_sha256']); self.assertEqual(status['state'],'succeeded')
                result = f.result(capture_id,status); inner = json.loads(result)
                self.assertEqual(inner['source']['writer'],FIRST_WRITER); self.assertEqual(len(inner['contributions']),1)
                self.assertEqual(f.record_count(),2); self.assertEqual(f.journal(capture_id)['acknowledged'],1)
                self.assertEqual(f.journal(capture_id)['outer_receipt_hash'],sha(encode(status['receipt'])))
                peer = json.loads(raw); peer['writer'] = dict(participant_id='synthetic-human',display_name='Synthetic Human',actor_kind='human'); peer['contributions']=[]
                peer_id = str(uuid.uuid4()); peer_admitted = f.submit(peer_id,encode(peer)); peer_status = f.wait(peer_id,peer_admitted['binding']['admission_sha256'])
                peer_receipt = json.loads(f.result(peer_id,peer_status))
                self.assertEqual(peer_receipt['source']['writer'],FIRST_WRITER); self.assertEqual(peer_receipt['source']['record_id'],inner['source']['record_id'])
                self.assertEqual(f.record_count(),2)
                # Preserve per-attempt stderr/exit state at the prior reopen boundary.
                reopens = [f.command({'command':'restart_native'}) for _ in range(3)]
                self.assertTrue(all(p['restarted'] for p in reopens)); self.assertEqual(f.result(capture_id,status),result)
                f.restart(); retried = f.submit(capture_id,raw)
                self.assertEqual(retried['receipt'],status['receipt']); self.assertEqual(f.result(capture_id,retried),result); self.assertEqual(f.record_count(),2)
                with sqlite3.connect(f'file:{f.native_root}/library/ledger.sqlite?mode=ro',uri=True) as db:
                    schema = db.execute('PRAGMA user_version').fetchone()[0]; stored = db.execute('SELECT id,source,document FROM records WHERE is_tail=0 ORDER BY id').fetchall()
                self.assertEqual(schema,23)
                evidence('completed-slice',dict(capture_request_id=capture_id,binding=status['binding'],outer_receipt=status['receipt'],
                    result_sha256=sha(result),result_bytes=len(result),ledger_records=2,native_acknowledged=1,storage_schema=schema,
                    source_native_host_restarted=True,exact_bytes_preserved=True,reopens=reopens,stored_records=stored),
                    {'completed-request.json':raw,'completed.receipt.json':result,'completed.outer-receipt.json':encode(status['receipt'])})
            finally: f.stop(); f.preserve('completed')
    def test_independent_native_and_host_source_revocation(self):
        with self.temporary() as directory:
            f = ApplicationHost(directory)
            try:
                self.assertEqual(f.command({'command':'revoke_native'})['command'],'revoked')
                capture_id = str(uuid.uuid4()); admitted = f.submit(capture_id,request()); held = f.wait(capture_id,admitted['binding']['admission_sha256'])
                self.assertEqual(held['state'],'needs_review'); self.assertEqual(f.record_count(),0)
                f.command({'command':'revoke_source'}); denied = f.rpc_reply('capture.capabilities.v1',{'library_id':f.library_id})
                self.assertEqual(denied,{'ok':False,'error':'app_identity_unverified'})
                evidence('revocation',dict(native_held=held,source_denied=denied,ledger_records=0))
            finally: f.stop(); f.preserve('revocation')
    def test_cancellation_after_native_write_holds_without_receipt_publication(self):
        with self.temporary() as directory:
            f = ApplicationHost(directory)
            try:
                f.command({'command':'pause_after_capture'}); capture_id = str(uuid.uuid4()); admitted = f.submit(capture_id,request())
                self.assertTrue(f.command({'command':'await_capture'})['captured'])
                binding = dict(capture_request_id=capture_id,admission_sha256=admitted['binding']['admission_sha256'])
                cancelled = f.rpc('capture.cancel.v1',binding); f.command({'command':'release_capture'}); held = f.wait(capture_id,binding['admission_sha256'])
                self.assertEqual(held['state'],'needs_review'); self.assertEqual(f.record_count(),2); self.assertIsNone(held['receipt']['result_ref'])
                f.wait_journal_phase(capture_id,'needs_review'); f.restart(); again = f.rpc('capture.status.v1',binding)
                self.assertEqual(again['state'],'needs_review'); self.assertEqual(f.record_count(),2)
                evidence('cancelled-slice-hold',dict(cancelled=cancelled,restart=again,ledger_records=2,replayed=False))
            finally: f.stop(); f.preserve('cancelled')
    def test_lost_ack_before_and_after_commit_survives_app_and_host_restarts(self):
        for where in ('before','after'):
            with self.subTest(where=where),self.temporary() as directory:
                f = ApplicationHost(directory)
                try:
                    f.command({'command':'arm_lost_ack','where':where}); capture_id,raw = str(uuid.uuid4()),request(); admitted = f.submit(capture_id,raw)
                    binding = dict(capture_request_id=capture_id,admission_sha256=admitted['binding']['admission_sha256'])
                    held = f.wait(capture_id,binding['admission_sha256']); self.assertEqual(held['state'],'needs_review'); self.assertEqual(f.record_count(),2)
                    self.assertIsNone(held['receipt']['result_ref']); f.wait_journal_phase(capture_id,'needs_review')
                    f.command({'command':'restart_native'}); f.restart(); again = f.rpc('capture.status.v1',binding)
                    upload = f.rpc_reply('capture.upload.begin.v2',dict(capture_request_id=capture_id,library_id=f.library_id,sha256=sha(raw),byte_count=len(raw)))
                    self.assertEqual(upload,{'ok':False,'error':'capture_upload_cancelled'}); self.assertEqual(again['state'],'needs_review')
                    self.assertEqual(f.record_count(),2); self.assertEqual(f.journal(capture_id)['phase'],'needs_review')
                    evidence('lost-ack-'+where,dict(arl_state=held['state'],restart=again,retry_upload=upload,native_phase='needs_review',ledger_records=2,replayed=False))
                finally: f.stop(); f.preserve('lost-ack-'+where)

if __name__ == '__main__': unittest.main()
