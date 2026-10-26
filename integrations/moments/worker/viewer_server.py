#!/usr/bin/env python3
"""Loopback-only Moments viewer. Serves the viewer, public JSON, images and local videos.

Private locators, keys, logs, directories and arbitrary files are never served.
"""
import argparse
from archive_storage import media_file
import errno
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import mimetypes
import json
from pathlib import Path
import re
from urllib.parse import unquote, urlsplit
from urllib.request import urlopen
import webbrowser

ROOT = Path(__file__).resolve().parent


class RangeNotSatisfiable(ValueError):
    pass


def byte_range(value, size):
    """One inclusive HTTP byte range; None means full representation.

    Malformed/multiple/unknown-unit ranges are explicitly unsupported. Bounds
    use Python integers; suffix requests and oversized ends are clamped.
    """
    if value is None:
        return None
    if not isinstance(value, str) or len(value) > 128 or size < 0:
        raise RangeNotSatisfiable()
    match = re.fullmatch(r"bytes=([0-9]*)-([0-9]*)", value)
    if match is None or not any(match.groups()) or size == 0:
        raise RangeNotSatisfiable()
    first, last = match.groups()
    if not first:
        count = int(last)
        if count == 0:
            raise RangeNotSatisfiable()
        return max(0, size - count), size - 1
    start = int(first)
    end = int(last) if last else size - 1
    if start >= size or end < start:
        raise RangeNotSatisfiable()
    return start, min(end, size - 1)


class Handler(BaseHTTPRequestHandler):
    def _valid_host(self):
        return len(self.headers.get_all('Host', [])) == 1 and self.headers.get('Host') in (
            '127.0.0.1:' + str(self.server.server_port), 'localhost:' + str(self.server.server_port))

    def _json(self, status, value, head_only=False):
        body=json.dumps(value,ensure_ascii=False,separators=(',',':')).encode()
        self.send_response(status);self._common_headers()
        self.send_header('Content-Type','application/json; charset=utf-8')
        self.send_header('Cache-Control','no-store');self.send_header('Content-Length',str(len(body)))
        self.end_headers()
        if not head_only:
            try:self.wfile.write(body)
            except (BrokenPipeError,ConnectionResetError):pass

    def do_POST(self):
        if not self._valid_host():self.send_error(403);return
        expected='http://'+self.headers['Host']
        if len(self.headers.get_all('Origin',[]))!=1 or self.headers.get('Origin')!=expected:
            self._json(403,{'error_code':'same_origin_required'});return
        route=urlsplit(self.path)
        if route.query or route.path not in ('/api/media/queue','/api/refresh'):self.send_error(404);return
        if self.headers.get('Content-Type','').split(';')[0].strip().lower()!='application/json':
            self._json(415,{'error_code':'json_required'});return
        if self.headers.get('Transfer-Encoding') or len(self.headers.get_all('Content-Length',[]))!=1:
            self._json(400,{'error_code':'invalid_body_length'});return
        try:
            size=int(self.headers['Content-Length'])
            if not 0<size<=16384:raise ValueError()
            self.connection.settimeout(5)
            body=json.loads(self.rfile.read(size))
            if route.path=='/api/refresh':
                if body!={}:raise ValueError()
                callback=getattr(self.server,'refresh_callback',None)
                self._json(202 if callback else 503,callback() if callback else {'error_code':'collector_unavailable'});return
            if not isinstance(body,dict) or set(body)!={'asset_ids'}:raise ValueError()
            ids=body['asset_ids']
            if not isinstance(ids,list) or not 1<=len(ids)<=20 or any(not isinstance(x,str) or len(x)>200 for x in ids):raise ValueError()
        except (ValueError,UnicodeError,TimeoutError):
            self._json(400,{'error_code':'invalid_queue_request'});return
        queue=getattr(self.server,'media_queue',None)
        if queue is None:self._json(503,{'enabled':False,'error_code':'async_images_disabled'});return
        try:self._json(202,queue.submit(ids,priority=True))
        except Exception:self._json(503,{'error_code':'queue_unavailable'})

    def do_GET(self):
        self._serve(head_only=False)

    def do_HEAD(self):
        self._serve(head_only=True)

    def _common_headers(self):
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('X-Moments-Viewer', '1')
        self.send_header('Referrer-Policy', 'no-referrer')
        self.send_header('Cross-Origin-Resource-Policy', 'same-origin')
        self.send_header('X-Frame-Options', 'DENY')

    def _serve(self, head_only):
        if len(self.headers.get_all('Host', [])) != 1 or self.headers.get('Host') not in ('127.0.0.1:' + str(self.server.server_port),
                                             'localhost:' + str(self.server.server_port)):
            self.send_error(403)
            return
        path = unquote(urlsplit(self.path).path)
        if path=='/api/media/status':
            queue=getattr(self.server,'media_queue',None)
            if queue is None:self._json(503,{'enabled':False,'error_code':'async_images_disabled'},head_only);return
            self._json(200,queue.snapshot(),head_only);return
        allowed = {'/': ROOT / 'moments.html', '/moments.html': ROOT / 'moments.html',
                   '/data/moments.json': ROOT / 'data/moments.json',
                   '/data/manifest.json': ROOT / 'data/manifest.json'}
        target = allowed.get(path)
        is_media = re.fullmatch(r'/data/media/[a-f0-9]{64}\.(jpg|jpeg|png|webp|gif|mp4)', path) is not None
        if target is None and is_media:
            target = media_file(ROOT / 'data', path.removeprefix('/data/'))
        if target is None or target.is_symlink() or not target.is_file() or (not is_media and not target.resolve().is_relative_to(ROOT)):
            self.send_error(404)
            return
        try:
            # The opened descriptor supplies both size and bytes. No whole-file
            # allocation, even for an original video or a browser seek request.
            stream = target.open('rb')
        except OSError:
            self.send_error(503)
            return
        with stream:
            import os
            size = os.fstat(stream.fileno()).st_size
            try:
                # Range is defined for GET. HEAD returns full metadata only.
                if is_media and not head_only and len(self.headers.get_all('Range', [])) > 1:
                    raise RangeNotSatisfiable()
                selected = byte_range(self.headers.get('Range'), size) if is_media and not head_only else None
            except RangeNotSatisfiable:
                self.send_response(416)
                self.send_header('Content-Range', 'bytes */' + str(size))
                self.send_header('Accept-Ranges', 'bytes')
                self.send_header('Content-Length', '0')
                self._common_headers()
                self.end_headers()
                return
            start, end = selected if selected is not None else (0, size - 1)
            length = max(0, end - start + 1)
            self.send_response(206 if selected is not None else 200)
            self.send_header('Content-Type', 'video/mp4' if target.suffix.lower() == '.mp4'
                             else mimetypes.guess_type(target.name)[0] or 'application/octet-stream')
            self.send_header('Content-Length', str(length))
            if is_media:
                self.send_header('Accept-Ranges', 'bytes')
            if selected is not None:
                self.send_header('Content-Range', f'bytes {start}-{end}/{size}')
            self._common_headers()
            self.send_header('Cache-Control', 'no-store' if target.suffix in ('.html', '.json') else 'private, max-age=86400')
            self.end_headers()
            if head_only:
                return
            stream.seek(start)
            remaining = length
            try:
                while remaining:
                    chunk = stream.read(min(65536, remaining))
                    if not chunk:
                        # A concurrent truncate must not append another response
                        # or pretend this short representation was complete.
                        self.close_connection = True
                        break
                    self.wfile.write(chunk)
                    remaining -= len(chunk)
            except (BrokenPipeError, ConnectionResetError, OSError):
                self.close_connection = True

    def log_message(self, *_):
        pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int, default=8787)
    parser.add_argument('--open', action='store_true')
    parser.add_argument('--async-images',action='store_true',help='Explicitly enable the controlled serial local image queue')
    parser.add_argument('--queue-all-images',action='store_true',help='Queue newly discovered image records in newest-first order')
    args = parser.parse_args()
    if args.queue_all_images and not args.async_images:parser.error('--queue-all-images requires --async-images')
    try:
        server = ThreadingHTTPServer(('127.0.0.1', args.port), Handler)
    except OSError as exc:
        if exc.errno == errno.EADDRINUSE and args.open:
            url = 'http://127.0.0.1:' + str(args.port) + '/'
            with urlopen(url, timeout=3) as response:
                if response.headers.get('X-Moments-Viewer') == '1':
                    webbrowser.open(url)
                    return
        raise
    if args.async_images:
        from async_media import Queue
        server.media_queue=Queue(ROOT/'data')
        if args.queue_all_images:
            document=json.loads((ROOT/'data/moments.json').read_text())
            ids=[media['asset_id'] for post in sorted(document['posts'],key=lambda p:p.get('created_at_unix') or 0,reverse=True)
                 for media in post.get('media',[]) if media.get('type')==2 and media.get('backup_status')=='locator_only_not_downloaded']
            server.media_queue.submit(ids)
        server.media_queue.start(execute=True)
    url = 'http://127.0.0.1:' + str(server.server_port) + '/'
    print(url, flush=True)
    if args.open:
        webbrowser.open(url)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        if getattr(server,'media_queue',None):server.media_queue.close()
        server.server_close()


if __name__ == '__main__':
    main()
