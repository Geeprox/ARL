"""Explicit selected-candidate ranking; pure codecs, no RPC registration or IO.

Explanation retains sourced research v2. Ranking never interprets that text as
an ordering. Full selected-record source parts must be reviewed before submit.
"""
from __future__ import annotations

import copy

from .contracts import Fault, encode
from .research import exact, integer, uid, digest, sha
from . import codex_sourced_contract as sourced
from .codex_contract import (BINDING_KEYS, PROVIDER, PROTOCOL_VERSION, _parse,
    _utf8, _identifier, _same, model_fingerprint, native_body)

NAME = 'tisra.codex.rerank.v1'
REQUEST = 'tisra.codex.rerank.request.v1'
RESPONSE = 'tisra.codex.rerank.result.v1'
HISTORY = 'tisra.codex.rerank.no-history.v1'
FORMATS = (REQUEST, RESPONSE, HISTORY)
MAX_INPUT = 8192
MAX_BODY = 32768
MAX_ENVELOPE = 262144
MAX_CANDIDATES = 8
MAX_PARTS = 100
MAX_CITATIONS = 50
MAX_REASON = 2048
ORIGINS = frozenset({'manual_selection', 'lexical_candidates'})
CITATION_SCHEMA = copy.deepcopy(sourced.OUTPUT_SCHEMA['properties']['citations']['items'])
OUTPUT_SCHEMA = {
    'type': 'object', 'additionalProperties': False,
    'required': ['schema_version', 'ranked_candidates'],
    'properties': {
        'schema_version': {'type': 'integer'},
        'ranked_candidates': {'type': 'array', 'items': {
            'type': 'object', 'additionalProperties': False,
            'required': ['candidate_id', 'reason', 'citations'],
            'properties': {'candidate_id': {'type': 'string'}, 'reason': {'type': 'string'},
                'citations': {'type': 'array', 'items': CITATION_SCHEMA}}}}}}


def _request(obj):
    exact(obj, {'schema_version', 'query', 'scope', 'candidate_origin', 'candidates'})
    integer(obj['schema_version'], 1, 1)
    _utf8(obj['query'], MAX_INPUT, 1)
    if not obj['query'].strip():
        raise Fault('invalid_arguments')
    exact(obj['scope'], {'scope_id', 'scope_revision'})
    uid(obj['scope']['scope_id'])
    integer(obj['scope']['scope_revision'], 0, 9007199254740991)
    if type(obj['candidate_origin']) is not str or obj['candidate_origin'] not in ORIGINS:
        raise Fault('invalid_arguments')
    candidates = obj['candidates']
    if type(candidates) is not list or not 1 <= len(candidates) <= MAX_CANDIDATES:
        raise Fault('invalid_arguments')
    groups, all_parts = {}, []
    for candidate in candidates:
        exact(candidate, {'candidate_id', 'parts'})
        identity, parts = candidate['candidate_id'], candidate['parts']
        uid(identity)
        if identity in groups or type(parts) is not list or not 1 <= len(parts) <= MAX_PARTS:
            raise Fault('invalid_arguments')
        validated = sourced._parts(parts, sources=True)
        if any(part['record_id'] != identity for part in parts):
            raise Fault('invalid_arguments')
        if len({part['revision'] for part in parts}) != 1 or not any(part['text'].strip() for part in parts):
            raise Fault('invalid_arguments')
        groups[identity] = validated
        all_parts.extend(parts)
    if len(all_parts) > MAX_PARTS:
        raise Fault('invalid_arguments')
    sourced._parts(all_parts, sources=True)  # Global uniqueness and metadata consistency.
    return groups, all_parts


def request_body(raw, args=None):
    obj = _parse(raw, MAX_INPUT, 'rerank_request_invalid', 'codex_input_too_large')
    try:
        _request(obj)
        if args is not None:
            ref = args['request']
            if not _same(ref['sha256'], sha(raw)) or not _same(ref['byte_count'], len(raw)):
                raise Fault('invalid_arguments')
    except (Fault, KeyError, TypeError, ValueError, UnicodeError, RecursionError):
        raise Fault('rerank_request_invalid') from None
    return obj


def reviewed_bindings(request):
    _, parts = _request(request)
    return [{key: part[key] for key in sourced.EVIDENCE_KEYS} for part in parts]


def structured_body(raw, request, maximum=MAX_BODY):
    obj = _parse(raw, MAX_BODY, 'rerank_result_invalid')
    try:
        integer(maximum, 128, MAX_BODY)
        if len(raw) > maximum:
            raise Fault('invalid_arguments')
        if type(request) is bytes:
            request = request_body(request)
        groups, _ = _request(request)
        exact(obj, {'schema_version', 'ranked_candidates'})
        integer(obj['schema_version'], 1, 1)
        rows = obj['ranked_candidates']
        if type(rows) is not list or len(rows) != len(groups):
            raise Fault('invalid_arguments')
        seen, count = set(), 0
        for row in rows:
            exact(row, {'candidate_id', 'reason', 'citations'})
            identity = row['candidate_id']
            uid(identity)
            if identity not in groups or identity in seen:
                raise Fault('invalid_arguments')
            seen.add(identity)
            _utf8(row['reason'], MAX_REASON, 1)
            if not row['reason'].strip() or type(row['citations']) is not list or not row['citations']:
                raise Fault('invalid_arguments')
            sourced._citations(row['citations'], parts=groups[identity])
            count += len(row['citations'])
        if seen != set(groups) or count > MAX_CITATIONS:
            raise Fault('invalid_arguments')
    except (Fault, KeyError, TypeError, ValueError, UnicodeError, RecursionError):
        raise Fault('rerank_result_invalid') from None
    return obj


def output_digest(body):
    return sha(encode(body))


def result_body(raw, args, *, request, binding, native=None, model_evidence=None):
    """Require original request and accepted host binding before publication."""
    obj = _parse(raw, MAX_ENVELOPE, 'rerank_result_invalid')
    try:
        req = request_body(request, args)
        exact(obj, set(BINDING_KEYS) | {'schema_version', 'contract_sha256', 'scope', 'candidate_origin',
            'provider_input_sha256', 'model_evidence', 'native', 'body', 'output_sha256',
            'reviewed_evidence_bindings', 'usage', 'token_hard_cap_supported'})
        integer(obj['schema_version'], 1, 1)
        uid(obj['job_id']); uid(obj['run_id']); integer(obj['epoch'], 0, 2147483647)
        for key in ['owner', 'auth_epoch', 'model']:
            _identifier(obj[key])
        for key in ['request_sha256', 'provider_input_sha256', 'model_fingerprint', 'output_sha256']:
            digest(obj[key])
        if (obj['owner'] != 'tisra' or obj['provider'] != PROVIDER or obj['contract_sha256'] != CONTRACT_SHA256 or
                tuple(obj[k] for k in ['request_format', 'output_format', 'history_version']) != FORMATS or
                obj['provider_input_sha256'] != sha(request) or obj['request_sha256'] != sha(request) or
                not _same(obj['scope'], req['scope']) or obj['candidate_origin'] != req['candidate_origin'] or
                not _same(obj['reviewed_evidence_bindings'], reviewed_bindings(req))):
            raise Fault('invalid_arguments')
        body = structured_body(encode(obj['body']), req, args['max_output_bytes'])
        if obj['output_sha256'] != output_digest(body):
            raise Fault('invalid_arguments')
        model = obj['model_evidence']
        exact(model, {'source', 'confirmed_identifier', 'adapter_binary_sha256', 'protocol_version',
                      'control_contract_sha256', 'backend_weights_revision'})
        if (model['source'] != 'thread_start_confirmed_identifier' or model['confirmed_identifier'] != obj['model'] or
                model['protocol_version'] != PROTOCOL_VERSION or model['backend_weights_revision'] is not None):
            raise Fault('invalid_arguments')
        digest(model['adapter_binary_sha256']); digest(model['control_contract_sha256'])
        if model_fingerprint(model) != obj['model_fingerprint']:
            raise Fault('invalid_arguments')
        actual_native = native_body(obj['native'], successful=True)
        exact(obj['usage'], {'tokens', 'cost'})
        if obj['usage']['tokens'] is not None or obj['usage']['cost'] is not None or obj['token_hard_cap_supported'] is not False:
            raise Fault('invalid_arguments')
        if type(binding) is not dict or not set(BINDING_KEYS) <= set(binding):
            raise Fault('invalid_arguments')
        for key in BINDING_KEYS:
            if not _same(obj[key], binding[key]) or (key in args and not _same(obj[key], args[key])):
                raise Fault('invalid_arguments')
        if native is not None and not _same(actual_native, native):
            raise Fault('invalid_arguments')
        if model_evidence is not None and not _same(model, model_evidence):
            raise Fault('invalid_arguments')
    except (Fault, KeyError, TypeError, ValueError, UnicodeError, RecursionError):
        raise Fault('rerank_result_invalid') from None
    return obj


CONTRACT = {
    'name': NAME, 'request_format': REQUEST, 'output_format': RESPONSE, 'history_version': HISTORY,
    'explanation': {'name': sourced.NAME, 'formats': list(sourced.FORMATS),
                    'contract_sha256': sourced.CONTRACT_SHA256, 'body_unchanged': True},
    'bounds': {'input_bytes': MAX_INPUT, 'generated_body_bytes': MAX_BODY, 'result_envelope_bytes': MAX_ENVELOPE,
               'candidates': MAX_CANDIDATES, 'parts_total': MAX_PARTS, 'citations_total': MAX_CITATIONS,
               'reason_bytes': MAX_REASON, 'whole_call_ms': 30000, 'provider_turns': 1, 'automatic_retries': 0},
    'request_exact_keys': ['schema_version', 'query', 'scope', 'candidate_origin', 'candidates'],
    'scope': {'exact_keys': ['scope_id', 'scope_revision'], 'revision_range': [0, 9007199254740991]},
    'candidate': {'exact_keys': ['candidate_id', 'parts'], 'candidate_id': 'canonical_record_id',
                  'part_keys': list(sourced.PART_KEYS), 'one_record_revision_per_candidate': True,
                  'nonblank_text_in_each_candidate': True, 'origins': sorted(ORIGINS)},
    'source_ranges_reuse_v2': {'revision': [1, 2147483647], 'unit': [0, 1999],
                             'start_utf8': [0, 8191], 'end_utf8': [1, 8192]},
    'generated_body_schema': OUTPUT_SCHEMA,
    'result_exact_keys': sorted(set(BINDING_KEYS) | {'schema_version', 'contract_sha256', 'scope',
        'candidate_origin', 'provider_input_sha256', 'model_evidence', 'native', 'body', 'output_sha256',
        'reviewed_evidence_bindings', 'usage', 'token_hard_cap_supported'}),
    'input_policy': 'complete_original_JSON_full_selected_record_text_and_reviewed_units; never_crop_highlights_or_batch',
    'ordering': 'array_order; exact_input_ID_set_once_each; same_candidate_exact_UTF8_citation_for_every_reason',
    'output_digest': 'sha256_existing_arl_encode_of_complete_generated_body',
    'history': 'none; unknown_history_fields_rejected',
    'submission': 'explicit_review_required; caller_scope_or_configuration_is_not_authorization',
    'publication': 'accepted_owner_job_run_request_epoch_auth_provider_model_binding_plus_current_scope_and_sources',
    'transport': {'provider': PROVIDER, 'internal_format': 'codex.appserver.rerank.v1',
                  'engine_method_namespace': 'existing codex.research.*.v1 only after registered capability negotiation',
                  'registration': 'no automatic registration; exact capability and digest must be separately admitted',
                  'background': False, 'embedding': False},
    'cost_hard_cap_supported': False, 'semantic_quality_verified': False,
}
CONTRACT_SHA256 = sha(encode(CONTRACT))
