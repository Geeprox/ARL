"""Only used by isolated controlled-supervisor tests; no task/tool calls."""
import json
import sys

from arl.client import Client

print('prepared',flush=True)
if sys.stdin.readline().strip() != 'go':
    raise SystemExit(2)
print(json.dumps(Client(sys.argv[1],'friday').rpc('heartbeat')),flush=True)
sys.stdin.readline()
