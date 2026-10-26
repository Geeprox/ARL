"""Two host-owned methods over the existing settings bridge; no RPC/store."""
from __future__ import annotations

from .controller_bridge import Request, SettingsControllerBridge, SetupFault


class _HostCapturedAction:
    __slots__ = ('request', '_bridge', '_click', '_used')

    def __init__(self, bridge, request, click):
        self.request, self._bridge, self._click = request, bridge, click
        self._used = False

    def __repr__(self):
        return '<NASSettingsHostAction: in-process>'

    def __reduce_ex__(self, protocol):
        raise TypeError('manual_click_not_serializable')

    async def run(self):
        if self._used:
            raise SetupFault('manual_intent_required')
        self._used = True
        return await self._bridge.perform_captured(self._click)


class SettingsHostPort:
    """Bind one owner-held SettingsControllerBridge, without copying its state.

    A native owner still has to provide the private cross-language embedding.
    These Python methods are callable locally and tested against the real
    NASSetupController. They do not add a socket, decoder, secret consumer,
    transport, manager, store, or authentication implementation.
    """
    __slots__ = ('_bridge',)

    def __init__(self, bridge: SettingsControllerBridge):
        if type(bridge) is not SettingsControllerBridge:
            raise SetupFault('host_not_configured')
        self._bridge = bridge

    def cached_snapshot(self):
        return self._bridge.cached_snapshot()

    def capture_after_click(self, request: Request):
        click = self._bridge.capture_after_click(request)
        return _HostCapturedAction(self._bridge, request, click)
