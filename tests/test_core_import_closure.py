"""Import packaged code in isolation, without the checkout on sys.path."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from script import stage_core_runtime as packager

from script.stage_core_runtime import ROOT, inputs


class CoreImportClosureTests(unittest.TestCase):
    def test_private_research_entry_imports_from_the_actual_package_inputs(self):
        with tempfile.TemporaryDirectory(prefix='arl-core-import-', dir=tempfile.gettempdir()) as directory:
            target = Path(directory)
            for name in inputs(private=True):
                if name.startswith('arl/'):
                    destination = target / name
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(ROOT / name, destination)
            code = 'import sys; sys.path.insert(0, sys.argv[1]); import arl.host; import arl.formal_research_host; import arl.research_product'
            result = subprocess.run([sys.executable, '-I', '-B', '-c', code, str(target)], capture_output=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr.decode())

    def test_public_entry_imports_without_private_composition(self):
        with tempfile.TemporaryDirectory(prefix='arl-public-import-', dir=tempfile.gettempdir()) as directory:
            target = Path(directory)
            for name in inputs(private=False):
                if name.startswith('arl/'):
                    destination = target / name
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(ROOT / name, destination)
            code = 'import sys; sys.path.insert(0, sys.argv[1]); import arl.host; from arl.extension_contracts import compatibility; assert compatibility is None'
            result = subprocess.run([sys.executable, '-I', '-B', '-c', code, str(target)], capture_output=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr.decode())

    def test_zip_checkout_uses_explicit_manifest_and_rejects_unlisted_source(self):
        with tempfile.TemporaryDirectory(prefix='arl-source-archive-',dir=tempfile.gettempdir()) as directory:
            target=Path(directory)
            shutil.copytree(ROOT/'arl',target/'arl',ignore=shutil.ignore_patterns('__pycache__'))
            (target/'script').mkdir()
            shutil.copyfile(ROOT/'script/core_runtime_sources.json',target/'script/core_runtime_sources.json')
            with patch.object(packager,'ROOT',target):
                self.assertIn('arl/host.py',packager.inputs(private=True))
                (target/'arl/unreviewed_extra.py').write_text('raise RuntimeError()')
                with self.assertRaisesRegex(ValueError,'core_source_set_changed'):packager.inputs(private=True)
