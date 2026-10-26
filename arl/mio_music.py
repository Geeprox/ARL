"""Mio protocol composition: preserve travel14 and publish honest music metadata.

The production constructor has no account transport. Playlist writes are paused
at this boundary even when a test/approved read transport is injected.
"""
from __future__ import annotations
import copy
import json
from urllib.parse import urlsplit
from uuid import UUID
from .contracts import Fault, object_schema, validate
from .netease_music import NeteaseMusicAdapter, LIST, DESCRIBE, CREATE, APPEND, SEARCH
from .service_connections import music_connection_status, service_catalog
from .travel import TravelAdapter

COVER = 'mio_netease_playlist_update_cover'
COVER_DESCRIPTOR = json.loads('{"name": "mio_netease_playlist_update_cover", "description": "Set the selected playlist cover from an HTTPS image URL, or use image_ref with a song_id returned by this playlist to select its coverImgUrl. The caller generates request_id and reuses it after uncertainty; repeated IDs only read back. No image SHA or previous cover is required. Original image composition is preserved; songs and cloud files are unchanged.", "inputSchema": {"type": "object", "additionalProperties": false, "required": ["request_id", "playlist_id"], "properties": {"request_id": {"type": "string", "format": "uuid", "minLength": 36, "maxLength": 36}, "intent": {"type": "string", "enum": ["update_playlist_cover"]}, "playlist_id": {"type": "string", "pattern": "^[0-9a-fA-F]{32}$", "minLength": 32, "maxLength": 32}, "image_url": {"type": "string", "minLength": 1}, "image_ref": {"type": "string", "pattern": "^[0-9a-fA-F]{32}$", "minLength": 32, "maxLength": 32}, "reconcile_only": {"type": "boolean", "default": false}}, "oneOf": [{"required": ["image_url"]}, {"required": ["image_ref"]}]}, "annotations": {"readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": true}}')
STATUS = 'mio_netease_connection_status'
ALIASES = {
    'mio_netease_playlist_list': LIST,
    'mio_netease_playlist_describe': DESCRIBE,
    'mio_netease_playlist_create': CREATE,
    'mio_netease_playlist_append_song': APPEND,
    'mio_netease_song_search': SEARCH,
}

class _ReadContext:
    def check_cancelled(self):
        return None

class MioMusicGateway:
    def __init__(self, legacy_respond, *, read_transport=None,
                 account_state='configuration_required'):
        if not callable(legacy_respond) or account_state not in {
                'configuration_required', 'login_required', 'contract_unverified', 'authorized_read'}:
            raise Fault('music_invalid_host_composition')
        if account_state == 'authorized_read' and read_transport is None:
            raise Fault('music_invalid_host_composition')
        self.legacy_respond = legacy_respond
        self.account_state = account_state
        self.adapter = NeteaseMusicAdapter(read_transport)
        self.travel = TravelAdapter().descriptors
        if len(self.travel) != 14:
            raise Fault('travel_catalog_changed')

    def _public_status(self):
        value = music_connection_status()
        value['state'] = self.account_state
        # No cached setup observation is promoted to a ready account session.
        value['ready'] = False
        return value

    def _music_tools(self):
        provider = next(r for r in service_catalog()['services'] if r['id'] == 'netease')
        rows = []
        for alias, name in ALIASES.items():
            descriptor = self.adapter.describe_capability(name)
            writes = name in {CREATE, APPEND}
            rows.append({'name': alias,
                         'description': provider['name'] + ('：写入暂停，需另行确认具体歌单和曲目。' if writes else '：配置、登录和账号调用尚需核验；未连接时返回明确状态。'),
                         'inputSchema': copy.deepcopy(descriptor['inputSchema']),
                         'annotations': {'readOnlyHint': not writes, 'destructiveHint': False,
                                         'idempotentHint': not writes, 'openWorldHint': True}})
        rows.append({'name': STATUS, 'description': '读取网易云连接状态和官方配置入口；不读取凭据，不登录，不访问账号。',
                     'inputSchema': object_schema(),
                     'annotations': {'readOnlyHint': True, 'destructiveHint': False,
                                     'idempotentHint': True, 'openWorldHint': False}})
        rows.append(copy.deepcopy(COVER_DESCRIPTOR))
        return rows

    @staticmethod
    def _result(value, error=False):
        return {'content': [{'type': 'text', 'text': json.dumps(value, ensure_ascii=False, separators=(',', ':'))}],
                'isError': error}

    def respond(self, request):
        if type(request) is not dict:
            raise Fault('invalid_request')
        if 'id' not in request:
            return self.legacy_respond(request)
        method = request.get('method')
        params = request.get('params', {})
        if method == 'tools/list':
            legacy = self.legacy_respond(request)
            if type(legacy) is not dict or type(legacy.get('result')) is not dict:
                raise Fault('travel_catalog_changed')
            tools = legacy['result'].get('tools')
            if tools != self.travel:
                raise Fault('travel_catalog_changed')
            reply = copy.deepcopy(legacy)
            reply['result']['tools'] += self._music_tools()
            return reply
        if method != 'tools/call' or type(params) is not dict or params.get('name') not in {*ALIASES, STATUS, COVER}:
            return self.legacy_respond(request)
        name, args = params['name'], params.get('arguments', {})
        try:
            if set(params) - {'name', 'arguments'}:
                raise Fault('invalid_arguments')
            if name == COVER:
                validate(args, COVER_DESCRIPTOR['inputSchema'])
                try:
                    if len(args['request_id']) != 36:
                        raise ValueError()
                    UUID(args['request_id'])
                    if ('image_url' in args) == ('image_ref' in args):
                        raise ValueError()
                    if 'image_url' in args:
                        url = urlsplit(args['image_url'])
                        if (not url.hostname or url.username is not None or url.password is not None
                                or any(ord(c) < 32 or ord(c) == 127 for c in args['image_url'])
                                or not (url.scheme == 'https' or url.scheme == 'http'
                                        and url.hostname in {'p1.music.126.net', 'p2.music.126.net'})):
                            raise ValueError()
                except (ValueError, TypeError, KeyError):
                    raise Fault('invalid_arguments')
                # Effects execute only in the authenticated, signed native owner.
                # The Python compatibility composition never opens its own CLI.
                raise Fault('music_write_authorization_required')
            elif name == STATUS:
                validate(args, object_schema())
                result = self._result(self._public_status())
            else:
                target = ALIASES[name]
                validate(args, self.adapter.describe_capability(target)['inputSchema'])
                if target in {CREATE, APPEND}:
                    raise Fault('music_write_authorization_required')
                if self.account_state != 'authorized_read':
                    raise Fault({'configuration_required': 'music_app_configuration_required',
                                 'login_required': 'music_login_required',
                                 'contract_unverified': 'music_contract_unverified'}[self.account_state])
                result = self._result(self.adapter.execute(target, args, _ReadContext()))
        except Fault as exc:
            permitted = {'invalid_arguments', 'music_write_authorization_required', 'music_app_configuration_required',
                         'music_login_required', 'music_contract_unverified', 'music_cli_unavailable',
                         'music_cli_changed', 'music_quota_exceeded', 'playlist_snapshot_incomplete'}
            code = exc.code if exc.code in permitted else 'music_unavailable'
            result = self._result({'error': {'code': code}, 'ready': False}, True)
        return {'jsonrpc': '2.0', 'id': request['id'], 'result': result}

def serve(gateway, source, destination):
    """Real bounded stdio protocol loop, also used by isolated IPC regression."""
    while True:
        raw = source.readline(16386)
        if not raw:
            return
        try:
            if len(raw) > 16384 or not raw.endswith('\n'):
                raise Fault('invalid_request')
            response = gateway.respond(json.loads(raw))
        except (Fault, ValueError, TypeError, KeyError):
            response = {'jsonrpc': '2.0', 'id': None, 'error': {'code': -32600, 'message': 'Invalid bounded request.'}}
        if response is not None:
            destination.write(json.dumps(response, ensure_ascii=False) + '\n')
            destination.flush()
