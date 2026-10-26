from __future__ import annotations

import hashlib
import platform
import time

from .contracts import Fault, Tool, object_schema, string


def build_tools(router, apple=None, travel=None):
    def digest(args, context):
        context.check_cancelled()
        return {"sha256": hashlib.sha256(args["text"].encode()).hexdigest()}

    tools = [
        Tool("runtime.ping", object_schema(), lambda a, c: {"pong": True}),
        Tool("runtime.info", object_schema(), lambda a, c: {
            "system": platform.system(), "machine": platform.machine(), "ui_required": False}),
        Tool("text.sha256", object_schema({"text": string()}, ["text"]), digest),
        Tool("model.complete", object_schema({"provider": string(64), "model": string(200),
            "prompt": string(1024), "max_tokens": {"type": "integer", "minimum": 8, "maximum": 512}},
            ["provider", "model", "prompt", "max_tokens"]),
            lambda a, c: router.complete(c.owner, a, c), idempotent=False,
            description="Explicit provider/model only; no fallback; output cap and persistent call budget"),
    ]
    if apple:
        tools += apple.tools()
    if travel:
        tools += travel.tools()
    # Public metadata is registered even before account enrollment. The
    # adapter has no transport, and this does not add any AppPolicy grants.
    from .netease_music import NeteaseMusicAdapter
    tools += NeteaseMusicAdapter().tools()
    return {t.name: t for t in tools}


class AppleAdapter:
    """Narrow future helper boundary. No implicit prompting, UI or permission probing."""
    def __init__(self, transport=None):
        self.transport = transport

    def run(self, name, args, context):
        context.check_cancelled()
        if self.transport is None:
            raise Fault("needs_permission", "Native Apple helper is not enabled")
        reply = self.transport(name, args)
        if reply.get("status") != "ok":
            raise Fault(reply.get("status") if reply.get("status") in {
                "needs_unlock", "needs_permission", "unsupported", "unavailable"} else "invalid_adapter_response")
        return reply.get("result")

    def tools(self):
        # Notes edits deliberately absent: HTML body assignment cannot guarantee rich-text preservation.
        return [Tool(name, schema, lambda a, c, n=name: self.run(n, a, c),
                     permissions=(permission,), availability="needs_permission" if not self.transport else "adapter",
                     description="No permission prompt; helper must check authorization before data access")
                for name, permission, schema in [
                    ("apple.calendar.list", "calendar_full_access", object_schema({
                        "start": string(40), "end": string(40)}, ["start", "end"])),
                    ("apple.reminders.list", "reminders_full_access", object_schema()),
                ]]
