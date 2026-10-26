"""Private server-metadata admission, separate from persistent directory grants."""
import asyncio
import base64
import hashlib
import json
import os
import re
import time
import uuid
from dataclasses import dataclass, replace
from nas_host import strict, CallerPins, CredentialFault, Failure
from homeplane.nas_connection.contracts import NASConnectionError, relative_path
from homeplane.nas_connection.worker import error_code
from smb_server_metadata import EncryptedServer, share_name

@dataclass(frozen=True)
class MetadataScope:
    purpose: str
    source_ref: str
    credential_ref: str
    credential_generation: str
    config_generation: int
    endpoint_fingerprint: str
    metadata_target: dict

class ServerBridge:
    def __init__(self, wire, *, server_factory=EncryptedServer):
        self.wire, self.factory = wire, server_factory
        self.server = None; self.scope = self.caller = self.epoch = None
        self.deadline = 0; self.sequence = 1; self.monitor = None
        self.shares = set(); self.cursors = {}; self.paths = {}; self.pages = 0

    async def authorize(self, stage, scope, *, lease=False):
        if time.monotonic() >= self.deadline or self.scope is None:
            raise CredentialFault(Failure.EXPIRED)
        reply = await self.wire.authorize(stage,scope,self.caller,lease=lease)
        if time.monotonic() >= self.deadline: raise CredentialFault(Failure.EXPIRED)
        return reply

    async def connect(self, frame):
        if (set(frame) != {'kind','id','nonce','caller','scope','endpoint'}
                or frame['kind'] != 'server_connect' or type(frame['id']) is not int or frame['id'] != 1
                or not isinstance(frame['nonce'],str) or not re.fullmatch('[0-9a-f]{32}',frame['nonce'])):
            raise CredentialFault(Failure.PROVIDER_INVALID)
        endpoint = frame['endpoint']
        if (type(endpoint) is not dict or set(endpoint) != {'source_ref','host','port','timeout_seconds','generation','endpoint_fingerprint','require_encryption'}
                or not isinstance(endpoint['host'],str) or not re.fullmatch('[A-Za-z0-9.-]{1,253}',endpoint['host'])
                or not isinstance(endpoint['source_ref'],str) or not re.fullmatch('[A-Za-z0-9_-]{1,128}',endpoint['source_ref'])
                or type(endpoint['port']) is not int or not 1 <= endpoint['port'] <= 65535
                or type(endpoint['timeout_seconds']) is not int or not 1 <= endpoint['timeout_seconds'] <= 30
                or type(endpoint['generation']) is not int or not 0 < endpoint['generation'] <= 2**63-1
                or endpoint['require_encryption'] is not True):
            raise CredentialFault(Failure.PROVIDER_INVALID)
        fingerprint = hashlib.sha256(json.dumps(['nas-server-v2','smb',endpoint['host'].lower(),str(endpoint['port']),'encryption-required'],separators=(',',':')).encode()).hexdigest()
        if endpoint['endpoint_fingerprint'] != fingerprint: raise CredentialFault(Failure.SOURCE_CHANGED)
        self.scope = MetadataScope(**frame['scope'])
        if (self.scope.purpose != 'server_metadata_only' or self.scope.metadata_target != {}
                or self.scope.source_ref != endpoint['source_ref'] or self.scope.config_generation != endpoint['generation']
                or self.scope.endpoint_fingerprint != fingerprint
                or not isinstance(self.scope.credential_ref,str) or str(uuid.UUID(self.scope.credential_ref)) != self.scope.credential_ref
                or not re.fullmatch('[0-9a-f]{32}',self.scope.credential_generation)):
            raise CredentialFault(Failure.PROVIDER_INVALID)
        self.caller = CallerPins(**frame['caller'])
        if self.caller.subject != 'local.arl.control' or self.wire.kernel_check and (self.caller.pid != os.getppid() or self.caller.uid != os.getuid()):
            raise CredentialFault(Failure.CALLER_UNVERIFIED)
        self.wire.nonce = frame['nonce']; self.deadline = time.monotonic()+120
        raw = bytearray(); envelope = None; username = password = ''
        try:
            await self.authorize('reserve',self.scope)
            reply = await self.authorize('lease',self.scope,lease=True)
            raw = bytearray(base64.b64decode(reply.pop('credential'),validate=True))
            envelope = strict(raw)
            if (type(envelope) is not dict or set(envelope) != {'schema','endpoint_fingerprint','username','password'}
                    or type(envelope['schema']) is not int or envelope['schema'] != 2 or envelope['endpoint_fingerprint'] != fingerprint
                    or type(envelope['username']) is not str or type(envelope['password']) is not str
                    or not 1 <= len(envelope['username']) <= 256 or len(envelope['username'].encode()) > 1024
                    or any(ord(c) < 32 or ord(c)==127 for c in envelope['username'])
                    or not 1 <= len(envelope['password']) <= 8192 or len(envelope['password'].encode()) > 32768 or '\0' in envelope['password']):
                raise CredentialFault(Failure.CREDENTIAL_INVALID)
            username,password = envelope.pop('username'),envelope.pop('password')
            await self.authorize('connect_effect',self.scope)
            self.server = await asyncio.to_thread(self.factory,endpoint,username,password)
            await self.authorize('reply',self.scope)
            self.epoch = uuid.uuid4().hex
            self.monitor = asyncio.create_task(self.watch())
            return self.snapshot()
        except BaseException as exc:
            from nas_diagnostic import failure_record
            failure_record(exc,'server_login')
            await self.stop()
            if isinstance(exc,(CredentialFault,NASConnectionError,asyncio.CancelledError)): raise
            raise NASConnectionError(error_code(exc)) from None
        finally:
            username = password = ''
            if envelope is not None: envelope.clear()
            raw[:] = b'\0'*len(raw); raw.clear()

    def snapshot(self, shares=None, cursor=None):
        return {'authenticated':self.server is not None,'epoch':self.epoch,'shares':shares or [],'next_cursor':cursor,'failure':None}

    async def command(self, frame):
        action = frame.get('kind'); keys = {'kind','id','nonce','scope'}
        target = {}
        if action == 'shares':
            keys.add('cursor'); target = {'operation':'shares','cursor':frame.get('cursor') or ''}
        elif action == 'preview_directories':
            keys.update({'share','path','cursor'})
            target = {'operation':'directories','share':frame.get('share'),'path':frame.get('path'),'cursor':frame.get('cursor') or ''}
        elif action == 'server_status': target = {'operation':'status'}
        elif action != 'stop': raise CredentialFault(Failure.DISABLED)
        if (set(frame) != keys or frame['nonce'] != self.wire.nonce or type(frame['id']) is not int
                or frame['id'] != self.sequence+1 or self.scope is None
                or frame['scope'] != replace(self.scope,metadata_target=target).__dict__):
            raise CredentialFault(Failure.PROVIDER_INVALID)
        self.sequence = frame['id']; scope = replace(self.scope,metadata_target=target)
        try:
            await self.authorize('request',scope)
            if action == 'stop': await self.stop(); return self.snapshot()
            if self.server is None: raise NASConnectionError('nas_unavailable')
            if action == 'server_status': result = self.snapshot()
            elif action == 'shares':
                cursor = frame['cursor']
                if self.pages >= 8: raise NASConnectionError('nas_budget_exceeded')
                if cursor is None: resume = 0; self.shares.clear(); self.paths.clear(); self.cursors.clear()
                elif type(cursor) is str and cursor in self.cursors: resume = self.cursors.pop(cursor)
                else: raise CredentialFault(Failure.TICKET_INVALID)
                names,resume = await asyncio.to_thread(self.server.shares,resume)
                if len(names)>128: raise CredentialFault(Failure.PROVIDER_INVALID)
                names = [share_name(x) for x in names]
                self.shares.update(names); self.pages += 1
                next_cursor = uuid.uuid4().hex if resume is not None else None
                if next_cursor: self.cursors[next_cursor] = resume
                result = self.snapshot(names,next_cursor)
            else:
                share,path,cursor = share_name(frame['share']),relative_path(frame['path'],allow_root=True),frame['cursor']
                if share not in self.shares: raise CredentialFault(Failure.SOURCE_CHANGED)
                known = self.paths.setdefault(share,{''})
                if path not in known: raise NASConnectionError('nas_object_unknown')
                if cursor is not None and (not isinstance(cursor,str) or not re.fullmatch('[0-9a-f]{32}',cursor)):
                    raise CredentialFault(Failure.PROVIDER_INVALID)
                result = await asyncio.to_thread(self.server.directories,share,path,cursor)
                if set(result) != {'path','directories','next_cursor'} or result['path'] != path or len(result['directories']) > 128:
                    raise CredentialFault(Failure.PROVIDER_INVALID)
                for directory in result['directories']:
                    relative_path(directory)
                    if directory.rpartition('/')[0] != path: raise CredentialFault(Failure.PROVIDER_INVALID)
                    known.add(directory)
                if len(known)>4096: raise NASConnectionError('nas_budget_exceeded')
            await self.authorize('request_reply',scope)
            return result
        except BaseException as exc:
            stage = {'shares':'share_list','preview_directories':'directory_list'}.get(action)
            if stage is not None:
                from nas_diagnostic import failure_record
                failure_record(exc,stage)
            if isinstance(exc,(CredentialFault,NASConnectionError,asyncio.CancelledError)): raise
            raise NASConnectionError(error_code(exc)) from None

    async def watch(self):
        await asyncio.sleep(max(0,self.deadline-time.monotonic()))
        await self.stop(from_monitor=True)

    async def stop(self,*,from_monitor=False):
        if self.monitor is not None and not from_monitor: self.monitor.cancel()
        self.monitor = None
        server,self.server = self.server,None
        self.epoch = None; self.shares.clear(); self.cursors.clear(); self.paths.clear()
        if server is not None: await asyncio.to_thread(server.close)
