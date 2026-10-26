from __future__ import annotations

import json
import subprocess
from pathlib import Path

from .contracts import Fault, encode


class EventKitTransport:
    """Host-only composition. Enabling private tools also requires a peer identity verifier.

    Build path is fixed at construction, cannot be provided over RPC. The helper
    never requests permission. Do not configure this for production before approval.
    """
    def __init__(self, executable):
        self.executable = Path(executable).resolve(strict=True)

    def __call__(self, tool, args):
        if tool not in {"apple.authorization", "apple.calendar.list", "apple.reminders.list"}:
            raise Fault("unknown_tool")
        try:
            result = subprocess.run([str(self.executable)], input=encode({"tool": tool, "args": args}),
                                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=12)
            if len(result.stdout) > 65536 or result.returncode != 0:
                raise Fault("invalid_adapter_response")
            return json.loads(result.stdout)
        except (OSError, ValueError, subprocess.TimeoutExpired):
            # Timeout is not evidence that the screen needs unlocking.
            raise Fault("apple_helper_unavailable") from None
