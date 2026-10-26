"""Controlled synthetic source: fixed launch gate, no enrollment or authority."""
import json
import os
from pathlib import Path
import sys

from arl.client import Client
from arl.contracts import Fault


def main():
    if len(sys.argv) != 4 or sys.argv[1] != '--isolated-test':
        raise SystemExit('isolated fixture only')
    proof = Path(sys.argv[2]) / 'synthetic-gate.json'
    proof.write_text(json.dumps({'pid': os.getpid(), 'released': False}))
    print('prepared', flush=True)
    if sys.stdin.readline() != 'go\n':
        raise SystemExit('closed launch gate')
    proof.write_text(json.dumps({'pid': os.getpid(), 'released': True}))
    client = Client(sys.argv[2], sys.argv[3])
    print(json.dumps({'released': True, 'pid': os.getpid()}), flush=True)
    for line in sys.stdin:
        command = json.loads(line)
        if set(command) != {'method', 'params'}:
            raise SystemExit('invalid synthetic command')
        try:
            reply = {'ok': True, 'result': client.rpc(command['method'], command['params'])}
        except Fault as error:
            reply = {'ok': False, 'error': error.code}
        print(json.dumps(reply, ensure_ascii=False), flush=True)


if __name__ == '__main__':
    main()
