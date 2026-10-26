"""Candidate-only permission normalization; no live cache/app mutation."""
import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('nas_stage',ROOT/'script/stage_nas_runtime.py')
nas=importlib.util.module_from_spec(spec);spec.loader.exec_module(nas)
class PermissionsTests(unittest.TestCase):
    def test_incremental_normalizes_modes_and_rebinds_inventory_without_changing_code(self):
        with tempfile.TemporaryDirectory() as folder:
            app=Path(folder)/'ARL.app';root=app/'Contents/Resources/NASRuntime';exe=root/'python/bin/python3.12'
            exe.parent.mkdir(parents=True);exe.write_bytes(b'signed bytes');exe.chmod(0o775)
            header=root/'python/include/header.h';header.parent.mkdir();header.write_bytes(b'header');header.chmod(0o664)
            (root/'provenance.json').write_text(json.dumps({'source_inputs':{'script/stage_nas_runtime.py':'old'}}))
            inv=root/'inventory.json';inv.write_text(json.dumps(nas.inventory(root)))
            info=app/'Contents/Info.plist';info.write_bytes(plistlib.dumps({'ARLNASRuntimeInventorySHA256':nas.sha(inv)}))
            code=nas.sha(exe);result=nas.refresh_staged_permissions(app)
            self.assertEqual(nas.sha(exe),code);self.assertEqual(exe.stat().st_mode&0o777,0o555)
            self.assertEqual(header.stat().st_mode&0o777,0o444)
            self.assertFalse(any(p.stat().st_mode&0o022 for p in root.rglob('*')))
            self.assertFalse(any(p.stat().st_mode&0o222 for p in (root/'python').rglob('*')))
            with self.assertRaises(PermissionError):(exe.parent/'__pycache__').mkdir()
            self.assertEqual(plistlib.loads(info.read_bytes())['ARLNASRuntimeInventorySHA256'],result['inventory_sha256'])
            rows=nas.inventory(root);rows.pop('inventory.json')
            self.assertEqual(rows,json.loads(inv.read_text()))
    def test_changed_inventory_or_symlink_is_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);(root/'link').symlink_to('/tmp')
            with self.assertRaisesRegex(ValueError,'symlink'):nas.normalize_permissions(root)
