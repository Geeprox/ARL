"""Real offline stdio + unavailable-account integration; no real CLI/accounts."""
import copy
import hashlib
import json
import importlib.util
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from types import SimpleNamespace

from arl.capabilities import build_tools
from arl.contracts import Fault
from arl.host import make_runtime
from arl.mio_music import MioMusicGateway, ALIASES, STATUS
from arl.netease_music import CREATE, APPEND, LIST, SEARCH, SCHEMAS
from arl.overview import overview
from arl.service_connections import music_connection_status, service_catalog
from arl.travel import TravelAdapter

ROOT = Path(__file__).resolve().parents[1]
LIVE14_SHA = '27a13fea4e9273a7c128853f1fe9eee3c10dc34a8d84edddf33f645845d06f2a'

def legacy(request):
    if request.get('method') == 'tools/list':
        return {'jsonrpc': '2.0', 'id': request['id'], 'result': {'tools': TravelAdapter().descriptors}}
    return {'jsonrpc': '2.0', 'id': request['id'], 'result': {'preserved_legacy_request': request}}

def request(name, args=None):
    return {'jsonrpc': '2.0', 'id': 2, 'method': 'tools/call', 'params': {'name': name, 'arguments': args or {}}}

def body(reply):
    return json.loads(reply['result']['content'][0]['text'])

class MusicServiceIntegrationTests(unittest.TestCase):
    def test_native_resource_manifest_preserves_policy_and_exact_nine_inputs(self):
        spec=importlib.util.spec_from_file_location('music_pack',ROOT/'integrations/mio_music/package_resources.py')
        module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as folder:
            app=Path(folder)/'ARLMioAppleBridge.app';(app/'Contents').mkdir(parents=True)
            old={'CFBundleIdentifier':'local.arl.mioapplebridge','ARLApprovedPolicySHA256':'a'*64}
            info=app/'Contents/Info.plist';info.write_bytes(plistlib.dumps(old))
            receipt=module.populate(ROOT,app)
            updated=plistlib.loads(info.read_bytes())
            self.assertEqual(updated['ARLApprovedPolicySHA256'],old['ARLApprovedPolicySHA256'])
            resources=app/'Contents/Resources/MioMusicBridge'
            manifest=json.loads((resources/'manifest.json').read_bytes())
            self.assertEqual(len(manifest),9)
            for name,digest in manifest.items():
                self.assertEqual(hashlib.sha256((resources/name).read_bytes()).hexdigest(),digest)
                self.assertEqual((resources/name).read_bytes(),(ROOT/name).read_bytes())
            self.assertEqual(updated['ARLMioMusicBridgeManifestSHA256'],hashlib.sha256((resources/'manifest.json').read_bytes()).hexdigest())
            self.assertFalse(receipt['credential_files_read'])

    def test_packager_refuses_installed_helper_and_existing_resource_stage(self):
        spec=importlib.util.spec_from_file_location('music_pack',ROOT/'integrations/mio_music/package_resources.py')
        module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
        with self.assertRaises(ValueError):module.populate(ROOT,Path.home()/'Applications/ARL.app/Contents/Library/LoginItems/ARLMioAppleBridge.app')
        with tempfile.TemporaryDirectory() as folder:
            app=Path(folder)/'ARLMioAppleBridge.app';(app/'Contents/Resources/MioMusicBridge').mkdir(parents=True)
            (app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'local.arl.mioapplebridge'}))
            with self.assertRaises(ValueError):module.populate(ROOT,app)

    def test_catalog_has_three_native_credential_flows_without_login_claims(self):
        rows = service_catalog()['services']
        self.assertEqual([x['id'] for x in rows], ['amap', 'fliggy', 'netease', 'codex'])
        row = rows[2]
        self.assertTrue(all(x['configuration'] == 'native_credentials' for x in rows[:3]))
        self.assertEqual(row['credential_purpose'], 'netease.music-account')
        for field in ('configure_command', 'login_command', 'install_command',
                      'configuration_directory', 'credential_file', 'session_file'):
            self.assertNotIn(field, row)
        state = music_connection_status()
        self.assertFalse(state['ready'])
        self.assertEqual(state['login'], 'not_verified')
        self.assertEqual(state['configuration'], 'not_verified')
        self.assertEqual(state['configuration_method'], 'native_credentials')
        self.assertEqual(state['credential_purpose'], 'netease.music-account')
        self.assertEqual(state['account_access'], 'not_authorized')
        self.assertEqual(state['writes'], 'paused')
        self.assertIn('服务连接', state['configuration_ui'])
        self.assertFalse(state['credential_contents_read'])

    def test_formal_host_registers_music_metadata_without_grants(self):
        with tempfile.TemporaryDirectory() as home:
            runtime = make_runtime(home)
            self.assertTrue(set(SCHEMAS) <= set(runtime.tools))
            self.assertFalse(runtime.execute_jobs)
            self.assertTrue(all(not (set(SCHEMAS) & policy.tools) for policy in runtime.policies.values()))
            runtime.router = SimpleNamespace(discover=lambda: [])
            metadata = overview(runtime)
            music = [x for x in metadata['capabilities'] if x['name'].startswith('netease.')]
            self.assertEqual(len(music), 5)
            self.assertTrue(all(x['availability'] == 'not_configured' and x['authorization_gate'] == 'authorization_not_checked' for x in music))

    def test_public_catalog_preserves_exact_live_travel14_and_adds_six(self):
        reply = MioMusicGateway(legacy).respond({'jsonrpc':'2.0','id':1,'method':'tools/list'})
        tools = reply['result']['tools']
        digest = hashlib.sha256(json.dumps(tools[:14],sort_keys=True,separators=(',',':'),ensure_ascii=False).encode()).hexdigest()
        self.assertEqual(digest, LIVE14_SHA)
        self.assertEqual(len(tools), 21)
        self.assertEqual(len({x['name'] for x in tools}), 21)
        self.assertEqual({x['name'] for x in tools[14:]}, {*ALIASES, STATUS, 'mio_netease_playlist_update_cover'})
        old = request('mio_maps_geo', {'address':'测试地址'})
        self.assertEqual(MioMusicGateway(legacy).respond(old), legacy(old))

    def test_changed_legacy_catalog_is_rejected(self):
        def changed(req):
            value = legacy(req)
            value['result']['tools'][0]['description'] = 'tampered'
            return value
        with self.assertRaises(Fault):
            MioMusicGateway(changed).respond({'id':1,'method':'tools/list'})

    def test_configuration_and_login_states_never_call_transport(self):
        class NoCalls:
            def invoke(self, *args, **kwargs):
                raise AssertionError('real_account_or_CLI_must_not_run')
        for state, expected in [('configuration_required','music_app_configuration_required'),('login_required','music_login_required'),('contract_unverified','music_contract_unverified')]:
            gateway = MioMusicGateway(legacy, read_transport=NoCalls(), account_state=state)
            self.assertEqual(body(gateway.respond(request('mio_netease_song_search',{'keyword':'测试'})))['error']['code'],expected)

    def test_write_pause_survives_read_authorization_and_forged_scope(self):
        class NoCalls:
            def invoke(self, *args, **kwargs):
                raise AssertionError('writes_must_not_run')
        gateway=MioMusicGateway(legacy,read_transport=NoCalls(),account_state='authorized_read')
        for name,args in [('mio_netease_playlist_create',{'name':'测试'}),('mio_netease_playlist_append_song',{'playlist_id':'a'*32,'song_id':'b'*32})]:
            self.assertEqual(body(gateway.respond(request(name,args)))['error']['code'],'music_write_authorization_required')
        self.assertEqual(body(gateway.respond(request('mio_netease_playlist_create',{'name':'测试','approved':True})))['error']['code'],'invalid_arguments')

    def test_authorized_synthetic_read_and_secret_error_redaction(self):
        class Fixture:
            def invoke(self, name, **kwargs):
                if name == LIST:
                    raise Fault('music_login_required','hidden_fake_secret')
                return {'songs':[{'encryptedId':'a'*32,'originalId':123,'name':'测试'}]}
        gateway=MioMusicGateway(legacy,read_transport=Fixture(),account_state='authorized_read')
        result=body(gateway.respond(request('mio_netease_song_search',{'keyword':'测试'})))
        self.assertEqual(result['songs'][0]['url'],'https://music.163.com/#/song?id=123')
        error=gateway.respond(request('mio_netease_playlist_list'))
        self.assertEqual(body(error)['error']['code'],'music_login_required')
        self.assertNotIn('hidden_fake_secret',json.dumps(error))

    def test_real_stdio_child_catalog_status_unconfigured_and_paused_write(self):
        script="""import sys
from arl.mio_music import MioMusicGateway, serve
from tests.test_music_service_integration import legacy
serve(MioMusicGateway(legacy),sys.stdin,sys.stdout)
"""
        frames=[{'jsonrpc':'2.0','id':1,'method':'tools/list'}, request(STATUS), request('mio_netease_playlist_list'),request('mio_netease_playlist_create',{'name':'未执行'})]
        result=subprocess.run([sys.executable,'-c',script],cwd=ROOT,
            env={'PATH':'/usr/bin:/bin','LANG':'C','LC_ALL':'C','TMPDIR':'/tmp','PYTHONDONTWRITEBYTECODE':'1'},
            input=''.join(json.dumps(x)+'\n' for x in frames),text=True,capture_output=True,timeout=10)
        self.assertEqual(result.returncode,0,result.stderr)
        replies=[json.loads(row) for row in result.stdout.splitlines()]
        self.assertEqual(len(replies),4)
        self.assertEqual(len(replies[0]['result']['tools']),21)
        self.assertFalse(body(replies[1])['ready'])
        self.assertEqual(body(replies[2])['error']['code'],'music_app_configuration_required')
        self.assertEqual(body(replies[3])['error']['code'],'music_write_authorization_required')

if __name__=='__main__':unittest.main()
