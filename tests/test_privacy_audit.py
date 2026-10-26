"""Publication leaks must be found without disclosing their values in reports."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from script import privacy_audit as audit


class PrivacyAuditTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='arl-publication-', dir='/private/tmp')
        self.root = Path(self.directory.name).resolve()
        self.config = patch.object(audit, 'ROOT', self.root)
        self.config.start()
        self.git('init', '-q')
        self.git('config', 'user.name', 'Fixture')
        self.git('config', 'user.email', 'fixture@example.invalid')
        self.secret = 'github_' + 'pat_' + 'Q' * 40

    def tearDown(self):
        self.config.stop()
        self.directory.cleanup()

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.root), *args], stderr=subprocess.DEVNULL)

    def test_untracked_and_staged_preimage_are_both_scanned(self):
        path = self.root / 'tracked.txt'
        path.write_text(self.secret)
        self.git('add', 'tracked.txt')
        path.write_text('clean working copy')
        (self.root / 'new file.txt').write_text(self.secret)
        result = audit.audit()
        hits = {(f['scope'], f['path']) for f in result['findings'] if 'credential_candidate' in f['types']}
        self.assertEqual(hits, {('index', 'tracked.txt'), ('untracked', 'new file.txt')})
        self.assertNotIn(self.secret, json.dumps(result))

    def test_ignored_state_is_excluded_and_links_are_never_followed(self):
        (self.root / '.gitignore').write_text('private/\n')
        private = self.root / 'private'
        private.mkdir()
        (private / 'state').write_text(self.secret)
        (self.root / 'alias').symlink_to(private, target_is_directory=True)
        result = audit.audit()
        self.assertEqual(result['findings'], [{'scope': 'untracked', 'path': 'alias', 'types': ['symlink_review']}])

    def test_deleted_history_and_commit_and_annotated_tag_are_scanned(self):
        path = self.root / 'removed.txt'
        path.write_text(self.secret)
        self.git('add', '.')
        self.git('commit', '-qm', 'initial')
        path.unlink()
        self.git('add', '-u')
        self.git('commit', '-qm', 'metadata ' + self.secret)
        self.git('tag', '-a', 'fixture-tag', '-m', 'tag ' + self.secret)
        result = audit.audit(history=True)
        self.assertFalse(result['release_ready'])
        self.assertTrue(any(f['scope'] == 'history' and 'credential_candidate' in f['types'] for f in result['findings']))
        self.assertEqual(sum(f['scope'] == 'history_metadata' and 'credential_candidate' in f['types'] for f in result['findings']), 2)
        self.assertNotIn(self.secret, json.dumps(result))

    def test_candidate_includes_hidden_files_binary_and_symlinks(self):
        candidate = self.root / 'candidate'
        candidate.mkdir()
        (candidate / '.env').write_text(self.secret)
        (candidate / 'image.png').write_bytes(b'\x89PNG\0fixture')
        (candidate / 'alias').symlink_to(self.root / 'outside')
        result = audit.audit_candidate(candidate)
        by_name = {f['path']: f['types'] for f in result['findings']}
        self.assertIn('credential_candidate', by_name['.env'])
        self.assertIn('credential_file_review', by_name['.env'])
        self.assertEqual(by_name['image.png'], ['binary_review'])
        self.assertEqual(by_name['alias'], ['symlink_review'])
        self.assertFalse(audit.audit_candidate(self.root)['release_ready'])

    def test_reports_are_private_and_refuse_linked_output(self):
        output = self.root / 'build' / 'report.json'
        result = audit.report([])
        audit.write_report(output, result)
        self.assertEqual(output.stat().st_mode & 0o777, 0o600)
        output.unlink()
        target = self.root / 'keep'
        target.write_text('preserve')
        output.symlink_to(target)
        with self.assertRaises(ValueError):
            audit.write_report(output, result)
        self.assertEqual(target.read_text(), 'preserve')

    def test_secret_formats_and_neutral_examples(self):
        for secret in ('sk-' + 'X' * 32, 'AKIA' + 'A' * 16,
                       '-----BEGIN ' + 'ENCRYPTED PRIVATE KEY-----'):
            self.assertTrue(set(audit.scan(secret.encode())) & {'credential_candidate', 'private_key_material'})
        self.assertEqual(audit.scan(b'contact@example.invalid\napi_key: "env:MY_KEY_REFERENCE"'), [])
        self.assertIn('credential_url', audit.scan(b'https://user:synthetic@example.invalid'))


if __name__ == '__main__':
    unittest.main()
