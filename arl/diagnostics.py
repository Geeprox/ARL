"""Finite metadata events only. No free-text input or file import/export."""
from __future__ import annotations

import json
import secrets
import threading
import time
from collections import deque

from .contracts import Fault, object_schema, string, validate

EVENTS = ('runtime_starting', 'runtime_ready', 'runtime_stopping', 'app_verified',
          'app_revoked', 'provider_check', 'rpc_rejected')
CODES = ('identity_unverified', 'method_not_authorized', 'unknown_app', 'unknown_method',
         'invalid_request', 'invalid_arguments', 'not_ready', 'internal_error',
         'provider_unavailable', 'probe_failed')
LEVELS = ('info', 'warning', 'error')
MAX_AGE_MS = 86400000

def log_schema(export=False):
    return object_schema({'cursor': {**string(64), 'pattern': r'[a-f0-9]{32}:[0-9]{1,20}'},
        'limit': {'type':'integer', 'minimum':1, 'maximum':500 if export else 100},
        'level': {'type':'string', 'enum':list(LEVELS)},
        'event': {'type':'string', 'enum':list(EVENTS)},
        'since_ms': {'type':'integer', 'minimum':0, 'maximum':1000000000000000},
        'until_ms': {'type':'integer', 'minimum':0, 'maximum':1000000000000000}})

def log_v3_schema():
    return object_schema({**log_schema()['properties'],
        'mode': {'type':'string', 'enum':['checkpoint','page']},
        'session_id': {**string(32), 'pattern': r'[a-f0-9]{32}'}}, ['mode'])

class Diagnostics:
    def __init__(self, app_ids, clock=None):
        self.clock = clock or (lambda: int(time.time()*1000))
        self.app_ids = frozenset(app_ids)
        self.boot = secrets.token_hex(16)
        self.records = deque(maxlen=1024)
        self.sequence = 0
        self.lock = threading.RLock()

    def emit(self, event, *, code=None, app=None, level='info'):
        # Reject/omit hostile strings rather than attempting regex redaction.
        if event not in EVENTS or level not in LEVELS:
            return
        with self.lock:
            self.sequence += 1
            self.records.append({'sequence':self.sequence, 'at_ms':self.clock(),
                'level':level, 'event':event, 'code':code if code in CODES else None,
                'app_id':app if type(app) is str and app in self.app_ids else None})

    def query(self, params, *, export=False):
        validate(params, log_schema(export))
        now = self.clock()
        until = params.get('until_ms', now)
        since = params.get('since_ms', max(0, until-900000))
        if not 0 <= since <= until <= now or until-since > MAX_AGE_MS:
            raise Fault('invalid_arguments')
        limit = params.get('limit', 500 if export else 50)
        with self.lock:
            cursor = params.get('cursor')
            after = 0
            if cursor is not None:
                try:
                    boot, raw = cursor.split(':')
                    after = int(raw)
                except (ValueError, TypeError, AttributeError):
                    raise Fault('invalid_cursor') from None
                if boot != self.boot or not 0 <= after <= self.sequence:
                    raise Fault('invalid_cursor')
            while self.records and self.records[0]['at_ms'] < now-MAX_AGE_MS:
                self.records.popleft()
            entries = list(self.records)
            oldest = entries[0]['sequence'] if entries else self.sequence+1
            truncated = after < oldest-1
            selected, scanned, size, lines = [], after, 0, []
            more = False
            for row in entries:
                if row['sequence'] <= after:
                    continue
                matches = (since <= row['at_ms'] <= until and
                    all(row[key] == params[key] for key in ('level','event') if key in params))
                if matches:
                    line = json.dumps(row, sort_keys=True, separators=(',',':'))+'\n'
                    length = len(line.encode('utf-8'))
                    if len(selected) >= limit or (export and size+length > 65536):
                        more = True
                        break
                    selected.append(dict(row)); lines.append(line); size += length
                scanned = row['sequence']
            response = {'schema_version':2, 'redaction_version':1,
                'next_cursor':self.boot+':'+str(scanned), 'more':more, 'truncated':truncated}
            if export:
                response.update(format='jsonl', content=''.join(lines),
                                records_count=len(selected), max_bytes=65536)
            else:
                response['records'] = selected
            return response

    def query_v3(self, params):
        """Atomic read of this diagnostic lifetime, never an authority token.

        Ordinary retention/filter queries do not rotate boot or sequence. A new
        Runtime creates a new ControlPlane/Diagnostics lifetime and new boot ID.
        The existing opaque cursor and all v2/export shapes remain unchanged.
        """
        validate(params, log_v3_schema())
        mode = params['mode']
        if mode == 'checkpoint':
            if set(params) != {'mode'}:
                raise Fault('invalid_arguments')
            with self.lock:
                return {'schema_version':3, 'redaction_version':1, 'mode':mode,
                        'session_id':self.boot, 'latest_sequence':self.sequence}
        if 'session_id' not in params:
            raise Fault('invalid_arguments')
        query = {key:value for key,value in params.items() if key not in {'mode','session_id'}}
        with self.lock:
            if params['session_id'] != self.boot:
                raise Fault('log_session_changed')
            response = self.query(query)
            # This is our own server-produced cursor. Only the server knows its
            # internal format; consumers use the explicit scanned sequence.
            scanned = int(response['next_cursor'].rsplit(':', 1)[1])
            if not response['more']:
                # No retained rows remain to examine. This also consumes events
                # removed by retention, so a filtered/expired empty tail does
                # not look perpetually unread to v3 consumers. v2 is unchanged.
                scanned = self.sequence
                response['next_cursor'] = self.boot+':'+str(scanned)
            response.update(schema_version=3, mode=mode, session_id=self.boot,
                            latest_sequence=self.sequence, scanned_through_sequence=scanned)
            return response
