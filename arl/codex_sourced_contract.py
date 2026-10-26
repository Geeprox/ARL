"""Pure sourced v2 contract; no provider launch, grant or Ledger access.

Original request bytes are the only provider input. Generated citations retain
their exact quotes and UTF-8 ranges; invalid citations reject the whole result.
Source metadata is not proof that generated references match source text.
"""
from __future__ import annotations

from .contracts import Fault, encode
from .research import digest, exact, integer, sha, uid
from .codex_contract import (BINDING_KEYS, EVIDENCE_KEYS as V1_EVIDENCE_KEYS, FINGERPRINT_KEYS,
                             INTERRUPT_STATES, MAX_TEXT_BYTES, NATIVE_TERMINALS,
                             PROTOCOL_VERSION, PROVIDER, _identifier, _parse,
                             _same, _utf8, _utf8_tree, model_fingerprint, native_body)

NAME = 'tisra.codex.research.v2'
REQUEST = 'tisra.codex.request.v2'
DESCRIPTOR = 'tisra.codex.descriptor.v2'
RESPONSE = 'tisra.codex.result.v2'
FORMATS = (REQUEST, RESPONSE, 'tisra.codex.history.v2')
LIMITS = {REQUEST: 8192, DESCRIPTOR: 32768, RESPONSE: 262144}
GENERATED_BODY_BYTES = 32768
EVIDENCE_KEYS = V1_EVIDENCE_KEYS + ('attachment_sha256',)
RENDERER_VERSION = RENDERER = 'tisra.codex.raw-json.v2'
RENDERER_METADATA = {
    'version': RENDERER,
    'input': 'complete_original_utf8_json_bytes_as_sole_text_input',
    'transformations': 'none_no_reserialize_fetch_truncate_summarize_or_normalize',
    'history': 'explicit_public_question_answer_and_original_citations_only',
    'output': 'text_and_original_generated_citations_in_original_order',
    'private_reasoning_replayed': False,
}
CITATION_KEYS = EVIDENCE_KEYS + ('quote', 'start_utf8', 'end_utf8')
PART_KEYS = EVIDENCE_KEYS + ('text', 'title', 'locator', 'extraction_state')
EXTRACTION_STATES = frozenset({'ready', 'partial', 'unavailable', 'failed'})
OUTPUT_SCHEMA = {
    'type': 'object', 'additionalProperties': False,
    'properties': {
        'text': {'type': 'string'},
        'citations': {'type': 'array', 'items': {
            'type': 'object', 'additionalProperties': False,
            'properties': {
                'evidence_id': {'type': 'string'}, 'snapshot_digest': {'type': 'string'},
                'record_id': {'type': 'string'}, 'revision': {'type': 'integer'},
                'unit': {'type': ['integer', 'null']}, 'quote': {'type': 'string'},
                'attachment_sha256': {'type': ['string', 'null']},
                'start_utf8': {'type': 'integer'}, 'end_utf8': {'type': 'integer'},
            },
            'required': list(CITATION_KEYS),
        }},
    },
    'required': ['text', 'citations'],
}


def _part_key(part):
    return tuple(part[key] for key in ('evidence_id', 'record_id', 'revision', 'unit'))


def _binding(part):
    uid(part['evidence_id'])
    digest(part['snapshot_digest'])
    uid(part['record_id'])
    integer(part['revision'], 1, 2147483647)
    if part['unit'] is not None:
        integer(part['unit'], 0, 1999)
        digest(part['attachment_sha256'])
    elif part['attachment_sha256'] is not None:
        raise Fault('invalid_arguments')


def _parts(parts, *, sources=False):
    if type(parts) is not list or len(parts) > 100:
        raise Fault('invalid_arguments')
    seen, digests, records, attachments = {}, {}, {}, {}
    for part in parts:
        exact(part, PART_KEYS if sources else EVIDENCE_KEYS)
        _binding(part)
        identity = _part_key(part)
        if identity in seen:
            raise Fault('invalid_arguments')
        seen[identity] = part
        evidence_id = part['evidence_id']
        if evidence_id in digests and digests[evidence_id] != part['snapshot_digest']:
            raise Fault('invalid_arguments')
        digests[evidence_id] = part['snapshot_digest']
        record_key = (evidence_id, part['record_id'])
        if part['unit'] is not None:
            attachment = part['attachment_sha256']
            if record_key in attachments and attachments[record_key] != attachment:
                raise Fault('invalid_arguments')
            attachments[record_key] = attachment
        metadata = (part['revision'],)
        if sources:
            _utf8(part['text'], 8192)
            _utf8(part['title'], 1024)
            if part['extraction_state'] not in EXTRACTION_STATES:
                raise Fault('invalid_arguments')
            if part['unit'] is None:
                if part['locator'] is not None:
                    raise Fault('invalid_arguments')
            else:
                _utf8(part['locator'], 200)
                if part['extraction_state'] not in {'ready', 'partial'}:
                    raise Fault('invalid_arguments')
            metadata += (part['title'], part['extraction_state'])
        if record_key in records and records[record_key] != metadata:
            raise Fault('invalid_arguments')
        records[record_key] = metadata
    return seen


def reviewed_body(value):
    """Validate flat source bindings; repeated snapshot IDs can have many parts."""
    try:
        _parts(value)
    except (Fault, UnicodeError, KeyError, TypeError, RecursionError):
        raise Fault('codex_result_invalid') from None
    return value


def reviewed_bindings(request):
    return [{key: part[key] for key in EVIDENCE_KEYS} for part in request['evidence']]


def snapshot_bindings(request):
    """Descriptor snapshots in first appearance order, not one per source part."""
    seen, result = set(), []
    for part in request['evidence']:
        if part['evidence_id'] not in seen:
            seen.add(part['evidence_id'])
            result.append({'evidenceID': part['evidence_id'], 'snapshotDigest': part['snapshot_digest']})
    return result


def output_digest(obj):
    """The output pin covers answer text and all original generated references."""
    return sha(encode({'text': obj['text'], 'citations': obj['citations']}))


def _citations(citations, *, parts=None, bindings=None):
    if type(citations) is not list or len(citations) > 50:
        raise Fault('invalid_arguments')
    seen = set()
    for citation in citations:
        exact(citation, CITATION_KEYS)
        _binding(citation)
        _utf8(citation['quote'], 16384, 1)
        integer(citation['start_utf8'], 0, 8191)
        integer(citation['end_utf8'], 1, 8192)
        if citation['start_utf8'] >= citation['end_utf8']:
            raise Fault('invalid_arguments')
        if len(citation['quote'].encode('utf-8')) != citation['end_utf8'] - citation['start_utf8']:
            raise Fault('invalid_arguments')
        # Tisra's visible citation identity excludes digest and offsets.
        identity = _part_key(citation) + (citation['quote'],)
        if identity in seen:
            raise Fault('invalid_arguments')
        seen.add(identity)
        original = parts if parts is not None else bindings
        if original is not None:
            source = original.get(_part_key(citation))
            if source is None or any(not _same(citation[key], source[key]) for key in EVIDENCE_KEYS):
                raise Fault('invalid_arguments')
            if parts is not None:
                raw = source['text'].encode('utf-8', errors='strict')
                if citation['end_utf8'] > len(raw):
                    raise Fault('invalid_arguments')
                quoted = raw[citation['start_utf8']:citation['end_utf8']]
                if quoted.decode('utf-8', errors='strict') != citation['quote']:
                    raise Fault('invalid_arguments')


def _request_obj(obj):
    exact(obj, {'schema_version', 'text', 'public_history', 'evidence', 'migration'})
    integer(obj['schema_version'], 2, 2)
    _utf8(obj['text'], 8192, 1)
    parts = _parts(obj['evidence'], sources=True)
    if type(obj['public_history']) is not list or len(obj['public_history']) > 20:
        raise Fault('invalid_arguments')
    for pair in obj['public_history']:
        exact(pair, {'run_id', 'request_sha256', 'output_sha256', 'question', 'answer', 'citations'})
        uid(pair['run_id'])
        digest(pair['request_sha256'])
        digest(pair['output_sha256'])
        _utf8(pair['question'], 8192)
        _utf8(pair['answer'], 8192)
        _citations(pair['citations'], parts=parts)
        if pair['output_sha256'] != output_digest({'text': pair['answer'], 'citations': pair['citations']}):
            raise Fault('invalid_arguments')
    migration = obj['migration']
    if migration is not None:
        exact(migration, {'from_request_format', 'from_output_format', 'from_history_version',
                         'parent_run_id', 'parent_fingerprint', 'source_request_sha256',
                         'encrypted_reasoning_replayed'})
        for key in ('from_request_format', 'from_output_format', 'from_history_version'):
            _utf8(migration[key], 200, 1)
        uid(migration['parent_run_id'])
        digest(migration['parent_fingerprint'])
        digest(migration['source_request_sha256'])
        if migration['encrypted_reasoning_replayed'] is not False:
            raise Fault('invalid_arguments')
    return parts


def request_body(raw, args=None):
    """Validate original complete bytes without truncation or reserialization."""
    obj = _parse(raw, LIMITS[REQUEST], 'codex_request_invalid', 'codex_input_too_large')
    try:
        _request_obj(obj)
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
    obj = _parse(raw, LIMITS[DESCRIPTOR], 'codex_request_invalid')
    try:
        exact(obj, {'version', 'executionID', 'threadID', 'sequence', 'parentRunID',
                    'parentFingerprint', 'startsAlternatePath', 'model', 'format',
                    'requestDigest', 'requestBytes', 'maximumResponseBytes',
                    'maximumOutputTokens', 'maximumTextBytes', 'evidence'})
        integer(obj['version'], 2, 2)
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
        if obj['format'] != 'tisra.codex.v2' or obj['maximumOutputTokens'] is not None:
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


def _output(obj, maximum, *, parts=None, bindings=None):
    exact(obj, {'text', 'citations'})
    integer(maximum, 1, MAX_TEXT_BYTES)
    _utf8(obj['text'], maximum, 1)
    if not obj['text'].strip():
        raise Fault('invalid_arguments')
    _citations(obj['citations'], parts=parts, bindings=bindings)
    if len(encode(obj)) > GENERATED_BODY_BYTES:
        raise Fault('invalid_arguments')


def structured_body(raw, request, max_text_bytes=MAX_TEXT_BYTES):
    """Strict generated body with all citations validated against supplied text."""
    obj = _parse(raw, GENERATED_BODY_BYTES, 'codex_result_invalid')
    try:
        if type(request) is bytes:
            request = request_body(request)
        _utf8_tree(request)
        parts = _request_obj(request)
        _output(obj, max_text_bytes, parts=parts)
    except (Fault, UnicodeError, KeyError, TypeError, RecursionError):
        raise Fault('codex_result_invalid') from None
    return obj


def result_body(raw, args, *, binding=None, native=None, model_evidence=None,
                reviewed_evidence=None, request=None):
    """Validate result pins and original citations, with optional trusted source.

    Without ``request`` only citation shape, identity and reviewed binding can
    be verified. The host must supply original sources before publication; a
    consumer must do so before presenting references as source-validated.
    """
    obj = _parse(raw, LIMITS[RESPONSE], 'codex_result_invalid')
    try:
        exact(obj, {'schema_version', 'provider_input_sha256', 'model_evidence', 'native',
                    'text', 'citations', 'output_sha256', 'reviewed_evidence_bindings',
                    'usage', 'token_hard_cap_supported'} | set(BINDING_KEYS))
        integer(obj['schema_version'], 2, 2)
        uid(obj['job_id'])
        uid(obj['run_id'])
        integer(obj['epoch'], 0, 2147483647)
        for key in ('owner', 'auth_epoch', 'model'):
            _identifier(obj[key])
        for key in ('request_sha256', 'provider_input_sha256', 'model_fingerprint', 'output_sha256'):
            digest(obj[key])
        if (obj['provider'] != PROVIDER or
            tuple(obj[key] for key in ('request_format', 'output_format', 'history_version')) != FORMATS or
            obj['provider_input_sha256'] != obj['request_sha256']):
            raise Fault('invalid_arguments')
        reviewed = reviewed_body(obj['reviewed_evidence_bindings'])
        parts = None
        if request is not None:
            if type(request) is bytes:
                request = request_body(request, args)
            _utf8_tree(request)
            parts = _request_obj(request)
            if not _same(reviewed, reviewed_bindings(request)):
                raise Fault('invalid_arguments')
        output = {'text': obj['text'], 'citations': obj['citations']}
        _output(output, args.get('max_output_bytes', MAX_TEXT_BYTES),
                parts=parts, bindings=_parts(reviewed))
        if obj['output_sha256'] != output_digest(output):
            raise Fault('invalid_arguments')
        model = obj['model_evidence']
        exact(model, {'source', 'confirmed_identifier', 'adapter_binary_sha256',
                      'protocol_version', 'control_contract_sha256', 'backend_weights_revision'})
        if (model['source'] != 'thread_start_confirmed_identifier' or
            model['confirmed_identifier'] != obj['model'] or
            model['protocol_version'] != PROTOCOL_VERSION or model['backend_weights_revision'] is not None):
            raise Fault('invalid_arguments')
        digest(model['adapter_binary_sha256'])
        digest(model['control_contract_sha256'])
        if obj['model_fingerprint'] != model_fingerprint(model):
            raise Fault('invalid_arguments')
        upstream = native_body(obj['native'], successful=True)
        exact(obj['usage'], {'tokens', 'cost'})
        if (obj['usage']['tokens'] is not None or obj['usage']['cost'] is not None or
            obj['token_hard_cap_supported'] is not False):
            raise Fault('invalid_arguments')
        for key in BINDING_KEYS:
            if key in args and not _same(obj[key], args[key]):
                raise Fault('invalid_arguments')
        if 'request' in args and not _same(obj['request_sha256'], args['request']['sha256']):
            raise Fault('invalid_arguments')
        if binding is not None:
            if type(binding) is not dict or not set(BINDING_KEYS) <= set(binding):
                raise Fault('invalid_arguments')
            if any(not _same(obj[key], binding[key]) for key in BINDING_KEYS):
                raise Fault('invalid_arguments')
        for actual, expected in ((upstream, native), (model, model_evidence), (reviewed, reviewed_evidence)):
            if expected is not None and not _same(actual, expected):
                raise Fault('invalid_arguments')
    except (Fault, UnicodeError, KeyError, TypeError, AttributeError, RecursionError):
        raise Fault('codex_result_invalid') from None
    return obj


# This machine-readable source agreement is independent from a model's adapter
# and control pins. It is mirrored verbatim in codex-native-sourced-v2.json.
CONTRACT = {
    'contract_version': 2,
    'status': 'source_only_consumer_acceptance_required',
    'provider': PROVIDER,
    'tool': NAME,
    'transport': {'schema_version': 1, 'rpc_namespace': 'codex.*.v1'},
    'formats': dict(zip(('request', 'output', 'history'), FORMATS)),
    'payload_purposes': {'request': REQUEST, 'descriptor': DESCRIPTOR, 'result': RESPONSE},
    'renderer': RENDERER_METADATA,
    'bounds': {'original_request_bytes': 8192, 'provider_input_bytes': 8192,
               'separate_descriptor_bytes': 32768, 'generated_body_original_bytes': GENERATED_BODY_BYTES,
               'generated_body_canonical_bytes': GENERATED_BODY_BYTES, 'generated_text_bytes': MAX_TEXT_BYTES,
               'stored_result_envelope_bytes': 262144, 'upstream_complete_json_line_bytes': 65536,
               'whole_call_wall_time_ms': 30000, 'provider_turns': 1, 'automatic_retries': 0,
               'output_token_hard_cap': None, 'cost_hard_cap': None},
    'common_rules': {'unknown_keys': 'reject', 'duplicate_keys': 'reject',
                     'nullable_keys': 'explicit_null_required', 'uuid': 'canonical_lowercase_uuid',
                     'sha256': '64_lowercase_hex', 'integer': 'finite_integer_not_boolean',
                     'strings': 'strict_utf8_no_unpaired_surrogates',
                     'overflow': 'reject_complete_object_before_external_start_no_truncation'},
    'request': {'schema_version': 2,
                'exact_keys': ['schema_version', 'text', 'public_history', 'evidence', 'migration'],
                'text': {'type': 'string', 'min_utf8_bytes': 1, 'max_utf8_bytes': 8192},
                'public_history': {'type': 'array', 'max_items': 20, 'item': 'public_history_pair'},
                'evidence': {'type': 'array', 'max_items': 100, 'item': 'selected_source_part',
                             'unique_by': ['evidence_id', 'record_id', 'revision', 'unit'],
                             'digest_consistency': 'one_snapshot_digest_per_evidence_id',
                             'record_consistency': 'one_revision_title_extraction_state_per_evidence_id_record_id'},
                'migration': 'explicit_null_or_migration_binding'},
    'objects': {
        'selected_source_part': {'exact_keys': list(PART_KEYS), 'evidence_id': 'uuid',
                                 'snapshot_digest': 'sha256_of_trusted_original_complete_snapshot_not_part_text',
                                 'record_id': 'uuid', 'revision': 'integer_1_to2147483647',
                                 'unit': 'explicit_null_or_integer_0_to1999', 'text': 'string_max8192_utf8_bytes',
                                 'attachment_sha256': 'explicit_null_for_note_or_sha256_of_original_attachment_for_extracted_unit',
                                 'attachment_binding': 'caller_supplies_matching_record_source_blob_hash_and_extraction_blob_hash_no_blob_fetch',
                                 'title': 'string_max1024_utf8_bytes',
                                 'locator': 'explicit_null_for_note_or_string_max200_utf8_bytes_for_unit',
                                 'extraction_state': sorted(EXTRACTION_STATES),
                                 'unit_requires_extraction_state': ['ready', 'partial'],
                                 'empty_note_text_allowed': True},
        'citation': {'exact_keys': list(CITATION_KEYS), 'evidence_id': 'uuid', 'snapshot_digest': 'sha256',
                     'record_id': 'uuid', 'revision': 'integer_1_to2147483647',
                     'unit': 'explicit_null_or_integer_0_to1999', 'quote': 'nonempty_string_max16384_utf8_bytes',
                     'attachment_sha256': 'explicit_null_for_note_or_exact_original_source_part_attachment_sha256',
                     'start_utf8': 'integer_0_to8191', 'end_utf8': 'integer_1_to8192',
                     'range': 'start_less_than_end_end_exclusive_relative_to_entire_exact_source_part_text',
                     'source_check': 'exact_matching_binding_and_strict_utf8_source_byteslice_equals_quote_no_normalization',
                     'duplicate_identity': ['evidence_id', 'record_id', 'revision', 'unit', 'quote']},
        'public_history_pair': {'exact_keys': ['run_id', 'request_sha256', 'output_sha256', 'question', 'answer', 'citations'],
                                'run_id': 'uuid', 'request_sha256': 'sha256', 'question': 'string_max8192_utf8_bytes',
                                'answer': 'string_max8192_utf8_bytes', 'citations': 'array_max50_citation',
                                'output_sha256': 'sha256_canonical_encode_text_answer_and_original_citations',
                                'source_validation': 'all_historical_citations_require_explicit_root_source_parts'},
        'migration_binding': {'exact_keys': ['from_request_format', 'from_output_format', 'from_history_version',
                                            'parent_run_id', 'parent_fingerprint', 'source_request_sha256',
                                            'encrypted_reasoning_replayed'],
                              'from_request_format': 'nonempty_string_max200_utf8_bytes',
                              'from_output_format': 'nonempty_string_max200_utf8_bytes',
                              'from_history_version': 'nonempty_string_max200_utf8_bytes',
                              'parent_run_id': 'uuid', 'parent_fingerprint': 'sha256',
                              'source_request_sha256': 'sha256', 'encrypted_reasoning_replayed': False},
    },
    'descriptor': {'version': 2, 'format': 'tisra.codex.v2', 'maximumOutputTokens': None,
                   'exact_keys': ['version', 'executionID', 'threadID', 'sequence', 'parentRunID',
                                  'parentFingerprint', 'startsAlternatePath', 'model', 'format', 'requestDigest',
                                  'requestBytes', 'maximumResponseBytes', 'maximumOutputTokens', 'maximumTextBytes', 'evidence'],
                   'maximumTextBytes': 'integer_1_to32768', 'maximumResponseBytes': 'integer_1_to262144',
                   'request_binding': 'original_execution_id_model_request_sha256_and_complete_byte_count_match_submit',
                   'evidence': 'ordered_unique_snapshot_id_digest_first_appearance_from_flat_parts'},
    'generated_body': {'exact_keys': ['text', 'citations'], 'text': 'nonempty_nonwhitespace_string_max_granted_text_bytes',
                       'citations': 'array_max50_citation_zero_allowed', 'provider_json_schema': OUTPUT_SCHEMA,
                       'validation': 'all_present_citations_match_exact_original_sources_or_reject_whole_result_no_filter_repair',
                       'missing_citations': 'allowed_consumer_may_show_missing_citation_notice',
                       'citation_meaning': 'proves_exact_source_passage_exists_not_that_each_inference_is_true'},
    'result_envelope': {
        'schema_version': 2,
        'exact_keys': ['schema_version', 'request_format', 'output_format', 'history_version', 'owner', 'job_id',
                       'run_id', 'request_sha256', 'provider_input_sha256', 'epoch', 'auth_epoch', 'provider',
                       'model', 'model_fingerprint', 'model_evidence', 'native', 'text', 'citations', 'output_sha256',
                       'reviewed_evidence_bindings', 'usage', 'token_hard_cap_supported'],
        'output_sha256': 'sha256_canonical_encode_text_and_all_original_generated_citations',
        'canonical_encoding': 'arl.contracts.encode_json_ensure_ascii_false_sort_keys_true_allow_nan_false_default_separators',
        'reviewed_evidence_bindings': 'ordered_original_flat_part_metadata_exact_evidence_keys_not_generated_citations',
        'source_validation': 'host_always_requires_original_request_consumer_requires_trusted_sources_for_quote_range_validation',
        'source_absent_validation': 'shape_uniqueness_hash_pins_and_reviewed_binding_only_no_source_quote_claim',
        'model_evidence': {'exact_keys': ['source', 'confirmed_identifier', 'adapter_binary_sha256', 'protocol_version',
                                        'control_contract_sha256', 'backend_weights_revision'],
                           'source': 'thread_start_confirmed_identifier', 'protocol_version': PROTOCOL_VERSION,
                           'confirmed_identifier': 'matches_original_granted_model_and_thread_start_response',
                           'adapter_binary_sha256': 'sha256', 'control_contract_sha256': 'sha256',
                           'backend_weights_revision': None},
        'model_fingerprint': {'basis': list(FINGERPRINT_KEYS), 'digest': 'sha256_canonical_encode_basis_fields_not_backend_weights'},
        'native': {'exact_keys': ['thread_id', 'turn_id', 'terminal', 'interrupt'],
                   'thread_id': 'acknowledged_nonempty_string_max100_characters',
                   'turn_id': 'acknowledged_nonempty_string_max100_characters',
                   'terminal': 'completed', 'interrupt': 'not_requested'},
        'usage': {'exact_keys': ['tokens', 'cost'], 'tokens': None, 'cost': None},
        'token_hard_cap_supported': False,
    },
    'receipt_binding': list(BINDING_KEYS),
    'reviewed_binding': {'exact_keys': list(EVIDENCE_KEYS), 'ordered': True,
                        'unique_by': ['evidence_id', 'record_id', 'revision', 'unit'],
                        'consistency': 'one_digest_per_evidence_id_one_revision_per_evidence_id_record_id_one_attachment_sha256_per_extracted_record'},
    'native_evidence': {'terminal': sorted(NATIVE_TERMINALS), 'interrupt': sorted(INTERRUPT_STATES),
                        'ack_is_terminal': False, 'backend_weights_revision': None},
    'recovery': {'persist_before_start': 'original_immutable_receipt_binding_and_uncertainty',
                 'persist_on_ack': 'matching_native_ids_and_original_model_control_pins',
                 'cancel': 'close_publication_gate_first_then_one_bounded_interrupt',
                 'lost_ack': 'needs_review_no_replay', 'late_output': 'discard_after_gate_closes',
                 'restore': 'validate_original_pins_status_cancel_cleanup_only_no_start_or_resubmit',
                 'durable_record': 'metadata_only_no_source_answer_quote_or_private_reasoning_plaintext'},
    'tools': 'deny_all_actions_and_non_text_provider_items',
    'workspace': 'host_owned_empty_ephemeral_read_only_network_disabled_inherited_mcp_disabled',
    'capability_advertisement': 'none_without_explicit_matching_consumer_grant_and_host_opt_in',
}
CONTRACT_SHA256 = sha(encode(CONTRACT))
