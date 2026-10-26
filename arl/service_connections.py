"""Public native credential catalog. Never reads credential/session contents."""
from __future__ import annotations

import json
from pathlib import Path
import unicodedata

from .contracts import Fault

CATALOG = Path(__file__).resolve().parents[1] / 'docs/service-connections.json'
_LIMIT = 16384
_CONTRACTS = {
    'amap': ('amap.maps-weather', ['mio_maps_']),
    'fliggy': ('fliggy.travel-readonly', ['mio_flyai_']),
    'netease': ('netease.music-account', ['netease.', 'mio_netease_']),
    'codex': (None, ['codex.']),
}
_REQUIRED = {'id', 'name', 'symbol', 'configuration', 'credential_purpose', 'tool_prefixes'}
_OPTIONAL = {'official_url', 'reason'}
_MUSIC_URL = 'https://github.com/NetEase/skills#ncm-cli-setup'


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('duplicate_catalog_key')
        result[key] = value
    return result


def _text(value, limit):
    return (type(value) is str and bool(value.strip())
            and len(value.encode('utf-8')) <= limit
            and all(unicodedata.category(char) not in {'Cc', 'Cf'} for char in value))


def _valid_row(row, expected_id):
    if type(row) is not dict or not _REQUIRED <= row.keys() or row.keys() - (_REQUIRED | _OPTIONAL):
        return False
    purpose, prefixes = _CONTRACTS[expected_id]
    configuration = 'host_scoped_model' if expected_id == 'codex' else 'native_credentials'
    if (row['id'] != expected_id or row['configuration'] != configuration
            or row['credential_purpose'] != purpose or row['tool_prefixes'] != prefixes
            or not _text(row['name'], 120) or not _text(row['symbol'], 80)):
        return False
    if 'reason' in row and not _text(row['reason'], 2048):
        return False
    if expected_id == 'netease':
        return row.get('official_url') == _MUSIC_URL and 'reason' in row
    if expected_id == 'codex':
        return 'official_url' not in row and 'reason' in row
    return 'official_url' not in row


def service_catalog():
    try:
        with CATALOG.open('rb') as source:
            raw = source.read(_LIMIT + 1)
        if len(raw) > _LIMIT:
            raise ValueError('catalog_limit')
        value = json.loads(raw, object_pairs_hook=_unique_object)
        if (type(value) is not dict or set(value) != {'schema_version', 'services'}
                or type(value['schema_version']) is not int or value['schema_version'] != 1):
            raise ValueError('catalog_schema')
        rows = value['services']
        if (type(rows) is not list or len(rows) != len(_CONTRACTS)
                or not all(_valid_row(row, identifier) for row, identifier in zip(rows, _CONTRACTS))):
            raise ValueError('catalog_services')
        return value
    except (OSError, ValueError, TypeError, UnicodeError, RecursionError):
        raise Fault('invalid_service_catalog') from None


def music_connection_status():
    """Public metadata has no SDK/account evidence and never implies login."""
    row = next(row for row in service_catalog()['services'] if row['id'] == 'netease')
    return {
        'service_id': row['id'], 'state': 'connection_unverified',
        'ready': False, 'configuration': 'not_verified', 'login': 'not_verified',
        'configuration_method': row['configuration'],
        'credential_purpose': row['credential_purpose'],
        'configuration_ui': 'ARL Control > 服务连接 > 网易云音乐',
        'official_url': row['official_url'],
        'account_access': 'not_authorized', 'writes': 'paused',
        'reason': row['reason'], 'credential_contents_read': False,
    }
