"""NAS 上的按应用路由、每日请求限额和持久化回执。"""
import argparse
from contextlib import closing, contextmanager
from datetime import datetime
import fcntl
from functools import partial
import hashlib
import http.client
from ipaddress import IPv4Address
import json
import os
from pathlib import Path
import re
import signal
import sqlite3
import stat
import sys
import threading
import time
import uuid
from zoneinfo import ZoneInfo

sys.path.insert(0, str(Path(__file__).resolve().parent))
from contract import APPS, MODEL, encode, normalize, text_request, time_stale
from local_api import atomic, chat_completion, codex_completion, failure, model_listing, read_json, server


ROUTES = {
    'codex': ('codex',),
    'openai': ('openai',),
    'codex_preferred': ('codex', 'openai'),
    'openai_preferred': ('openai', 'codex'),
}
OPENAI_HOST = 'api.openai.com'
LOCAL_DAY = ZoneInfo('Asia/Shanghai')


def proxy_address(value):
    try:
        host, port = value.split(':')
        address = IPv4Address(host)
        first, second, _, _ = address.packed
        is_lan = first == 10 or first == 172 and 16 <= second <= 31 or (first, second) == (192, 168)
        if is_lan and port.isascii() and port.isdigit() and 1 <= int(port) <= 65535:
            return str(address), int(port)
    except ValueError:
        pass
    raise argparse.ArgumentTypeError('OpenAI 出网代理需要内网 IPv4:端口')


def valid_limit(value):
    return value is None or (type(value) is int and 0 <= value <= 100000)


def validate_policy(value, apps):
    required = {'schema', 'revision', 'apps'}
    if (type(value) is not dict or not required <= value.keys() <= required | {'global_daily_api_requests'}
            or value['schema'] != 1):
        raise ValueError('invalid_routing_policy')
    if type(value['revision']) is not str or str(uuid.UUID(value['revision'])) != value['revision']:
        raise ValueError('invalid_policy_revision')
    if not valid_limit(value.get('global_daily_api_requests')) or type(value['apps']) is not dict or set(value['apps']) != set(apps):
        raise ValueError('invalid_policy_limits_or_apps')
    required = {'mode', 'api_model'}
    for config in value['apps'].values():
        if (type(config) is not dict or not required <= config.keys() <= required | {'daily_api_requests'}
                or type(config['mode']) is not str or config['mode'] not in ROUTES
                or not valid_limit(config.get('daily_api_requests'))
                or type(config['api_model']) is not str or not re.fullmatch(r'gpt-[A-Za-z0-9._-]{1,95}', config['api_model'])):
            raise ValueError('invalid_application_policy')
    return value


class Policy:
    def __init__(self, control, state, apps):
        self.path = control / 'policy.json'
        self.accepted = state / 'policy.accepted.json'
        self.apps = apps
        self.lock = threading.Lock()
        self.current = None
        self.invalid = False
        try:
            self.current = validate_policy(read_json(self.accepted, 32768), apps)
        except (OSError, ValueError, TypeError):
            pass
        self.read()

    def read(self):
        with self.lock:
            try:
                desired = validate_policy(read_json(self.path, 32768), self.apps)
                if self.current is not None and desired['revision'] == self.current['revision'] and desired != self.current:
                    raise ValueError('policy_revision_reused')
                if self.current != desired:
                    atomic(self.accepted, desired)
                    self.current = desired
                self.invalid = False
            except (OSError, ValueError, TypeError):
                self.invalid = True
                if self.current is None:
                    raise ValueError('routing_policy_unavailable') from None
            return self.current


class Ledger:
    def __init__(self, path):
        self.path = path
        fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid():
                raise ValueError('private_router_ledger_required')
            # 目录的默认 ACL 可能在创建时附带组权限，重新设置后以 NAS 读回为准。
            if info.st_mode & 0o077:
                os.fchmod(fd, 0o600)
                if os.fstat(fd).st_mode & 0o077:
                    raise ValueError('private_router_ledger_required')
        finally:
            os.close(fd)
        with closing(self.connect()) as db:
            db.execute('PRAGMA journal_mode=WAL')
            db.executescript("""
                CREATE TABLE IF NOT EXISTS requests (
                    app TEXT NOT NULL, id TEXT NOT NULL, fingerprint TEXT NOT NULL, day TEXT NOT NULL,
                    started_at INTEGER NOT NULL, revision TEXT NOT NULL,
                    provider TEXT, reason TEXT, api_attempt INTEGER NOT NULL,
                    status INTEGER, body TEXT, observed_tokens INTEGER,
                    PRIMARY KEY (app, id)
                );
                CREATE INDEX IF NOT EXISTS usage_day ON requests (day, api_attempt, app);
            """)

    def connect(self):
        db = sqlite3.connect(self.path, timeout=10, isolation_level=None)
        db.row_factory = sqlite3.Row
        return db

    @contextmanager
    def admission(self):
        with closing(self.connect()) as db:
            db.execute('BEGIN IMMEDIATE')
            try:
                yield db
                db.commit()
            except BaseException:
                db.rollback()
                raise

    @staticmethod
    def counts(db, day, app):
        row = db.execute(
            'SELECT COUNT(*) AS total, COALESCE(SUM(app = ?), 0) AS own, '
            'COALESCE(SUM(CASE WHEN app = ? THEN observed_tokens END), 0) AS tokens '
            'FROM requests WHERE day = ? AND api_attempt = 1', (app, app, day),
        ).fetchone()
        return row['total'], row['own'], row['tokens']

    def finish(self, app, identity, provider, reason, status, body, tokens):
        with closing(self.connect()) as db:
            db.execute(
                'UPDATE requests SET provider = ?, reason = ?, status = ?, body = ?, observed_tokens = ? '
                'WHERE app = ? AND id = ?', (provider, reason, status, encode(body).decode(), tokens, app, identity),
            )

    def prune(self):
        now = int(time.time())
        with closing(self.connect()) as db:
            db.execute('UPDATE requests SET body = NULL WHERE started_at < ? AND body IS NOT NULL', (now - 86400,))
            db.execute('DELETE FROM requests WHERE started_at < ?', (now - 30 * 86400,))


class OpenAIError(Exception):
    def __init__(self, code, *, rejected=False, tokens=None):
        super().__init__(code)
        self.rejected = rejected
        self.tokens = tokens


def credential(path):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, encoding='ascii') as stream:
            info = os.fstat(stream.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_mode & 0o077 or info.st_size > 2048:
                return None
            value = stream.read(2049).strip()
        return value if re.fullmatch(r'sk-[A-Za-z0-9_-]{20,1000}', value) else None
    except (OSError, UnicodeError):
        return None


def openai_completion(key, model, value, request, *, proxy=None):
    # 固定上游和文本请求结构，应用的认证令牌仅用于 NAS。
    payload = {'model': model, 'messages': request['messages'], 'max_completion_tokens': 4096, 'store': False}
    headers = {
        'Authorization': 'Bearer ' + key, 'Content-Type': 'application/json',
        'Host': OPENAI_HOST,
    }
    host, port = proxy or (OPENAI_HOST, 443)
    connection = http.client.HTTPSConnection(host, port, timeout=8)
    try:
        try:
            if proxy is not None:
                connection.set_tunnel(OPENAI_HOST, 443)
            connection.connect()
        except (OSError, http.client.HTTPException):
            # 建连或 TLS 握手失败时还未发送请求，允许切换到备用通道。
            raise OpenAIError('api_unreachable', rejected=True) from None
        connection.sock.settimeout(100)
        try:
            connection.request('POST', '/v1/chat/completions', body=encode(payload), headers=headers)
            with connection.getresponse() as response:
                code = response.status
                if code in (401, 403, 404, 429):
                    raise OpenAIError('api_rate_or_quota' if code == 429 else 'api_access_rejected', rejected=True)
                if code != 200:
                    raise OpenAIError('api_result_unknown')
                raw = response.read(262145)
                if len(raw) > 262144:
                    raise OpenAIError('api_output_unavailable')
                data = json.loads(raw)
        except (OSError, http.client.HTTPException, ValueError, UnicodeError):
            # 发送后的传输异常无法确认是否已计费，保留该次尝试。
            raise OpenAIError('api_result_unknown') from None
    finally:
        connection.close()
    tokens = None
    usage = data.get('usage') if type(data) is dict else None
    if type(usage) is dict and all(type(usage.get(key)) is int and usage[key] >= 0
                                  for key in ('prompt_tokens', 'completion_tokens', 'total_tokens')):
        usage = {key: usage[key] for key in ('prompt_tokens', 'completion_tokens', 'total_tokens')}
        tokens = usage['total_tokens']
    try:
        choice, = data['choices']
        text = choice['message']['content']
        reason = choice['finish_reason']
        if not isinstance(text, str) or not text.strip() or len(text.encode()) > 32768 or reason not in ('stop', 'length'):
            raise ValueError('invalid_completion')
    except (KeyError, IndexError, TypeError, ValueError):
        raise OpenAIError('api_output_unavailable', tokens=tokens) from None
    body = chat_completion(request['id'], value['model'], text, reason)
    if tokens is not None:
        body['usage'] = usage
    body['arl'] = {'request_id': request['id'], 'provider': 'openai', 'api_model': model}
    return 200, body, tokens


class Router:
    def __init__(self, queue, control, state, key_file, apps, *, api=openai_completion, codex=codex_completion):
        self.queue = queue
        self.control = control
        self.key_file = key_file
        self.apps = tuple(apps)
        self.policy = Policy(control, state, self.apps)
        self.ledger = Ledger(state / 'usage.sqlite3')
        self.api = api
        self.codex = codex

    def catalog(self, app):
        try:
            catalog = read_json(self.queue / app / 'catalog.json', 131072)
            if not time_stale(catalog):
                return catalog
        except (OSError, ValueError, TypeError):
            pass
        return None

    def models(self, app):
        mode = self.policy.read()['apps'][app]['mode']
        routes = ROUTES[mode]
        catalog = self.catalog(app) if 'codex' in routes else None
        if catalog is not None:
            return 200, model_listing(app, catalog)
        if 'openai' in routes and credential(self.key_file):
            return 200, model_listing(app, {
                'models': [{'id': MODEL, 'object': 'model', 'owned_by': 'arl'}],
                'schema_version': 2, 'catalog_version': 'nas-router', 'package_revision': 'api',
                'quota_policy': 'nas_daily_api_requests', 'local_lifetime_call_limit': None,
            })
        return 503, failure('provider_unavailable')

    def complete(self, app, value, request_id):
        identity = str(uuid.uuid4()) if request_id is None else str(uuid.UUID(request_id))
        if request_id is not None and identity != request_id:
            raise ValueError('invalid_request_id')
        if type(value) is not dict or type(value.get('model')) is not str:
            raise ValueError('invalid_text_request')
        fingerprint = hashlib.sha256(encode(value)).hexdigest()
        policy = self.policy.read()
        config = policy['apps'][app]
        routes = ROUTES[config['mode']]
        root = self.queue / app
        catalog = self.catalog(app) if 'codex' in routes else None
        key = credential(self.key_file) if 'openai' in routes else None
        prepared = {}
        if catalog is not None:
            try:
                prepared['codex'] = normalize(app, value, catalog, request_id=identity)
            except ValueError:
                pass
        if key is not None and 1 <= len(value['model']) <= 256:
            prepared['openai'] = {'id': identity, 'messages': text_request(app, value)}

        with self.ledger.admission() as db:
            day = datetime.now(LOCAL_DAY).date().isoformat()
            existing = db.execute('SELECT * FROM requests WHERE app = ? AND id = ?', (app, identity)).fetchone()
            if existing is not None:
                if existing['fingerprint'] != fingerprint:
                    return 409, failure('request_id_conflict', identity), None
                if existing['body'] is not None:
                    return existing['status'], json.loads(existing['body']), existing['provider']
                code = 'request_receipt_expired' if existing['status'] is not None else 'request_pending_or_unknown'
                return 422, failure(code, identity), existing['provider']
            global_used, app_used, _ = self.ledger.counts(db, day, app)
            global_limit = policy.get('global_daily_api_requests')
            app_limit = config.get('daily_api_requests')
            capped = ((global_limit is not None and global_used >= global_limit)
                      or (app_limit is not None and app_used >= app_limit))
            provider = None
            reason = None
            for candidate in routes:
                if candidate == 'openai' and capped:
                    reason = reason or 'daily_api_limit'
                    continue
                if candidate in prepared:
                    provider = candidate
                    break
                reason = reason or ('codex_unavailable' if candidate == 'codex' else 'api_unavailable')
            if provider is None:
                return (429 if reason == 'daily_api_limit' else 503), failure(reason, identity), None
            db.execute(
                'INSERT INTO requests (app,id,fingerprint,day,started_at,revision,provider,reason,api_attempt) '
                'VALUES (?,?,?,?,?,?,?,?,?)',
                (app, identity, fingerprint, day, int(time.time()), policy['revision'], provider, reason, int(provider == 'openai')),
            )
        tokens = None
        if provider == 'openai':
            try:
                status, body, tokens = self.api(key, config['api_model'], value, prepared['openai'])
            except OpenAIError as error:
                tokens = error.tokens
                reason = str(error)
                if error.rejected and 'codex' in prepared:
                    provider = 'codex'
                else:
                    status, body = (429 if reason == 'api_rate_or_quota' else 422), failure(reason, identity)
        if provider == 'codex':
            try:
                status, body = self.codex(app, root, value, prepared['codex'])
            except (OSError, ValueError, KeyError, TypeError):
                status, body = 422, failure('codex_result_unknown', identity)
        self.ledger.finish(app, identity, provider, reason, status, body, tokens)
        return status, body, provider

    def publish(self):
        policy = self.policy.read()
        today = datetime.now(LOCAL_DAY).date().isoformat()
        entries = {}
        with closing(self.ledger.connect()) as db:
            total = 0
            api_configured = credential(self.key_file) is not None
            for app in self.apps:
                total, used, tokens = self.ledger.counts(db, today, app)
                row = db.execute(
                    'SELECT provider, reason, status FROM requests WHERE app = ? ORDER BY rowid DESC LIMIT 1', (app,),
                ).fetchone()
                entries[app] = {
                    'mode': policy['apps'][app]['mode'], 'daily_api_requests': policy['apps'][app].get('daily_api_requests'),
                    'api_requests': used, 'reported_tokens': tokens, 'codex_ready': self.catalog(app) is not None,
                    'last_provider': row['provider'] if row else None, 'last_reason': row['reason'] if row else None,
                    'last_status': row['status'] if row else None,
                }
        atomic(self.control / 'status.json', {
            'schema': 1, 'applied_revision': policy['revision'], 'updated_at': int(time.time()), 'day': today,
            'policy_invalid': self.policy.invalid, 'api_configured': api_configured, 'api_requests': total, 'apps': entries,
            'global_daily_api_requests': policy.get('global_daily_api_requests'),
        })


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--queue', type=Path, default=Path('/queue'))
    parser.add_argument('--control', type=Path, default=Path('/control'))
    parser.add_argument('--state', type=Path, default=Path('/state'))
    parser.add_argument('--key-file', type=Path, default=Path('/run/secrets/openai'))
    parser.add_argument('--openai-proxy', type=proxy_address)
    parser.add_argument('--robin-token-file', type=Path)
    parser.add_argument('apps', choices=APPS, nargs='+')
    args = parser.parse_args()
    proxy = args.openai_proxy
    if proxy is None:
        proxy_file = Path(__file__).resolve().with_name('openai-egress.json')
        try:
            value = read_json(proxy_file, 256)
        except FileNotFoundError:
            pass
        else:
            if type(value) is not dict or set(value) != {'connect'} or type(value['connect']) is not str:
                parser.error('无效的 OpenAI 出网配置')
            try:
                proxy = proxy_address(value['connect'])
            except argparse.ArgumentTypeError as error:
                parser.error(str(error))
    os.umask(0o077)
    stopped = threading.Event()
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda *_: stopped.set())
    with (args.state / 'router.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        router = Router(args.queue, args.control, args.state, args.key_file, sorted(set(args.apps)),
                        api=partial(openai_completion, proxy=proxy))
        router.ledger.prune()
        listeners = []
        try:
            for app in router.apps:
                root = args.queue / app
                token_path = args.robin_token_file if app == 'robin' and args.robin_token_file else root / 'secret/token'
                fd = os.open(token_path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
                with os.fdopen(fd, encoding='ascii') as stream:
                    token = stream.read(513).strip()
                if not token or len(token) > 512 or not token.isascii() or any(ord(c) < 33 or ord(c) > 126 for c in token):
                    raise ValueError('invalid_app_bridge_token')
                path = root / 'router.sock'
                if path.is_socket():
                    path.unlink()
                listener = server(app, root, token, router=router, socket_path=path)
                listeners.append((listener, path))
                path.chmod(0o600)
            for listener, _ in listeners:
                threading.Thread(target=listener.serve_forever, daemon=True).start()
            next_prune = time.monotonic() + 3600
            while not stopped.is_set():
                router.publish()
                if time.monotonic() >= next_prune:
                    router.ledger.prune()
                    next_prune = time.monotonic() + 3600
                stopped.wait(3)
        finally:
            for listener, path in listeners:
                listener.server_close()
                path.unlink(missing_ok=True)


if __name__ == '__main__':
    main()
