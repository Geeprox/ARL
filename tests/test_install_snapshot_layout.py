"""Snapshot store compatibility and cross-version serialization; synthetic files only."""
import fcntl
from pathlib import Path
import os
import plistlib
import tempfile
import unittest
import uuid
from arl.install_transaction import Layout,Transaction,InstallFault
from arl.install_platform import MacPlatform
from unittest.mock import patch

class SnapshotLayoutTests(unittest.TestCase):
    def setUp(self):
        self.temporary=tempfile.TemporaryDirectory();self.account=Path(self.temporary.name).resolve()/'account'
        self.account.mkdir(mode=0o700)
        (self.account/'Library/Application Support/ARL').mkdir(parents=True,mode=0o700)
    def tearDown(self):self.temporary.cleanup()
    def install_marker(self,version):
        info=self.account/'Applications/ARL.app/Contents/Info.plist';info.parent.mkdir(parents=True,exist_ok=True)
        info.write_bytes(plistlib.dumps({} if version is None else {'ARLInstallSnapshotLayout':version}))
    def test_old_management_bootstraps_legacy_then_new_reads_its_transaction(self):
        self.install_marker(None);old=Layout(self.account)
        self.assertEqual(old.root,old.legacy_root)
        identifier=str(uuid.uuid4());folder=old.root/identifier;folder.mkdir(parents=True)
        self.install_marker(2);new=Layout(self.account)
        self.assertEqual(new.root,new.noindex_root)
        self.assertEqual(new.folder(identifier),folder)
        self.assertEqual(new.folder(str(uuid.uuid4())).parent,new.noindex_root)
    def test_new_install_uses_noindex_and_legacy_lock_blocks_other_writer(self):
        layout=Layout(self.account)
        self.assertTrue(layout.root.name.endswith('.noindex'))
        with Transaction(layout,object()).lock():
            fd=os.open(layout.lock_path,os.O_RDWR)
            try:
                with self.assertRaises(BlockingIOError):fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
            finally:os.close(fd)
    def test_duplicate_transaction_locations_are_rejected(self):
        layout=Layout(self.account);identifier=str(uuid.uuid4())
        for root in [layout.noindex_root,layout.legacy_root]:(root/identifier).mkdir(parents=True)
        with self.assertRaisesRegex(InstallFault,'ambiguous_install_transaction'):layout.folder(identifier)

    def test_timeout_cleanup_checks_shared_legacy_lock_in_noindex_layout(self):
        layout=Layout(self.account);platform=MacPlatform(layout,self.account/'host')
        folder=layout.noindex_root/str(uuid.uuid4())
        with Transaction(layout,object()).lock():
            self.assertEqual(layout.lock_path,layout.legacy_root/'lock')
            self.assertFalse((layout.noindex_root/'lock').exists())
            with patch('arl.install_platform.time.monotonic',side_effect=[0,0.01,0.2]),patch('arl.install_platform.time.sleep'),self.assertRaisesRegex(InstallFault,'install_worker_cleanup_unproven'):
                platform.management_quiet(folder,{},seconds=0.1)
        platform.management_quiet(folder,{},seconds=0.1)
