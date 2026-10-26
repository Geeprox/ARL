"""Source-only Codex native research SDK. Importing it authorizes no inference.

Recovery records contain immutable acceptance metadata, never selected evidence
text. Their expected SHA256 must come from the consumer's trusted local store.
"""
from __future__ import annotations

import base64
import copy

from . import codex_contract as contract
from .contracts import Fault, encode
from .research import (CHUNK, READ_CHUNK, REQUEST as RESEARCH_REQUEST,
                       DESCRIPTOR as RESEARCH_DESCRIPTOR, digest, exact,
                       integer, sha, strict_json, text, uid)
from .research_client import PayloadCleanupPending, ResearchClient

NAME = contract.NAME
REQUEST, DESCRIPTOR, RESPONSE = contract.REQUEST, contract.DESCRIPTOR, contract.RESPONSE
FORMATS, LIMITS = contract.FORMATS, contract.LIMITS
RECORD_LIMIT = 8192
PARAM_KEYS = frozenset({'schema_version', 'run_id', 'epoch', 'request', 'descriptor',
    'provider', 'model', 'model_fingerprint', 'request_format', 'output_format',
    'history_version', 'max_output_tokens', 'max_output_bytes', 'priority', 'deadline_ms'})
RECEIPT_KEYS = frozenset({'schema_version', 'job_id', 'owner', 'run_id',
    'request_sha256', 'epoch', 'auth_epoch', 'state', 'provider', 'model',
    'model_fingerprint', 'request_format', 'output_format', 'history_version',
    'result_ref', 'error_code', 'cancel_requested', 'external_stop', 'native'})
STATES = frozenset({'queued', 'running', 'succeeded', 'failed', 'cancelled',
                   'needs_unlock', 'needs_review'})
TERMINAL = frozenset({'completed', 'interrupted', 'failed'})
INTERRUPT_NEXT = {'not_requested': contract.INTERRUPT_STATES,
    'sent': frozenset({'sent', 'unknown', 'acknowledged', 'rejected'}),
    'unknown': frozenset({'unknown', 'acknowledged', 'rejected'}),
    'acknowledged': frozenset({'acknowledged'}), 'rejected': frozenset({'rejected'})}


def _identifier(value, maximum=200):
    text(value, maximum)
    value.encode('utf-8', errors='strict')


def _same(actual, expected):
    # A boolean is not an integer pin, even though Python compares them equal.
    return encode(actual) == encode(expected)


def _ref(value, purpose, limits=LIMITS):
    exact(value, {'payload_id', 'sha256', 'byte_count'})
    uid(value['payload_id']); digest(value['sha256'])
    integer(value['byte_count'], 1, limits[purpose])


def _params(args, contract=contract):
    from .priority import validate_request
    if 'scheduling' in args:validate_request(args['scheduling'])
    exact(args, PARAM_KEYS | ({'scheduling'} if 'scheduling' in args else set()))
    integer(args['schema_version'], 1, 1); uid(args['run_id'])
    integer(args['epoch'], 0, 2147483647)
    _ref(args['request'], contract.REQUEST, contract.LIMITS)
    _ref(args['descriptor'], contract.DESCRIPTOR, contract.LIMITS)
    if args['request']['payload_id'] == args['descriptor']['payload_id']:
        raise Fault('invalid_arguments')
    if args['provider'] != contract.PROVIDER or args['max_output_tokens'] is not None:
        raise Fault('invalid_arguments')
    _identifier(args['model'], 150); digest(args['model_fingerprint'])
    if tuple(args[key] for key in ('request_format', 'output_format', 'history_version')) != contract.FORMATS:
        raise Fault('invalid_arguments')
    integer(args['max_output_bytes'], 128, contract.MAX_TEXT_BYTES)
    if type(args['priority']) is not str or args['priority'] not in {'explicit', 'background', 'interactive'}:
        raise Fault('invalid_arguments')
    integer(args['deadline_ms'], 1, 30000)


def _reviewed(value):
    if type(value) is not list or len(value) > 100:
        raise Fault('invalid_arguments')
    seen = set()
    for item in value:
        exact(item, contract.EVIDENCE_KEYS)
        uid(item['evidence_id']); uid(item['record_id']); digest(item['snapshot_digest'])
        integer(item['revision'], 0, 2147483647)
        if item['unit'] is not None:
            if type(item['unit']) is not str or len(item['unit'].encode('utf-8')) > 200:
                raise Fault('invalid_arguments')
        if item['evidence_id'] in seen:
            raise Fault('invalid_arguments')
        seen.add(item['evidence_id'])


class _NativeTransport:
    """Reuse generic payload upload/cleanup with a separate native wire scope."""
    def __init__(self, client, contract=contract):
        self.client, self.app = client, client.app
        self.request_purpose, self.descriptor_purpose = contract.REQUEST, contract.DESCRIPTOR

    def rpc(self, method, params=None):
        params = copy.deepcopy(params)
        if method == 'payload.begin.v1':
            params['purpose'] = {RESEARCH_REQUEST: self.request_purpose,
                                 RESEARCH_DESCRIPTOR: self.descriptor_purpose}[params['purpose']]
        return self.client.rpc('codex.' + method, params)


class CodexResearchClient(ResearchClient):
    """Typed native client over a supplied app-bound ``rpc(method, params)``.

    Construction and restore perform no RPC. Submit has no automatic retry;
    ambiguous acceptance revokes every known input handle before returning.
    """
    name = NAME
    contract = contract
    renderer_version = 'tisra.codex.raw-json.v1'
    structured_generated_citations = False
    expected_contract_sha256 = None

    def __init__(self, client):
        super().__init__(_NativeTransport(client, self.contract))
        self._submissions = {}
        self._run_pins = {}

    def _upload(self, raw, purpose, run_id, epoch, created, cancelled, on_payload_created):
        request_purpose, descriptor_purpose = self.contract.REQUEST, self.contract.DESCRIPTOR
        if type(raw) is not bytes or purpose not in {request_purpose, descriptor_purpose}:
            raise Fault('invalid_arguments')
        if purpose == request_purpose and len(raw) > self.contract.LIMITS[request_purpose]:
            raise Fault('codex_input_too_large')
        integer(len(raw), 1, self.contract.LIMITS[purpose])
        def observed(record):
            if on_payload_created is not None:
                on_payload_created(dict(record, purpose=purpose))
        legacy = {request_purpose: RESEARCH_REQUEST, descriptor_purpose: RESEARCH_DESCRIPTOR}[purpose]
        return super()._upload(raw, legacy, run_id, epoch, created, cancelled, observed)

    def capabilities(self):
        value = self.client.rpc('research.capabilities.v1', {})
        contract = self.contract
        expected = {'schema_version': 1, 'tool': self.name,
            'formats': dict(zip(('request', 'output', 'history'), contract.FORMATS)),
            'renderer_version': self.renderer_version, 'provider': contract.PROVIDER,
            'model_evidence_basis': 'pinned_adapter_binary_protocol_controls_confirmed_identifier',
            'backend_weights_revision': None, 'max_request_bytes': contract.LIMITS[contract.REQUEST],
            'max_descriptor_bytes': contract.LIMITS[contract.DESCRIPTOR],
            'max_response_bytes': contract.LIMITS[contract.RESPONSE],
            'max_output_bytes': contract.MAX_TEXT_BYTES, 'max_output_tokens': None,
            'token_hard_cap_supported': False, 'cost_hard_cap_supported': False,
            'max_deadline_ms': 30000, 'max_provider_turns': 1, 'automatic_retries': 0,
            'structured_generated_citations': self.structured_generated_citations,
            'request_frame_bytes': 16384,
            'response_frame_bytes': 65536}
        try:
            exact(value, set(expected) | {'contract_sha256', 'provider_evidence', 'models'})
            if any(not _same(value[key], item) for key, item in expected.items()):
                raise Fault('invalid_arguments')
            digest(value['contract_sha256'])
            if self.expected_contract_sha256 is not None and value['contract_sha256'] != self.expected_contract_sha256:
                raise Fault('invalid_arguments')
            if value['provider_evidence'] not in {'test_double', 'implementation_only'}:
                raise Fault('invalid_arguments')
            if type(value['models']) is not dict or len(value['models']) > 100:
                raise Fault('invalid_arguments')
            for model, fingerprint in value['models'].items():
                _identifier(model, 150); digest(fingerprint)
            if len(encode(value)) > 65536:
                raise Fault('invalid_arguments')
        except (Fault, TypeError, ValueError, UnicodeError, RecursionError):
            raise Fault('invalid_response') from None
        return value

    def submit(self, raw, descriptor, *, epoch, provider, model_fingerprint,
               priority='explicit', deadline_ms=30000, cancelled=lambda: False,
               on_payload_created=None, scheduling=None):
        # Validate both complete objects and every argument before any upload.
        contract = self.contract
        request = contract.request_body(raw)
        try:
            descriptor_raw = encode(descriptor)
            run_id = descriptor['executionID']
            # Distinct canonical placeholders permit full local argument checks.
            args = {'schema_version': 1, 'run_id': run_id, 'epoch': epoch,
                'request': {'payload_id': '00000000-0000-0000-0000-000000000001',
                            'sha256': sha(raw), 'byte_count': len(raw)},
                'descriptor': {'payload_id': '00000000-0000-0000-0000-000000000002',
                               'sha256': sha(descriptor_raw), 'byte_count': len(descriptor_raw)},
                'provider': provider, 'model': descriptor['model'],
                'model_fingerprint': model_fingerprint, 'request_format': contract.FORMATS[0],
                'output_format': contract.FORMATS[1], 'history_version': contract.FORMATS[2],
                'max_output_tokens': None, 'max_output_bytes': descriptor['maximumTextBytes'],
                'priority': priority, 'deadline_ms': deadline_ms}
            if scheduling is not None:args['scheduling']=dict(scheduling)
            _params(args, contract)
        except (KeyError, TypeError, ValueError, UnicodeError, RecursionError):
            raise Fault('invalid_arguments') from None
        metadata = contract.descriptor(descriptor_raw, args)
        reviewed = contract.reviewed_bindings(request)
        if metadata['evidence'] != self._descriptor_evidence(request, reviewed):
            raise Fault('descriptor_mismatch')
        created = []
        try:
            args['request'] = self._upload(raw, contract.REQUEST, run_id, epoch, created, cancelled, on_payload_created)
            args['descriptor'] = self._upload(descriptor_raw, contract.DESCRIPTOR, run_id, epoch, created, cancelled, on_payload_created)
            self._cancelled(cancelled)
            receipt = self.client.rpc('research.submit.v1', args)
            self._cancelled(cancelled)
            self.check(receipt, args)
            with self._pin_lock:
                record = self._submissions[self._key(receipt)]
                if record['reviewed'] is not None and not _same(record['reviewed'], reviewed):
                    raise Fault('research_receipt_mismatch')
                record['reviewed'] = copy.deepcopy(reviewed)
                self._remember_source(record, raw)
            return receipt, args
        except BaseException:
            self.cleanup_payloads(created)
            raise

    def _descriptor_evidence(self, request, reviewed):
        return [{'evidenceID': item['evidence_id'], 'snapshotDigest': item['snapshot_digest']}
                for item in reviewed]

    def _remember_source(self, record, raw):
        pass

    def _reviewed_metadata(self, value):
        _reviewed(value)

    def _response_options(self, receipt, args, source_request):
        return {}

    @staticmethod
    def _key(receipt):
        return tuple(receipt[key] for key in ('owner', 'job_id', 'run_id', 'request_sha256', 'epoch'))

    def _validate(self, receipt, args, job_id=None):
        contract = self.contract
        try:
            _params(args, contract)
            exact(receipt, RECEIPT_KEYS | ({'scheduling'} if 'scheduling' in args else set()))
            if 'scheduling' in args:
                from .priority import validate_acceptance
                validate_acceptance(args['scheduling'],receipt['scheduling'])
            expected = {'schema_version': 1, 'owner': self.client.app, 'run_id': args['run_id'],
                'epoch': args['epoch'], 'request_sha256': args['request']['sha256'],
                **{key: args[key] for key in ('provider', 'model', 'model_fingerprint',
                    'request_format', 'output_format', 'history_version')}}
            if any(not _same(receipt[key], item) for key, item in expected.items()):
                raise Fault('invalid_arguments')
            if job_id is not None and receipt['job_id'] != job_id:
                raise Fault('invalid_arguments')
            uid(receipt['job_id']); uid(receipt['run_id']); digest(receipt['request_sha256'])
            _identifier(receipt['owner']); _identifier(receipt['auth_epoch'])
            integer(receipt['schema_version'], 1, 1); integer(receipt['epoch'], 0, 2147483647)
            if (receipt['state'] not in STATES or receipt['external_stop'] not in contract.NATIVE_TERMINALS
                    or type(receipt['cancel_requested']) is not bool):
                raise Fault('invalid_arguments')
            if receipt['error_code'] is not None:
                _identifier(receipt['error_code'], 100)
            native = contract.native_body(receipt['native'], successful=receipt['state'] == 'succeeded')
            if receipt['external_stop'] != native['terminal']:
                raise Fault('invalid_arguments')
            if native['turn_id'] is not None and native['thread_id'] is None:
                raise Fault('invalid_arguments')
            if receipt['result_ref'] is not None:
                _ref(receipt['result_ref'], contract.RESPONSE, contract.LIMITS)
            success = receipt['state'] == 'succeeded'
            if success != (receipt['result_ref'] is not None):
                raise Fault('invalid_arguments')
            if success and (receipt['cancel_requested'] or receipt['error_code'] is not None
                            or receipt['external_stop'] != 'completed'):
                raise Fault('invalid_arguments')
            if receipt['state'] in {'queued', 'running'} and (receipt['cancel_requested'] or receipt['error_code'] is not None):
                raise Fault('invalid_arguments')
            if receipt['state'] == 'queued' and (receipt['external_stop'] != 'not_started'
                    or native != {'thread_id': None, 'turn_id': None, 'terminal': 'not_started', 'interrupt': 'not_requested'}):
                raise Fault('invalid_arguments')
        except (Fault, KeyError, TypeError, ValueError, UnicodeError, RecursionError):
            raise Fault('research_receipt_mismatch') from None

    def _pin(self, receipt, args):
        """Validate/update under the inherited pin lock; never replace first pins."""
        key = self._key(receipt)
        run_key = (receipt['owner'], receipt['run_id'], receipt['epoch'])
        record = self._submissions.get(key)
        if self._run_pins.get(run_key, key) != key:
            raise Fault('research_receipt_mismatch')
        if self._auth_pins.get(key, receipt['auth_epoch']) != receipt['auth_epoch']:
            raise Fault('research_receipt_mismatch')
        if record is not None:
            if not _same(record['params'], args):
                raise Fault('research_receipt_mismatch')
            old = record['latest']
            if 'scheduling' in args and not _same(old['scheduling'],receipt['scheduling']):
                raise Fault('research_receipt_mismatch')
            for field in contract.BINDING_KEYS:
                if not _same(old[field], receipt[field]):
                    raise Fault('research_receipt_mismatch')
            for field in ('thread_id', 'turn_id'):
                if old['native'][field] is not None and old['native'][field] != receipt['native'][field]:
                    raise Fault('research_receipt_mismatch')
            terminal = old['native']['terminal']
            if ((terminal in TERMINAL and terminal != receipt['native']['terminal']) or
                    (terminal == 'unknown' and receipt['native']['terminal'] == 'not_started') or
                    receipt['native']['interrupt'] not in INTERRUPT_NEXT[old['native']['interrupt']]):
                raise Fault('research_receipt_mismatch')
            if old['cancel_requested'] and not receipt['cancel_requested']:
                raise Fault('research_receipt_mismatch')
            if record['gate_closed'] and receipt['state'] in {'queued', 'running', 'succeeded'}:
                raise Fault('research_receipt_mismatch')
            if old['state'] in {'succeeded', 'failed', 'cancelled'}:
                allowed = {old['state'], 'cancelled'}
                # Native completion survives local revoke/grant/cancel invalidation.
                # The cancellation evidence below closes the publication gate.
                if receipt['cancel_requested']:
                    allowed.add('needs_review')
                if receipt['state'] not in allowed:
                    raise Fault('research_receipt_mismatch')
            if old['result_ref'] is not None and receipt['result_ref'] is not None and not _same(old['result_ref'], receipt['result_ref']):
                raise Fault('research_receipt_mismatch')
        else:
            record = {'receipt': copy.deepcopy(receipt), 'params': copy.deepcopy(args),
                      'reviewed': None, 'gate_closed': False}
        # Only valid, mutually consistent data may establish any pin.
        record['latest'] = copy.deepcopy(receipt)
        record['gate_closed'] |= receipt['cancel_requested'] or receipt['state'] == 'cancelled'
        self._submissions[key] = record
        self._run_pins[run_key] = key
        self._auth_pins[key] = receipt['auth_epoch']
        return receipt

    def check(self, receipt, args, job_id=None):
        self._validate(receipt, args, job_id)
        with self._pin_lock:
            return self._pin(receipt, args)

    def _baseline(self, receipt, args):
        self._validate(receipt, args)
        with self._pin_lock:
            record = self._submissions.get(self._key(receipt))
            if record is None:
                self._pin(receipt, args)
                record = self._submissions[self._key(receipt)]
            # The immutable original receipt remains usable as a status handle.
            if (not _same(record['params'], args) or
                    not any(_same(receipt, record[field]) for field in ('receipt', 'latest'))):
                raise Fault('research_receipt_mismatch')
        return record

    def status(self, receipt, args):
        self._baseline(receipt, args)
        return self.check(self.client.rpc('research.status.v1', self.binding(receipt)), args, receipt['job_id'])

    def cancel(self, receipt, args):
        self._baseline(receipt, args)
        # Close the local publication gate even if the cancel acknowledgement is lost.
        with self._pin_lock:
            self._submissions[self._key(receipt)]['gate_closed'] = True
        return self.check(self.client.rpc('research.cancel.v1', self.binding(receipt)), args, receipt['job_id'])

    def read_response(self, receipt, args, *, source_request=None):
        options = self._response_options(receipt, args, source_request)
        current = self.status(receipt, args)
        if current['state'] != 'succeeded' or current['cancel_requested'] or not current['result_ref']:
            raise Fault('research_not_completed')
        with self._pin_lock:
            reviewed = copy.deepcopy(self._submissions[self._key(receipt)]['reviewed'])
        if reviewed is None:
            raise Fault('research_restore_mismatch')
        value = current['result_ref']; _ref(value, self.contract.RESPONSE, self.contract.LIMITS)
        output = bytearray()
        while len(output) < value['byte_count']:
            offset = len(output)
            chunk = self.client.rpc('payload.read.v1', {'payload_id': value['payload_id'],
                                    'offset': offset, 'limit': READ_CHUNK})
            try:
                exact(chunk, {'schema_version', 'payload_id', 'sha256', 'byte_count',
                              'offset', 'data_base64', 'eof'})
                integer(chunk['schema_version'], 1, 1)
                integer(chunk['offset'], offset, offset)
                if any(not _same(chunk[key], item) for key, item in value.items()):
                    raise Fault('payload_binding_mismatch')
                if type(chunk['data_base64']) is not str or type(chunk['eof']) is not bool:
                    raise Fault('invalid_response')
                raw = base64.b64decode(chunk['data_base64'], validate=True)
                if (not 1 <= len(raw) <= READ_CHUNK or offset + len(raw) > value['byte_count']
                        or base64.b64encode(raw).decode() != chunk['data_base64']
                        or chunk['eof'] != (offset + len(raw) == value['byte_count'])):
                    raise Fault('invalid_response')
            except (KeyError, TypeError, ValueError, UnicodeError):
                raise Fault('invalid_response') from None
            output.extend(raw)
        if sha(output) != value['sha256']:
            raise Fault('payload_hash_mismatch')
        raw = bytes(output)
        self.contract.result_body(raw, args, binding=current, native=current['native'],
                                  reviewed_evidence=reviewed, **options)
        final = self.status(receipt, args)
        if (final['state'] != 'succeeded' or final['cancel_requested']
                or not _same(final['result_ref'], value)):
            raise Fault('research_invalidated')
        return raw

    def durable_record(self, receipt, args):
        self._validate(receipt, args)
        with self._pin_lock:
            record = self._submissions.get(self._key(receipt))
            if (record is None or record['reviewed'] is None or
                    not _same(record['receipt'], receipt) or not _same(record['params'], args)):
                raise Fault('research_restore_mismatch')
            value = {'schema_version': 1, 'receipt': copy.deepcopy(record['receipt']),
                     'params': copy.deepcopy(record['params']),
                     'reviewed_evidence_bindings': copy.deepcopy(record['reviewed'])}
        raw = encode(value)
        if not 1 <= len(raw) <= RECORD_LIMIT:
            raise Fault('research_restore_mismatch')
        return raw

    def restore_submission(self, raw, expected_sha256):
        try:
            digest(expected_sha256)
            if type(raw) is not bytes or not 1 <= len(raw) <= RECORD_LIMIT or sha(raw) != expected_sha256:
                raise Fault('invalid_arguments')
            value = strict_json(raw)
            if encode(value) != raw:
                raise Fault('invalid_arguments')
            exact(value, {'schema_version', 'receipt', 'params', 'reviewed_evidence_bindings'})
            integer(value['schema_version'], 1, 1)
            _params(value['params'], self.contract)
            self._reviewed_metadata(value['reviewed_evidence_bindings'])
        except (Fault, KeyError, TypeError, ValueError, UnicodeError, RecursionError):
            raise Fault('research_restore_mismatch') from None
        receipt, args = value['receipt'], value['params']
        self._validate(receipt, args)
        with self._pin_lock:
            existing = self._submissions.get(self._key(receipt))
            if existing is not None:
                if (not _same(existing['receipt'], receipt) or not _same(existing['params'], args)
                        or (existing['reviewed'] is not None and
                            not _same(existing['reviewed'], value['reviewed_evidence_bindings']))):
                    raise Fault('research_receipt_mismatch')
                # Repeated restore must not erase newer native evidence or a closed gate.
            else:
                self._pin(receipt, args)
                existing = self._submissions[self._key(receipt)]
            existing['reviewed'] = copy.deepcopy(value['reviewed_evidence_bindings'])
        return copy.deepcopy(receipt), copy.deepcopy(args)


class CodexSourcedResearchClient(CodexResearchClient):
    """Native v2 SDK with exact source-backed citation validation.

    The selected source request stays in memory after submit. Recovery exports
    contain metadata only, so a fresh client must receive the same original
    request bytes through ``read_response(..., source_request=raw)``. Missing or
    mismatched source data rejects locally before status/read RPCs.
    """
    name = 'tisra.codex.research.v2'
    renderer_version = 'tisra.codex.raw-json.v2'
    structured_generated_citations = True

    def __init__(self, client, *, sourced_contract_sha256=None):
        # Keep v1 imports and construction independent from the v2 extension.
        from . import codex_sourced_contract as sourced
        if sourced_contract_sha256 is not None:
            digest(sourced_contract_sha256)
            if sourced_contract_sha256 != sourced.CONTRACT_SHA256:
                raise Fault('invalid_arguments')
        self.contract = sourced
        self.expected_contract_sha256 = sourced.CONTRACT_SHA256
        super().__init__(client)

    def _descriptor_evidence(self, request, reviewed):
        return self.contract.snapshot_bindings(request)

    def _remember_source(self, record, raw):
        record['source_request'] = raw

    def _reviewed_metadata(self, value):
        self.contract.reviewed_body(value)

    def _response_options(self, receipt, args, source_request):
        self._validate(receipt, args)
        with self._pin_lock:
            record = self._submissions.get(self._key(receipt))
            cached = record.get('source_request') if record is not None else None
            reviewed = copy.deepcopy(record['reviewed']) if record is not None else None
        raw = cached if source_request is None else source_request
        if raw is None:
            raise Fault('codex_source_unavailable')
        request = self.contract.request_body(raw, args)
        if reviewed is None:
            raise Fault('research_restore_mismatch')
        if not _same(self.contract.reviewed_bindings(request), reviewed):
            raise Fault('research_restore_mismatch')
        self._baseline(receipt, args)
        return {'request': request}
