import copy
import io
import json
import hashlib
import subprocess
import types
import unittest
from pathlib import Path
from unittest.mock import patch

from adapter import ENDPOINT, WeatherAdapter, FixedHTTPSWeatherTransport, WeatherFault, request_for
import http_worker

FAKE_KEY = 'fixture_only_not_a_real_key'
LIVE = {'status': '1', 'infocode': '10000', 'lives': [{'adcode': '310101', 'city': '黄浦区',
    'province': '上海市', 'reporttime': '2026-10-01 08:00:00', 'weather': '多云',
    'temperature': '24.5', 'humidity': '60', 'winddirection': '东北', 'windpower': '≤3'}]}
FORECAST = {'status': '1', 'infocode': '10000', 'forecasts': [{'adcode': '310101',
    'city': '黄浦区', 'province': '上海市', 'reporttime': '2026-10-01 08:00:00', 'casts': [{
        'date': '2026-10-01', 'dayweather': '多云', 'nightweather': '阴', 'daytemp': '25',
        'nighttemp': '18', 'daywind': '东北', 'nightwind': '北', 'daypower': '≤3', 'nightpower': '≤3'}]}]}


class WeatherTests(unittest.TestCase):
    def adapter(self, data=LIVE):
        return WeatherAdapter(lambda request: copy.deepcopy(data), clock=lambda: 1790784000000)

    def error(self, result, code):
        self.assertTrue(result['isError']); body = json.loads(result['content'][0]['text'])
        self.assertEqual(body['error']['code'], code)

    def test_current_and_default_use_base(self):
        calls = []
        adapter = WeatherAdapter(lambda request: calls.append(request) or LIVE)
        result = adapter.call({'adcode': '310101'})
        self.assertEqual(calls[0].params, {'city': '310101', 'extensions': 'base', 'output': 'JSON'})
        self.assertEqual(result['current']['temperature_celsius'], 24.5)
        self.assertIsNone(result['report_timezone']); self.assertEqual(result['forecast'], [])

    def test_forecast_uses_all(self):
        calls = []
        result = WeatherAdapter(lambda r: calls.append(r) or FORECAST).call({'adcode': '310101', 'mode': 'forecast'})
        self.assertEqual(calls[0].extensions, 'all'); self.assertIsNone(result['current'])
        self.assertEqual(result['forecast'][0]['date'], '2026-10-01')

    def test_bad_input_never_calls_transport(self):
        calls = []
        adapter = WeatherAdapter(lambda r: calls.append(r) or LIVE)
        for args in [None, [], {}, {'adcode': 310101}, {'adcode': '３１０１０１'}, {'adcode': 'Shanghai'},
                     {'adcode': '310101\n'}, {'adcode': '310101', 'mode': 'hourly'},
                     {'adcode': '310101', 'key': FAKE_KEY}, {'adcode': '310101', 'url': ENDPOINT},
                     {'adcode': '310101', 'mode': True}]:
            with self.subTest(args=args): self.error(adapter.mcp_result(args), 'invalid_arguments')
        self.assertEqual(calls, [])

    def test_default_transport_disabled(self):
        self.error(WeatherAdapter().mcp_result({'adcode': '310101'}), 'transport_not_enabled')

    def test_location_mismatch_rejected(self):
        data = copy.deepcopy(LIVE); data['lives'][0]['adcode'] = '110101'
        self.error(self.adapter(data).mcp_result({'adcode': '310101'}), 'location_mismatch')

    def test_no_data_is_not_success(self):
        self.error(self.adapter({'status': '1', 'infocode': '10000', 'lives': []}).mcp_result({'adcode': '310101'}), 'no_data')

    def test_error_mapping_and_no_secret_or_exception(self):
        mapping = {'10001': 'credential_unavailable', '10002': 'permission_denied',
                   '10012': 'permission_denied', '10003': 'rate_limited', '10004': 'rate_limited',
                   '20000': 'invalid_arguments', '99999': 'provider_unavailable'}
        for code, expected in mapping.items():
            result = self.adapter({'status': '0', 'infocode': code, 'info': FAKE_KEY}).mcp_result({'adcode': '310101'})
            self.error(result, expected); self.assertNotIn(FAKE_KEY, json.dumps(result))
        def fail(_): raise RuntimeError('request?key='+FAKE_KEY)
        result = WeatherAdapter(fail).mcp_result({'adcode': '310101'})
        self.error(result, 'provider_unavailable'); self.assertNotIn(FAKE_KEY, json.dumps(result))

    def test_unknown_upstream_fields_not_forwarded(self):
        data = copy.deepcopy(LIVE); data['key'] = FAKE_KEY; data['lives'][0]['notes'] = FAKE_KEY
        self.assertNotIn(FAKE_KEY, json.dumps(self.adapter(data).mcp_result({'adcode': '310101'})))

    def test_missing_numeric_is_nullable_not_zero(self):
        data = copy.deepcopy(LIVE); data['lives'][0]['temperature'] = ''; data['lives'][0]['humidity'] = None
        current = self.adapter(data).call({'adcode': '310101'})['current']
        self.assertIsNone(current['temperature_celsius']); self.assertIsNone(current['humidity_percent'])

    def test_invalid_numeric_and_report_time(self):
        for field, value in [('temperature', 'NaN'), ('humidity', '101'), ('reporttime', 'yesterday')]:
            data = copy.deepcopy(LIVE); data['lives'][0][field] = value
            self.error(self.adapter(data).mcp_result({'adcode': '310101'}), 'invalid_provider_response')

    def test_forecast_dates_and_bounds_not_truncated(self):
        for casts in [[], FORECAST['forecasts'][0]['casts'] * 9, FORECAST['forecasts'][0]['casts'] * 2,
                      [dict(FORECAST['forecasts'][0]['casts'][0], date='2026-02-30')]]:
            data = copy.deepcopy(FORECAST); data['forecasts'][0]['casts'] = casts
            self.error(self.adapter(data).mcp_result({'adcode': '310101', 'mode': 'forecast'}), 'invalid_provider_response')

    def test_response_size_and_json_rejected(self):
        data = copy.deepcopy(LIVE); data['extra'] = 'x' * 65537
        self.error(self.adapter(data).mcp_result({'adcode': '310101'}), 'response_too_large')
        self.error(self.adapter({'value': float('nan')}).mcp_result({'adcode': '310101'}), 'invalid_provider_response')

    def test_mcp_success_envelope_and_timestamp(self):
        result = self.adapter().mcp_result({'adcode': '310101'})
        self.assertEqual(set(result), {'content', 'isError'}); self.assertFalse(result['isError'])
        body = json.loads(result['content'][0]['text']); self.assertEqual(body['schema_version'], 1)
        self.assertEqual(body['fetched_at_ms'], 1790784000000)
        self.assertEqual(body['report_time'], '2026-10-01 08:00:00')

    def test_schema_and_existing_13_unchanged(self):
        root = Path(__file__).resolve().parents[2]
        data = (root/'docs/mio-tools.json').read_bytes()
        self.assertEqual(hashlib.sha256(data).hexdigest(), '6649a0db844fbd29141be75da0320a11f57f887d3fbdf148730926d44b02bfff')
        existing = json.loads(data)['tools']; self.assertEqual(len(existing), 13)
        new = json.loads(Path(__file__).with_name('tool.json').read_text())
        self.assertEqual(new['name'], 'mio_maps_weather'); self.assertNotIn(new['name'], {t['name'] for t in existing})
        self.assertFalse(new['inputSchema']['additionalProperties']); self.assertTrue(new['annotations']['readOnlyHint'])

    def test_host_key_callback_lazy_and_never_argv_env(self):
        calls = []
        def run(argv, **kwargs):
            self.assertNotIn(FAKE_KEY, str(argv)); self.assertNotIn(FAKE_KEY, str(kwargs['env']))
            self.assertEqual(json.loads(kwargs['input'])['params']['extensions'], 'base')
            self.assertEqual(kwargs['timeout'], 5); self.assertEqual(kwargs['stderr'], subprocess.DEVNULL)
            return types.SimpleNamespace(returncode=0, stdout=json.dumps(LIVE).encode())
        transport = FixedHTTPSWeatherTransport(lambda: calls.append(1) or FAKE_KEY, runner=run)
        self.assertEqual(calls, []); transport(request_for({'adcode': '310101'})); self.assertEqual(calls, [1])

    def test_transport_deadline_sanitized_without_retry(self):
        calls = []
        def run(argv, **kwargs):
            calls.append(1); raise subprocess.TimeoutExpired(argv, kwargs['timeout'], output=FAKE_KEY)
        result = WeatherAdapter(FixedHTTPSWeatherTransport(lambda: FAKE_KEY, runner=run)).mcp_result({'adcode': '310101'})
        self.error(result, 'deadline_exceeded'); self.assertNotIn(FAKE_KEY, json.dumps(result)); self.assertEqual(calls, [1])

    def test_key_callback_failure_sanitized(self):
        def key(): raise RuntimeError(FAKE_KEY)
        result = WeatherAdapter(FixedHTTPSWeatherTransport(key)).mcp_result({'adcode': '310101'})
        self.error(result, 'credential_unavailable'); self.assertNotIn(FAKE_KEY, json.dumps(result))

    def test_worker_get_fixed_https_no_redirect_no_proxy(self):
        class Response:
            def __enter__(self): return self
            def __exit__(self, *_): pass
            def read(self, count):
                self_count = count; self_outer.assertEqual(self_count, 65537)
                return json.dumps(LIVE).encode()
        self_outer = self
        def open_request(request, timeout):
            self.assertEqual(request.get_method(), 'GET'); self.assertTrue(request.full_url.startswith(ENDPOINT+'?'))
            self.assertEqual(timeout, 5); return Response()
        opener = types.SimpleNamespace(open=open_request)
        output = io.BytesIO(); stdin = io.BytesIO(json.dumps({'key': FAKE_KEY, 'params': request_for({'adcode': '310101'}).params}).encode())
        with patch.object(http_worker.sys, 'stdin', types.SimpleNamespace(buffer=stdin)), \
             patch.object(http_worker.sys, 'stdout', types.SimpleNamespace(buffer=output)), \
             patch.object(http_worker.urllib.request, 'build_opener', return_value=opener) as build:
            self.assertEqual(http_worker.main(), 0)
            self.assertEqual(build.call_args.args[0].proxies, {})
            with self.assertRaises(ValueError): build.call_args.args[1].redirect_request(None, None, None, None, None, None)
        self.assertEqual(json.loads(output.getvalue()), LIVE)


if __name__ == '__main__': unittest.main()
