"""Private carrier for task25's exact SettingsHostPort, held metadata only.

The existing registered host calls this server on an inherited/registered
channel. It adds no public listener, enrollment, authentication claim or store.
The capture/run correlation ID is bound to this channel and exact request;
the actual non-serializable Python click object stays in this process.
"""
from __future__ import annotations
import asyncio
from dataclasses import asdict
import socket
import time
import uuid

from arl_nas_credential import NASReadScope
from arl_nas_credential.settings import Action
from arl_nas_ui_composition.controller_bridge import Configuration, Request, SetupFault
from arl_nas_ui_composition.host_port import SettingsHostPort
from .gateway import canonical, decode

SERVICE = 'arl.nas.read-session.v1'
CONFIG_FIELDS = {'address', 'port', 'transport', 'share', 'root', 'application_scope',
                 'connection_timeout_seconds', 'automatic_read_retries', 'maximum_concurrent_reads', 'require_encryption'}

def request_from_wire(raw):
    value = decode(raw)
    if type(value) is not dict or set(value) != {'action', 'configuration', 'expected_snapshot_revision', 'expected_configuration_generation', 'read_scope'}:
        raise SetupFault('invalid_configuration')
    config = value['configuration']
    if type(config) is not dict or set(config) != CONFIG_FIELDS: raise SetupFault('invalid_configuration')
    try:
        action = Action(value['action'])
        if action not in {Action.SAVE_CONFIGURATION, Action.STOP}: raise SetupFault('native_resolver_unavailable')
        scope = NASReadScope(**value['read_scope']) if value['read_scope'] is not None else None
        return Request(action, Configuration(**config), value['expected_snapshot_revision'], value['expected_configuration_generation'], scope)
    except SetupFault: raise
    except Exception: raise SetupFault('invalid_configuration') from None

def snapshot_to_wire(snapshot):
    facts = ('configuration_saved', 'credential_reference_saved', 'credential_available', 'connected', 'readable', 'writable')
    result = {'revision': snapshot.revision, 'configuration': asdict(snapshot.configuration) if snapshot.configuration else None,
              'current_configuration_generation': snapshot.current_configuration_generation,
              'read_scope': asdict(snapshot.read_scope), 'provider': snapshot.provider,
              'connection_epoch': None, 'availability': {action.value: asdict(admission) for action, admission in snapshot.availability}}
    result.update({name: asdict(getattr(snapshot, name)) for name in facts})
    # The held task25 adapter owns the semantics. No caller descriptor goes on
    # this metadata wire and native readiness cannot be invented by decoding it.
    return result

class SettingsPrivateChannelServer:
    def __init__(self, port: SettingsHostPort, *, authority, clock=time.monotonic):
        if type(port) is not SettingsHostPort or authority is None: raise SetupFault('host_not_configured')
        self._port, self._authority, self._clock = port, authority, clock
        self._pending, self._seen = {}, set()
        self._channel, self._closed = None, False

    async def _check(self, channel):
        if self._closed or (self._channel is not None and channel is not self._channel):
            raise SetupFault('caller_unverified')
        try: await self._authority.verify(channel)
        except SetupFault: raise
        except Exception: raise SetupFault('caller_unverified') from None
        if self._channel is None: self._channel = channel
        if self._closed or channel is not self._channel: raise SetupFault('caller_unverified')

    async def dispatch(self, channel, raw):
        await self._check(channel)
        try: value = decode(raw)
        except Exception: raise SetupFault('binding_mismatch') from None
        keys = {'schema_version', 'service', 'request_id', 'phase', 'request_json'}
        if (type(value) is not dict or set(value) != keys or type(value['schema_version']) is not int or
                value['schema_version'] != 1 or value['service'] != SERVICE or value['phase'] not in {'snapshot', 'capture', 'run'}
                or type(value['request_json']) is not str or type(value['request_id']) is not str):
            raise SetupFault('binding_mismatch')
        try:
            if str(uuid.UUID(value['request_id'])) != value['request_id']: raise ValueError()
        except ValueError: raise SetupFault('binding_mismatch') from None
        identity, phase, request_text = value['request_id'], value['phase'], value['request_json']
        if phase != 'run':
            self._pending = {key: record for key, record in self._pending.items() if self._clock() < record[2]}
        outcome, failure = 'captured', None
        snapshot = self._port.cached_snapshot()
        try:
            await self._check(channel)
            if phase == 'snapshot':
                if request_text != '{}': raise SetupFault('binding_mismatch')
                outcome = 'cached'
            elif phase == 'capture':
                request = request_from_wire(request_text)
                if (identity in self._seen or len(self._seen) >= 64 or
                        (self._pending and request.action != Action.STOP)):
                    raise SetupFault('operation_in_progress')
                captured = self._port.capture_after_click(request)  # exact actual capture_click, synchronously
                self._seen.add(identity)
                if request.action == Action.STOP: self._pending.clear()
                self._pending[identity] = (request_text, captured, self._clock() + 30)
            else:
                pending = self._pending.pop(identity, None)  # consumed before await/effect, never restored
                if pending is None or pending[0] != request_text: raise SetupFault('manual_intent_required')
                if self._clock() >= pending[2]: raise SetupFault('manual_intent_expired')
                # The bridge rechecks the exact owned Save/connection/manager
                # and private run epoch BEFORE cancellation. A carrier pending
                # ID/capture success is not that authority. The valid bridge
                # cancels only its owned task and fences that task's late reply.
                reply = await pending[1].run()
                if reply.request != pending[1].request: raise SetupFault('binding_mismatch')
                outcome, failure, snapshot = reply.outcome, reply.failure, reply.snapshot
            await self._check(channel)
        except asyncio.CancelledError:
            outcome, failure, snapshot = 'held', 'user_cancelled', self._port.cached_snapshot()
        except SetupFault as exc:
            outcome, failure, snapshot = 'held', exc.code, self._port.cached_snapshot()
        result = {**value, 'outcome': outcome, 'failure': failure,
                  'snapshot_json': canonical(snapshot_to_wire(snapshot)).decode()}
        await self._check(channel)
        return canonical(result) + b'\n'

    async def serve(self, channel):
        await self._check(channel)
        channel.setblocking(False)
        loop = asyncio.get_running_loop()
        writer, tasks, buffer = asyncio.Lock(), set(), bytearray()
        failed = False
        async def handle(raw):
            nonlocal failed
            try:
                response = await self.dispatch(channel, raw)
                if len(response) > 32768: raise SetupFault('binding_mismatch')
                async with writer:
                    await self._check(channel)
                    async with asyncio.timeout(2): await loop.sock_sendall(channel, response)
            except BaseException:
                if not self._closed:
                    failed = True
                    try: channel.shutdown(socket.SHUT_RDWR)
                    except OSError: pass
        try:
            for _ in range(128):
                async with asyncio.timeout(8):
                    while b'\n' not in buffer:
                        part = await loop.sock_recv(channel, 4096)
                        if not part: return
                        buffer.extend(part)
                        if len(buffer) > 65536: raise SetupFault('binding_mismatch')
                raw, _, rest = buffer.partition(b'\n'); buffer = bytearray(rest)
                if failed or len(raw) > 32768 or len(tasks) >= 4: raise SetupFault('operation_in_progress')
                task = asyncio.create_task(handle(bytes(raw)))
                tasks.add(task); task.add_done_callback(tasks.discard)
                await asyncio.sleep(0)
        finally:
            self._closed = True
            self._pending.clear()
            for task in tuple(tasks): task.cancel()
            try:
                if tasks:
                    async with asyncio.timeout(1): await asyncio.gather(*tuple(tasks), return_exceptions=True)
            finally: channel.close()
