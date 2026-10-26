"""Optional, host-owned immutable uploads for the frozen capture runtime.

The existing Handler supplies the actual verified app. Upload RPCs cannot enroll
an app, choose an owner, provide an epoch or purpose, or name a filesystem path.
These private tables are separate from research/Responses payloads and exist
only when a host explicitly attaches this engine to its caller-owned Store.
"""
from __future__ import annotations

import base64
import binascii
import hashlib
import math
import uuid

from .contracts import Fault, encode
from .tisra_capture_contract import (
    MAX_REQUEST_BYTES, REQUEST_PURPOSE, _digest, _exact, _integer, _uuid,
)
from .tisra_capture_runtime import (
    METHODS as CAPTURE_METHODS, CapturePayloadRequest, CaptureRuntime,
    UploadedCapturePayload,
)

UPLOAD_METHODS = frozenset({
    'capture.upload.begin.v2', 'capture.upload.append.v2', 'capture.upload.seal.v2',
})
METHODS = CAPTURE_METHODS | UPLOAD_METHODS
CHUNK_BYTES = 8192
MAX_BASE64_BYTES = 4 * ((CHUNK_BYTES + 2) // 3)
MAX_UPLOAD_RECORDS = 4096
_METADATA = ('id,owner,capture_request_id,library_id,auth_epoch,purpose,sha256,'
             'byte_count,received,state,expires,authority,pin')


class _SealedResolver:
    def __init__(self, engine):
        self.engine = engine

    def resolve(self, request):
        return self.engine._resolve(request)


class UploadedCaptureRuntime(CaptureRuntime):
    """Explicit capture composition with finite private SQLite upload storage.

    Authority, registration, independent grants and native pins are rechecked
    under the same configuration lock as every byte effect. A trusted row binds
    continuation RPCs to their library before authorization; payload IDs are
    always looked up with their actual verified owner. The resolver additionally
    checks the frozen request's capture/epoch/purpose/hash/count, and _payload
    binds its library to the v1 CaptureBinding without changing the v1 types.

    revoke() is host-only. No upload enrollment, configuration or revoke RPC is
    installed. Revoked, expired and interrupted uploads retain bounded metadata
    tombstones but no bytes. Sealed data survives restart until expiry/revocation;
    inherited recovery holds unfinished captures and never replays a source.
    """
    def __init__(self, *, upload_ttl=900, owner_byte_cap=2 * 1048576,
                 global_byte_cap=16 * 1048576, owner_upload_cap=8,
                 global_upload_cap=128, **kwargs):
        if ('payload_resolver' in kwargs and kwargs['payload_resolver'] is not None):
            raise Fault('capture_upload_configuration_invalid')
        kwargs.pop('payload_resolver', None)
        if (type(upload_ttl) not in {int, float} or not math.isfinite(upload_ttl)
                or not 1 <= upload_ttl <= 86400):
            raise Fault('capture_upload_configuration_invalid')
        for value, maximum in ((owner_byte_cap, 64 * 1048576),
                               (global_byte_cap, 256 * 1048576),
                               (owner_upload_cap, MAX_UPLOAD_RECORDS),
                               (global_upload_cap, MAX_UPLOAD_RECORDS)):
            if type(value) is not int or not 1 <= value <= maximum:
                raise Fault('capture_upload_configuration_invalid')
        self.upload_ttl = upload_ttl
        self.owner_byte_cap, self.global_byte_cap = owner_byte_cap, global_byte_cap
        self.owner_upload_cap, self.global_upload_cap = owner_upload_cap, global_upload_cap
        super().__init__(payload_resolver=_SealedResolver(self), **kwargs)

    def attach(self, store):
        super().attach(store)
        with store.transaction():
            store.db.execute('''CREATE TABLE IF NOT EXISTS capture_uploads_v2(
                id TEXT PRIMARY KEY, owner TEXT NOT NULL,
                capture_request_id TEXT NOT NULL, library_id TEXT NOT NULL,
                auth_epoch TEXT NOT NULL,
                purpose TEXT NOT NULL CHECK(purpose='tisra.capture.request.v1'),
                sha256 TEXT NOT NULL, byte_count INTEGER NOT NULL
                    CHECK(byte_count BETWEEN 1 AND 524288),
                received INTEGER NOT NULL DEFAULT 0
                    CHECK(received BETWEEN 0 AND byte_count),
                state TEXT NOT NULL CHECK(state IN
                    ('staging','sealed','revoked','expired','invalidated')),
                expires REAL NOT NULL, authority TEXT NOT NULL, pin TEXT NOT NULL,
                data BLOB NOT NULL)''')
            store.db.execute('''CREATE INDEX IF NOT EXISTS capture_upload_owner_v2
                ON capture_uploads_v2(owner,capture_request_id)''')
            store.db.execute('''CREATE TRIGGER IF NOT EXISTS capture_upload_binding_v2
                BEFORE UPDATE ON capture_uploads_v2 WHEN
                NEW.id!=OLD.id OR NEW.owner!=OLD.owner OR
                NEW.capture_request_id!=OLD.capture_request_id OR
                NEW.library_id!=OLD.library_id OR NEW.auth_epoch!=OLD.auth_epoch OR
                NEW.purpose!=OLD.purpose OR NEW.sha256!=OLD.sha256 OR
                NEW.byte_count!=OLD.byte_count OR NEW.expires!=OLD.expires OR
                NEW.authority!=OLD.authority OR NEW.pin!=OLD.pin
                BEGIN SELECT RAISE(ABORT,'capture upload binding is immutable'); END''')
            store.db.execute('''CREATE TRIGGER IF NOT EXISTS capture_upload_sealed_v2
                BEFORE UPDATE ON capture_uploads_v2 WHEN OLD.state='sealed' AND
                (NEW.state='staging' OR (NEW.state='sealed' AND
                    (NEW.data!=OLD.data OR NEW.received!=OLD.received)))
                BEGIN SELECT RAISE(ABORT,'sealed capture upload is immutable'); END''')

    def _metadata(self, owner, payload_id):
        _uuid(payload_id)
        row = self.store.db.execute(
            'SELECT ' + _METADATA + ' FROM capture_uploads_v2 WHERE owner=? AND id=?',
            (owner, payload_id)).fetchone()
        if row is None:
            raise Fault('capture_upload_not_found')
        return row

    def _live(self, row, method):
        # Library comes only from the owner-scoped private row, never a caller's
        # continuation request. _authorize checks fresh metadata and native pins.
        authority, _ = self._authorize(row['owner'], method, row['library_id'])
        if (encode(authority.__dict__).decode() != row['authority'] or
                encode(self.pins[row['library_id']].__dict__).decode() != row['pin'] or
                authority.auth_epoch != row['auth_epoch'] or row['purpose'] != REQUEST_PURPOSE):
            raise Fault('capture_upload_binding_mismatch')
        if row['state'] in {'revoked', 'invalidated'}:
            raise Fault('capture_upload_revoked')
        if row['state'] == 'expired' or row['expires'] <= self.clock():
            raise Fault('capture_upload_expired')
        self._check_cancelled(row['owner'], row['capture_request_id'])
        return authority

    def _check_cancelled(self, owner, capture_request_id):
        row = self.store.db.execute('''SELECT j.cancel,j.state FROM capture_delivery_v1 c
            JOIN jobs j ON j.id=c.job WHERE c.owner=? AND c.capture_request_id=?''',
            (owner, capture_request_id)).fetchone()
        if row is not None and (row['cancel'] or row['state'] == 'cancelled'):
            raise Fault('capture_upload_cancelled')

    def _cleanup(self):
        self.store.db.execute('''UPDATE capture_uploads_v2 SET state='expired',data=x''
            WHERE expires<=? AND state IN ('staging','sealed')''', (self.clock(),))

    def _reserve(self, owner, byte_count):
        self._cleanup()
        db = self.store.db
        if db.execute('SELECT COUNT(*) FROM capture_uploads_v2').fetchone()[0] >= MAX_UPLOAD_RECORDS:
            raise Fault('capture_upload_budget_exceeded')
        owner_usage = db.execute('''SELECT COUNT(*),COALESCE(SUM(byte_count),0)
            FROM capture_uploads_v2 WHERE owner=? AND state IN ('staging','sealed')
            AND expires>?''', (owner, self.clock())).fetchone()
        global_usage = db.execute('''SELECT COUNT(*),COALESCE(SUM(byte_count),0)
            FROM capture_uploads_v2 WHERE state IN ('staging','sealed') AND expires>?''',
            (self.clock(),)).fetchone()
        if (owner_usage[0] >= self.owner_upload_cap or
                owner_usage[1] + byte_count > self.owner_byte_cap or
                global_usage[0] >= self.global_upload_cap or
                global_usage[1] + byte_count > self.global_byte_cap):
            raise Fault('capture_upload_budget_exceeded')

    @staticmethod
    def _ref(row):
        return {'payload_id': row['id'], 'sha256': row['sha256'],
                'byte_count': row['byte_count']}

    def _upload(self, owner, method, params):
        if method == 'capture.upload.begin.v2':
            _exact(params, {'capture_request_id', 'library_id', 'sha256', 'byte_count'})
            _uuid(params['capture_request_id']); _uuid(params['library_id'])
            _digest(params['sha256']); _integer(params['byte_count'], 1, MAX_REQUEST_BYTES)
            with self._configuration_lock, self.store.transaction():
                authority, _ = self._authorize(owner, method, params['library_id'])
                self._check_cancelled(owner, params['capture_request_id'])
                self._reserve(owner, params['byte_count'])
                payload_id = str(uuid.uuid4())
                expires = self.clock() + self.upload_ttl
                self.store.db.execute('''INSERT INTO capture_uploads_v2
                    (id,owner,capture_request_id,library_id,auth_epoch,purpose,sha256,
                     byte_count,state,expires,authority,pin,data)
                    VALUES(?,?,?,?,?,?,?,?,'staging',?,?,?,x'')''',
                    (payload_id, owner, params['capture_request_id'], authority.library_id,
                     authority.auth_epoch, REQUEST_PURPOSE, params['sha256'], params['byte_count'],
                     expires, encode(authority.__dict__).decode(),
                     encode(self.pins[authority.library_id].__dict__).decode()))
                return dict(payload_id=payload_id, sha256=params['sha256'],
                            byte_count=params['byte_count'], expires_at_ms=int(expires * 1000),
                            chunk_bytes=CHUNK_BYTES)
        keys = ({'payload_id', 'offset', 'data_base64'} if method == 'capture.upload.append.v2'
                else {'payload_id'})
        _exact(params, keys)
        with self._configuration_lock, self.store.transaction():
            row = self._metadata(owner, params['payload_id'])
            self._live(row, method)
            if method == 'capture.upload.append.v2':
                if row['state'] != 'staging':
                    raise Fault('capture_upload_immutable')
                _integer(params['offset'], 0, MAX_REQUEST_BYTES)
                encoded = params['data_base64']
                if type(encoded) is not str or not 1 <= len(encoded) <= MAX_BASE64_BYTES:
                    raise Fault('capture_invalid_arguments')
                try:
                    chunk = base64.b64decode(encoded, validate=True)
                except (ValueError, binascii.Error):
                    raise Fault('capture_invalid_arguments') from None
                if (not 1 <= len(chunk) <= CHUNK_BYTES or
                        base64.b64encode(chunk).decode('ascii') != encoded):
                    raise Fault('capture_invalid_arguments')
                if params['offset'] != row['received']:
                    raise Fault('capture_upload_offset_mismatch')
                if row['received'] + len(chunk) > row['byte_count']:
                    raise Fault('capture_upload_size_exceeded')
                raw = bytes(self.store.db.execute('''SELECT data FROM capture_uploads_v2
                    WHERE owner=? AND id=?''', (owner, row['id'])).fetchone()[0])
                self.store.db.execute('''UPDATE capture_uploads_v2 SET data=?,received=?
                    WHERE owner=? AND id=?''',
                    (raw + chunk, row['received'] + len(chunk), owner, row['id']))
                return {'payload_id': row['id'], 'offset': row['received'] + len(chunk)}
            raw = bytes(self.store.db.execute('''SELECT data FROM capture_uploads_v2
                WHERE owner=? AND id=?''', (owner, row['id'])).fetchone()[0])
            if (len(raw) != row['byte_count'] or row['received'] != row['byte_count'] or
                    hashlib.sha256(raw).hexdigest() != row['sha256']):
                raise Fault('capture_upload_hash_mismatch')
            self.store.db.execute("UPDATE capture_uploads_v2 SET state='sealed' WHERE owner=? AND id=?",
                                  (owner, row['id']))
            return self._ref(row)

    def dispatch(self, owner, method, params, policy, *, verified_app=None):
        if verified_app != owner:
            raise Fault('app_identity_unverified')
        if method in UPLOAD_METHODS:
            return self._upload(owner, method, params)
        result = super().dispatch(owner, method, params, policy, verified_app=verified_app)
        if method == 'capture.cancel.v1':
            self.revoke(owner, capture_request_id=params['capture_request_id'])
        return result

    def _resolve(self, request):
        if type(request) is not CapturePayloadRequest:
            raise Fault('capture_upload_binding_mismatch')
        _uuid(request.capture_request_id); _digest(request.sha256)
        _integer(request.byte_count, 1, MAX_REQUEST_BYTES)
        with self._configuration_lock, self.store.lock:
            row = self._metadata(request.owner, request.payload_id)
            self._live(row, 'capture.submit.v1')
            if (request.capture_request_id != row['capture_request_id'] or
                    request.auth_epoch != row['auth_epoch'] or request.purpose != row['purpose'] or
                    request.sha256 != row['sha256'] or request.byte_count != row['byte_count']):
                raise Fault('capture_upload_binding_mismatch')
            if row['state'] != 'sealed':
                raise Fault('capture_upload_not_sealed')
            raw = bytes(self.store.db.execute('''SELECT data FROM capture_uploads_v2
                WHERE owner=? AND id=?''', (request.owner, request.payload_id)).fetchone()[0])
            if len(raw) != request.byte_count or hashlib.sha256(raw).hexdigest() != request.sha256:
                raise Fault('capture_upload_hash_mismatch')
            return UploadedCapturePayload(request, raw, True, row['expires'])

    def _payload(self, binding, ref):
        with self._configuration_lock, self.store.lock:
            row = self._metadata(binding.writer_app, ref['payload_id'])
            if row['library_id'] != binding.library_id:
                raise Fault('capture_upload_binding_mismatch')
            return super()._payload(binding, ref)

    def _status(self, row, method, raw_request=None):
        # Completion publishes its terminal state under this same lock. Keep
        # the state read, cached receipt verification and projection coherent;
        # a running read must not become succeeded with an absent receipt.
        with self._configuration_lock:
            return super()._status(row, method, raw_request)

    def revoke(self, owner, *, payload_id=None, capture_request_id=None):
        """Host-only irreversible revocation, scoped to an exact owner."""
        if payload_id is not None:
            _uuid(payload_id)
        if capture_request_id is not None:
            _uuid(capture_request_id)
        with self._configuration_lock, self.store.transaction():
            query = "UPDATE capture_uploads_v2 SET state='revoked',data=x'' WHERE owner=?"
            args = [owner]
            if payload_id is not None:
                query += ' AND id=?'; args.append(payload_id)
            if capture_request_id is not None:
                query += ' AND capture_request_id=?'; args.append(capture_request_id)
            return self.store.db.execute(query, args).rowcount

    def recover(self):
        with self._configuration_lock, self.store.transaction():
            self._cleanup()
            self.store.db.execute("UPDATE capture_uploads_v2 SET state='invalidated',data=x'' WHERE state='staging'")
        super().recover()
