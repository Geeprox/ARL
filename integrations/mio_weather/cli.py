"""Future fixed Mio provider wrapper. Not installed; never creates/changes a key."""
import json
import os
import stat
import sys
from pathlib import Path

# -I ignores the script directory; add only this deployment-owned fixed module.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from adapter import FixedHTTPSWeatherTransport, WeatherAdapter, WeatherFault

KEY_FILE = Path.home() / 'Library/Application Support/MioReadOnly/amap.json'


def existing_amap_key():
    fd = os.open(str(KEY_FILE), os.O_RDONLY | os.O_NOFOLLOW)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
            raise WeatherFault('credential_unavailable')
        raw = os.read(fd, 16385)
        if len(raw) > 16384:
            raise WeatherFault('credential_unavailable')
        data = json.loads(raw)
        return data['AMAP_MAPS_API_KEY']
    except Exception:
        raise WeatherFault('credential_unavailable') from None
    finally:
        os.close(fd)


def main():
    raw = sys.stdin.buffer.read(16385)
    try:
        if len(raw) > 16384:
            raise ValueError()
        args = json.loads(raw)
    except Exception:
        result = {'content': [{'type': 'text', 'text': '{"schema_version":1,"error":{"code":"invalid_arguments","retryable":false}}'}], 'isError': True}
    else:
        result = WeatherAdapter(FixedHTTPSWeatherTransport(existing_amap_key)).mcp_result(args)
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
