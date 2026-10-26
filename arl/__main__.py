from __future__ import annotations

import argparse
import json
import signal
import sys
import threading

from .client import Client
from .contracts import Fault
from .lifecycle import InstanceLock, private_home
from .service import Runtime
from .extension_contracts import compatibility


def main():
    parser = argparse.ArgumentParser(description="ARL headless local runtime; no auto-start installation")
    parser.add_argument("command", choices=["serve", "health", "capabilities", "providers", "stop", "enable"])
    parser.add_argument("--home", required=True, help="Owner-only runtime state directory (short Unix socket path)")
    parser.add_argument("--app", default=compatibility.DEFAULT_APP if compatibility else "settings")
    parser.add_argument("--enable-local-inference", action="store_true", help="Allow explicit existing Ollama tasks; never cloud/download")
    parser.add_argument("--start-delay", type=float, default=0, help=argparse.SUPPRESS)
    args = parser.parse_args()
    try:
        home = private_home(args.home)
        if args.command == "serve":
            runtime = Runtime(home, start_delay=max(0, args.start_delay), local_enabled=args.enable_local_inference, execute_jobs=compatibility is not None)
            def stop(signum, frame):
                threading.Thread(target=runtime.shutdown, daemon=True).start()
            signal.signal(signal.SIGTERM, stop)
            signal.signal(signal.SIGINT, stop)
            runtime.run()
        elif args.command == "enable":
            lock = InstanceLock(home)
            try:
                (home/"disabled").unlink(missing_ok=True)
            finally:
                lock.close()
            print(json.dumps({"bootstrap_allowed": True}))
        else:
            print(json.dumps(Client(home, args.app).rpc(args.command), ensure_ascii=False))
    except Fault as exc:
        print(json.dumps({"error": exc.code}), file=sys.stderr)
        return 0 if exc.code in {"already_running", "user_disabled"} else 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
