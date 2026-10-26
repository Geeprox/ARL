"""Actual production factories and Handler; synthetic peers/catalog, no provider IO."""
import base64
import hashlib
import json
from pathlib import Path
import socket
import tempfile
import threading
import time
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch
import uuid

from arl.application_models import ICON_METHOD
from arl.codex_execution_options import read_catalog
from arl.codex_server import CodexService, CodexTextAdapter
from arl.compat_host import compose_codex_service, make_runtime
from arl.formal_peer import FormalTisraPeer
from arl.identity import RegisteredPeerVerifier
from arl.service import Handler, MAX_FRAME
from tests.test_application_models import actual_icon

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/tmp'


class ApplicationHostTests(unittest.TestCase):
    def setUp(self):
        OUT.mkdir(parents=True, exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(prefix='apphost-', dir=OUT)
        self.home = Path(self.tmp.name)
        self.live = True
        self.stack = []
        self.runtimes = []
        for method, replacement in [
            ('__call__', lambda peer, conn, app: 'tisra' if self.live and app == 'tisra' else None),
            ('session_binding', lambda peer, conn, app: ('synthetic-identity', lambda: self.live))]:
            p = patch.object(FormalTisraPeer, method, replacement)
            p.start(); self.stack.append(p)
        # Any accidental preflight/process would fail the test, rather than run CLI.
        self.no_process = patch('arl.codex_server.subprocess.Popen', side_effect=AssertionError('provider process forbidden'))
        self.no_process.start()

    def tearDown(self):
        for runtime in self.runtimes:
            runtime.control.close(); runtime.service_portal.close()
        self.no_process.stop()
        for p in self.stack: p.stop()
        self.tmp.cleanup()

    def factory(self, *, codex=True, cache=True, peer=True):
        helper=self.home/'synthetic-helper'; helper.write_bytes(b'offline never executed')
        formal = FormalTisraPeer(helper) if peer else None
        if codex:
            adapter = CodexTextAdapter(enabled=True, test_command=['never-run-offline-only'])
            service = CodexService(adapter, caller='arl-control', model='offline-fixture-model',
                authorization_current=lambda: True, peer_current=lambda: True,
                allow_model_selection=True, allow_test_command=True)
            session = Mock()
            session.response.return_value = {'data': [{'model': service.model,
                'defaultReasoningEffort': 'medium', 'supportedReasoningEfforts': [
                    {'reasoningEffort': e} for e in ('low', 'medium', 'high', 'xhigh', 'max')],
                'serviceTiers': [{'id': 'fast'}]}], 'nextCursor': None}
            service.catalog = read_catalog(session)
            session.send.assert_called_once_with('model/list', {'limit': 20, 'includeHidden': False})
            if cache:
                service.checked_mono = time.monotonic()
                service.checked_at_ms = int(time.time()*1000)
            runtime = compose_codex_service(self.home / 'host', service=service,
                peer_verifier=RegisteredPeerVerifier({'arl-control'}), isolated=True,
                formal_tisra_peer=formal)
        else:
            service = None
            runtime = make_runtime(self.home / 'host', formal_tisra_peer=formal)
        self.runtimes.append(runtime)
        return runtime, service

    def rpc(self, runtime, method, params=None, app='tisra'):
        request = {'protocol':'arl/1', 'app':app, 'method':method, 'params':params or {}}
        raw = json.dumps(request, separators=(',', ':')).encode()+b'\n'
        self.assertLessEqual(len(raw), MAX_FRAME)
        a,b = socket.socketpair(); a.settimeout(5); errors=[]
        def handler():
            try: Handler(b, (), SimpleNamespace(runtime=runtime))
            except Exception as e: errors.append(type(e).__name__)
            finally: b.close()
        thread=threading.Thread(target=handler); thread.start()
        try:
            a.sendall(raw); a.shutdown(socket.SHUT_WR); reply=bytearray()
            while True:
                chunk=a.recv(4096)
                if not chunk: break
                reply.extend(chunk)
        finally: a.close(); thread.join(6)
        self.assertFalse(thread.is_alive()); self.assertEqual(errors, [])
        self.assertLessEqual(len(reply), MAX_FRAME)
        return json.loads(reply)

    def ok(self, runtime, method, params=None, app='tisra'):
        reply=self.rpc(runtime,method,params,app)
        self.assertTrue(reply['ok'], reply)
        return reply['result']

    def open(self, runtime):
        opened=self.ok(runtime,'connection.open',{'client_nonce':'b'*64,'name':'Tisra / 织语',
            'icon_ref':'sf:text.book.closed','version':'0.1.0.6','capabilities':[]})
        self.ok(runtime,'connection.confirm',{k:opened[k] for k in ('session_id','challenge')})
        return opened['session_id']

    def request(self, sid, catalog, package='high', **changes):
        result={'schema_version':1,'session_id':sid,'catalog_version':catalog['catalog_version'],
            'request_id':str(uuid.uuid4()),'request_sha256':'a'*64,'task_kind':'research',
            'package_id':package,'priority':'explicit','deadline_ms':30000,
            'thinking_effort':next(p['target_effort'] for p in catalog['packages'] if p['package_id']==package),
            'service_tier':'default','allow_degradation':False}
        return dict(result,**changes)

    def icon_roundtrip(self, runtime, sid):
        icon=actual_icon()
        registered=self.ok(runtime,ICON_METHOD,{'schema_version':1,'session_id':sid,'icon':icon})
        self.assertTrue(registered['registered']); self.assertFalse(registered['display_attested'])
        result=self.ok(runtime,'settings.app_icon.v1',{'app_id':'tisra','sha256':icon['sha256']},'settings')
        self.assertEqual(hashlib.sha256(base64.b64decode(result['png_base64'])).hexdigest(),icon['sha256'])
        row=next(r for r in self.ok(runtime,'settings.snapshot',app='settings')['apps'] if r['id']=='tisra')
        self.assertEqual(row['authorization'],'none'); self.assertEqual(row['authorized_tools'],[])
        self.assertEqual(row['application_icon']['sha256'],icon['sha256'])
        self.assertNotIn('png_base64',json.dumps(row))

    def test_production_factory_five_packages_resolve_without_any_job_grant(self):
        runtime,_=self.factory(); sid=self.open(runtime)
        features=self.ok(runtime,'runtime.describe')['features']
        self.assertEqual((features['application_models'],features['application_icon']),(1,1))
        catalog=self.ok(runtime,'application.models.discover.v1',{'session_id':sid})
        for offer in catalog['packages']:
            self.assertTrue(offer['available'])
            receipt=self.ok(runtime,'application.models.request.v1',self.request(sid,catalog,offer['package_id']))
            self.assertTrue(receipt['accepted']); self.assertFalse(receipt['execution_authorized'])
            self.assertFalse(receipt['queue_admitted']); self.assertEqual(receipt['resolved']['effort'],offer['target_effort'])
        self.assertIsNone(runtime.store)
        self.assertEqual(runtime.work_scope,frozenset({('arl-control','codex.text.plan.v1')}))
        policy=runtime.policies['tisra']
        self.assertEqual((policy.max_pending,policy.max_calls,len(policy.tools),len(policy.providers)),(0,0,0,0))
        for method in ('submit','get','cancel'):
            reply=self.rpc(runtime,method)
            self.assertFalse(reply['ok']); self.assertEqual(reply['error']['code'],'method_not_authorized')

    def test_metadata_only_factory_still_connects_and_registers_real_icon(self):
        runtime,_=self.factory(codex=False); sid=self.open(runtime)
        catalog=self.ok(runtime,'application.models.discover.v1',{'session_id':sid})
        self.assertEqual(len(catalog['packages']),5)
        self.assertTrue(all(not p['available'] and p['model'] is None and p['effort'] is None for p in catalog['packages']))
        self.icon_roundtrip(runtime,sid)
        reply=self.ok(runtime,'application.models.request.v1',self.request(sid,catalog))
        self.assertFalse(reply['accepted']); self.assertEqual(reply['reasons'],['package_unavailable'])
        self.assertIsNone(runtime.store); self.assertIsNone(runtime.codex_service)

    def test_expired_codex_cache_does_not_block_metadata_or_run_preflight(self):
        runtime,service=self.factory(cache=False); sid=self.open(runtime)
        catalog=self.ok(runtime,'application.models.discover.v1',{'session_id':sid})
        self.assertTrue(all(not p['available'] for p in catalog['packages']))
        self.icon_roundtrip(runtime,sid)
        self.assertEqual(service.status()['state'],'preflight_pending')
        self.assertIsNone(service.last_inference_at_ms); self.assertIsNone(runtime.store)

    def test_canonical_cache_refresh_changes_resolution_and_expiry_rejects_old_catalog(self):
        runtime,service=self.factory(); sid=self.open(runtime)
        first=self.ok(runtime,'application.models.discover.v1',{'session_id':sid})
        service.checked_mono=None
        unavailable=self.ok(runtime,'application.models.discover.v1',{'session_id':sid})
        self.assertNotEqual(first['catalog_version'],unavailable['catalog_version'])
        stale=self.ok(runtime,'application.models.request.v1',self.request(sid,first))
        self.assertEqual(stale['reasons'],['catalog_changed']); self.assertFalse(stale['accepted'])
        service.checked_mono=time.monotonic()
        fresh=self.ok(runtime,'application.models.discover.v1',{'session_id':sid})
        self.assertEqual(first['catalog_version'],fresh['catalog_version'])

    def test_unsupported_effort_and_fast_never_silently_change_or_execute(self):
        runtime,_=self.factory(); sid=self.open(runtime)
        catalog=self.ok(runtime,'application.models.discover.v1',{'session_id':sid})
        for changes,reason in [({'thinking_effort':'unknown'},'provider_effort_unavailable'),
                               ({'service_tier':'fast'},'fast_authorization_required')]:
            reply=self.ok(runtime,'application.models.request.v1',self.request(sid,catalog,**changes))
            self.assertFalse(reply['accepted']); self.assertEqual(reply['reasons'],[reason])
        self.assertIsNone(runtime.store)

    def test_lost_original_peer_closes_existing_handshake_and_icon(self):
        runtime,_=self.factory(); sid=self.open(runtime); self.icon_roundtrip(runtime,sid)
        self.live=False
        reply=self.rpc(runtime,'application.models.discover.v1',{'session_id':sid})
        self.assertFalse(reply['ok']); self.assertEqual(reply['error']['code'],'app_identity_unverified')
        icon=actual_icon()
        reply=self.rpc(runtime,'settings.app_icon.v1',{'app_id':'tisra','sha256':icon['sha256']},'settings')
        self.assertFalse(reply['ok']); self.assertEqual(reply['error']['code'],'application_icon_unavailable')

    def test_default_composition_advertises_no_inactive_gateway_and_enrolls_nobody(self):
        runtime,_=self.factory(codex=False,peer=False)
        features=self.ok(runtime,'runtime.describe',app='settings')['features']
        self.assertNotIn('application_models',features); self.assertNotIn('application_icon',features)
        row=next(r for r in self.ok(runtime,'settings.snapshot',app='settings')['apps'] if r['id']=='tisra')
        self.assertEqual(row['registration'],'unregistered')
        self.assertFalse(self.rpc(runtime,'connection.open')['ok'])


if __name__=='__main__':unittest.main()
