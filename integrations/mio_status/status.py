"""Read-only local tunnel evidence; never treats this as provider/tool readiness."""
import hashlib
import json
import os
import stat
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

HEALTH_FILE = Path.home() / 'Library/Application Support/MioReadOnly/travel-tunnel/health-url.txt'
MANIFEST = Path(__file__).resolve().parents[2] / 'docs/mio-tools.json'


def checked_base(path=HEALTH_FILE):
    try:
        fd = os.open(str(path), os.O_RDONLY | os.O_NOFOLLOW)
    except OSError:
        raise ValueError('unsafe_health_locator') from None
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
            raise ValueError('unsafe_health_locator')
        raw = os.read(fd, 1025)
    finally:
        os.close(fd)
    if len(raw) > 1024:
        raise ValueError('invalid_health_locator')
    parsed = urllib.parse.urlsplit(raw.decode().strip())
    if (parsed.scheme != 'http' or parsed.hostname != '127.0.0.1' or not parsed.port or
            parsed.username or parsed.password or parsed.query or parsed.fragment or parsed.path not in ('', '/')):
        raise ValueError('invalid_health_locator')
    return f'http://127.0.0.1:{parsed.port}'


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *_args, **_kwargs):
        raise ValueError('redirect_rejected')


def probe_worker():
    try:
        base = checked_base()
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
        result = {}
        for route, expected in (('healthz', 'live'), ('readyz', 'ready')):
            try:
                with opener.open(base+'/'+route, timeout=0.75) as response:
                    raw = response.read(257)
                    result[route] = {'http': response.status,
                        'state': expected if len(raw) <= 256 and raw.decode().strip() == expected else 'unknown'}
            except Exception:
                result[route] = {'http': None, 'state': 'unavailable'}
        print(json.dumps(result))
        return 0
    except Exception:
        print(json.dumps({'error': 'health_locator_unavailable'}))
        return 1


class MioStatusProbe:
    def __init__(self, runner=subprocess.run, clock=None):
        self.runner = runner
        self.clock = clock or (lambda: int(time.time()*1000))

    def snapshot(self):
        result = {'schema_version': 1, 'module_id': 'mio.gateway', 'checked_at_ms': self.clock(),
            'tunnel': {'liveness': 'unknown', 'readiness': 'unknown', 'source': 'local_client_health',
                       'external_roundtrip': 'not_checked'},
            'capabilities': {'source': 'reviewed_manifest', 'tool_count': None, 'manifest_sha256': None,
                             'manifest_updated_at_ms': None, 'live_publication_verified': False},
            'providers': 'not_probed', 'error_code': None}
        try:
            raw = MANIFEST.read_bytes(); data = json.loads(raw)
            result['capabilities'].update(tool_count=len(data['tools']),
                manifest_sha256=hashlib.sha256(raw).hexdigest(),
                manifest_updated_at_ms=int(MANIFEST.stat().st_mtime*1000))
        except Exception:
            result['error_code'] = 'catalog_unavailable'
        try:
            reply = self.runner([sys.executable, '-I', str(Path(__file__).resolve()), '--probe-worker'],
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=2,
                env={'PATH': '/usr/bin:/bin:/usr/sbin:/sbin'})
            if reply.returncode or len(reply.stdout) > 4096:
                raise ValueError()
            evidence = json.loads(reply.stdout)
            for route, target, expected in (('healthz', 'liveness', 'live'), ('readyz', 'readiness', 'ready')):
                row = evidence.get(route, {})
                result['tunnel'][target] = expected if row.get('http') == 200 and row.get('state') == expected else 'unavailable' if row.get('state') == 'unavailable' else 'unknown'
        except subprocess.TimeoutExpired:
            result['error_code'] = 'probe_deadline_exceeded'
        except Exception:
            result['error_code'] = 'probe_unavailable'
        return result


if __name__ == '__main__':
    if sys.argv[1:] == ['--probe-worker']:
        raise SystemExit(probe_worker())
    if sys.argv[1:]:
        raise SystemExit(2)
    print(json.dumps(MioStatusProbe().snapshot(), sort_keys=True))
