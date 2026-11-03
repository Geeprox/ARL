"""An explicit volume-identity upgrade preserves all once-only effect records."""
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from script.journal_anchor_upgrade import UpgradeError, apply, plan


class JournalAnchorUpgradeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='arl-anchor-')
        self.home = Path(self.temp.name).resolve()
        self.home.chmod(0o700)
        self.parent = self.home / 'reminders-v3'
        self.tasks = self.parent / 'product-v1/tasks'
        self.tasks.mkdir(parents=True, mode=0o700)
        self.parent.chmod(0o700)
        self.tasks.parent.chmod(0o700)
        root, tasks = self.tasks.parent.stat(), self.tasks.stat()
        self.raw = ('v1\n%d\n%d\n%d\n%d\n' % (root.st_dev - 1, root.st_ino, tasks.st_dev - 1, tasks.st_ino)).encode()
        self.anchor = self.parent / 'product-v1.anchor'
        self.anchor.write_bytes(self.raw)
        self.anchor.chmod(0o600)
        self.record = self.tasks / 'unknown.json'
        self.record.write_bytes(b'{"state":"unknown","automatic_replay":false}')
        self.record.chmod(0o600)
        self.volume = lambda path: '00112233-4455-6677-8899-aabbccddeeff'

    def tearDown(self):
        self.temp.cleanup()

    def test_exact_review_preserves_unknown_bytes_and_legacy_anchor(self):
        before = self.record.read_bytes()
        reviewed = plan(self.home, volume=self.volume)
        self.assertEqual(reviewed['entries'][0]['state'], 'legacy_device_changed')
        self.assertEqual(self.anchor.read_bytes(), self.raw)
        result = apply(self.home, reviewed['plan_sha256'], owners_stopped=True, volume=self.volume)
        self.assertEqual(result['status'], 'upgraded')
        self.assertFalse(result['records_modified'])
        self.assertEqual(self.record.read_bytes(), before)
        self.assertEqual(next(self.parent.glob('*.anchor.legacy-*')).read_bytes(), self.raw)
        self.assertEqual(plan(self.home, volume=self.volume)['entries'][0]['state'], 'current')

    def test_record_change_after_review_refuses_before_anchor_write(self):
        reviewed = plan(self.home, volume=self.volume)
        self.record.write_bytes(b'changed')
        with self.assertRaisesRegex(UpgradeError, 'reviewed_plan_changed'):
            apply(self.home, reviewed['plan_sha256'], owners_stopped=True, volume=self.volume)
        self.assertEqual(self.anchor.read_bytes(), self.raw)

    def test_replaced_directory_or_volume_cannot_be_silently_adopted(self):
        reviewed = plan(self.home, volume=self.volume)
        self.tasks.rename(self.parent / 'preserved')
        self.tasks.mkdir(mode=0o700)
        with self.assertRaisesRegex(UpgradeError, 'journal_missing_or_replaced'):
            apply(self.home, reviewed['plan_sha256'], owners_stopped=True, volume=self.volume)
        self.assertEqual(self.anchor.read_bytes(), self.raw)

    def test_running_owner_and_unreviewed_plan_are_rejected(self):
        reviewed = plan(self.home, volume=self.volume)
        with self.assertRaisesRegex(UpgradeError, 'stop_native_owners_first'):
            apply(self.home, reviewed['plan_sha256'], volume=self.volume)
        with self.assertRaisesRegex(UpgradeError, 'reviewed_plan_changed'):
            apply(self.home, '0' * 64, owners_stopped=True, volume=self.volume)
        self.assertEqual(self.anchor.read_bytes(), self.raw)

    def test_hardlinked_or_symlinked_records_are_rejected(self):
        os.link(self.record, self.tasks / 'alias')
        with self.assertRaisesRegex(UpgradeError, 'unsafe_journal'):
            plan(self.home, volume=self.volume)
        (self.tasks / 'alias').unlink()
        (self.tasks / 'link').symlink_to(self.record)
        with self.assertRaisesRegex(UpgradeError, 'symlink_refused'):
            plan(self.home, volume=self.volume)

    def test_noncanonical_legacy_anchor_is_not_repaired(self):
        rows = self.raw.splitlines()
        for malformed in (self.raw.rstrip(b'\n'), b'v1\n+' + b'\n'.join(rows[1:]) + b'\n',
                          b'v1\n ' + b'\n'.join(rows[1:]) + b'\n'):
            with self.subTest(anchor=malformed):
                self.anchor.write_bytes(malformed)
                with self.assertRaisesRegex(UpgradeError, 'invalid_anchor'):
                    plan(self.home, volume=self.volume)
                self.assertEqual(self.anchor.read_bytes(), malformed)

    def test_unreadable_tree_or_failed_enumeration_cannot_prove_inventory(self):
        unreadable=self.tasks/'unreadable'
        unreadable.mkdir(mode=0o700)
        unreadable.chmod(0)
        try:
            with self.assertRaisesRegex(UpgradeError,'unsafe_journal'):
                plan(self.home,volume=self.volume)
        finally:
            unreadable.chmod(0o700)
        with patch('script.journal_anchor_upgrade.os.scandir',side_effect=PermissionError('synthetic')):
            with self.assertRaisesRegex(UpgradeError,'journal_inventory_unavailable'):
                plan(self.home,volume=self.volume)
        self.assertEqual(self.anchor.read_bytes(),self.raw)


if __name__ == '__main__':
    unittest.main()
