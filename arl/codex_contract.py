"""Pure validators for the frozen, opt-in Codex native research contract.

Validation never renders or reserializes the request. Its caller retains and
passes the complete original UTF-8 bytes to the provider and payload store.
Importing this module installs no provider, grant, tool or capability.
"""
from __future__ import annotations

from .contracts import Fault, encode
from .research import digest, exact, integer, sha, strict_json, text, uid

NAME = 'tisra.codex.research.v1'
REQUEST = 'tisra.codex.request.v1'
DESCRIPTOR = 'tisra.codex.descriptor.v1'
RESPONSE = 'tisra.codex.result.v1'
FORMATS = (REQUEST, RESPONSE, 'tisra.codex.history.v1')
LIMITS = {REQUEST: 8192, DESCRIPTOR: 32768, RESPONSE: 262144}
MAX_TEXT_BYTES = 32768
PROVIDER = 'codex_app_server'
PROTOCOL_VERSION = '0.159.0'
BINDING_KEYS = ('owner', 'job_id', 'run_id', 'request_sha256', 'epoch',
                'auth_epoch', 'provider', 'model', 'model_fingerprint',
                'request_format', 'output_format', 'history_version')
EVIDENCE_KEYS = ('evidence_id', 'snapshot_digest', 'record_id', 'revision', 'unit')
NATIVE_TERMINALS = frozenset({'not_started', 'unknown', 'completed', 'interrupted', 'failed'})
INTERRUPT_STATES = frozenset({'not_requested', 'sent', 'acknowledged', 'rejected', 'unknown'})
FINGERPRINT_KEYS = ('adapter_binary_sha256', 'protocol_version',
                    'control_contract_sha256', 'confirmed_identifier')


def _same(actual, expected):
    """JSON pin equality must not conflate true, 1 and 1.0."""
    if type(actual) is not type(expected):
        return False
    if type(actual) is dict:
        return (set(actual) == set(expected) and
                all(_same(actual[key], expected[key]) for key in actual))
    if type(actual) is list:
        return len(actual) == len(expected) and all(_same(a, b) for a, b in zip(actual, expected))
    return actual == expected


def model_fingerprint(evidence):
    """Fingerprint adapter/protocol/controls/model pins, never backend weights."""
    return sha(encode({key: evidence[key] for key in FINGERPRINT_KEYS}))


def _utf8(value, maximum, minimum=0):
    if type(value) is not str:
        raise Fault('invalid_arguments')
    try:
        size = len(value.encode('utf-8', errors='strict'))
    except UnicodeError:
        raise Fault('invalid_arguments') from None
    if not minimum <= size <= maximum:
        raise Fault('invalid_arguments')


def _identifier(value, maximum=200):
    # Existing research descriptor/receipt identifiers have character bounds
    # and exclude control characters. UTF-8 validity is checked separately.
    text(value, maximum)
    value.encode('utf-8', errors='strict')


def _utf8_tree(value):
    # json.loads admits escaped unpaired surrogates, even in object keys.
    if type(value) is str:
        value.encode('utf-8', errors='strict')
    elif type(value) is list:
        for item in value:
            _utf8_tree(item)
    elif type(value) is dict:
        for key, item in value.items():
            _utf8_tree(key)
            _utf8_tree(item)


def _parse(raw, maximum, code, too_large=None):
    if type(raw) is not bytes or not raw:
        raise Fault(code)
    # The complete serialized object, including whitespace and JSON escapes,
    # must fit before parsing or any external work can be admitted.
    if len(raw) > maximum:
        raise Fault(too_large or code)
    try:
        obj = strict_json(raw)
        _utf8_tree(obj)
        return obj
    except (Fault, UnicodeError, RecursionError):
        raise Fault(code) from None


def _evidence_binding(obj):
    uid(obj['evidence_id'])
    digest(obj['snapshot_digest'])
    uid(obj['record_id'])
    integer(obj['revision'], 0, 2147483647)
    if obj['unit'] is not None:
        _utf8(obj['unit'], 200)


def reviewed_bindings(request):
    """Project validated request snapshots in their original order.

    These input bindings do not assert that the generated text has citations or
    independently verify the corresponding source Ledger contents.
    """
    return [{key: item[key] for key in EVIDENCE_KEYS} for item in request['evidence']]


def native_body(value, *, successful=False):
    """Validate acknowledged native evidence, including nullable pending IDs."""
    try:
        exact(value, {'thread_id', 'turn_id', 'terminal', 'interrupt'})
        for key in ('thread_id', 'turn_id'):
            if value[key] is not None:
                _identifier(value[key], 100)
        if value['terminal'] not in NATIVE_TERMINALS or value['interrupt'] not in INTERRUPT_STATES:
            raise Fault('invalid_arguments')
        if successful and (value['thread_id'] is None or value['turn_id'] is None or
                           value['terminal'] != 'completed' or value['interrupt'] != 'not_requested'):
            raise Fault('invalid_arguments')
    except (Fault, UnicodeError, KeyError, TypeError):
        raise Fault('codex_result_invalid') from None
    return value


def request_body(raw, args=None):
    """Validate the complete frozen request and return its unmodified object."""
    obj = _parse(raw, LIMITS[REQUEST], 'codex_request_invalid', 'codex_input_too_large')
    try:
        exact(obj, {'schema_version', 'text', 'public_history', 'evidence', 'migration'})
        integer(obj['schema_version'], 1, 1)
        _utf8(obj['text'], 8192, 1)
        if type(obj['evidence']) is not list or len(obj['evidence']) > 100:
            raise Fault('invalid_arguments')
        evidence = {}
        for item in obj['evidence']:
            exact(item, set(EVIDENCE_KEYS) | {'text'})
            _evidence_binding(item)
            _utf8(item['text'], 8192)
            if item['evidence_id'] in evidence:
                raise Fault('invalid_arguments')
            evidence[item['evidence_id']] = item
        if type(obj['public_history']) is not list or len(obj['public_history']) > 20:
            raise Fault('invalid_arguments')
        for pair in obj['public_history']:
            exact(pair, {'run_id', 'request_sha256', 'output_sha256',
                         'question', 'answer', 'citations'})
            uid(pair['run_id'])
            digest(pair['request_sha256'])
            digest(pair['output_sha256'])
            _utf8(pair['question'], 8192)
            _utf8(pair['answer'], 8192)
            if type(pair['citations']) is not list or len(pair['citations']) > 50:
                raise Fault('invalid_arguments')
            for citation in pair['citations']:
                exact(citation, set(EVIDENCE_KEYS) | {'quote'})
                _evidence_binding(citation)
                _utf8(citation['quote'], 1024, 1)
                snapshot = evidence.get(citation['evidence_id'])
                if (snapshot is None or
                    any(citation[key] != snapshot[key] for key in EVIDENCE_KEYS) or
                    citation['quote'] not in snapshot['text']):
                    raise Fault('invalid_arguments')
        migration = obj['migration']
        if migration is not None:
            exact(migration, {'from_request_format', 'from_output_format',
                             'from_history_version', 'parent_run_id',
                             'parent_fingerprint', 'source_request_sha256',
                             'encrypted_reasoning_replayed'})
            for key in ('from_request_format', 'from_output_format', 'from_history_version'):
                _utf8(migration[key], 200, 1)
            uid(migration['parent_run_id'])
            digest(migration['parent_fingerprint'])
            digest(migration['source_request_sha256'])
            if migration['encrypted_reasoning_replayed'] is not False:
                raise Fault('invalid_arguments')
    except (Fault, UnicodeError, KeyError, TypeError, RecursionError):
        raise Fault('codex_request_invalid') from None
    if args is not None:
        try:
            reference = args['request']
            if not _same(reference['sha256'], sha(raw)) or not _same(reference['byte_count'], len(raw)):
                raise Fault('descriptor_mismatch')
            digest(reference['sha256'])
            integer(reference['byte_count'], 1, LIMITS[REQUEST])
        except (Fault, KeyError, TypeError):
            raise Fault('descriptor_mismatch') from None
    return obj


def descriptor(raw, args):
    """Validate separate metadata; request evidence ordering is bound by host."""
    obj = _parse(raw, LIMITS[DESCRIPTOR], 'codex_request_invalid')
    try:
        exact(obj, {'version', 'executionID', 'threadID', 'sequence', 'parentRunID',
                    'parentFingerprint', 'startsAlternatePath', 'model', 'format',
                    'requestDigest', 'requestBytes', 'maximumResponseBytes',
                    'maximumOutputTokens', 'maximumTextBytes', 'evidence'})
        integer(obj['version'], 1, 1)
        uid(obj['executionID'])
        uid(obj['threadID'])
        integer(obj['sequence'], 0, 1000000)
        if obj['parentRunID'] is not None:
            uid(obj['parentRunID'])
        if obj['parentFingerprint'] is not None:
            digest(obj['parentFingerprint'])
        if type(obj['startsAlternatePath']) is not bool:
            raise Fault('invalid_arguments')
        _identifier(obj['model'], 150)
        if obj['format'] != 'tisra.codex.v1' or obj['maximumOutputTokens'] is not None:
            raise Fault('invalid_arguments')
        digest(obj['requestDigest'])
        integer(obj['requestBytes'], 1, LIMITS[REQUEST])
        integer(obj['maximumTextBytes'], 1, MAX_TEXT_BYTES)
        integer(obj['maximumResponseBytes'], 1, LIMITS[RESPONSE])
        if type(obj['evidence']) is not list or len(obj['evidence']) > 100:
            raise Fault('invalid_arguments')
        seen = set()
        for item in obj['evidence']:
            exact(item, {'evidenceID', 'snapshotDigest'})
            uid(item['evidenceID'])
            digest(item['snapshotDigest'])
            if item['evidenceID'] in seen:
                raise Fault('invalid_arguments')
            seen.add(item['evidenceID'])
    except (Fault, UnicodeError, KeyError, TypeError):
        raise Fault('codex_request_invalid') from None
    try:
        if (not _same(obj['executionID'], args['run_id']) or not _same(obj['model'], args['model']) or
            not _same(obj['requestDigest'], args['request']['sha256']) or
            not _same(obj['requestBytes'], args['request']['byte_count']) or
            not _same(obj['maximumTextBytes'], args['max_output_bytes'])):
            raise Fault('descriptor_mismatch')
    except (Fault, KeyError, TypeError):
        raise Fault('descriptor_mismatch') from None
    return obj


def result_body(raw, args, *, binding=None, native=None, model_evidence=None,
                reviewed_evidence=None):
    """Validate a successful result, including all supplied original pins.

    This is a pure envelope check. The host separately enforces publication
    admission, cancellation, first auth epoch and matching durable native state.
    """
    obj = _parse(raw, LIMITS[RESPONSE], 'codex_result_invalid')
    try:
        exact(obj, {'schema_version', 'provider_input_sha256', 'model_evidence',
                    'native', 'text', 'output_sha256', 'reviewed_evidence_bindings',
                    'usage', 'token_hard_cap_supported'} | set(BINDING_KEYS))
        integer(obj['schema_version'], 1, 1)
        uid(obj['job_id'])
        uid(obj['run_id'])
        integer(obj['epoch'], 0, 2147483647)
        for key in ('owner', 'auth_epoch', 'model'):
            _identifier(obj[key])
        for key in ('request_sha256', 'provider_input_sha256', 'model_fingerprint',
                    'output_sha256'):
            digest(obj[key])
        if (obj['provider'] != PROVIDER or
            tuple(obj[key] for key in ('request_format', 'output_format', 'history_version')) != FORMATS or
            obj['provider_input_sha256'] != obj['request_sha256']):
            raise Fault('invalid_arguments')
        maximum = args.get('max_output_bytes', MAX_TEXT_BYTES)
        integer(maximum, 1, MAX_TEXT_BYTES)
        _utf8(obj['text'], maximum)
        if obj['output_sha256'] != sha(obj['text'].encode('utf-8')):
            raise Fault('invalid_arguments')
        model = obj['model_evidence']
        exact(model, {'source', 'confirmed_identifier', 'adapter_binary_sha256',
                      'protocol_version', 'control_contract_sha256', 'backend_weights_revision'})
        if (model['source'] != 'thread_start_confirmed_identifier' or
            model['confirmed_identifier'] != obj['model'] or
            model['protocol_version'] != PROTOCOL_VERSION or
            model['backend_weights_revision'] is not None):
            raise Fault('invalid_arguments')
        digest(model['adapter_binary_sha256'])
        digest(model['control_contract_sha256'])
        if obj['model_fingerprint'] != model_fingerprint(model):
            raise Fault('invalid_arguments')
        upstream = obj['native']
        native_body(upstream, successful=True)
        reviewed = obj['reviewed_evidence_bindings']
        if type(reviewed) is not list or len(reviewed) > 100:
            raise Fault('invalid_arguments')
        seen = set()
        for item in reviewed:
            exact(item, EVIDENCE_KEYS)
            _evidence_binding(item)
            if item['evidence_id'] in seen:
                raise Fault('invalid_arguments')
            seen.add(item['evidence_id'])
        exact(obj['usage'], {'tokens', 'cost'})
        if (obj['usage']['tokens'] is not None or obj['usage']['cost'] is not None or
            obj['token_hard_cap_supported'] is not False):
            raise Fault('invalid_arguments')
        # Compare every pin available from the immutable submit arguments.
        for key in BINDING_KEYS:
            if key in args and not _same(obj[key], args[key]):
                raise Fault('invalid_arguments')
        if 'request' in args and not _same(obj['request_sha256'], args['request']['sha256']):
            raise Fault('invalid_arguments')
        if binding is not None:
            if type(binding) is not dict or not set(BINDING_KEYS) <= set(binding):
                raise Fault('invalid_arguments')
            for key in BINDING_KEYS:
                if not _same(obj[key], binding[key]):
                    raise Fault('invalid_arguments')
        for actual, expected in ((upstream, native), (model, model_evidence),
                                 (reviewed, reviewed_evidence)):
            if expected is not None and not _same(actual, expected):
                raise Fault('invalid_arguments')
    except (Fault, UnicodeError, KeyError, TypeError, AttributeError, RecursionError):
        raise Fault('codex_result_invalid') from None
    return obj
