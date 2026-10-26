"""Pure contract tests: no native process, external inference or grant access."""
import copy
import json
from pathlib import Path
import unittest
from unittest.mock import patch

from arl.codex_contract import (BINDING_KEYS, DESCRIPTOR, FORMATS, LIMITS, NAME,
                                REQUEST, RESPONSE, descriptor, model_fingerprint,
                                native_body, request_body, result_body, reviewed_bindings)
from arl.contracts import Fault, encode
from arl.research import sha


RUN = '11111111-1111-4111-8111-111111111111'
JOB = '22222222-2222-4222-8222-222222222222'
EVIDENCE = '33333333-3333-4333-8333-333333333333'
RECORD = '44444444-4444-4444-8444-444444444444'
MODEL = 'synthetic-model'


def request():
    evidence = {'evidence_id': EVIDENCE, 'snapshot_digest': sha(b'source snapshot'),
                'record_id': RECORD, 'revision': 3, 'unit': None,
                'text': 'Synthetic evidence: exact quote. 中文 evidence.'}
    citation = {key: value for key, value in evidence.items() if key != 'text'}
    citation['quote'] = 'exact quote'
    return {'schema_version': 1, 'text': 'Summarize supplied evidence.',
            'public_history': [{'run_id': RUN, 'request_sha256': sha(b'prior request'),
                                'output_sha256': sha(b'prior answer'), 'question': 'Prior?',
                                'answer': 'Prior answer.', 'citations': [citation]}],
            'evidence': [evidence], 'migration': None}


def metadata(raw):
    return {'version': 1, 'executionID': RUN, 'threadID': JOB, 'sequence': 0,
            'parentRunID': None, 'parentFingerprint': None, 'startsAlternatePath': False,
            'model': MODEL, 'format': 'tisra.codex.v1', 'requestDigest': sha(raw),
            'requestBytes': len(raw), 'maximumResponseBytes': 262144,
            'maximumOutputTokens': None, 'maximumTextBytes': 32768,
            'evidence': [{'evidenceID': EVIDENCE, 'snapshotDigest': sha(b'source snapshot')}]}


def arguments(raw):
    return {'run_id': RUN, 'model': MODEL, 'max_output_bytes': 32768,
            'request': {'payload_id': JOB, 'sha256': sha(raw), 'byte_count': len(raw)}}


def result(raw):
    model = {'source': 'thread_start_confirmed_identifier', 'confirmed_identifier': MODEL,
             'adapter_binary_sha256': sha(b'pinned synthetic adapter'),
             'protocol_version': '0.159.0', 'control_contract_sha256': sha(b'pinned controls'),
             'backend_weights_revision': None}
    return {'schema_version': 1, 'request_format': FORMATS[0], 'output_format': FORMATS[1],
            'history_version': FORMATS[2], 'owner': 'tisra', 'job_id': JOB, 'run_id': RUN,
            'request_sha256': sha(raw), 'provider_input_sha256': sha(raw), 'epoch': 1,
            'auth_epoch': 'first-grant-epoch', 'provider': 'codex_app_server', 'model': MODEL,
            'model_fingerprint': model_fingerprint(model), 'model_evidence': model,
            'native': {'thread_id': 'acknowledged-thread', 'turn_id': 'acknowledged-turn',
                       'terminal': 'completed', 'interrupt': 'not_requested'},
            'text': 'Synthetic answer. 中文', 'output_sha256': sha('Synthetic answer. 中文'.encode()),
            'reviewed_evidence_bindings': reviewed_bindings(request()),
            'usage': {'tokens': None, 'cost': None}, 'token_hard_cap_supported': False}


class CodexContractTests(unittest.TestCase):
    def assert_fault(self, code, action):
        with self.assertRaises(Fault) as caught:
            action()
        self.assertEqual(caught.exception.code, code)

    def setUp(self):
        self.request = request()
        self.raw = encode(self.request)
        self.args = arguments(self.raw)
        self.metadata = metadata(self.raw)
        self.result = result(self.raw)
        self.args.update({key: self.result[key] for key in BINDING_KEYS if key != 'request_sha256'})

    def test_contract_names_limits_and_exact_shapes_match_frozen_proposal(self):
        path = Path(__file__).resolve().parents[1] / 'integrations/tisra/codex-native-proposal-v1.json'
        proposal = json.loads(path.read_bytes())
        self.assertEqual(NAME, 'tisra.codex.research.v1')
        self.assertEqual(FORMATS, tuple(proposal['formats'][key] for key in ('request', 'output', 'history')))
        self.assertEqual(LIMITS, {REQUEST: 8192, DESCRIPTOR: 32768, RESPONSE: 262144})
        self.assertEqual(set(self.request), set(proposal['request']['exact_keys']))
        self.assertEqual(set(self.result), set(proposal['result_envelope']['exact_keys']))
        self.assertEqual(BINDING_KEYS, tuple(proposal['receipt_binding']))

    def test_original_whitespace_key_order_and_unicode_are_not_rendered_or_mutated(self):
        raw = json.dumps(self.request, ensure_ascii=False, indent=2).encode() + b' \n\t'
        original = bytes(raw)
        parsed = request_body(raw, arguments(raw))
        self.assertEqual(parsed, self.request)
        self.assertEqual(raw, original)
        self.assertNotEqual(raw, encode(parsed))
        self.assertEqual(parsed['public_history'][0]['citations'][0]['quote'], 'exact quote')

    def test_complete_original_bytes_limit_is_checked_before_json_parser(self):
        raw = self.raw + b' ' * (8192 - len(self.raw))
        self.assertEqual(request_body(raw, arguments(raw)), self.request)
        with patch('arl.codex_contract.strict_json', side_effect=AssertionError('must not parse')):
            self.assert_fault('codex_input_too_large', lambda: request_body(raw + b' '))
            self.assert_fault('codex_input_too_large', lambda: request_body(b'!' * 8193))

    def test_invalid_encoding_duplicates_nonfinite_and_unpaired_surrogates_are_rejected(self):
        for raw in (b'\xff', b'{"schema_version":1,"schema_version":1}',
                    self.raw.replace(b'"revision": 3', b'"revision": NaN'),
                    self.raw.replace(b'"revision": 3', b'"revision": Infinity'),
                    self.raw.replace(b'"revision": 3', b'"revision": 1e999'),
                    self.raw.replace(b'"text": "Summarize supplied evidence."', b'"text": "\\ud800"'),
                    self.raw.replace(b'"unit": null', b'"unit": "\\udfff"'),
                    self.raw.replace(b'"schema_version":', b'"\\ud800":'),
                    self.raw.replace(b'"revision": 3', b'"revision": 3, "revision": 3')):
            with self.subTest(raw=raw):
                self.assert_fault('codex_request_invalid', lambda: request_body(raw))
        self.assertEqual(request_body(self.raw.replace(b'"text": "Summarize supplied evidence."',
                                                       b'"text": "\\ud83d\\ude00"'))['text'], '😀')

    def test_request_missing_extra_keys_or_wrong_container_types_are_rejected(self):
        for change in ({'tools': []}, {'text': ''}, {'schema_version': True},
                       {'schema_version': 1.0}, {'public_history': {}}, {'evidence': False},
                       {'evidence': [None] * 101}, {'migration': {}}, {'text': None}):
            with self.subTest(change=change):
                obj = dict(self.request, **change)
                self.assert_fault('codex_request_invalid', lambda: request_body(encode(obj)))
        for key in self.request:
            obj = dict(self.request)
            del obj[key]
            self.assert_fault('codex_request_invalid', lambda: request_body(encode(obj)))

    def test_utf8_byte_limits_apply_to_units_and_quotes(self):
        obj = copy.deepcopy(self.request)
        obj['evidence'][0]['unit'] = obj['public_history'][0]['citations'][0]['unit'] = '界' * 66
        request_body(encode(obj))
        obj['evidence'][0]['unit'] = obj['public_history'][0]['citations'][0]['unit'] = '界' * 67
        self.assert_fault('codex_request_invalid', lambda: request_body(encode(obj)))
        obj = copy.deepcopy(self.request)
        obj['evidence'][0]['text'] = 'é' * 512
        obj['public_history'][0]['citations'][0]['quote'] = 'é' * 512
        request_body(encode(obj))
        obj['evidence'][0]['text'] += 'é'
        obj['public_history'][0]['citations'][0]['quote'] += 'é'
        self.assert_fault('codex_request_invalid', lambda: request_body(encode(obj)))

    def test_citations_match_every_snapshot_binding_and_exact_quote_substring(self):
        for key, value in (('evidence_id', JOB), ('snapshot_digest', sha(b'other snapshot')),
                           ('record_id', JOB), ('revision', 4), ('unit', 'other unit'),
                           ('quote', 'Exact Quote'), ('quote', ''), ('quote', 'absent quote')):
            with self.subTest(key=key, value=value):
                obj = copy.deepcopy(self.request)
                obj['public_history'][0]['citations'][0][key] = value
                self.assert_fault('codex_request_invalid', lambda: request_body(encode(obj)))
        obj = copy.deepcopy(self.request)
        obj['evidence'] = []
        self.assert_fault('codex_request_invalid', lambda: request_body(encode(obj)))

    def test_evidence_ids_are_unique_and_revisions_uuids_digests_are_strict(self):
        obj = copy.deepcopy(self.request)
        obj['evidence'].append(dict(obj['evidence'][0]))
        self.assert_fault('codex_request_invalid', lambda: request_body(encode(obj)))
        for key, value in (('revision', True), ('revision', -1), ('revision', 2147483648),
                           ('revision', 3.0), ('evidence_id', EVIDENCE.replace('-', '')),
                           ('record_id', 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA'),
                           ('snapshot_digest', 'A' * 64), ('snapshot_digest', '0' * 63)):
            obj = copy.deepcopy(self.request)
            obj['evidence'][0][key] = value
            self.assert_fault('codex_request_invalid', lambda: request_body(encode(obj)))

    def test_history_nested_exact_keys_and_item_count(self):
        obj = copy.deepcopy(self.request)
        minimal = dict(obj['public_history'][0], question='', answer='', citations=[])
        obj['public_history'] = [minimal] * 20
        request_body(encode(obj))
        obj['public_history'].append(minimal)
        self.assert_fault('codex_request_invalid', lambda: request_body(encode(obj)))
        obj = copy.deepcopy(self.request)
        obj['public_history'][0]['citations'] = [None] * 51
        self.assert_fault('codex_request_invalid', lambda: request_body(encode(obj)))
        for path in ('history', 'evidence', 'citation'):
            obj = copy.deepcopy(self.request)
            target = {'history': obj['public_history'][0], 'evidence': obj['evidence'][0],
                      'citation': obj['public_history'][0]['citations'][0]}[path]
            target['encrypted_content'] = 'not supported'
            self.assert_fault('codex_request_invalid', lambda: request_body(encode(obj)))

    def test_migration_is_explicit_public_binding_and_never_encrypted_reasoning_replay(self):
        migration = {'from_request_format': 'openai.responses.request.v1',
                     'from_output_format': 'openai.responses.envelope.v1',
                     'from_history_version': 'openai.responses.history.v1',
                     'parent_run_id': RUN, 'parent_fingerprint': sha(b'original parent pins'),
                     'source_request_sha256': sha(b'original source'), 'encrypted_reasoning_replayed': False}
        obj = dict(self.request, migration=migration)
        self.assertEqual(request_body(encode(obj))['migration'], migration)
        for key, value in (('encrypted_reasoning_replayed', True), ('encrypted_reasoning_replayed', 0),
                           ('parent_fingerprint', None), ('source_request_sha256', 'not a digest'),
                           ('from_request_format', ''), ('from_history_version', '界' * 67)):
            obj = dict(self.request, migration=dict(migration, **{key: value}))
            self.assert_fault('codex_request_invalid', lambda: request_body(encode(obj)))
        for key in migration:
            value = dict(migration)
            del value[key]
            self.assert_fault('codex_request_invalid', lambda: request_body(encode(dict(self.request, migration=value))))

    def test_request_raw_digest_and_complete_byte_count_bind_to_submit_reference(self):
        request_body(self.raw, self.args)
        for value in (dict(self.args['request'], sha256=sha(b'altered')),
                      dict(self.args['request'], byte_count=len(self.raw) - 1),
                      dict(self.args['request'], byte_count=float(len(self.raw)))):
            self.assert_fault('descriptor_mismatch', lambda: request_body(self.raw, dict(self.args, request=value)))

    def test_descriptor_is_separate_exact_native_format_with_explicit_null_tokens(self):
        self.assertEqual(descriptor(encode(self.metadata), self.args), self.metadata)
        for change in ({'format': 'openai.responses.v1'}, {'maximumOutputTokens': 1},
                       {'maximumOutputTokens': False}, {'maximumTextBytes': 0},
                       {'maximumTextBytes': 32769}, {'maximumResponseBytes': 262145},
                       {'maximumResponseBytes': True}, {'startsAlternatePath': 1},
                       {'sequence': True}, {'requestBytes': 8193}, {'endpoint': 'forbidden'}):
            obj = dict(self.metadata, **change)
            self.assert_fault('codex_request_invalid', lambda: descriptor(encode(obj), self.args))
        for key in ('maximumOutputTokens', 'parentRunID', 'parentFingerprint', 'maximumTextBytes'):
            obj = dict(self.metadata)
            del obj[key]
            self.assert_fault('codex_request_invalid', lambda: descriptor(encode(obj), self.args))

    def test_descriptor_bindings_match_run_model_request_bytes_and_output_byte_cap(self):
        for key, value in (('executionID', JOB), ('model', 'other-model'),
                           ('requestDigest', sha(b'other raw')), ('requestBytes', len(self.raw) - 1),
                           ('maximumTextBytes', 1)):
            obj = dict(self.metadata, **{key: value})
            self.assert_fault('descriptor_mismatch', lambda: descriptor(encode(obj), self.args))
        raw = encode(self.metadata)
        descriptor(raw + b' ' * (32768 - len(raw)), self.args)
        self.assert_fault('codex_request_invalid', lambda: descriptor(raw + b' ' * (32769 - len(raw)), self.args))

    def test_descriptor_nested_evidence_does_not_invent_or_duplicate_ids(self):
        for item in ({'evidenceID': EVIDENCE, 'snapshotDigest': sha(b'snapshot'), 'recordID': RECORD},
                     {'evidenceID': EVIDENCE}, {'evidenceID': True, 'snapshotDigest': sha(b'snapshot')}):
            obj = dict(self.metadata, evidence=[item])
            self.assert_fault('codex_request_invalid', lambda: descriptor(encode(obj), self.args))
        obj = dict(self.metadata, evidence=self.metadata['evidence'] * 2)
        self.assert_fault('codex_request_invalid', lambda: descriptor(encode(obj), self.args))

    def test_result_is_byte_hash_bound_and_matches_all_original_pins(self):
        binding = {key: self.result[key] for key in BINDING_KEYS}
        raw = json.dumps(self.result, ensure_ascii=False, indent=2).encode() + b'\n'
        parsed = result_body(raw, self.args, binding=binding, native=self.result['native'],
                             model_evidence=self.result['model_evidence'],
                             reviewed_evidence=self.result['reviewed_evidence_bindings'])
        self.assertEqual(parsed, self.result)
        self.assertEqual(raw[-1:], b'\n')
        self.assertEqual(parsed['request_sha256'], sha(self.raw))
        self.assertEqual(parsed['output_sha256'], sha(parsed['text'].encode()))

    def test_result_complete_envelope_and_utf8_text_byte_limits(self):
        obj = dict(self.result, text='é' * 16384, output_sha256=sha(('é' * 16384).encode()))
        result_body(encode(obj), self.args)
        obj['text'] += 'é'
        obj['output_sha256'] = sha(obj['text'].encode())
        self.assert_fault('codex_result_invalid', lambda: result_body(encode(obj), self.args))
        raw = encode(self.result)
        result_body(raw + b' ' * (262144 - len(raw)), self.args)
        self.assert_fault('codex_result_invalid', lambda: result_body(raw + b' ' * (262145 - len(raw)), self.args))
        self.assert_fault('codex_result_invalid', lambda: result_body(raw, dict(self.args, max_output_bytes=1)))

    def test_success_result_requires_matching_completed_native_evidence(self):
        for key, value in (('thread_id', None), ('turn_id', ''), ('thread_id', 'x' * 101),
                           ('terminal', 'unknown'), ('terminal', 'interrupted'),
                           ('interrupt', 'acknowledged'), ('interrupt', 'sent')):
            obj = copy.deepcopy(self.result)
            obj['native'][key] = value
            self.assert_fault('codex_result_invalid', lambda: result_body(encode(obj), self.args))
        foreign = dict(self.result['native'], turn_id='foreign-turn')
        self.assert_fault('codex_result_invalid', lambda: result_body(encode(self.result), self.args, native=foreign))
        pending = {'thread_id': None, 'turn_id': None, 'terminal': 'unknown', 'interrupt': 'acknowledged'}
        self.assertIs(native_body(pending), pending)
        self.assert_fault('codex_result_invalid', lambda: native_body(pending, successful=True))

    def test_model_fingerprint_uses_adapter_protocol_controls_and_confirmed_model(self):
        evidence = self.result['model_evidence']
        basis = {key: evidence[key] for key in ('adapter_binary_sha256', 'protocol_version',
                                              'control_contract_sha256', 'confirmed_identifier')}
        self.assertEqual(model_fingerprint(evidence), sha(encode(basis)))
        for key, value in (('source', 'configured_model_only'), ('confirmed_identifier', 'other-model'),
                           ('protocol_version', '0.159.1'), ('backend_weights_revision', 'invented'),
                           ('adapter_binary_sha256', sha(b'changed binary')),
                           ('control_contract_sha256', sha(b'changed controls'))):
            obj = copy.deepcopy(self.result)
            obj['model_evidence'][key] = value
            self.assert_fault('codex_result_invalid', lambda: result_body(encode(obj), self.args))

    def test_no_invented_usage_tokens_cost_citations_or_weight_revision(self):
        for change in ({'usage': {'tokens': 0, 'cost': None}}, {'usage': {'tokens': None, 'cost': 0}},
                       {'usage': {'tokens': None}}, {'usage': {'tokens': None, 'cost': None, 'output_tokens': 1}},
                       {'token_hard_cap_supported': True}, {'token_hard_cap_supported': 0},
                       {'citations': []}, {'weights_revision': None}):
            obj = dict(self.result, **change)
            self.assert_fault('codex_result_invalid', lambda: result_body(encode(obj), self.args))
        for key in self.result:
            obj = dict(self.result)
            del obj[key]
            self.assert_fault('codex_result_invalid', lambda: result_body(encode(obj), self.args))

    def test_result_binding_hash_format_epoch_and_fingerprint_drift_fail_closed(self):
        for key, value in (('request_sha256', sha(b'changed')), ('provider_input_sha256', sha(b'changed')),
                           ('output_sha256', sha(b'changed')), ('provider', 'responses_fixture'),
                           ('output_format', 'openai.responses.envelope.v1'), ('auth_epoch', 'later-epoch'),
                           ('epoch', True), ('model_fingerprint', 'test-double-revision'),
                           ('model_fingerprint', sha(b'fictional fingerprint')), ('run_id', JOB)):
            obj = dict(self.result, **{key: value})
            self.assert_fault('codex_result_invalid', lambda: result_body(encode(obj), self.args))
        binding = {key: self.result[key] for key in BINDING_KEYS}
        for key, value in (('owner', 'other-owner'), ('job_id', RUN), ('epoch', True), ('auth_epoch', 'changed')):
            expected = dict(binding, **{key: value})
            self.assert_fault('codex_result_invalid', lambda: result_body(encode(self.result), self.args, binding=expected))

    def test_reviewed_evidence_is_ordered_original_binding_and_not_generated_citation(self):
        expected = reviewed_bindings(self.request)
        result_body(encode(self.result), self.args, reviewed_evidence=expected)
        self.assertEqual(set(expected[0]), {'evidence_id', 'snapshot_digest', 'record_id', 'revision', 'unit'})
        altered = copy.deepcopy(expected)
        altered[0]['revision'] = True
        self.assert_fault('codex_result_invalid', lambda: result_body(encode(self.result), self.args, reviewed_evidence=altered))
        second = dict(expected[0], evidence_id=JOB)
        obj = dict(self.result, reviewed_evidence_bindings=expected + [second])
        result_body(encode(obj), self.args, reviewed_evidence=expected + [second])
        self.assert_fault('codex_result_invalid', lambda: result_body(encode(obj), self.args, reviewed_evidence=[second] + expected))
        for reviewed in ([dict(expected[0], quote='invented')], expected * 2):
            obj = dict(self.result, reviewed_evidence_bindings=reviewed)
            self.assert_fault('codex_result_invalid', lambda: result_body(encode(obj), self.args))

    def test_result_invalid_utf8_duplicate_keys_and_surrogates_are_rejected(self):
        raw = encode(self.result)
        for malformed in (b'\xff', raw.replace(b'"epoch": 1', b'"epoch": 1, "epoch": 1'),
                          raw.replace(b'"cost": null', b'"cost": null, "cost": null'),
                          raw.replace(b'"acknowledged-thread"', b'"\\ud800"')):
            self.assert_fault('codex_result_invalid', lambda: result_body(malformed, self.args))


if __name__ == '__main__':
    unittest.main()
