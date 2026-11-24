"""容器回环的 OpenAI 兼容入口和 NAS 路由器的私有套接字。"""
import hmac
import http.client
import json
import os
import socket
import socketserver
import stat
import sys
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from contract import APPS, encode, normalize, time_stale
from model_context import TRANSPORT_FRAME_BYTES


def atomic(path, value):
    raw = encode(value)
    temporary = path.with_name('.' + path.name + '.' + uuid.uuid4().hex)
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(raw)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def read_json(path, limit):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size > limit:
            raise ValueError('frame_too_large')
        return json.loads(stream.read(limit + 1))


def model_listing(app, catalog):
    models = catalog['models']
    if app == 'robin':
        models = [model for model in models if model['id'].startswith('arl/package/')]
    metadata = ('schema_version', 'catalog_version', 'package_revision', 'quota_policy', 'local_lifetime_call_limit')
    return {'object': 'list', 'data': models, 'arl': {key: catalog[key] for key in metadata}}


def failure(code, request_id=None):
    error = {'code': code, 'retryable': False}
    if request_id is not None:
        error['request_id'] = request_id
    return {'error': error}


def chat_completion(identity, model, content, finish_reason='stop'):
    return {'id': 'chatcmpl-' + identity, 'object': 'chat.completion', 'created': int(time.time()), 'model': model,
            'choices': [{'index': 0, 'message': {'role': 'assistant', 'content': content}, 'finish_reason': finish_reason}]}


def codex_completion(app, root, value, request):
    identity = request['id']
    target = root / 'requests' / (identity + '.json')
    response = root / 'responses' / target.name
    if not target.exists():
        pending = [path for path in target.parent.glob('*.json') if not (response.parent / path.name).exists()]
        if len(pending) >= 128:
            return 503, failure('queue_capacity_reached')
        request['created_at'] = time.time()
        request['expires_at'] = request['created_at'] + (720 if app == 'robin' else 300)
        atomic(target, request)
    original = read_json(target, TRANSPORT_FRAME_BYTES)
    if original.get('content_sha256') != request['content_sha256'] or original.get('selector') != request['selector']:
        return 409, failure('request_id_conflict', identity)
    deadline = time.monotonic() + (725 if app == 'robin' else 305)
    while not response.exists():
        if time.monotonic() > deadline:
            atomic(root / 'cancelled' / target.name, {'id': identity})
            return 422, failure('arl_task_pending_or_cancelled', identity)
        time.sleep(.4)
    result = read_json(response, 131072)
    if result.get('id') != identity or result.get('app') != app:
        raise ValueError('response_mismatch')
    if result.get('state') != 'succeeded':
        body = failure(result.get('error', 'arl_task_failed'), identity)
        body['error'].update(job_id=result.get('job_id'), provider_error=result.get('provider_error'),
                             message='Original ARL task retained; no automatic new call.')
        return 422, body
    receipt = result.get('selection_receipt', {})
    if (result.get('schema') != 2 or receipt.get('content_sha256') != request['content_sha256']
            or receipt.get('selector') != request['selector']):
        raise ValueError('response_mismatch')
    body = chat_completion(identity, value['model'], result['text'])
    body['arl'] = {'request_id': identity, 'job_id': result['job_id'],
                   'package_id': request['selector'].get('package_id'), 'package_revision': receipt['package_revision']}
    return 200, body


class RouterConnection(http.client.HTTPConnection):
    def __init__(self, path, timeout):
        super().__init__('localhost', timeout=timeout)
        self.path = path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(str(self.path))


class RouterSocketServer(ThreadingHTTPServer):
    address_family = socket.AF_UNIX

    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = 'localhost', 0


def server(app, root, secret, *, router=None, socket_path=None, router_marker=None, address=('127.0.0.1', 19421)):
    if app not in APPS:
        raise ValueError('app')

    class Handler(BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'

        def log_message(self, *args):
            pass

        def send_body(self, status, raw, content_type, *, provider=None, no_retry=False):
            self.send_response(status)
            if no_retry:
                self.send_header('x-should-retry', 'false')
            if provider in ('codex', 'openai'):
                self.send_header('X-ARL-Provider', provider)
            self.send_header('Content-Type', content_type)
            self.send_header('Content-Length', str(len(raw)))
            self.send_header('Cache-Control', 'no-store')
            self.end_headers()
            self.wfile.write(raw)

        def reply(self, status, value, *, provider=None):
            self.send_body(status, encode(value), 'application/json', provider=provider,
                           no_retry=value.get('error', {}).get('retryable') is False)

        def completion(self, status, value, request, provider):
            if status != 200 or not request.get('stream'):
                return self.reply(status, value, provider=provider)
            choice = value['choices'][0]
            common = {key: value[key] for key in ('id', 'created', 'model')}
            chunks = [
                {**common, 'object': 'chat.completion.chunk', 'choices': [
                    {'index': 0, 'delta': choice['message'], 'finish_reason': None}]},
                {**common, 'object': 'chat.completion.chunk', 'choices': [
                    {'index': 0, 'delta': {}, 'finish_reason': choice['finish_reason']}]},
            ]
            if isinstance(request.get('stream_options'), dict) and request['stream_options'].get('include_usage') is True and 'usage' in value:
                chunks.append({**common, 'object': 'chat.completion.chunk', 'choices': [], 'usage': value['usage']})
            body = b''.join(b'data: ' + encode(chunk) + b'\n\n' for chunk in chunks) + b'data: [DONE]\n\n'
            return self.send_body(status, body, 'text/event-stream', provider=provider)

        def relay(self, body=None):
            # 已迁移应用继续使用原令牌。连接失败时保留原请求的准入语义。
            connection = RouterConnection(root / 'router.sock', 750 if app == 'robin' else 330)
            headers = {'Authorization': 'Bearer ' + secret}
            request_id = self.headers.get('Idempotency-Key')
            if request_id is not None:
                headers['Idempotency-Key'] = request_id
            try:
                connection.request(self.command, self.path, body=body, headers=headers)
                response = connection.getresponse()
                raw = response.read(524289)
                if len(raw) > 524288:
                    raise ValueError('router_response_too_large')
                status = response.status
                content_type = response.getheader('Content-Type', 'application/json')
                provider = response.getheader('X-ARL-Provider')
                no_retry = response.getheader('x-should-retry') == 'false'
            except (OSError, http.client.HTTPException, ValueError):
                return self.reply(503, failure('nas_router_unavailable_or_pending'))
            finally:
                connection.close()
            return self.send_body(status, raw, content_type, provider=provider, no_retry=no_retry)

        def authorized(self):
            return hmac.compare_digest(self.headers.get('Authorization', ''), 'Bearer ' + secret)

        def do_GET(self):
            if not self.authorized():
                return self.reply(401, failure('unauthorized'))
            if self.path not in ('/v1/models', '/health'):
                return self.reply(404, failure('not_found'))
            if router_marker is not None and router_marker.is_file():
                return self.relay()
            if self.path == '/health':
                return self.reply(200, {'ok': True, 'app': app, 'transport': 'nas-router' if router is not None else 'arl-file-queue',
                                        'inference_verified': False})
            if router is not None:
                return self.reply(*router.models(app))
            try:
                catalog = read_json(root / 'catalog.json', 131072)
                if time_stale(catalog):
                    return self.reply(503, failure('catalog_stale'))
                return self.reply(200, model_listing(app, catalog))
            except (OSError, ValueError, KeyError):
                return self.reply(503, failure('catalog_unavailable'))

        def do_POST(self):
            if not self.authorized():
                self.close_connection = True
                return self.reply(401, failure('unauthorized'))
            if self.path != '/v1/chat/completions':
                self.close_connection = True
                return self.reply(404, failure('not_found'))
            try:
                self.connection.settimeout(10)
                length = int(self.headers.get('Content-Length', '0'))
                if not 0 < length <= TRANSPORT_FRAME_BYTES or self.headers.get('Transfer-Encoding'):
                    self.close_connection = True
                    raise ValueError('invalid_frame')
                raw = self.rfile.read(length)
                if len(raw) != length:
                    raise ValueError('invalid_frame')
                if router_marker is not None and router_marker.is_file():
                    return self.relay(raw)
                value = json.loads(raw)
                request_id = self.headers.get('Idempotency-Key')
                if router is not None:
                    status, body, provider = router.complete(app, value, request_id)
                else:
                    catalog = read_json(root / 'catalog.json', 131072)
                    request = normalize(app, value, catalog, request_id=request_id)
                    status, body = codex_completion(app, root, value, request)
                    provider = 'codex'
                return self.completion(status, body, value, provider)
            except (ValueError, UnicodeError, KeyError, TypeError):
                self.reply(400, failure('invalid_or_unsupported_text_request'))
            except (BrokenPipeError, ConnectionResetError, socket.timeout):
                pass
            except OSError:
                self.reply(503, failure('queue_unavailable'))

    if socket_path is not None:
        return RouterSocketServer(str(socket_path), Handler)
    return ThreadingHTTPServer(address, Handler)


if __name__ == '__main__':
    app = sys.argv[1]
    root = Path('/friday-queue')
    secret = Path('/friday-secret/token').read_text().strip()
    if os.geteuid() == 0:
        os.setgid(100)
        os.setuid(1026)
    marker = Path(__file__).resolve().parent / 'router-enrolled' / app
    server(app, root, secret, router_marker=marker).serve_forever()
