import json
import os
import subprocess
import tempfile
import types
import unittest
from pathlib import Path

from status import MioStatusProbe, checked_base


class StatusTests(unittest.TestCase):
    def test_positive_is_only_local_client_evidence(self):
        def runner(argv, **kwargs):
            self.assertEqual(kwargs['timeout'], 2)
            return types.SimpleNamespace(returncode=0, stdout=b'{"healthz":{"http":200,"state":"live"},"readyz":{"http":200,"state":"ready"}}')
        result = MioStatusProbe(runner).snapshot()
        self.assertEqual(result['tunnel']['readiness'], 'ready')
        self.assertEqual(result['tunnel']['external_roundtrip'], 'not_checked')
        self.assertFalse(result['capabilities']['live_publication_verified'])
        self.assertEqual(result['capabilities']['tool_count'], 13)
        self.assertEqual(result['providers'], 'not_probed')
        self.assertNotIn('url', json.dumps(result)); self.assertNotIn('key', json.dumps(result))

    def test_http_200_with_unknown_body_is_not_ready(self):
        result = MioStatusProbe(lambda *a, **k: types.SimpleNamespace(returncode=0,
            stdout=b'{"readyz":{"http":200,"state":"unknown"}}')).snapshot()
        self.assertEqual(result['tunnel']['readiness'], 'unknown')

    def test_http_failure_is_not_ready(self):
        result = MioStatusProbe(lambda *a, **k: types.SimpleNamespace(returncode=0,
            stdout=b'{"readyz":{"http":503,"state":"ready"}}')).snapshot()
        self.assertEqual(result['tunnel']['readiness'], 'unknown')

    def test_deadline_does_not_retry_or_expose_exception(self):
        calls = []
        def runner(argv, **kwargs):
            calls.append(1); raise subprocess.TimeoutExpired(argv, 2, output=b'secret')
        result = MioStatusProbe(runner).snapshot()
        self.assertEqual(result['error_code'], 'probe_deadline_exceeded'); self.assertEqual(calls, [1])
        self.assertNotIn('secret', json.dumps(result))

    def test_unsafe_locator_destinations(self):
        with tempfile.TemporaryDirectory() as home:
            path = Path(home)/'health-url.txt'
            for value in ('https://127.0.0.1:1234', 'http://example.com:1234',
                          'http://127.0.0.1:1234/private', 'http://u:p@127.0.0.1:1234',
                          'http://127.0.0.1:1234?key=secret', 'http://127.0.0.1:1234/#secret'):
                path.write_text(value); path.chmod(0o600)
                with self.subTest(value=value), self.assertRaises(ValueError): checked_base(path)

    def test_locator_owned_private_and_no_symlink(self):
        with tempfile.TemporaryDirectory() as home:
            path = Path(home)/'health-url.txt'; path.write_text('http://127.0.0.1:1234'); path.chmod(0o600)
            self.assertEqual(checked_base(path), 'http://127.0.0.1:1234')
            path.chmod(0o644)
            with self.assertRaises(ValueError): checked_base(path)
            path.chmod(0o600); alias = Path(home)/'alias'; alias.symlink_to(path)
            with self.assertRaises(ValueError): checked_base(alias)


if __name__ == '__main__': unittest.main()
