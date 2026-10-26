#!/usr/bin/env python3
"""Download cached Moments image locators; no cookies, login, or key extraction.

Only recognized image bytes become backups. Unsupported/encrypted resources
are explicit gaps. This does not promise original-resolution CDN responses.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import fcntl
import hashlib
import json
from pathlib import Path
import urllib.error
import urllib.parse
import urllib.request

from moments_backup import atomic_json, now

MAX_BYTES = 40 * 1024 * 1024


def allowed_url(value):
    parsed = urllib.parse.urlsplit(value or '')
    host = (parsed.hostname or '').lower()
    if parsed.scheme not in ('http', 'https') or parsed.username or parsed.password:
        raise ValueError('invalid_url')
    if parsed.port not in (None, 80, 443):
        raise ValueError('invalid_port')
    if host != 'mmbiz.qlogo.cn' and not any(host == suffix or host.endswith('.' + suffix)
               for suffix in ('qpic.cn', 'wechat.com')):
        raise ValueError('unsupported_cdn')
    return urllib.parse.urlunsplit(('https', parsed.netloc, parsed.path, parsed.query, ''))


class SafeRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return super().redirect_request(req, fp, code, msg, headers, allowed_url(newurl))


def locator_url(locator, variant):
    """XML stores CDN access tokens separately from URL text."""
    value = allowed_url(locator[variant])
    attrs = locator.get('attrs', {}).get(variant, {})
    token = attrs.get('token')
    if not token:
        return value
    parsed = urllib.parse.urlsplit(value)
    query = [(k, v) for k, v in urllib.parse.parse_qsl(parsed.query, keep_blank_values=True)
             if k not in ('token', 'idx')]
    query.extend([('token', token), ('idx', '1')])
    return urllib.parse.urlunsplit((parsed.scheme, parsed.netloc, parsed.path,
                                   urllib.parse.urlencode(query, quote_via=urllib.parse.quote), ''))


def image_format(data):
    # Tencent JPEG responses can carry a short trailer after JPEG's EOI.
    # Preserve all response bytes, including that trailer, in the backup.
    if data.startswith(b'\xff\xd8\xff') and data.rfind(b'\xff\xd9') >= max(3, len(data) - 4096):
        return 'jpg'
    if data.startswith(b'\x89PNG\r\n\x1a\n') and b'IEND' in data[-16:]:
        return 'png'
    if data.startswith((b'GIF87a', b'GIF89a')) and data.endswith(b';'):
        return 'gif'
    if data[:4] == b'RIFF' and data[8:12] == b'WEBP' and len(data) == int.from_bytes(data[4:8], 'little') + 8:
        return 'webp'
    return None


def existing_valid(output, record):
    from archive_storage import media_file
    relative = Path(record.get('local_path') or '')
    if relative.is_absolute() or '..' in relative.parts or not relative.parts:
        return False
    target = media_file(output, str(relative))
    if target is None:
        return False
    data = target.read_bytes()
    return bool(image_format(data)) and hashlib.sha256(data).hexdigest() == record.get('sha256')


def fetch_image(url, key=None):
    opener = urllib.request.build_opener(SafeRedirect())
    request = urllib.request.Request(allowed_url(url), headers={'User-Agent': 'Mozilla/5.0'})
    with opener.open(request, timeout=15) as response:
        data = response.read(MAX_BYTES + 1)
        expected = response.headers.get('Content-Length')
        if len(data) > MAX_BYTES:
            raise ValueError('too_large')
        if expected is not None and int(expected) != len(data):
            raise ValueError('incomplete_download')
        fmt = image_format(data)
        if not fmt and key and str(key).isdigit() and int(key) != 0:
            from sns_crypto import decrypt_image
            data = decrypt_image(data, key)
            fmt = image_format(data)
        if not fmt:
            raise ValueError('not_supported_image_bytes')
        return data, fmt


def download_one(output, locator):
    record = {'status': 'failed', 'local_path': None, 'last_attempt_at': now()}
    if str(locator.get('kind')) != '2':
        return dict(record, status='unsupported', error_code='non_image_media')
    failures = []
    for variant in ('url', 'thumb'):
        if not locator.get(variant):
            continue
        try:
            key = locator.get('attrs', {}).get(variant, {}).get('key')
            data, fmt = fetch_image(locator_url(locator, variant), key)
            sha = hashlib.sha256(data).hexdigest()
            relative = 'media/' + sha + '.' + fmt
            target = output / relative
            target.parent.mkdir(mode=0o700, exist_ok=True)
            # Content-addressed names permit safe sharing between posts.
            if not target.exists() or hashlib.sha256(target.read_bytes()).hexdigest() != sha:
                import os
                import tempfile
                fd, temporary = tempfile.mkstemp(prefix='.download-', dir=target.parent)
                try:
                    os.fchmod(fd, 0o600)
                    with os.fdopen(fd, 'wb') as stream:
                        stream.write(data)
                        stream.flush()
                        os.fsync(stream.fileno())
                    os.replace(temporary, target)
                finally:
                    if os.path.exists(temporary):
                        os.unlink(temporary)
            return dict(record, status='downloaded' if variant == 'url' else 'thumbnail_only',
                        local_path=relative, sha256=sha, bytes=len(data), format=fmt,
                        source_variant=variant, error_code=None)
        except urllib.error.HTTPError as exc:
            failures.append(variant + ':http_' + str(exc.code))
        except ValueError as exc:
            failures.append(variant + ':' + str(exc))
        except Exception as exc:
            # Exception strings can embed signed URLs. Only retain type names.
            failures.append(variant + ':' + type(exc).__name__)
    return dict(record, error_code=';'.join(failures) or 'no_locator')


def run(output, workers=6, limit=None, retry_failed=False, retry_error=None, upgrade_thumbnails=False):
    output = Path(output).resolve()
    with open(output / '.media.lock', 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        locators = json.loads((output / 'private/locators.json').read_text())['assets']
        state_path = output / 'media-state.json'
        state = json.loads(state_path.read_text()) if state_path.exists() else {'schema_version': 1, 'assets': {}}
        state.setdefault('assets', {})
        pending = []
        for asset_id, locator in locators.items():
            previous = state['assets'].get(asset_id)
            locator_sha = hashlib.sha256(json.dumps(locator, sort_keys=True).encode()).hexdigest()
            if previous and existing_valid(output, previous):
                if previous.get('status') == 'downloaded':
                    continue
                if not upgrade_thumbnails and previous.get('locator_sha256') == locator_sha:
                    continue
            if previous and previous.get('locator_sha256') == locator_sha and previous.get('status') in ('failed', 'unsupported') and not retry_failed and not (retry_error and retry_error in previous.get('error_code', '')):
                continue
            pending.append((asset_id, locator))
        if limit is not None:
            pending = pending[:limit]
        print(json.dumps({'pending': len(pending)}, ensure_ascii=False), flush=True)
        with ThreadPoolExecutor(max_workers=workers) as pool:
            futures = {pool.submit(download_one, output, locator): asset_id for asset_id, locator in pending}
            for done, future in enumerate(as_completed(futures), 1):
                asset_id = futures[future]
                result = future.result()
                result['locator_sha256'] = hashlib.sha256(json.dumps(locators[asset_id], sort_keys=True).encode()).hexdigest()
                previous = state['assets'].get(asset_id)
                if result['status'] == 'failed' and previous and existing_valid(output, previous):
                    result = dict(previous, last_attempt_at=result['last_attempt_at'],
                                  upgrade_error_code=result.get('error_code'))
                state['assets'][asset_id] = result
                state['updated_at'] = now()
                atomic_json(state_path, state)
                if done % 25 == 0 or done == len(pending):
                    counts = {}
                    for item in state['assets'].values():
                        key = item['status']
                        counts[key] = counts.get(key, 0) + 1
                    print(json.dumps({'processed_this_run': done, 'counts': counts}), flush=True)
        return state


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True)
    parser.add_argument('--workers', type=int, default=6, choices=range(1, 17))
    parser.add_argument('--limit', type=int)
    parser.add_argument('--retry-failed', action='store_true')
    parser.add_argument('--retry-error', help='retry only failures containing this error code')
    parser.add_argument('--upgrade-thumbnails', action='store_true')
    args = parser.parse_args()
    run(args.output, args.workers, args.limit, args.retry_failed, args.retry_error, args.upgrade_thumbnails)
