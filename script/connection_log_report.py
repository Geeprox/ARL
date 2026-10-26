#!/usr/bin/env python3
"""Count completed local Mio requests. No remote front-door traffic is inferred."""
import argparse
import collections
import datetime
import json
import os
from pathlib import Path
import stat


def report(directory):
    minutes = collections.defaultdict(collections.Counter)
    statuses = collections.Counter()
    events = collections.Counter()
    malformed = 0
    for path in sorted(directory.glob('connection-*.jsonl')):
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1:
            continue
        with path.open() as stream:
            for line in stream:
                try:
                    row = json.loads(line)
                    at = datetime.datetime.fromtimestamp(row['at_ms'] / 1000, datetime.timezone.utc)
                    minute = at.strftime('%Y-%m-%dT%H:%M:00Z')
                    event, source = row['event'], row['source']
                except (ValueError, KeyError, TypeError, OverflowError):
                    malformed += 1
                    continue
                events[source + '.' + event] += 1
                if source == 'mio' and event == 'request_finished':
                    minutes[minute]['requests'] += 1
                    minutes[minute]['failures'] += row.get('failed') is True
                if source == 'tunnel' and event == 'retry':
                    minutes[minute]['upstream_retries'] += 1
                if isinstance(row.get('http_status'), int):
                    statuses[str(row['http_status'])] += 1
    return {'scope': 'completed requests at the signed local Mio host; excludes unobserved remote ingress',
            'minutes': {key: dict(value) for key, value in sorted(minutes.items())},
            'upstream_http_statuses_when_emitted': dict(statuses), 'events': dict(events),
            'malformed_or_partial_lines': malformed}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, default=Path.home() / 'Library/Application Support/ARL/connection-logs.noindex')
    args = parser.parse_args()
    print(json.dumps(report(args.directory), ensure_ascii=False, indent=2))
