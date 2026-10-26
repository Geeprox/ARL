"""Isolated read-only weather extension. Not registered in any running service."""
from __future__ import annotations

import datetime as dt
import json
import re
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

ENDPOINT = 'https://restapi.amap.com/v3/weather/weatherInfo'
MAX_REPLY = 65536


class WeatherFault(Exception):
    def __init__(self, code, retryable=False):
        self.code, self.retryable = code, retryable
        super().__init__(code)


@dataclass(frozen=True)
class WeatherRequest:
    adcode: str
    extensions: str

    @property
    def params(self):
        return {'city': self.adcode, 'extensions': self.extensions, 'output': 'JSON'}


def request_for(args):
    if (type(args) is not dict or not {'adcode'} <= args.keys() or
            args.keys() - {'adcode', 'mode'} or type(args['adcode']) is not str or
            not re.fullmatch('[0-9]{6}', args['adcode']) or
            args.get('mode', 'current') not in ('current', 'forecast')):
        raise WeatherFault('invalid_arguments')
    return WeatherRequest(args['adcode'], 'base' if args.get('mode', 'current') == 'current' else 'all')


def text(value, limit=128):
    if type(value) is not str or not value or len(value) > limit or any(ord(c) < 32 for c in value):
        raise WeatherFault('invalid_provider_response')
    return value


def number(value, low, high):
    if value in (None, ''):
        return None
    if type(value) is not str or not re.fullmatch(r'-?[0-9]{1,3}(\.[0-9]{1,2})?', value):
        raise WeatherFault('invalid_provider_response')
    value = float(value)
    if not low <= value <= high:
        raise WeatherFault('invalid_provider_response')
    return value


def report_time(value):
    raw = text(value, 19)
    try:
        if dt.datetime.strptime(raw, '%Y-%m-%d %H:%M:%S').strftime('%Y-%m-%d %H:%M:%S') != raw:
            raise ValueError()
    except ValueError:
        raise WeatherFault('invalid_provider_response') from None
    return raw  # Preserve provider text; the upstream schema gives no timezone.


def normalize(data, request, fetched_at_ms):
    if type(data) is not dict:
        raise WeatherFault('invalid_provider_response')
    if data.get('status') != '1' or data.get('infocode') != '10000':
        code = data.get('infocode')
        if code in {'10001', '10009', '10013'}:
            raise WeatherFault('credential_unavailable')
        if code in {'10002', '10005', '10006', '10007', '10008', '10012'}:
            raise WeatherFault('permission_denied')
        if code in {'10003', '10004', '10010'}:
            raise WeatherFault('rate_limited')
        if code in {'20000', '20001'}:
            raise WeatherFault('invalid_arguments')
        raise WeatherFault('provider_unavailable', retryable=True)
    key = 'lives' if request.extensions == 'base' else 'forecasts'
    rows = data.get(key)
    if type(rows) is not list:
        raise WeatherFault('invalid_provider_response')
    if not rows:
        raise WeatherFault('no_data')
    if len(rows) != 1 or type(rows[0]) is not dict or rows[0].get('adcode') != request.adcode:
        raise WeatherFault('location_mismatch')
    row = rows[0]
    result = {'schema_version': 1, 'source': 'amap', 'adcode': request.adcode,
              'city': text(row.get('city')), 'province': text(row.get('province')),
              'mode': 'current' if request.extensions == 'base' else 'forecast',
              'report_time': report_time(row.get('reporttime')), 'report_timezone': None,
              'fetched_at_ms': fetched_at_ms, 'current': None, 'forecast': []}
    if request.extensions == 'base':
        result['current'] = {'weather': text(row.get('weather')),
            'temperature_celsius': number(row.get('temperature'), -100, 100),
            'humidity_percent': number(row.get('humidity'), 0, 100),
            'wind_direction': text(row.get('winddirection')),
            'wind_force': text(row.get('windpower'))}
    else:
        casts = row.get('casts')
        if type(casts) is not list or not 1 <= len(casts) <= 8:
            raise WeatherFault('invalid_provider_response')
        dates = set()
        for cast in casts:
            if type(cast) is not dict:
                raise WeatherFault('invalid_provider_response')
            date = text(cast.get('date'), 10)
            try:
                if dt.date.fromisoformat(date).isoformat() != date or date in dates:
                    raise ValueError()
            except ValueError:
                raise WeatherFault('invalid_provider_response') from None
            dates.add(date)
            result['forecast'].append({'date': date, 'day_weather': text(cast.get('dayweather')),
                'night_weather': text(cast.get('nightweather')),
                'day_temperature_celsius': number(cast.get('daytemp'), -100, 100),
                'night_temperature_celsius': number(cast.get('nighttemp'), -100, 100),
                'day_wind': text(cast.get('daywind')), 'night_wind': text(cast.get('nightwind')),
                'day_wind_force': text(cast.get('daypower')), 'night_wind_force': text(cast.get('nightpower'))})
    return result


class WeatherAdapter:
    """Injected host transport owns credentials and its overall network deadline."""
    def __init__(self, transport=None, clock=None):
        self.transport = transport
        self.clock = clock or (lambda: int(time.time() * 1000))

    def call(self, args):
        request = request_for(args)
        if self.transport is None:
            raise WeatherFault('transport_not_enabled')
        try:
            reply = self.transport(request)
        except WeatherFault:
            raise
        except Exception:
            raise WeatherFault('provider_unavailable', retryable=True) from None
        try:
            size = len(json.dumps(reply, ensure_ascii=False, allow_nan=False).encode())
        except (ValueError, TypeError):
            raise WeatherFault('invalid_provider_response') from None
        if size > MAX_REPLY:
            raise WeatherFault('response_too_large')
        return normalize(reply, request, self.clock())

    def mcp_result(self, args):
        try:
            body, error = self.call(args), False
        except WeatherFault as exc:
            body, error = {'schema_version': 1, 'error': {'code': exc.code, 'retryable': exc.retryable}}, True
        return {'content': [{'type': 'text', 'text': json.dumps(body, ensure_ascii=False, allow_nan=False)}],
                'isError': error}


class FixedHTTPSWeatherTransport:
    """Optional source-only transport. Key callback is host-injected, never tool input.

    The short-lived worker receives the key over stdin, not argv/env/files. Its
    deadline is enforced by subprocess.run; no redirect, proxy, pull or retry.
    No callback is invoked on construction. Production wiring is not installed.
    """
    def __init__(self, key_provider, runner=subprocess.run, deadline_seconds=5):
        if type(deadline_seconds) not in (int, float) or not 0 < deadline_seconds <= 5:
            raise ValueError('invalid_weather_deadline')
        self.key_provider, self.runner, self.deadline = key_provider, runner, deadline_seconds

    def __call__(self, request):
        try:
            key = self.key_provider()
        except Exception:
            raise WeatherFault('credential_unavailable') from None
        if type(key) is not str or not re.fullmatch('[A-Za-z0-9_-]{16,128}', key):
            raise WeatherFault('credential_unavailable')
        raw = json.dumps({'key': key, 'params': request.params}).encode()
        try:
            reply = self.runner([sys.executable, '-I', str(Path(__file__).with_name('http_worker.py'))],
                input=raw, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                timeout=self.deadline, env={'PATH': '/usr/bin:/bin:/usr/sbin:/sbin'})
        except subprocess.TimeoutExpired:
            raise WeatherFault('deadline_exceeded', retryable=True) from None
        except OSError:
            raise WeatherFault('provider_unavailable', retryable=True) from None
        if reply.returncode != 0:
            raise WeatherFault('provider_unavailable', retryable=True)
        if len(reply.stdout) > MAX_REPLY:
            raise WeatherFault('response_too_large')
        try:
            return json.loads(reply.stdout)
        except (ValueError, TypeError):
            raise WeatherFault('invalid_provider_response') from None
