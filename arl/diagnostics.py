"""Finite metadata events only. No free-text input or file import/export."""
from __future__ import annotations

import json
import secrets
import threading
import time
import os
import re
import stat
import tempfile
from pathlib import Path
from collections import deque

from .contracts import Fault, object_schema, string, validate

EVENTS = ('runtime_starting', 'runtime_ready', 'runtime_stopping', 'app_verified',
          'app_revoked', 'provider_check', 'rpc_rejected', 'model_task_queued', 'model_task_succeeded', 'model_task_failed', 'diagnostic_history_reset')
CODES = ('identity_unverified', 'method_not_authorized', 'unknown_app', 'unknown_method',
         'invalid_request', 'invalid_arguments', 'not_ready', 'internal_error',
         'provider_unavailable', 'probe_failed')
LEVELS = ('info', 'warning', 'error')
MAX_AGE_MS = 86400000
DETAIL_REASONS = frozenset((*CODES,'provider_controls_unverified','provider_deadline_exceeded','provider_timeout',
    'provider_preflight_failed','model_unavailable','unsupported_model','unsupported_reasoning_effort',
    'call_budget_exceeded','deadline_exceeded','cancelled','scope_expired','idempotency_conflict',
    'task_execution_disabled','app_connection_required','app_session_expired','input_too_large','result_too_large'))
DETAIL_METHODS = frozenset(('connection.open','connection.confirm','connection.heartbeat','connection.close',
    'model.task.submit.v1','model.task.get.v1','model.task.cancel.v1','health','ready','runtime.describe',
    'settings.snapshot','settings.logs','settings.logs.v3','settings.log_details.v1','settings.scheduler.v1'))

def diagnostic_context(value):
    """Finite task metadata only; never input, output, paths or provider messages."""
    if type(value) is not dict:return {}
    result={}
    for key,item in value.items():
        if key=='task_id' and type(item) is str and re.fullmatch(r'[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}',item):result[key]=item
        elif key=='package_id' and item in ('low','medium','high','very_high','highest'):result[key]=item
        elif key=='model' and type(item) is str and re.fullmatch(r'(?:gpt|o[1-9])[a-z0-9._-]{0,60}',item):result[key]=item
        elif key=='reasoning_effort' and item in ('none','minimal','low','medium','high','xhigh','max','ultra'):result[key]=item
        elif key=='method' and type(item) is str and item in DETAIL_METHODS:result[key]=item
        elif key=='reason' and type(item) is str and item in DETAIL_REASONS:result[key]=item
        elif key=='duration_ms' and type(item) is int and 0<=item<=3600000:result[key]=item
    return result

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
    def __init__(self, app_ids, clock=None, path=None):
        self.clock = clock or (lambda: int(time.time()*1000))
        self.app_ids = frozenset(app_ids)
        self.boot = secrets.token_hex(16)
        self.records = deque(maxlen=1024)
        self.sequence = 0
        self.lock = threading.RLock()
        self.path = Path(path) if path is not None else None
        self.persistence_error=False
        if self.path is not None:
            try:self._restore()
            except (Fault,OSError,ValueError,TypeError,KeyError):
                # Diagnostic corruption must not prevent the infrastructure
                # service from starting. Import no unvalidated bytes/identities.
                self.records.clear();self.sequence=0
                self.emit('diagnostic_history_reset',level='warning')

    def _restore(self):
        try:
            fd = os.open(self.path, os.O_RDONLY | os.O_NOFOLLOW)
        except FileNotFoundError:
            self._legacy_metadata()
            return
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077 or info.st_nlink != 1 or info.st_size > 1048576:
                raise Fault('unsafe_diagnostic_log')
            data = json.loads(os.read(fd, 1048577))
        finally:
            os.close(fd)
        if type(data) is not dict or set(data) != {'schema_version', 'records'} or data['schema_version'] != 1 or type(data['records']) is not list or len(data['records']) > 1024:
            raise Fault('unsafe_diagnostic_log')
        previous = 0
        for row in data['records']:
            if (type(row) is not dict or set(row) not in ({'sequence','at_ms','level','event','code','app_id'},{'sequence','at_ms','level','event','code','app_id','context'}) or
                    type(row['sequence']) is not int or row['sequence'] <= previous or
                    type(row['at_ms']) is not int or row['at_ms'] < 0 or row['event'] not in EVENTS or
                    row['level'] not in LEVELS or row['code'] not in (*CODES,None) or
                    (row['app_id'] is not None and (type(row['app_id']) is not str or re.fullmatch(r'[A-Za-z0-9_.-]{1,64}',row['app_id']) is None))):
                raise Fault('unsafe_diagnostic_log')
            if 'context' in row and (type(row['context']) is not dict or diagnostic_context(row['context'])!=row['context']):raise Fault('unsafe_diagnostic_log')
            previous = row['sequence']
            # Historical identities are labels, never restored registrations or grants.
            if self.clock()-MAX_AGE_MS <= row['at_ms'] <= self.clock()+60000:
                self.records.append(dict(row))
        self.sequence = previous

    def _legacy_metadata(self):
        """One-time migration of the previous fixed-field host lifecycle log."""
        try:fd=os.open(self.path.parent/'host.log',os.O_RDONLY|os.O_NOFOLLOW)
        except FileNotFoundError:return
        try:
            info=os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid!=os.geteuid() or info.st_mode&0o077 or info.st_nlink!=1 or info.st_size>65536:return
            raw=os.read(fd,65537)
        finally:os.close(fd)
        mapping={'starting':'runtime_starting','ready':'runtime_ready','stopped':'runtime_stopping'}
        for line in raw.splitlines()[-1024:]:
            try:row=json.loads(line)
            except (ValueError,UnicodeError):continue
            if (type(row) is not dict or set(row)-{'at','event','version','code'} or
                type(row.get('at')) is not int or row.get('event') not in mapping or
                not self.clock()-MAX_AGE_MS<=row['at']*1000<=self.clock()):continue
            self.sequence+=1
            self.records.append({'sequence':self.sequence,'at_ms':row['at']*1000,'level':'info',
                'event':mapping[row['event']],'code':None,'app_id':None})

    def _persist(self):
        if self.path is None:
            return
        raw = json.dumps({'schema_version':1,'records':list(self.records)},sort_keys=True,separators=(',',':')).encode()
        fd, name = tempfile.mkstemp(prefix='.diagnostics-',dir=self.path.parent)
        try:
            with os.fdopen(fd,'wb') as stream:
                stream.write(raw); stream.flush(); os.fsync(stream.fileno())
            os.replace(name,self.path)
        finally:
            if os.path.exists(name): os.unlink(name)

    def emit(self, event, *, code=None, app=None, level='info', context=None):
        # Reject/omit hostile strings rather than attempting regex redaction.
        if event not in EVENTS or level not in LEVELS:
            return
        with self.lock:
            self.sequence += 1
            self.records.append({'sequence':self.sequence, 'at_ms':self.clock(),
                'level':level, 'event':event, 'code':code if code in CODES else None,
                'app_id':app if type(app) is str and app in self.app_ids else None})
            safe=diagnostic_context(context)
            if safe:self.records[-1]['context']=safe
            try:self._persist();self.persistence_error=False
            except OSError:self.persistence_error=True

    def query(self, params, *, export=False):
        validate(params, log_schema(export))
        now = self.clock()
        until = params.get('until_ms', now)
        since = params.get('since_ms', max(0, until-MAX_AGE_MS))
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
                    # Preserve the exact six-field legacy log wire contract.
                    public={key:value for key,value in row.items() if key!='context'}
                    line = json.dumps(public, sort_keys=True, separators=(',',':'))+'\n'
                    length = len(line.encode('utf-8'))
                    if len(selected) >= limit or (export and size+length > 65536):
                        more = True
                        break
                    selected.append(public); lines.append(line); size += length
                scanned = row['sequence']
            response = {'schema_version':2, 'redaction_version':1,
                'next_cursor':self.boot+':'+str(scanned), 'more':more, 'truncated':truncated}
            if export:
                response.update(format='jsonl', content=''.join(lines),
                                records_count=len(selected), max_bytes=65536)
            else:
                response['records'] = selected
            return response

    def details(self,params):
        validate(params,object_schema({'sequence':{'type':'integer','minimum':1,'maximum':1000000000000000},'session_id':{**string(32),'pattern':r'[a-f0-9]{32}'}},['sequence','session_id']))
        with self.lock:
            if params['session_id']!=self.boot:raise Fault('log_session_changed')
            row=next((r for r in self.records if r['sequence']==params['sequence'] and r['at_ms']>=self.clock()-MAX_AGE_MS),None)
            return {'schema_version':1,'session_id':self.boot,'sequence':params['sequence'],'available':row is not None,
                    'context':dict(row.get('context',{})) if row else {}}

    def recent(self,params):
        validate(params,object_schema({'limit':{'type':'integer','minimum':1,'maximum':500},'level':{'type':'string','enum':list(LEVELS)}}))
        with self.lock:
            rows=[r for r in self.records if self.clock()-MAX_AGE_MS<=r['at_ms']<=self.clock() and
                  ('level' not in params or r['level']==params['level'])]
            limit=params.get('limit',500)
            return {'schema_version':1,'session_id':self.boot,'limit':limit,'total':len(rows),'truncated':len(rows)>limit,
                    'records':[{k:v for k,v in row.items() if k!='context'} for row in rows[-limit:]]}

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
