"""Isolated package/consumer evidence; no live state, keys, TCC or deployment."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import time
import unittest
from script.stage_core_runtime import stage
from script.bundled_runtime_entry import verify
from script.prepare_mio_migration import candidates
from deployment.manage import Manager, DeploymentError
from arl.client import Client

ROOT=Path(__file__).resolve().parents[1]

class CorePackageTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='core-package-',dir=ROOT/'build')
        self.root=Path(self.temp.name);self.app=self.root/'package'
        (self.app/'Contents').mkdir(parents=True)
        (self.app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'test.package.only'}))
        self.record=stage(self.app,private=False)
        self.package=self.app/'Contents/Resources/CoreRuntime'
    def tearDown(self):self.temp.cleanup()
    def test_complete_inventory_source_identity_and_private_exclusion(self):
        data=verify(self.package)
        self.assertEqual(data['source_sha256'],self.record['source_sha256'])
        self.assertEqual(data['profile'],'public-core-zero-grants')
        self.assertFalse((self.package/'code/arl/private_compat.py').exists())
        code=self.package/'code/arl/service.py';code.chmod(0o644);code.write_bytes(code.read_bytes()+b'\n')
        with self.assertRaisesRegex(ValueError,'runtime_hash_mismatch'):verify(self.package)
    def test_unlisted_resource_and_symbolic_link_reject(self):
        self.package.chmod(0o755) # intentional mutation of this isolated test fixture
        p=self.package/'extra';p.write_text('unexpected')
        with self.assertRaisesRegex(ValueError,'unlisted_runtime_resource'):verify(self.package)
        p.unlink();p.symlink_to('/tmp')
        with self.assertRaisesRegex(ValueError,'unsafe_runtime_resource'):verify(self.package)
    def test_actual_packaged_runtime_description_and_parent_death_cleanup(self):
        home=self.root/'state';home.mkdir(mode=0o700)
        entry=self.package/'entry.py'
        wrapper = "import os,subprocess,sys; p=subprocess.Popen([sys.executable,'-I','-B',sys.argv[1],'--parent-pid',str(os.getpid()),'--isolated-test','--home',sys.argv[2]],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL); print(p.pid,flush=True); sys.stdin.buffer.read(1)"
        parent=subprocess.Popen([sys.executable,'-I','-B','-c',wrapper,str(entry),str(home)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        try:
            child=int(parent.stdout.readline());self.assertGreater(child,1)
            client=Client(home,'settings');self.assertTrue(client.connect(timeout=6)['ready'])
            description=client.describe_runtime()
            self.assertEqual(description['source_sha256'],self.record['source_sha256'])
            self.assertEqual(description['features']['app_sessions'],1)
            self.assertEqual(client.rpc('overview')['policy']['paid_inference_enabled'],False)
            parent.stdin.write(b'x');parent.stdin.flush();parent.communicate(timeout=3)
            deadline=time.monotonic()+6
            while (home/'runtime.sock').exists() and time.monotonic()<deadline:time.sleep(.05)
            self.assertFalse((home/'runtime.sock').exists(),'packaged child did not release its own socket')
        finally:
            if parent.poll() is None:parent.terminate()
            parent.communicate(timeout=3)
    def test_legacy_production_installer_cannot_touch_real_state(self):
        with self.assertRaisesRegex(DeploymentError,'legacy_installer_retired'):
            Manager().deploy('/nonexistent-package','unapproved')

class MioMigrationTests(unittest.TestCase):
    def test_v2_v3_only_path_and_hash_change_no_scope_expansion(self):
        profile=b'command: /old/executable --gateway /same/state\napi_key: env:TEST_KEY_REFERENCE\n'
        for version in [2,3]:
            before={'schema_version':version,'enabled':1,'profile_sha256':hashlib.sha256(profile).hexdigest(),
                'scope':'unchanged','max_effects':3,'tunnel_id':'tunnel_'+'0'*32}
            if version==3:before['calendar_execution_policy']='os_tcc_only'
            raw,after_profile=candidates(json.dumps(before).encode(),profile,'/old/executable','/nested/executable')
            after=json.loads(raw)
            self.assertEqual({k for k in before if before[k]!=after[k]},{'profile_sha256'})
            self.assertEqual(after_profile,profile.replace(b'/old/executable',b'/nested/executable'))
    def test_changed_preimage_duplicate_path_and_unknown_policy_fail_closed(self):
        profile=b'/old/executable /old/executable'
        raw=json.dumps({'schema_version':2,'enabled':1,'profile_sha256':hashlib.sha256(profile).hexdigest()}).encode()
        with self.assertRaisesRegex(ValueError,'mio_gateway_path_not_unique'):candidates(raw,profile,'/old/executable','/new')
        with self.assertRaisesRegex(ValueError,'mio_activation_changed'):candidates(raw,b'changed','/old/executable','/new')
        raw=json.dumps({'schema_version':3,'enabled':1,'profile_sha256':hashlib.sha256(profile).hexdigest(),'calendar_execution_policy':'unknown'}).encode()
        with self.assertRaisesRegex(ValueError,'mio_calendar_policy_changed'):candidates(raw,profile,'/old/executable','/new')
