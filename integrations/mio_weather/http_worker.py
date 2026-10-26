"""Private fixed-destination HTTP worker; no raw exception or URL logging."""
import json
import re
import sys
import urllib.parse
import urllib.request


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *_args, **_kwargs):
        raise ValueError('redirect_rejected')


def main():
    try:
        raw = sys.stdin.buffer.read(2049)
        if len(raw) > 2048:
            return 1
        obj = json.loads(raw)
        if type(obj) is not dict or set(obj) != {'key', 'params'}:
            return 1
        params = obj['params']
        if (type(params) is not dict or set(params) != {'city', 'extensions', 'output'} or
                type(params['city']) is not str or not re.fullmatch('[0-9]{6}', params['city']) or
                params['extensions'] not in ('base', 'all') or params['output'] != 'JSON' or
                type(obj['key']) is not str or not re.fullmatch('[A-Za-z0-9_-]{16,128}', obj['key'])):
            return 1
        url = 'https://restapi.amap.com/v3/weather/weatherInfo?' + urllib.parse.urlencode({**params, 'key': obj['key']})
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
        with opener.open(urllib.request.Request(url, method='GET'), timeout=5) as response:
            raw = response.read(65537)
        if len(raw) > 65536 or obj['key'].encode() in raw:
            return 1
        json.loads(raw)  # Only JSON; no forwarded headers/URLs/provider exceptions.
        sys.stdout.buffer.write(raw)
        return 0
    except Exception:
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
