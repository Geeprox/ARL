"""Inventory coverage and honest prerequisite accounting, without running apps."""
import copy
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

from script import check


class TestProfilesTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='arl-test-plan-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root/'tests').mkdir()
        self.path = self.root/'tests/test_fixture.py'
        self.path.write_text('''import unittest
class Fixture(unittest.TestCase):
    def test_portable(self): pass
    def test_external(self): pass
class Native(unittest.TestCase):
    def test_native(self): pass
''')
        self.catalog = {'schema_version': 1, 'profiles': {p: p for p in check.PROFILES},
            'requirements': {'missing_source': {'kind': 'path', 'value': 'absent/original-evidence'}},
            'modules': {'tests.test_fixture': {'kind': 'unittest', 'profile': 'portable', 'requires': [],
                'overrides': {'Fixture.test_external': {'profile': 'external', 'requires': ['missing_source']},
                    'Native': {'profile': 'native', 'requires': []}}}}}
        self.manifest = self.root/'catalog.json'

    def load(self):
        self.manifest.write_text(json.dumps(self.catalog))
        return check.load_catalog(self.manifest, self.root)

    def test_new_test_module_must_be_explicitly_classified(self):
        self.load()
        (self.root/'tests/test_new.py').write_text('class New: pass')
        with self.assertRaisesRegex(check.InventoryError, 'unclassified_modules'):
            self.load()

    def test_removed_or_export_omitted_test_cannot_leave_a_false_inventory(self):
        self.load(); self.path.unlink()
        with self.assertRaisesRegex(check.InventoryError, 'missing_modules'):
            self.load()

    def test_duplicate_method_declaration_cannot_count_the_shadowing_method_twice(self):
        self.path.write_text('''import unittest
class Fixture(unittest.TestCase):
    def test_duplicate(self): pass
    def test_duplicate(self): pass
''')
        self.catalog['modules']['tests.test_fixture']['overrides'] = {}
        with self.assertRaisesRegex(check.InventoryError, 'duplicate_test_declaration'):
            self.load()

    def test_all_reports_original_external_prerequisite_as_blocked(self):
        catalog, files = self.load()
        result = check.plan(catalog, files, check.PROFILES, root=self.root)
        self.assertEqual(result['selected_case_count'], 2)
        self.assertEqual(result['blocked'], [{'test': 'tests.test_fixture.Fixture.test_external',
            'profile': 'external', 'unmet_requirements': ['missing_source']}])
        self.assertEqual(result['not_selected'], [])
        self.assertFalse((self.root/'absent').exists())

    def test_portable_profile_keeps_other_groups_explicitly_not_selected(self):
        catalog, files = self.load()
        result = check.plan(catalog, files, {'portable'}, root=self.root)
        self.assertEqual(result['selected_case_count'], 1)
        self.assertEqual(len(result['not_selected']), 2)
        self.assertEqual(result['blocked'], [])

    def test_specific_method_partition_overrides_class_without_hiding_other_cases(self):
        self.catalog['modules']['tests.test_fixture']['overrides'].update({
            'Fixture': {'profile': 'native', 'requires': []},
            'Fixture.test_portable': {'profile': 'portable', 'requires': []}})
        catalog, files = self.load()
        result = check.plan(catalog, files, {'portable'}, root=self.root)
        self.assertEqual(result['jobs'][0]['cases'], ['Fixture.test_portable'])
        self.assertEqual(len(result['not_selected']), 2)

    def test_partial_module_filter_is_explicit_and_keeps_full_inventory(self):
        catalog, files = self.load()
        result = check.plan(catalog, files, check.PROFILES, root=self.root)
        filtered = check.filter_modules(result, {'tests.some_other_module'})
        self.assertEqual(filtered['module_inventory_count'], 1)
        self.assertEqual(filtered['module_filter'], ['tests.some_other_module'])
        self.assertEqual(filtered['selected_case_count'], 0)
        self.assertTrue(all(r['reason']=='explicit_module_filter' for r in filtered['not_selected']))

    def test_stale_partition_and_unknown_requirement_fail_closed(self):
        original = copy.deepcopy(self.catalog)
        self.catalog['modules']['tests.test_fixture']['overrides']['NoSuchClass'] = {'profile': 'private'}
        with self.assertRaisesRegex(check.InventoryError, 'stale_test_partition'):
            self.load()
        self.catalog = original
        self.catalog['modules']['tests.test_fixture']['requires'] = ['imaginary_requirement']
        with self.assertRaisesRegex(check.InventoryError, 'unknown_test_requirement'):
            self.load()

    def test_python_paths_cannot_point_outside_the_project(self):
        self.catalog['modules']['tests.test_fixture']['python_paths'] = ['../private-account']
        with self.assertRaisesRegex(check.InventoryError, 'external_test_python_path'):
            self.load()

    def test_command_runner_requires_the_selected_python_interpreter(self):
        self.path.write_text('print("standalone fixture")\n')
        self.catalog['modules']['tests.test_fixture'] = {
            'kind': 'command', 'profile': 'portable', 'argv': ['/unreviewed/python', '-c', 'pass']}
        with self.assertRaisesRegex(check.InventoryError, 'invalid_test_command'):
            self.load()

    def test_isolated_python_child_cannot_write_bytecode_when_environment_is_ignored(self):
        # -I would ignore the runner environment. Assert the actual interpreter
        # flag and import an ordinary source module to verify the side effect.
        code = ('import pathlib,sys; assert sys.flags.isolated; assert sys.dont_write_bytecode; '
                'p=pathlib.Path(sys.argv[1]); (p/"fixture_import.py").write_text("VALUE=7\\n"); '
                'sys.path.insert(0,str(p)); import fixture_import; assert fixture_import.VALUE==7; '
                'assert not (p/"__pycache__").exists()')
        test_plan = {'jobs': [{'module': 'fixture', 'kind': 'command', 'cases': [None],
            'argv': ['{python}', '-I', '-c', code, '{temporary}'], 'timeout_seconds': 10}],
            'blocked': [], 'not_selected': []}
        with patch.dict(os.environ, {'PYTHONDONTWRITEBYTECODE': '0'}):
            result = check.execute(test_plan, self.root/'receipt', python=sys.executable)
        self.assertTrue(result['all_green'])
        self.assertEqual(result['tests_run'], 1)

    def test_release_cache_interpreter_is_not_executed_in_place(self):
        with patch.object(check, 'ROOT', self.root):
            with self.assertRaisesRegex(check.InventoryError, 'release_cache_test_interpreter'):
                check.execute({'jobs': []}, self.root/'receipt',
                    python=str(self.root/'vendor/nas/python/bin/python3'))
        self.assertFalse((self.root/'receipt').exists())

    def test_unexpected_skip_is_incomplete_not_a_passing_receipt(self):
        class Skipped(unittest.TestCase):
            @unittest.skip('separate original fixture unavailable')
            def test_case(self): pass
        module = type('FixtureModule', (), {'Skipped': Skipped})
        path = self.root/'worker.json'
        with patch('script.check.importlib.import_module', return_value=module):
            code = check.worker('fixture', ['Skipped.test_case'], path)
        result = json.loads(path.read_text())
        self.assertEqual(code, 2)
        self.assertFalse(result['ok'])
        self.assertEqual(result['status'], 'incomplete')
        self.assertEqual(len(result['skipped']), 1)

    def test_real_catalog_covers_every_current_python_test_module(self):
        catalog, files = check.load_catalog()
        self.assertEqual(set(files), set(catalog['modules']))
        self.assertIn('tests.test_codex_production', files)
        self.assertIn('tests.Moments.test_native_capture', files)
        self.assertIn('tests.service_portal.test_portal_hooks', files)


if __name__ == '__main__':
    unittest.main()
