"""Import packaged code in isolation, without the checkout on sys.path."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from script import export_public_core, stage_core_runtime as packager

from script.stage_core_runtime import ROOT, inputs


class CoreImportClosureTests(unittest.TestCase):
    def test_public_closure_traverses_imports_in_package_initializers(self):
        sources = {
            'arl/__init__.py': 'from arl.root_dependency import value',
            'arl/host.py': 'import arl.nested.entry',
            'arl/client.py': '',
            'arl/__main__.py': '',
            'arl/supervisor.py': '',
            'arl/application_platform.py': '',
            'arl/root_dependency.py': 'value = 1',
            'arl/nested/__init__.py': 'from .dependency import value',
            'arl/nested/entry.py': '',
            'arl/nested/dependency.py': 'value = 2',
        }
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for relative, contents in sources.items():
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(contents)
            with patch.object(export_public_core, 'ROOT', root):
                self.assertEqual(export_public_core.closure(), {Path(name) for name in sources})

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
            code = ('import sys; sys.path.insert(0, sys.argv[1]); import arl.host; '
                    'from arl.application_platform import ApplicationPlatform; '
                    'from arl.extension_contracts import compatibility; assert compatibility is None')
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
