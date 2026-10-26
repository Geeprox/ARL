import unittest
from dataclasses import replace
from arl.runtime_description import RuntimeDescription, validate_description
from arl.contracts import Fault, AppPolicy
from tests.test_runtime import RuntimeCase, running
from arl.client import Client

class DescriptionTests(unittest.TestCase):
    def test_boot_changes_source_stays_stable_and_features_are_copied(self):
        first, second = RuntimeDescription(), RuntimeDescription()
        self.assertNotEqual(first.boot_id, second.boot_id)
        self.assertEqual(first.source_sha256, second.source_sha256)
        reply = validate_description(first.snapshot(False))
        self.assertFalse(reply['ready'])
        reply['features'].clear()
        self.assertEqual(first.snapshot(True)['features']['app_sessions'], 1)
    def test_rejects_malformed_and_boolean_feature_versions(self):
        good = RuntimeDescription().snapshot(True)
        for field, value in [('boot_id', 'wrong'), ('source_sha256', 'f'*63),
                             ('protocol', 'arl/2'), ('schema_version', True),
                             ('features', {'app_sessions': True}), ('ready', 1)]:
            with self.subTest(field=field), self.assertRaises(Fault):
                validate_description({**good, field: value})

class DescriptionConsumerTests(RuntimeCase):
    def test_actual_metadata_consumer_and_no_health_grant_rejection(self):
        with running(self.home) as (runtime, client):
            metadata = Client(self.home, 'settings')
            result = metadata.describe_runtime()
            self.assertTrue(result['ready'])
            self.assertEqual(result['features']['app_sessions'], 1)
            self.assertEqual(result['source_sha256'], runtime.description.source_sha256)
            runtime.policies['tisra'] = replace(runtime.policies['tisra'], methods=frozenset({'heartbeat'}))
            self.assert_fault('method_not_authorized', client.describe_runtime)
    def test_restart_has_different_boot_identity(self):
        with running(self.home) as (_, client): first = Client(self.home, 'settings').describe_runtime()
        with running(self.home) as (_, client): second = Client(self.home, 'settings').describe_runtime()
        self.assertEqual(first['source_sha256'], second['source_sha256'])
        self.assertNotEqual(first['boot_id'], second['boot_id'])
