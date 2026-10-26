from __future__ import annotations

from .contracts import Fault


class WakeRegistry:
    """Callbacks come from host composition, never RPC paths/URLs/commands.

    Durable events are delivered on SDK poll. Native offline launch is a deployment
    adapter (e.g. allowlisted bundle IDs), deliberately absent from the MVP.
    """
    def __init__(self, store, app_ids, callbacks=None):
        self.store = store
        self.app_ids = frozenset(app_ids)
        self.callbacks = callbacks or {}
        if set(self.callbacks) - self.app_ids:
            raise Fault("unknown_app")

    def wake(self, source, target):
        if source not in self.app_ids or target not in self.app_ids:
            raise Fault("unknown_app")
        self.store.wake(source, target)
        callback = self.callbacks.get(target)
        if callback:
            try:
                callback()
            except Exception:
                raise Fault("wake_delivery_failed") from None
        return {"target": target, "delivery": "host_callback" if callback else "durable_inbox",
                "offline_launch_available": bool(callback)}
