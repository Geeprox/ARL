"""Release recoverability and scope checks; no installed App or LaunchServices."""
import importlib.util,json,hashlib,stat,tempfile,unittest,zipfile
from pathlib import Path
from unittest.mock import patch
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('finalize_build',ROOT/'script/finalize_build.py');f=importlib.util.module_from_spec(spec);spec.loader.exec_module(f)
class FinalizationTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name).resolve();self.out=self.root/'build/releases.noindex/fixture';self.app=self.out/'package/ARL.app';self.app.mkdir(parents=True)
        resource=self.app/'code';resource.write_bytes(b'original');resource.chmod(0o444)
        self.manifest=self.out/'package/manifest.json';self.manifest.write_text(json.dumps({'bundle_files':{'code':{'sha256':f.sha(resource),'mode':0o444}}}))
        self.archive=self.out/'fixture.zip';self.write_zip(b'original')
        self.receipt();self.root_patch=patch.object(f,'ROOT',self.root);self.root_patch.start();self.registry_patch=patch.object(f,'registered_paths',return_value=[]);self.registry_patch.start()
    def tearDown(self):self.registry_patch.stop();self.root_patch.stop();self.temp.cleanup()
    def write_zip(self,data):
        with zipfile.ZipFile(self.archive,'w') as z:
            info=zipfile.ZipInfo('package/ARL.app/code');info.external_attr=(stat.S_IFREG|0o444)<<16;z.writestr(info,data)
    def receipt(self):
        (self.out/'artifact.json').write_text(json.dumps({'status':'PASS','manifest':'package/manifest.json','archive':'fixture.zip','archive_sha256':f.sha(self.archive),'manifest_sha256':f.sha(self.manifest)}))
    def test_readonly_check_then_recoverable_idempotent_cleanup(self):
        source=self.root/'source.swift';source.write_text('user work')
        with patch.object(f.subprocess,'run') as command:
            f.finalize(self.out,check=True);self.assertTrue(self.app.exists());command.assert_not_called()
            command.return_value.returncode=0
            f.finalize(self.out);f.finalize(self.out)
        self.assertFalse(self.app.exists());self.assertTrue(self.archive.exists());self.assertEqual(source.read_text(),'user work')
        with zipfile.ZipFile(self.archive) as z:self.assertEqual(z.read('package/ARL.app/code'),b'original')
    def test_changed_staging_is_retained(self):
        p=self.app/'code';p.chmod(0o644);p.write_bytes(b'new user modification')
        with self.assertRaisesRegex(ValueError,'staged_app_changed'):f.finalize(self.out)
        self.assertTrue(self.app.exists())
    def test_archive_content_mismatch_is_retained_even_with_updated_zip_hash(self):
        self.write_zip(b'bad archive');self.receipt()
        with self.assertRaisesRegex(ValueError,'archive_content_changed'):f.finalize(self.out)
        self.assertTrue(self.app.exists())

    def test_context_closes_staging_even_when_probe_fails(self):
        with patch.object(f.subprocess,'run') as command:
            command.return_value.returncode=0
            with self.assertRaisesRegex(RuntimeError,'probe_failed'):
                with f.staged_release(self.out):raise RuntimeError('probe_failed')
        self.assertFalse(self.app.exists());self.assertTrue(self.archive.is_file())
    def test_parallel_finalization_cannot_remove_live_staging(self):
        with f.staging_lock(self.out):
            with self.assertRaisesRegex(ValueError,'release_staging_busy'):f.finalize(self.out)
        self.assertTrue(self.app.exists())
    def test_extract_rejects_path_escape_before_writing(self):
        with patch.object(f.subprocess,'run') as command:
            command.return_value.returncode=0;f.finalize(self.out)
        with zipfile.ZipFile(self.archive,'a') as z:z.writestr('package/../escape',b'unsafe')
        self.receipt()
        with patch.object(f.subprocess,'run') as command,self.assertRaisesRegex(ValueError,'archive_entry_scope'):
            f.materialize(self.out)
        command.assert_not_called();self.assertFalse(self.app.exists());self.assertFalse((self.out/'escape').exists())

    def test_lexical_dotdot_and_real_external_scope_are_rejected(self):
        outside=self.root/'outside.noindex';outside.mkdir()
        for path in [self.root/'build/fake.noindex/../../outside.noindex',outside,self.root/'build/plain']:
            with self.assertRaisesRegex(ValueError,'archive_output_scope'):f.finalize(path,check=True)
    def test_unknown_owned_worker_keeps_candidate_staging(self):
        from arl.install_transaction import InstallFault
        with self.assertRaises(InstallFault):
            with f.staged_release(self.out):raise InstallFault('install_worker_cleanup_unproven')
        self.assertTrue(self.app.exists());self.assertEqual(json.loads((self.out/'finalization.json').read_text())['status'],'PENDING')
