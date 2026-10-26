"""Finite isolated source client; parent controls synthetic commands over stdin.

This executable neither enrolls itself nor supplies authority to the runtime.
The test supervisor separately registers its actual kernel PID/image/birth.
"""
import json
import os
import sys

from arl.client import Client
from arl.contracts import Fault


def main():
    if len(sys.argv) != 4 or sys.argv[1] != '--isolated-test':
        raise SystemExit('isolated fixture only')
    client = Client(sys.argv[2], sys.argv[3])
    print(json.dumps({'pid': os.getpid()}), flush=True)
    for line in sys.stdin:
        command = json.loads(line)
        if command == {'command': 'stop'}:
            return
        if set(command) != {'method', 'params'}:
            raise SystemExit('invalid test command')
        try:
            result = client.rpc(command['method'], command['params'])
            reply = {'ok': True, 'result': result}
        except Fault as error:
            reply = {'ok': False, 'error': error.code}
        print(json.dumps(reply, ensure_ascii=False), flush=True)


if __name__ == '__main__':
    main()
