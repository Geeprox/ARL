"""Opt-in typed research. No provider or app grant is installed by importing this module."""
from __future__ import annotations

import base64
import hashlib
import json
import re
import time
import uuid
from contextlib import nullcontext
from dataclasses import dataclass

from .contracts import Fault, Tool, encode, object_schema, string

NAME = 'tisra.research.v1'
REQUEST = 'tisra.research.request.v1'
DESCRIPTOR = 'tisra.research.descriptor.v1'
RESPONSE = 'tisra.research.response.v1'
LIMITS = {REQUEST: 524288, DESCRIPTOR: 32768, RESPONSE: 1048576}
CHUNK = 8192
READ_CHUNK = 32768
METHODS = frozenset({'research.capabilities.v1', 'research.submit.v1', 'research.status.v1',
                    'research.cancel.v1', 'payload.begin.v1', 'payload.write.v1',
                    'payload.seal.v1', 'payload.read.v1', 'payload.revoke.v1'})
FORMATS = ('openai.responses.request.v1', 'openai.responses.envelope.v1',
           'openai.responses.history.v1')


def sha(data):
    return hashlib.sha256(data).hexdigest()


def exact(obj, keys):
    if type(obj) is not dict or set(obj) != set(keys):
        raise Fault('invalid_arguments')


def integer(value, low, high):
    if type(value) is not int or not low <= value <= high:
        raise Fault('invalid_arguments')


def text(value, maximum=200):
    if type(value) is not str or not 1 <= len(value) <= maximum or any(ord(c) < 32 for c in value):
        raise Fault('invalid_arguments')


def digest(value):
    if type(value) is not str or not re.fullmatch('[a-f0-9]{64}', value):
        raise Fault('invalid_arguments')


def uid(value):
    try:
        if str(uuid.UUID(value)) != value:
            raise ValueError()
    except (ValueError, AttributeError, TypeError):
        raise Fault('invalid_arguments') from None


from .wire import strict_json


def ref(value, purpose):
    exact(value, {'payload_id', 'sha256', 'byte_count'})
    uid(value['payload_id']); digest(value['sha256'])
    integer(value['byte_count'], 1, LIMITS[purpose])


def descriptor(raw, args):
    d = strict_json(raw)
    exact(d, {'version', 'executionID', 'threadID', 'sequence', 'parentRunID',
              'parentFingerprint', 'startsAlternatePath', 'model', 'format', 'requestDigest',
              'requestBytes', 'maximumResponseBytes', 'maximumOutputTokens', 'evidence'})
    integer(d['version'], 1, 1); uid(d['executionID']); uid(d['threadID'])
    integer(d['sequence'], 0, 1000000)
    if d['parentRunID'] is not None: uid(d['parentRunID'])
    if d['parentFingerprint'] is not None: digest(d['parentFingerprint'])
    if type(d['startsAlternatePath']) is not bool: raise Fault('invalid_arguments')
    text(d['model'], 150)
    if d['format'] != 'openai.responses.v1': raise Fault('unsupported_research_format')
    digest(d['requestDigest']); integer(d['requestBytes'], 1, LIMITS[REQUEST])
    integer(d['maximumResponseBytes'], 1, LIMITS[RESPONSE])
    integer(d['maximumOutputTokens'], 1, 4096)
    if type(d['evidence']) is not list or len(d['evidence']) > 100: raise Fault('invalid_arguments')
    seen = set()
    for e in d['evidence']:
        exact(e, {'evidenceID', 'snapshotDigest'}); uid(e['evidenceID']); digest(e['snapshotDigest'])
        if e['evidenceID'] in seen: raise Fault('invalid_arguments')
        seen.add(e['evidenceID'])
    if (d['executionID'] != args['run_id'] or d['requestDigest'] != args['request']['sha256'] or
        d['requestBytes'] != args['request']['byte_count'] or d['model'] != args['model'] or
        d['maximumOutputTokens'] != args['max_output_tokens']):
        raise Fault('descriptor_mismatch')
    return d


def request_body(raw, args):
    """Validate supported immutable source format; never reserialize or strip fields."""
    obj = strict_json(raw)
    exact(obj, {'model', 'store', 'stream', 'background', 'truncation', 'max_output_tokens',
                'include', 'input', 'text', 'instructions'})
    if (obj['model'] != args['model'] or obj['store'] is not False or obj['stream'] is not False or
        obj['background'] is not False or obj['truncation'] != 'disabled' or
        obj['include'] != ['reasoning.encrypted_content']):
        raise Fault('unsupported_research_format')
    integer(obj['max_output_tokens'], 1, 4096)
    if obj['max_output_tokens'] != args['max_output_tokens']: raise Fault('descriptor_mismatch')
    if type(obj['input']) is not list or not 1 <= len(obj['input']) <= 200:
        raise Fault('unsupported_research_format')
    # Preserve encrypted reasoning and provider output items exactly. Tools are
    # not offered, and only existing message/reasoning history is admitted.
    for item in obj['input']:
        if type(item) is not dict: raise Fault('unsupported_research_format')
        if item.get('type') == 'reasoning':
            if set(item) - {'type', 'id', 'summary', 'encrypted_content', 'status'}:
                raise Fault('unsupported_research_format')
            text(item.get('encrypted_content'), LIMITS[REQUEST])
        elif item.get('type', 'message') == 'message':
            if set(item) - {'type', 'id', 'role', 'content', 'status', 'phase'} or item.get('role') not in {'user', 'assistant'}:
                raise Fault('unsupported_research_format')
            if type(item.get('content')) is str:
                text(item['content'], LIMITS[REQUEST])
                continue
            if type(item.get('content')) is not list: raise Fault('unsupported_research_format')
            for part in item['content']:
                if type(part) is not dict or part.get('type') not in {'input_text', 'output_text', 'refusal'}:
                    raise Fault('unsupported_research_format')
                if set(part) - {'type', 'text', 'refusal', 'annotations', 'logprobs'}:
                    raise Fault('unsupported_research_format')
        else:
            raise Fault('unsupported_research_format')
    exact(obj['text'], {'format'}); f = obj['text']['format']
    exact(f, {'type', 'name', 'strict', 'schema'})
    if f['type'] != 'json_schema' or f['name'] != 'sourced_research' or f['strict'] is not True or type(f['schema']) is not dict:
        raise Fault('unsupported_research_format')
    text(obj['instructions'], LIMITS[REQUEST])
    return obj


def response_body(raw, args):
    obj = strict_json(raw)
    if type(obj) is not dict or not {'id', 'model', 'status', 'output'} <= set(obj):
        raise Fault('invalid_provider_response')
    text(obj['id']); text(obj['model'])
    if obj['model'] != args['model'] or obj['status'] not in {'completed', 'incomplete'} or type(obj['output']) is not list:
        raise Fault('invalid_provider_response')
    usage = obj.get('usage')
    if usage is not None:
        if type(usage) is not dict: raise Fault('invalid_provider_response')
        integer(usage.get('output_tokens'), 0, args['max_output_tokens'])
    # Keep all upstream envelope fields, including output/reasoning, unchanged.
    return obj


@dataclass(frozen=True)
class ResearchGrant:
    provider: str
    models: frozenset
    auth_epoch: str
    max_output_tokens: int = 4096


class ResearchEngine:
    """Shares the service's single worker/SQLite transaction lock; off by default.

    adapters are host objects: name, model_fingerprints, formats, token_hard_cap,
    evidence ('test_double' or 'upstream_api'), complete(raw, args, context)->bytes.
    No caller can register an adapter, grant or endpoint.
    """
    name = NAME
    formats = FORMATS
    limits = LIMITS
    request_purpose, descriptor_purpose, response_purpose = REQUEST, DESCRIPTOR, RESPONSE

    def payload_ref(self, value, purpose):
        exact(value, {'payload_id', 'sha256', 'byte_count'})
        uid(value['payload_id']); digest(value['sha256'])
        integer(value['byte_count'], 1, self.limits[purpose])

    def validate_descriptor(self, raw, args):
        return descriptor(raw, args)

    def validate_request(self, raw, args):
        return request_body(raw, args)

    def validate_response(self, raw, args, run):
        return response_body(raw, args)

    def validate_pair(self, raw, meta, args):
        pass

    def provider_context(self, context, run):
        return context

    def external_admission(self, run):
        pass

    def capability_result(self, owner):
        g, a = self.grant(owner)
        return {'schema_version': 1, 'tool': self.name, 'formats': dict(zip(('request', 'output', 'history'), self.formats)),
                'provider': g.provider, 'provider_evidence': a.evidence,
                'models': {m: a.model_fingerprints[m] for m in sorted(g.models) if m in a.model_fingerprints},
                'max_request_bytes': self.limits[self.request_purpose], 'max_descriptor_bytes': self.limits[self.descriptor_purpose],
                'max_response_bytes': self.limits[self.response_purpose], 'max_output_tokens': min(4096, g.max_output_tokens),
                'token_hard_cap_supported': True, 'request_frame_bytes': 16384, 'response_frame_bytes': 65536}

    def __init__(self, grants, adapters, *, clock=time.time):
        self.grants, self.adapters, self.clock = dict(grants), dict(adapters), clock
        self.store = None
        self.tool = Tool(self.name, object_schema({'run_id': string(36)}, ['run_id']), self.execute,
                         idempotent=False, permissions=('typed_research', 'provider_inference'))

    def attach(self, store):
        self.store = store
        # Separate optional extension, not a change to installed metadata-only DB.
        with store.transaction():
            store.db.execute('CREATE TABLE IF NOT EXISTS research_extension(version INTEGER NOT NULL)')
            version = store.db.execute('SELECT version FROM research_extension').fetchall()
            if version and (len(version) != 1 or version[0][0] != 1): raise Fault('unsupported_research_store')
            if not version: store.db.execute('INSERT INTO research_extension VALUES(1)')
            store.db.execute('''CREATE TABLE IF NOT EXISTS research_payloads(
                id TEXT PRIMARY KEY, owner TEXT NOT NULL, purpose TEXT NOT NULL, run_id TEXT NOT NULL,
                epoch INTEGER NOT NULL, hash TEXT NOT NULL, size INTEGER NOT NULL, data BLOB NOT NULL,
                state TEXT NOT NULL, next_index INTEGER NOT NULL, expires REAL NOT NULL)''')
            store.db.execute('''CREATE TABLE IF NOT EXISTS research_chunks(
                payload TEXT NOT NULL, idx INTEGER NOT NULL, hash TEXT NOT NULL, size INTEGER NOT NULL,
                PRIMARY KEY(payload,idx))''')
            store.db.execute('''CREATE TABLE IF NOT EXISTS research_runs(
                owner TEXT NOT NULL, run_id TEXT NOT NULL, job TEXT NOT NULL UNIQUE, epoch INTEGER NOT NULL,
                digest TEXT NOT NULL, args TEXT NOT NULL, auth_epoch TEXT NOT NULL,
                invalidated INTEGER NOT NULL DEFAULT 0, external_started INTEGER NOT NULL DEFAULT 0,
                result TEXT, reply_slot TEXT NOT NULL, PRIMARY KEY(owner,run_id))''')
            if 'reply_slot' not in {r[1] for r in store.db.execute('PRAGMA table_info(research_runs)')}:
                raise Fault('unsupported_research_store')

    def grant(self, owner, args=None):
        g = self.grants.get(owner)
        if g is None: raise Fault('research_not_authorized')
        a = self.adapters.get(g.provider)
        if a is None or getattr(a,'formats',None) != self.formats or getattr(a,'token_hard_cap',False) is not True:
            raise Fault('unsupported_research_provider')
        if args is not None:
            if (args['provider'] != g.provider or args['model'] not in g.models or
                args['model_fingerprint'] != a.model_fingerprints.get(args['model']) or
                args['max_output_tokens'] > g.max_output_tokens):
                raise Fault('research_not_authorized')
        return g, a

    def replace_grant(self, owner, grant):
        """Host-only revocation linearizes with publication; no RPC enrollment."""
        with self.store.transaction():
            if grant is None:
                self.grants.pop(owner, None)
            else:
                self.grants[owner] = grant
            for run in self.store.db.execute('SELECT * FROM research_runs WHERE owner=?', (owner,)).fetchall():
                if json.loads(run['args'])['request_format'] != self.formats[0]: continue
                if self.invalid(run):
                    self.invalidate(run)

    def payload(self, owner, pid, *, usable=True):
        uid(pid)
        row = self.store.db.execute('SELECT * FROM research_payloads WHERE owner=? AND id=?', (owner, pid)).fetchone()
        if row is None: raise Fault('payload_not_found')
        if usable:
            if row['state'] == 'revoked': raise Fault('payload_revoked')
            if row['expires'] <= self.clock(): raise Fault('payload_expired')
        return row

    @staticmethod
    def projection(row):
        return {'payload_id': row['id'], 'sha256': row['hash'], 'byte_count': row['size']}

    def cleanup(self):
        # Keep bounded tombstones for stable expiry/idempotency; clear content.
        self.store.db.execute("UPDATE research_payloads SET data=x'' WHERE expires<=? OR state='revoked'", (self.clock(),))
        self.store.db.execute("DELETE FROM research_chunks WHERE payload IN (SELECT id FROM research_payloads WHERE expires<=? OR state='revoked')", (self.clock(),))

    def reserve(self, owner, size):
        self.cleanup()
        db = self.store.db
        total = db.execute('SELECT COUNT(*) FROM research_payloads').fetchone()[0]
        if total >= 4096: raise Fault('payload_budget_exceeded')
        active = db.execute("SELECT COUNT(*),COALESCE(SUM(size),0) FROM research_payloads WHERE owner=? AND expires>? AND state!='revoked'", (owner, self.clock())).fetchone()
        global_size = db.execute("SELECT COALESCE(SUM(size),0) FROM research_payloads WHERE expires>? AND state!='revoked'", (self.clock(),)).fetchone()[0]
        if active[0] >= 16 or active[1]+size > 8*1048576 or global_size+size > 16*1048576:
            raise Fault('payload_budget_exceeded')

    def object_bytes(self, owner, value, purpose, run_id, epoch):
        self.payload_ref(value, purpose)
        p = self.payload(owner, value['payload_id'])
        if (p['state'] != 'sealed' or p['purpose'] != purpose or p['run_id'] != run_id or
            p['epoch'] != epoch or self.projection(p) != value):
            raise Fault('payload_binding_mismatch')
        return bytes(p['data'])

    def payload_rpc(self, owner, method, p):
        with self.store.transaction():
            if method != 'payload.begin.v1':
                row = self.payload(owner, p.get('payload_id'), usable=False)
                if row['purpose'] not in self.limits: raise Fault('payload_binding_mismatch')
            if method == 'payload.begin.v1':
                exact(p, {'purpose', 'run_id', 'epoch', 'sha256', 'byte_count'})
                if type(p['purpose']) is not str or p['purpose'] not in {self.request_purpose, self.descriptor_purpose}: raise Fault('invalid_arguments')
                uid(p['run_id']); integer(p['epoch'], 0, 2147483647); digest(p['sha256'])
                integer(p['byte_count'], 1, self.limits[p['purpose']]); self.reserve(owner, p['byte_count'])
                pid = str(uuid.uuid4()); expires = self.clock()+900
                self.store.db.execute('INSERT INTO research_payloads VALUES(?,?,?,?,?,?,?,?,?,?,?)',
                    (pid, owner, p['purpose'], p['run_id'], p['epoch'], p['sha256'], p['byte_count'], b'', 'staging', 0, expires))
                return {'schema_version': 1, 'payload_id': pid, 'expires_at_ms': int(expires*1000), 'chunk_bytes': CHUNK}
            if method == 'payload.revoke.v1':
                exact(p, {'payload_id'}); row = self.payload(owner, p['payload_id'], usable=False)
                self.store.db.execute("UPDATE research_payloads SET state='revoked',data=x'' WHERE id=?", (row['id'],))
                self.store.db.execute('DELETE FROM research_chunks WHERE payload=?', (row['id'],))
                # Any bound object, including a reply, invalidates future publication/read.
                run = self.store.db.execute('SELECT * FROM research_runs WHERE owner=? AND run_id=?', (owner, row['run_id'])).fetchone()
                if run and run['epoch'] == row['epoch']: self.invalidate(run)
                return {'schema_version': 1, 'revoked': True, 'external_stop': 'unknown'}
            if method == 'payload.write.v1':
                exact(p, {'payload_id', 'index', 'data_base64', 'sha256'})
                integer(p['index'], 0, 63); digest(p['sha256']); text(p['data_base64'], 10924)
                try: data = base64.b64decode(p['data_base64'], validate=True)
                except ValueError: raise Fault('invalid_arguments') from None
                if not 1 <= len(data) <= CHUNK or base64.b64encode(data).decode() != p['data_base64'] or sha(data) != p['sha256']:
                    raise Fault('invalid_arguments')
                row = self.payload(owner, p['payload_id'])
                old = self.store.db.execute('SELECT hash,size FROM research_chunks WHERE payload=? AND idx=?', (row['id'], p['index'])).fetchone()
                if old:
                    if tuple(old) != (sha(data), len(data)): raise Fault('chunk_conflict')
                    return {'schema_version': 1, 'accepted_index': p['index']}
                if row['state'] != 'staging': raise Fault('payload_immutable')
                if p['index'] != row['next_index'] or len(row['data'])+len(data) > row['size']:
                    raise Fault('invalid_chunk_order')
                self.store.db.execute('INSERT INTO research_chunks VALUES(?,?,?,?)', (row['id'], p['index'], sha(data), len(data)))
                self.store.db.execute('UPDATE research_payloads SET data=?,next_index=next_index+1 WHERE id=?', (bytes(row['data'])+data, row['id']))
                return {'schema_version': 1, 'accepted_index': p['index']}
            if method == 'payload.seal.v1':
                exact(p, {'payload_id', 'sha256', 'byte_count'}); digest(p['sha256']); integer(p['byte_count'], 1, self.limits[self.response_purpose])
                row = self.payload(owner, p['payload_id'])
                if self.projection(row) != p or len(row['data']) != row['size'] or sha(row['data']) != row['hash']:
                    raise Fault('payload_hash_mismatch')
                self.store.db.execute("UPDATE research_payloads SET state='sealed' WHERE id=?", (row['id'],))
                return dict(schema_version=1, **self.projection(row))
            if method == 'payload.read.v1':
                exact(p, {'payload_id', 'offset', 'limit'}); integer(p['offset'], 0, self.limits[self.response_purpose]); integer(p['limit'], 1, READ_CHUNK)
                row = self.payload(owner, p['payload_id'])
                if row['state'] != 'sealed': raise Fault('payload_not_sealed')
                if row['purpose'] == self.response_purpose:
                    run = self.store.db.execute('SELECT * FROM research_runs WHERE owner=? AND run_id=?', (owner, row['run_id'])).fetchone()
                    if run is None or self.invalid(run): raise Fault('research_invalidated')
                if p['offset'] > row['size']: raise Fault('invalid_arguments')
                data = bytes(row['data'])[p['offset']:p['offset']+p['limit']]
                return dict(schema_version=1, **self.projection(row), offset=p['offset'],
                            data_base64=base64.b64encode(data).decode(), eof=p['offset']+len(data)==row['size'])
        raise Fault('unknown_method')

    def submit_args(self, p):
        from .priority import validate_request
        if 'scheduling' in p:validate_request(p['scheduling'])
        exact(p, {'schema_version', 'run_id', 'epoch', 'request', 'descriptor', 'provider', 'model',
                  'model_fingerprint', 'request_format', 'output_format', 'history_version',
                  'max_output_tokens', 'priority', 'deadline_ms'} | ({'scheduling'} if 'scheduling' in p else set()))
        integer(p['schema_version'], 1, 1); uid(p['run_id']); integer(p['epoch'], 0, 2147483647)
        self.payload_ref(p['request'], self.request_purpose); self.payload_ref(p['descriptor'], self.descriptor_purpose)
        for k in ('provider', 'model', 'model_fingerprint'): text(p[k])
        if tuple(p[k] for k in ('request_format', 'output_format', 'history_version')) != self.formats:
            raise Fault('unsupported_research_format')
        integer(p['max_output_tokens'], 1, 4096)
        # Priority/deadline are further constrained by server AppPolicy in Store.
        text(p['priority'], 20); integer(p['deadline_ms'], 1, 600000)

    def binding(self, owner, p):
        exact(p, {'job_id', 'run_id', 'request_sha256', 'epoch'})
        uid(p['job_id']); uid(p['run_id']); digest(p['request_sha256']); integer(p['epoch'], 0, 2147483647)
        r = self.store.db.execute('SELECT * FROM research_runs WHERE owner=? AND run_id=?', (owner, p['run_id'])).fetchone()
        if r is None: raise Fault('research_not_found')
        args = json.loads(r['args'])
        if tuple(args[k] for k in ('request_format', 'output_format', 'history_version')) != self.formats:
            raise Fault('research_receipt_mismatch')
        if r['job'] != p['job_id'] or r['epoch'] != p['epoch'] or args['request']['sha256'] != p['request_sha256']:
            raise Fault('research_receipt_mismatch')
        return r

    def invalid(self, run):
        if run['invalidated']: return True
        args = json.loads(run['args'])
        try:
            g, _ = self.grant(run['owner'], args)
            if g.auth_epoch != run['auth_epoch']: return True
            job = self.store.row(run['owner'], run['job'])
            if job['schedule_v1']:
                if self.store.priority_authority is None:return True
                self.store.priority_authority.check_plan(run['owner'],job['tool'],json.loads(job['schedule_v1']))
            # The 15-minute input TTL invalidates queued/in-flight work. After
            # atomic success, the immutable reply has its own 24-hour TTL.
            if job['state'] != 'succeeded':
                for key, purpose in (('request', self.request_purpose), ('descriptor', self.descriptor_purpose)):
                    self.object_bytes(run['owner'], args[key], purpose, run['run_id'], run['epoch'])
        except Fault:
            return True
        job = self.store.row(run['owner'], run['job'])
        return bool(job['cancel'] or (job['state'] in {'queued','running'} and job['deadline_at'] is not None and job['deadline_at'] <= self.clock()))

    def invalidate(self, run):
        self.store.db.execute('UPDATE research_runs SET invalidated=1,result=NULL WHERE job=?', (run['job'],))
        self.store.db.execute('UPDATE jobs SET cancel=1 WHERE id=?', (run['job'],))
        state = 'needs_review' if run['external_started'] else 'cancelled'
        self.store.set_state(run['job'], state, error='research_invalidated')
        args = json.loads(run['args'])
        self.store.db.execute("UPDATE research_payloads SET state='revoked',data=x'' WHERE owner=? AND run_id=? AND epoch=? AND purpose=?",
                              (run['owner'], args['run_id'], args['epoch'], self.response_purpose))
        self.store.audit(run['owner'], run['job'], 'research_invalidated')

    def receipt(self, run):
        args = json.loads(run['args']); job = self.store.row(run['owner'], run['job'])
        invalid = self.invalid(run)
        result = json.loads(run['result']) if run['result'] and not invalid and job['state']=='succeeded' else None
        state = ('needs_review' if run['external_started'] else 'cancelled') if invalid else job['state']
        receipt = {'schema_version': 1, 'job_id': run['job'], 'owner': run['owner'], 'run_id': run['run_id'],
            'request_sha256': args['request']['sha256'], 'epoch': run['epoch'], 'auth_epoch': run['auth_epoch'],
            'state': state, 'provider': args['provider'], 'model': args['model'],
            'model_fingerprint': args['model_fingerprint'], 'request_format': args['request_format'],
            'output_format': args['output_format'], 'history_version': args['history_version'],
            'result_ref': result, 'error_code': 'research_invalidated' if invalid else job['error'],
            'cancel_requested': bool(job['cancel'] or run['invalidated']),
            'external_stop': 'unknown' if run['external_started'] else 'not_started'}
        if 'scheduling' in args:receipt['scheduling']=self.store.project(job)['scheduling']
        return receipt

    def dispatch(self, owner, method, p, policy, *, submit_method=None, in_transaction=False):
        self.grant(owner)
        if method.startswith('payload.'): return self.payload_rpc(owner, method, p)
        if in_transaction and not self.store.db.in_transaction:
            raise Fault('research_transaction_missing')
        with (nullcontext() if in_transaction else self.store.transaction()):
            if method == 'research.capabilities.v1':
                exact(p, set()); return self.capability_result(owner)
            if method == 'research.submit.v1':
                self.submit_args(p); g, _ = self.grant(owner, p)
                from .priority import RouteContext
                route=RouteContext(submit_method or method,p['provider'],p['model'],p['model_fingerprint'])
                normalized = dict(p, request={k:v for k,v in p['request'].items() if k!='payload_id'},
                                    descriptor={k:v for k,v in p['descriptor'].items() if k!='payload_id'})
                key = sha(encode(normalized))
                old = self.store.db.execute('SELECT * FROM research_runs WHERE owner=? AND run_id=?', (owner, p['run_id'])).fetchone()
                if old:
                    if old['digest'] != key: raise Fault('idempotency_conflict')
                    self.store.submit(owner,p['run_id'],self.tool,{'run_id':p['run_id']},policy,
                        verified=True,schedule={'priority':p['priority'],'deadline_ms':p['deadline_ms']},
                        in_transaction=True,priority_request=p.get('scheduling'),priority_route=route)
                    return self.receipt(old)  # Same run after blob expiry, never new inference.
                raw = self.object_bytes(owner, p['request'], self.request_purpose, p['run_id'], p['epoch'])
                meta = self.object_bytes(owner, p['descriptor'], self.descriptor_purpose, p['run_id'], p['epoch'])
                d = self.validate_descriptor(meta, p); self.validate_request(raw, p); self.validate_pair(raw, meta, p)
                # Reserve maximum reply storage before admission/call budget.
                # Paid inference must not start only to discover storage is full.
                self.reserve(owner, d['maximumResponseBytes'])
                slot = str(uuid.uuid4())
                self.store.db.execute('INSERT INTO research_payloads VALUES(?,?,?,?,?,?,?,?,?,?,?)',
                    (slot, owner, self.response_purpose, p['run_id'], p['epoch'], '0'*64,
                     d['maximumResponseBytes'], b'', 'reserved', 0, self.clock()+900))
                count = self.store.db.execute('SELECT COUNT(*) FROM research_runs WHERE owner=?', (owner,)).fetchone()[0]
                if count >= 256: raise Fault('research_budget_exceeded')
                if self.name not in policy.tools: raise Fault('tool_not_authorized')
                job = self.store.submit(owner, p['run_id'], self.tool, {'run_id':p['run_id']}, policy,
                    verified=True, schedule={'priority':p['priority'], 'deadline_ms':p['deadline_ms']}, in_transaction=True,
                    priority_request=p.get('scheduling'),priority_route=route)
                self.store.db.execute('INSERT INTO research_runs(owner,run_id,job,epoch,digest,args,auth_epoch,reply_slot) VALUES(?,?,?,?,?,?,?,?)',
                    (owner, p['run_id'], job['id'], p['epoch'], key, encode(p).decode(), g.auth_epoch, slot))
                return self.receipt(self.store.db.execute('SELECT * FROM research_runs WHERE job=?', (job['id'],)).fetchone())
            if method in {'research.status.v1', 'research.cancel.v1'}:
                run = self.binding(owner, p)
                if method == 'research.cancel.v1' or self.invalid(run): self.invalidate(run)
                run = self.store.db.execute('SELECT * FROM research_runs WHERE job=?', (run['job'],)).fetchone()
                return self.receipt(run)
        raise Fault('unknown_method')

    def execute(self, args, context):
        with self.store.transaction():
            r = self.store.db.execute('SELECT * FROM research_runs WHERE owner=? AND run_id=? AND job=?',
                (context.owner, args['run_id'], context.row['id'])).fetchone()
            if r is None or self.invalid(r): raise Fault('research_invalidated')
            p = json.loads(r['args']); _, adapter = self.grant(context.owner, p)
            raw = self.object_bytes(context.owner, p['request'], self.request_purpose, r['run_id'], r['epoch'])
            context.check_cancelled()
            self.external_admission(r)
            self.store.db.execute('UPDATE research_runs SET external_started=1 WHERE job=?', (r['job'],))
            provider_context = self.provider_context(context, r)
        # External call outside transaction. Adapter receives exact original bytes.
        reply = adapter.complete(raw, p, provider_context)
        if type(reply) is not bytes: raise Fault('invalid_provider_response')
        return reply

    def complete(self, row, raw=None, error=None):
        """Publication CAS and job completion share one durable transaction."""
        with self.store.transaction():
            r = self.store.db.execute('SELECT * FROM research_runs WHERE job=? AND owner=?', (row['id'], row['owner'])).fetchone()
            if r is None:
                self.store.set_state(row['id'], 'needs_review', error='research_binding_missing'); return
            if self.invalid(r):
                self.invalidate(r); return
            args = json.loads(r['args'])
            if error is None:
                try:
                    d = self.validate_descriptor(self.object_bytes(r['owner'], args['descriptor'], self.descriptor_purpose, r['run_id'], r['epoch']), args)
                    if not 1 <= len(raw) <= d['maximumResponseBytes']: raise Fault('result_too_large')
                    self.validate_response(raw, args, r)
                    slot = self.payload(r['owner'], r['reply_slot'])
                    if slot['state'] != 'reserved' or slot['size'] < len(raw):
                        raise Fault('payload_budget_exceeded')
                    pid = r['reply_slot']; value = {'payload_id':pid, 'sha256':sha(raw), 'byte_count':len(raw)}
                    self.store.db.execute("UPDATE research_payloads SET hash=?,size=?,data=?,state='sealed',expires=? WHERE id=?",
                        (sha(raw), len(raw), raw, self.clock()+86400, pid))
                    self.store.db.execute('UPDATE research_runs SET result=? WHERE job=?', (encode(value).decode(), r['job']))
                    self.store.set_state(row['id'], 'succeeded', value)
                    self.store.audit(r['owner'], r['job'], 'succeeded')
                    return
                except Fault as exc:
                    error = exc.code
            state = 'needs_review' if r['external_started'] else 'failed'
            # Only finite internal codes. Provider exceptions never enter payload/logs.
            allowed = {'result_too_large','invalid_provider_response','invalid_payload','invalid_arguments',
                       'payload_budget_exceeded','descriptor_mismatch','provider_unavailable','deadline_exceeded',
                       'cancelled','research_invalidated','tool_contract_changed','tool_not_authorized',
                       'app_identity_unverified'}
            self.store.set_state(row['id'], state, error=error if error in allowed else 'research_provider_error')
            self.store.db.execute("UPDATE research_payloads SET state='revoked',data=x'' WHERE id=? AND state='reserved'", (r['reply_slot'],))
            self.store.audit(r['owner'], r['job'], state)
