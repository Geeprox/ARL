"""Native readiness must consume the actual build-only preflight result."""
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from script.bootstrap import checks


class BootstrapChecksTests(unittest.TestCase):
    def native(self, code):
        calls = []
        def run(argv, **kwargs):
            calls.append(argv)
            if '--version' in argv:
                return SimpleNamespace(returncode=0, stdout=b'Apple Swift version 6.2')
            return SimpleNamespace(returncode=code)
        with patch('script.bootstrap.platform.system', return_value='Darwin'), \
             patch('script.bootstrap.platform.machine', return_value='arm64'), \
             patch('script.bootstrap.platform.mac_ver', return_value=('14.0', (), '')), \
             patch('script.bootstrap.shutil.which', return_value='/fixture/tool'), \
             patch('script.bootstrap.Path.is_file', return_value=True), \
             patch('script.bootstrap.Path.is_dir', return_value=True), \
             patch('script.bootstrap.subprocess.run', side_effect=run):
            result = checks(native=True)
        self.assertEqual(calls[-1][-2:], ['--check', '--build-only'])
        self.assertFalse(any('/usr/bin/security' in c for c in calls))
        return result

    def test_missing_recipe_inputs_cannot_report_ready(self):
        result = self.native(1)
        self.assertFalse(result['ready'])
        self.assertFalse(result['required']['native_build_inputs'])

    def test_verified_native_preflight_reports_ready(self):
        result = self.native(0)
        self.assertTrue(result['ready'])
        self.assertTrue(result['required']['native_build_inputs'])
