"""Offline public-catalog contract tests; no credentials, network or native calls."""
import copy
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

from arl.contracts import Fault
from arl import service_connections as catalog
from arl.mio_music import MioMusicGateway, STATUS


class ServiceConnectionCatalogTests(unittest.TestCase):
    def setUp(self):
        self.valid = catalog.service_catalog()

    def read(self, value=None, *, raw=None):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'catalog.json'
            path.write_bytes(raw if raw is not None else json.dumps(value, ensure_ascii=False).encode())
            with patch.object(catalog, 'CATALOG', path):
                return catalog.service_catalog()

    def reject(self, value=None, *, raw=None):
        with self.assertRaises(Fault) as error:
            self.read(value, raw=raw)
        self.assertEqual(error.exception.code, 'invalid_service_catalog')

    def test_native_contract_round_trips_all_three_purposes(self):
        value = self.read(self.valid)
        self.assertEqual([row['credential_purpose'] for row in value['services'][:3]],
                         ['amap.maps-weather', 'fliggy.travel-readonly', 'netease.music-account'])
        self.assertEqual({row['configuration'] for row in value['services'][:3]}, {'native_credentials'})
        self.assertEqual(value['services'][3]['id'], 'codex')
        self.assertEqual(value['services'][3]['configuration'], 'host_scoped_model')
        self.assertEqual(value['services'][3]['tool_prefixes'], ['codex.'])
        self.assertIsNone(value['services'][3]['credential_purpose'])

    def test_codex_does_not_admit_credentials_remote_endpoint_or_general_rpc(self):
        for field, value in [('credential_purpose', 'netease.music-account'),
                             ('official_url', 'https://unverified.invalid/'),
                             ('tool_prefixes', ['execute_']), ('endpoint', 'https://unverified.invalid/'),
                             ('cookie', 'synthetic-secret')]:
            changed = copy.deepcopy(self.valid)
            changed['services'][3][field] = value
            self.reject(changed)
        self.assertEqual(catalog.music_connection_status()['service_id'], 'netease')

    def test_old_cli_and_user_home_configuration_fields_are_rejected(self):
        for field in ('install_command', 'configure_command', 'login_command',
                      'configuration_directory', 'credential_file', 'session_file', 'persistent_access'):
            with self.subTest(field=field):
                value = copy.deepcopy(self.valid)
                value['services'][2][field] = 'legacy-placeholder'
                self.reject(value)
        value = copy.deepcopy(self.valid)
        value['services'][2]['configuration'] = 'official_cli'
        self.reject(value)

    def test_wrong_purpose_prefixes_missing_fields_and_reordered_rows_are_rejected(self):
        for index in range(3):
            for key, replacement in [('credential_purpose', 'amap.wrong-purpose'),
                                     ('tool_prefixes', ['mio_forged_']), ('configuration', None)]:
                with self.subTest(index=index, key=key):
                    value = copy.deepcopy(self.valid)
                    value['services'][index][key] = replacement
                    self.reject(value)
            value = copy.deepcopy(self.valid)
            del value['services'][index]['credential_purpose']
            self.reject(value)
        value = copy.deepcopy(self.valid)
        value['services'].reverse()
        self.reject(value)

    def test_invalid_json_root_version_and_row_types_fail_with_finite_fault(self):
        for value in (None, [], {}, {'schema_version': 1, 'services': [None] * 3},
                      {'schema_version': 1, 'services': {'netease': {}}}):
            with self.subTest(value=value):
                self.reject(value)
        for version in (True, False, 1.0, '1', 2):
            value = copy.deepcopy(self.valid)
            value['schema_version'] = version
            self.reject(value)
        for raw in (b'{', b'\xff', b'{"schema_version":1,"schema_version":1,"services":[]}', b'[' * 1100):
            self.reject(raw=raw)

    def test_untrusted_urls_and_unbounded_display_text_are_rejected(self):
        for url in ('http://github.com/NetEase/skills#ncm-cli-setup',
                    'https://github.com.evil.invalid/NetEase/skills#ncm-cli-setup', None):
            value = copy.deepcopy(self.valid)
            value['services'][2]['official_url'] = url
            self.reject(value)
        for key, replacement in [('name', ''), ('name', 'x' * 121), ('symbol', 5),
                                 ('reason', 'x' * 2049), ('reason', 'hidden\nline'),
                                 ('reason', 'hidden\u202eline'), ('reason', None)]:
            value = copy.deepcopy(self.valid)
            value['services'][2][key] = replacement
            self.reject(value)

    def test_missing_oversized_and_duplicate_fields_fail_closed(self):
        value = copy.deepcopy(self.valid)
        del value['services'][2]['reason']
        self.reject(value)
        raw = json.dumps(self.valid).encode().replace(b'"name":', b'"name":"duplicate", "name":', 1)
        self.reject(raw=raw)
        self.reject(raw=b' ' * 16385)
        path = Mock()
        path.open.side_effect = FileNotFoundError()
        with patch.object(catalog, 'CATALOG', path), self.assertRaises(Fault) as error:
            catalog.service_catalog()
        self.assertEqual(error.exception.code, 'invalid_service_catalog')

    def test_only_one_bounded_public_catalog_read_occurs(self):
        source = io.BytesIO(json.dumps(self.valid).encode())
        checked = Mock(wraps=source)
        path = Mock()
        path.open.return_value.__enter__ = Mock(return_value=checked)
        path.open.return_value.__exit__ = Mock(return_value=False)
        with patch.object(catalog, 'CATALOG', path):
            result = catalog.music_connection_status()
        path.open.assert_called_once_with('rb')
        checked.read.assert_called_once_with(16385)
        self.assertFalse(result['credential_contents_read'])

    def test_public_status_is_native_metadata_without_sdk_login_evidence(self):
        state = catalog.music_connection_status()
        self.assertEqual(state['state'], 'connection_unverified')
        self.assertFalse(state['ready'])
        self.assertEqual(state['configuration_method'], 'native_credentials')
        self.assertEqual(state['credential_purpose'], 'netease.music-account')
        self.assertEqual(state['configuration'], 'not_verified')
        self.assertEqual(state['login'], 'not_verified')
        self.assertEqual(state['account_access'], 'not_authorized')
        self.assertEqual(state['writes'], 'paused')
        self.assertNotIn('configure_command', state)
        self.assertNotIn('login_command', state)

    def test_gateway_status_succeeds_with_native_catalog_and_never_calls_account(self):
        def forbidden(*args, **kwargs):
            raise AssertionError('status_must_not_call_account_or_legacy')
        for account_state in ('configuration_required', 'login_required', 'contract_unverified', 'authorized_read'):
            gateway = MioMusicGateway(forbidden, read_transport=Mock(invoke=forbidden), account_state=account_state)
            result = gateway.respond({'jsonrpc': '2.0', 'id': 1, 'method': 'tools/call',
                                      'params': {'name': STATUS, 'arguments': {}}})
            payload = json.loads(result['result']['content'][0]['text'])
            self.assertFalse(result['result']['isError'])
            self.assertFalse(payload['ready'])
            self.assertEqual(payload['login'], 'not_verified')
            self.assertEqual(payload['writes'], 'paused')
            self.assertFalse(payload['credential_contents_read'])


if __name__ == '__main__':
    unittest.main()
