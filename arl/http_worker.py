"""Private killable HTTP I/O helper. No inference, credentials, files or shell API."""
import json
import sys
from urllib.parse import urlparse

from .contracts import Fault, encode
from .providers import _blocking_local_json


def main():
    try:
        data = json.loads(sys.stdin.buffer.read(16385))
        if set(data) != {"url", "body", "timeout"}:
            raise Fault("invalid_provider_request")
        url = urlparse(data["url"])
        if (url.scheme != "http" or url.hostname != "127.0.0.1" or url.username or url.password
                or url.fragment or not 0 < (url.port or 80) < 65536):
            raise Fault("provider_destination_rejected")
        reply = {"ok": True, "result": _blocking_local_json(data["url"], data["body"], data["timeout"])}
    except Fault as exc:
        reply = {"ok": False, "error": exc.code}
    except Exception:
        reply = {"ok": False, "error": "provider_unavailable"}
    sys.stdout.buffer.write(encode(reply))


if __name__ == "__main__":
    main()
