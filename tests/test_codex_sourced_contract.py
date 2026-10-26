"""Pure sourced-v2 checks; no native process, Ledger or external inference."""
import copy
import json
from pathlib import Path
import unittest
from unittest.mock import patch

from arl import codex_sourced_contract as contract
from arl.contracts import Fault, encode
from arl.research import sha

RUN = '11111111-1111-4111-8111-111111111111'
JOB = '22222222-2222-4222-8222-222222222222'
SNAPSHOT = '33333333-3333-4333-8333-333333333333'
RECORD = '44444444-4444-4444-8444-444444444444'
OTHER_RECORD = '55555555-5555-4555-8555-555555555555'
OTHER_SNAPSHOT = '66666666-6666-4666-8666-666666666666'
MODEL = 'synthetic-model'


def part(unit=None, text='Exact note. 中文 passage. End.', **overrides):
    value = {'evidence_id': SNAPSHOT, 'snapshot_digest': sha(b'original complete snapshot'),
             'record_id': RECORD, 'revision': 1, 'unit': unit, 'text': text,
             'attachment_sha256': None if unit is None else sha(b'original attachment'),
             'title': 'Supplied title', 'locator': None if unit is None else 'page 1',
             'extraction_state': 'partial'}
    return dict(value, **overrides)


def citation(source, quote):
    value = {key: source[key] for key in contract.EVIDENCE_KEYS}
    start = source['text'].encode().index(quote.encode())
    return dict(value, quote=quote, start_utf8=start, end_utf8=start + len(quote.encode()))


def request():
    note = part()
    unit = part(0, 'Extracted é 😀 original unit text.')
    second_record = part(record_id=OTHER_RECORD, extraction_state='unavailable', text='Second record note.')
    other_snapshot = part(evidence_id=OTHER_SNAPSHOT, snapshot_digest=sha(b'older complete snapshot'),
                          text='Older explicit source note.')
    history_citation = citation(other_snapshot, 'Older explicit source')
    history = {'run_id': RUN, 'request_sha256': sha(b'original prior request'),
               'question': 'Prior question?', 'answer': 'Prior answer.', 'citations': [history_citation]}
    history['output_sha256'] = contract.output_digest({'text': history['answer'], 'citations': history['citations']})
    return {'schema_version': 2, 'text': 'Answer from original supplied evidence.',
            'public_history': [history], 'evidence': [note, unit, second_record, other_snapshot], 'migration': None}


def structured(request):
    return {'text': 'Original sourced answer. 中文',
            'citations': [citation(request['evidence'][0], '中文 passage'),
                          citation(request['evidence'][1], 'é 😀 original')]}


def metadata(raw, obj):
    return {'version': 2, 'executionID': RUN, 'threadID': JOB, 'sequence': 0,
            'parentRunID': None, 'parentFingerprint': None, 'startsAlternatePath': False,
            'model': MODEL, 'format': 'tisra.codex.v2', 'requestDigest': sha(raw), 'requestBytes': len(raw),
            'maximumResponseBytes': 262144, 'maximumOutputTokens': None, 'maximumTextBytes': 32768,
            'evidence': contract.snapshot_bindings(obj)}


def result(raw, request):
    model = {'source': 'thread_start_confirmed_identifier', 'confirmed_identifier': MODEL,
             'adapter_binary_sha256': sha(b'pinned adapter'), 'protocol_version': '0.159.0',
             'control_contract_sha256': sha(b'pinned sourced v2 controls'), 'backend_weights_revision': None}
    body = structured(request)
    return {'schema_version': 2, 'request_format': contract.FORMATS[0], 'output_format': contract.FORMATS[1],
            'history_version': contract.FORMATS[2], 'owner': 'tisra', 'job_id': JOB, 'run_id': RUN,
            'request_sha256': sha(raw), 'provider_input_sha256': sha(raw), 'epoch': 1, 'auth_epoch': 'first-grant',
            'provider': 'codex_app_server', 'model': MODEL, 'model_fingerprint': contract.model_fingerprint(model),
            'model_evidence': model,
            'native': {'thread_id': 'ack-thread', 'turn_id': 'ack-turn', 'terminal': 'completed', 'interrupt': 'not_requested'},
            **body, 'output_sha256': contract.output_digest(body),
            'reviewed_evidence_bindings': contract.reviewed_bindings(request),
            'usage': {'tokens': None, 'cost': None}, 'token_hard_cap_supported': False}


class CodexSourcedContractTests(unittest.TestCase):
    def setUp(self):
        self.request = request()
        self.raw = encode(self.request)
        self.body = structured(self.request)
        self.result = result(self.raw, self.request)
        self.args = {'request': {'payload_id': JOB, 'sha256': sha(self.raw), 'byte_count': len(self.raw)},
                     'max_output_bytes': 32768,
                     **{key: self.result[key] for key in contract.BINDING_KEYS if key != 'request_sha256'}}
        self.descriptor = metadata(self.raw, self.request)

    def assert_fault(self, code, action):
        with self.assertRaises(Fault) as caught:
            action()
        self.assertEqual(caught.exception.code, code)

    def test_frozen_json_schema_policy_and_pure_digest_match(self):
        path = Path(__file__).resolve().parents[1] / 'integrations/tisra/codex-native-sourced-v2.json'
        proposal = json.loads(path.read_bytes())
        self.assertEqual(proposal, contract.CONTRACT)
        self.assertEqual(contract.CONTRACT_SHA256, sha(encode(proposal)))
        self.assertEqual(proposal['generated_body']['provider_json_schema'], contract.OUTPUT_SCHEMA)
        self.assertEqual(set(proposal['result_envelope']['exact_keys']), set(self.result))
        self.assertEqual(contract.NAME, 'tisra.codex.research.v2')
        self.assertEqual(contract.LIMITS, {contract.REQUEST: 8192, contract.DESCRIPTOR: 32768, contract.RESPONSE: 262144})

    def test_constant_provider_schema_only_uses_supported_subset(self):
        allowed = {'type', 'properties', 'required', 'additionalProperties', 'items'}
        def check(schema):
            self.assertLessEqual(set(schema), allowed)
            if schema['type'] == 'object':
                self.assertIs(schema['additionalProperties'], False)
                self.assertEqual(set(schema['required']), set(schema['properties']))
                for value in schema['properties'].values():
                    check(value)
            elif schema['type'] == 'array':
                check(schema['items'])
        check(contract.OUTPUT_SCHEMA)
        unit = contract.OUTPUT_SCHEMA['properties']['citations']['items']['properties']['unit']
        self.assertEqual(unit, {'type': ['integer', 'null']})
        attachment = contract.OUTPUT_SCHEMA['properties']['citations']['items']['properties']['attachment_sha256']
        self.assertEqual(attachment, {'type': ['string', 'null']})

    def test_original_request_bytes_remain_unmodified_and_complete_limit_is_first(self):
        raw = json.dumps(self.request, ensure_ascii=False, indent=2).encode() + b'\n\t '
        args = dict(self.args, request=dict(self.args['request'], sha256=sha(raw), byte_count=len(raw)))
        self.assertEqual(contract.request_body(raw, args), self.request)
        self.assertNotEqual(raw, encode(self.request))
        padded = self.raw + b' ' * (8192 - len(self.raw))
        contract.request_body(padded)
        with patch('arl.codex_contract.strict_json', side_effect=AssertionError('overflow parsed')):
            self.assert_fault('codex_input_too_large', lambda: contract.request_body(padded + b' '))

    def test_many_parts_records_and_snapshots_have_ordered_flat_and_dedup_bindings(self):
        parsed = contract.request_body(self.raw, self.args)
        self.assertEqual([part['unit'] for part in parsed['evidence'][:2]], [None, 0])
        flat = contract.reviewed_bindings(parsed)
        self.assertEqual(len(flat), 4)
        self.assertIs(contract.reviewed_body(flat), flat)
        snapshots = contract.snapshot_bindings(parsed)
        self.assertEqual(snapshots, [{'evidenceID': SNAPSHOT, 'snapshotDigest': sha(b'original complete snapshot')},
                                    {'evidenceID': OTHER_SNAPSHOT, 'snapshotDigest': sha(b'older complete snapshot')}])
        self.assertEqual(contract.descriptor(encode(self.descriptor), self.args), self.descriptor)

    def test_duplicate_part_or_inconsistent_digest_revision_title_state_reject_entire_request(self):
        obj = copy.deepcopy(self.request)
        obj['evidence'].append(dict(obj['evidence'][0]))
        self.assert_fault('codex_request_invalid', lambda: contract.request_body(encode(obj)))
        for key, value in (('snapshot_digest', sha(b'other snapshot')), ('revision', 2),
                           ('title', 'different record title'), ('extraction_state', 'ready')):
            obj = copy.deepcopy(self.request)
            obj['evidence'][1][key] = value
            self.assert_fault('codex_request_invalid', lambda: contract.request_body(encode(obj)))

    def test_unit_revision_locator_extraction_types_and_bounds(self):
        for key, value in (('unit', True), ('unit', '0'), ('unit', -1), ('unit', 2000),
                           ('revision', 0), ('revision', True), ('revision', 1.0),
                           ('locator', None), ('locator', '界' * 67),
                           ('attachment_sha256', None), ('attachment_sha256', 'A' * 64),
                           ('extraction_state', 'unavailable'), ('extraction_state', 'failed')):
            obj = copy.deepcopy(self.request)
            obj['evidence'][1][key] = value
            self.assert_fault('codex_request_invalid', lambda: contract.request_body(encode(obj)))
        for key, value in (('locator', 'note has no locator'), ('extraction_state', 'pending'),
                           ('attachment_sha256', sha(b'not a note attachment')),
                           ('title', '界' * 342), ('record_id', 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA')):
            obj = copy.deepcopy(self.request)
            obj['evidence'][0][key] = value
            self.assert_fault('codex_request_invalid', lambda: contract.request_body(encode(obj)))
        obj = copy.deepcopy(self.request)
        obj['evidence'][0]['text'] = ''
        obj['public_history'] = []
        contract.request_body(encode(obj))

    def test_request_duplicate_unknown_missing_and_surrogate_keys_rejected(self):
        for raw in (b'\xff', self.raw.replace(b'"schema_version": 2', b'"schema_version": 2,"schema_version":2'),
                    self.raw.replace(b'"locator": "page 1"', b'"locator": "page 1","locator":"page 1"'),
                    self.raw.replace(b'"title": "Supplied title"', b'"title":"\\ud800"')):
            self.assert_fault('codex_request_invalid', lambda: contract.request_body(raw))
        for key in self.request:
            obj = copy.deepcopy(self.request)
            del obj[key]
            self.assert_fault('codex_request_invalid', lambda: contract.request_body(encode(obj)))
        for field in ('reasoning', 'tools', 'output_schema'):
            obj = dict(self.request, **{field: {}})
            self.assert_fault('codex_request_invalid', lambda: contract.request_body(encode(obj)))

    def test_descriptor_version_formats_null_token_cap_and_byte_bindings_are_exact(self):
        for key, value, code in (('version', 1, 'codex_request_invalid'), ('format', 'tisra.codex.v1', 'codex_request_invalid'),
                                  ('maximumOutputTokens', 0, 'codex_request_invalid'),
                                  ('executionID', JOB, 'descriptor_mismatch'),
                                  ('requestDigest', sha(b'other raw'), 'descriptor_mismatch'),
                                  ('requestBytes', len(self.raw) - 1, 'descriptor_mismatch'),
                                  ('maximumTextBytes', 1, 'descriptor_mismatch')):
            obj = dict(self.descriptor, **{key: value})
            self.assert_fault(code, lambda: contract.descriptor(encode(obj), self.args))
        raw = encode(self.descriptor)
        contract.descriptor(raw + b' ' * (32768 - len(raw)), self.args)
        self.assert_fault('codex_request_invalid', lambda: contract.descriptor(raw + b' ' * (32769 - len(raw)), self.args))

    def test_exact_unicode_quote_byte_ranges_and_generated_original_order_survive(self):
        raw = json.dumps(self.body, ensure_ascii=False, indent=2).encode() + b'\n'
        parsed = contract.structured_body(raw, self.request, 32768)
        self.assertEqual(parsed, self.body)
        for cite in parsed['citations']:
            source = next(part for part in self.request['evidence'] if part['unit'] == cite['unit'] and
                          part['record_id'] == cite['record_id'] and part['evidence_id'] == cite['evidence_id'])
            self.assertEqual(source['text'].encode()[cite['start_utf8']:cite['end_utf8']], cite['quote'].encode())
        self.assertEqual(parsed['citations'][0]['quote'], '中文 passage')
        self.assertEqual(parsed['citations'][1]['quote'], 'é 😀 original')

    def test_invalid_binding_and_range_reject_all_citations_without_filter_or_repair(self):
        for key, value in (('evidence_id', OTHER_SNAPSHOT), ('snapshot_digest', sha(b'wrong')),
                           ('attachment_sha256', sha(b'wrong attachment')),
                           ('record_id', OTHER_RECORD), ('revision', 2), ('unit', 1),
                           ('quote', '中文  passage'), ('quote', ''), ('start_utf8', True),
                           ('end_utf8', 1.0), ('start_utf8', -1), ('end_utf8', 8193),
                           ('start_utf8', 11), ('start_utf8', 13)):
            obj = copy.deepcopy(self.body)
            obj['citations'][0][key] = value
            self.assert_fault('codex_result_invalid', lambda: contract.structured_body(encode(obj), self.request))
        obj = copy.deepcopy(self.body)
        cite = obj['citations'][0]
        cite['start_utf8'] = cite['end_utf8']
        self.assert_fault('codex_result_invalid', lambda: contract.structured_body(encode(obj), self.request))

    def test_utf8_offsets_are_not_character_offsets_and_no_unicode_normalization_occurs(self):
        source = part(text='é 😀 cafe\u0301 final')
        req = dict(self.request, public_history=[], evidence=[source])
        body = {'text': 'Original answer', 'citations': [citation(source, '😀 cafe\u0301')]}
        contract.structured_body(encode(body), req)
        bad = copy.deepcopy(body)
        bad['citations'][0]['quote'] = '😀 café'
        self.assert_fault('codex_result_invalid', lambda: contract.structured_body(encode(bad), req))
        bad = copy.deepcopy(body)
        bad['citations'][0]['start_utf8'] = source['text'].index('😀')
        self.assert_fault('codex_result_invalid', lambda: contract.structured_body(encode(bad), req))
        bad = copy.deepcopy(body)
        bad['citations'][0]['end_utf8'] -= 1
        self.assert_fault('codex_result_invalid', lambda: contract.structured_body(encode(bad), req))

    def test_duplicate_tisra_identity_rejected_even_when_ranges_differ(self):
        source = part(text='quote quote')
        req = dict(self.request, public_history=[], evidence=[source])
        first = citation(source, 'quote')
        second = dict(first, start_utf8=6, end_utf8=11)
        body = {'text': 'Answer', 'citations': [first, second]}
        self.assert_fault('codex_result_invalid', lambda: contract.structured_body(encode(body), req))

    def test_zero_citations_supported_but_empty_or_whitespace_answer_rejected(self):
        body = {'text': 'Missing sources are visible.', 'citations': []}
        self.assertEqual(contract.structured_body(encode(body), self.request), body)
        for text in ('', ' \n\t ', '\u3000'):
            self.assert_fault('codex_result_invalid', lambda: contract.structured_body(encode(dict(body, text=text)), self.request))
        for citations in (None, {}, [None] * 51):
            self.assert_fault('codex_result_invalid', lambda: contract.structured_body(encode(dict(body, citations=citations)), self.request))
        self.assert_fault('codex_result_invalid', lambda: contract.structured_body(encode(dict(body, tool_call={})), self.request))

    def test_generated_complete_raw_and_canonical_limits_reject_without_truncation(self):
        empty = {'text': 'Answer', 'citations': []}
        raw = encode(empty)
        contract.structured_body(raw + b' ' * (32768 - len(raw)), self.request)
        self.assert_fault('codex_result_invalid', lambda: contract.structured_body(raw + b' ' * (32769 - len(raw)), self.request))
        body = {'text': 'x' * (32768 - len(encode({'text': '', 'citations': []}))), 'citations': []}
        self.assertEqual(len(encode(body)), 32768)
        contract.structured_body(encode(body), self.request)
        body['text'] += 'x'
        compact = json.dumps(body, separators=(',', ':')).encode()
        self.assertLessEqual(len(compact), 32768)
        self.assert_fault('codex_result_invalid', lambda: contract.structured_body(compact, self.request))
        self.assert_fault('codex_result_invalid', lambda: contract.structured_body(encode(empty), self.request, 1))

    def test_history_output_digest_binds_answer_and_original_citation_ranges(self):
        contract.request_body(self.raw)
        for key, value in (('answer', 'Altered prior answer.'), ('output_sha256', sha(b'answer text only'))):
            obj = copy.deepcopy(self.request)
            obj['public_history'][0][key] = value
            self.assert_fault('codex_request_invalid', lambda: contract.request_body(encode(obj)))
        obj = copy.deepcopy(self.request)
        obj['evidence'].pop()
        self.assert_fault('codex_request_invalid', lambda: contract.request_body(encode(obj)))
        obj = copy.deepcopy(self.request)
        obj['public_history'][0]['citations'][0]['start_utf8'] += 1
        self.assert_fault('codex_request_invalid', lambda: contract.request_body(encode(obj)))

    def test_migration_rejects_private_replay_and_all_nullable_fields_remain_required(self):
        migration = {'from_request_format': contract.REQUEST, 'from_output_format': contract.RESPONSE,
                     'from_history_version': contract.FORMATS[2], 'parent_run_id': RUN,
                     'parent_fingerprint': sha(b'original pin'), 'source_request_sha256': sha(b'original bytes'),
                     'encrypted_reasoning_replayed': False}
        contract.request_body(encode(dict(self.request, migration=migration)))
        for value in (True, 0, None):
            invalid = dict(migration, encrypted_reasoning_replayed=value)
            self.assert_fault('codex_request_invalid', lambda: contract.request_body(encode(dict(self.request, migration=invalid))))
        for field in ('unit', 'locator', 'attachment_sha256'):
            obj = copy.deepcopy(self.request)
            del obj['evidence'][0][field]
            self.assert_fault('codex_request_invalid', lambda: contract.request_body(encode(obj)))

    def test_reviewed_metadata_flat_uniqueness_and_consistency_without_plaintext(self):
        reviewed = contract.reviewed_bindings(self.request)
        for change in ({'unit': True}, {'revision': 0}, {'snapshot_digest': sha(b'other snapshot')},
                       {'revision': 2}, {'quote': 'private quote'}, {'text': 'private text'}):
            obj = copy.deepcopy(reviewed)
            obj[1].update(change)
            self.assert_fault('codex_result_invalid', lambda: contract.reviewed_body(obj))
        self.assert_fault('codex_result_invalid', lambda: contract.reviewed_body(reviewed + [reviewed[0]]))

    def test_extracted_parts_have_explicit_consistent_attachment_pins_and_citations_bind_them(self):
        obj = copy.deepcopy(self.request)
        other_unit = dict(obj['evidence'][1], unit=1)
        obj['evidence'].append(other_unit)
        contract.request_body(encode(obj))
        obj['evidence'][-1]['attachment_sha256'] = sha(b'changed attachment')
        self.assert_fault('codex_request_invalid', lambda: contract.request_body(encode(obj)))
        reviewed = contract.reviewed_bindings(obj)
        self.assert_fault('codex_result_invalid', lambda: contract.reviewed_body(reviewed))
        body = copy.deepcopy(self.body)
        body['citations'][1]['attachment_sha256'] = sha(b'changed attachment')
        self.assert_fault('codex_result_invalid', lambda: contract.structured_body(encode(body), self.request))
        body['citations'][1]['attachment_sha256'] = None
        self.assert_fault('codex_result_invalid', lambda: contract.structured_body(encode(body), self.request))

    def test_result_has_original_citations_and_output_pin_includes_all_reference_fields(self):
        raw = encode(self.result)
        binding = {key: self.result[key] for key in contract.BINDING_KEYS}
        parsed = contract.result_body(raw, self.args, binding=binding, native=self.result['native'],
                                      model_evidence=self.result['model_evidence'],
                                      reviewed_evidence=contract.reviewed_bindings(self.request), request=self.raw)
        self.assertEqual(parsed, self.result)
        self.assertEqual(parsed['citations'], self.body['citations'])
        self.assertEqual(parsed['output_sha256'], contract.output_digest(self.body))
        self.assertNotEqual(parsed['output_sha256'], sha(parsed['text'].encode()))
        obj = copy.deepcopy(self.result)
        obj['citations'][0]['end_utf8'] -= 1
        self.assert_fault('codex_result_invalid', lambda: contract.result_body(encode(obj), self.args))

    def test_metadata_validation_does_not_claim_source_quote_validation(self):
        obj = copy.deepcopy(self.result)
        obj['citations'][0]['quote'] = 'fake quotation'
        obj['output_sha256'] = contract.output_digest(obj)
        # Trusted source text is absent in this structural-only call.
        contract.result_body(encode(obj), self.args)
        self.assert_fault('codex_result_invalid', lambda: contract.result_body(encode(obj), self.args, request=self.request))
        obj['citations'][0]['record_id'] = JOB
        obj['output_sha256'] = contract.output_digest(obj)
        self.assert_fault('codex_result_invalid', lambda: contract.result_body(encode(obj), self.args))

    def test_result_reviewed_order_and_original_request_hash_are_bound(self):
        obj = copy.deepcopy(self.result)
        obj['reviewed_evidence_bindings'].reverse()
        self.assert_fault('codex_result_invalid', lambda: contract.result_body(encode(obj), self.args, request=self.request))
        self.assert_fault('codex_result_invalid', lambda: contract.result_body(encode(obj), self.args,
                          reviewed_evidence=contract.reviewed_bindings(self.request)))
        alternate_raw = self.raw + b' '
        self.assert_fault('codex_result_invalid', lambda: contract.result_body(encode(self.result), self.args, request=alternate_raw))

    def test_result_complete_envelope_limit_and_extra_missing_or_duplicate_fields(self):
        raw = encode(self.result)
        contract.result_body(raw + b' ' * (262144 - len(raw)), self.args, request=self.request)
        self.assert_fault('codex_result_invalid', lambda: contract.result_body(raw + b' ' * (262145 - len(raw)), self.args))
        for key in self.result:
            obj = dict(self.result)
            del obj[key]
            self.assert_fault('codex_result_invalid', lambda: contract.result_body(encode(obj), self.args))
        self.assert_fault('codex_result_invalid', lambda: contract.result_body(encode(dict(self.result, annotations=[])), self.args))
        duplicate = raw.replace(b'"schema_version": 2', b'"schema_version":2,"schema_version":2')
        self.assert_fault('codex_result_invalid', lambda: contract.result_body(duplicate, self.args))

    def test_native_model_grant_usage_and_format_checks_remain_strict(self):
        for key, value in (('schema_version', 1), ('output_format', 'tisra.codex.result.v1'),
                           ('epoch', True), ('provider_input_sha256', sha(b'changed request')),
                           ('model_fingerprint', sha(b'fictional weights')), ('auth_epoch', 'later-grant'),
                           ('usage', {'tokens': 0, 'cost': None}), ('token_hard_cap_supported', True)):
            obj = dict(self.result, **{key: value})
            self.assert_fault('codex_result_invalid', lambda: contract.result_body(encode(obj), self.args, request=self.request))
        for target, key, value in (('native', 'terminal', 'interrupted'), ('native', 'interrupt', 'acknowledged'),
                                    ('native', 'turn_id', None), ('model_evidence', 'backend_weights_revision', 'invented'),
                                    ('model_evidence', 'control_contract_sha256', sha(b'changed controls'))):
            obj = copy.deepcopy(self.result)
            obj[target][key] = value
            self.assert_fault('codex_result_invalid', lambda: contract.result_body(encode(obj), self.args, request=self.request))


if __name__ == '__main__':
    unittest.main()
