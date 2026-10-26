from __future__ import annotations

import datetime
import json
from pathlib import Path

from .contracts import Fault, Tool, validate

SCHEMA_PATH = Path(__file__).resolve().parents[1] / "docs" / "mio-tools.json"


class TravelAdapter:
    """Compatible tools over an injected approved transport; never creates a tunnel."""
    def __init__(self, transport=None):
        self.transport = transport
        self.descriptors = json.loads(SCHEMA_PATH.read_text())["tools"]

    def call(self, name, args, context):
        context.check_cancelled()
        rule = next((t for t in self.descriptors if t["name"] == name), None)
        if rule is None:
            raise Fault("unknown_tool")
        validate(args, rule["inputSchema"])
        if name == "mio_tunnel_ping":
            return {"content": [{"type": "text", "text": "pong from mac-mini"}], "isError": False}
        if self.transport is None:
            raise Fault("travel_transport_not_enabled")
        return self.transport(name, args)

    def tools(self):
        return [Tool(t["name"], t["inputSchema"], lambda a, c, n=t["name"]: self.call(n, a, c),
                     availability="ready" if t["name"] == "mio_tunnel_ping" or self.transport else "adapter_only",
                     description=t["description"]) for t in self.descriptors]
