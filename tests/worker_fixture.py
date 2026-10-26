"""Isolated crash-test worker; no real Apple/home/travel side effects."""
import sys
import time
from pathlib import Path

from arl.contracts import AppPolicy, Tool, object_schema
from arl.service import Runtime


def main():
    home = Path(sys.argv[1])
    def slow(args, context):
        for _ in range(40):
            context.check_cancelled()
            time.sleep(0.025)
        return {"done": True}
    def fake_write(args, context):
        marker = home / "fake-effect"
        marker.write_text(str(int(marker.read_text())+1) if marker.exists() else "1")
        # Deliberately uncertain external-effect boundary during process crash.
        time.sleep(2)
        return {"done": True}
    tools = [Tool("test.slow", object_schema(), slow),
             Tool("test.write", object_schema(), fake_write, idempotent=False)]
    Runtime(home, extra_tools=tools, policies={"tisra": AppPolicy(frozenset(t.name for t in tools))}).run()


if __name__ == "__main__":
    main()
