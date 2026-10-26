"""Frozen synthetic consumer evidence through the inactive outer protocol.

Callbacks below recognize only pinned fixture bytes. They are transport doubles,
not a production inner validator, Ledger reference lookup or journal observation.
"""
import hashlib
import json
from pathlib import Path
import unittest

from arl.contracts import Fault, encode
from arl.tisra_capture_contract import (
    CONTRACT_SHA256, CaptureCodec, CaptureContext, CommitConfirmation,
    MAX_REQUEST_BYTES, MAX_RESULT_BYTES, replay_decision, validate_outer,
    validate_request, validated_result,
)

ROOT = Path(__file__).resolve().parents[1] / 'integrations/tisra'
PIN = 'f6a6618c280e78389cce1846f24613689ba4c166604597f93aafe9904cef3ce8'
CODEC = 'tisra.link-capture.inner.v1'
REQUEST_ID = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
LIBRARY_ID = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
PAYLOAD_ID = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'


class FrozenCaptureEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.manifest = json.loads((ROOT / 'capture-inner-manifest-v1.json').read_bytes())
        self.evidence = json.loads((ROOT / 'capture-inner-frozen-v1.json').read_bytes())
        self.cases = self.manifest['receipt_cases']
        self.directory = ROOT / 'capture-inner-v1'

    def params(self, raw):
        return {'schema_version': 1, 'capture_request_id': REQUEST_ID,
                'library_id': LIBRARY_ID, 'codec': CODEC,
                'consumer_schema_sha256': PIN,
                'payload': {'payload_id': PAYLOAD_ID,
                            'sha256': hashlib.sha256(raw).hexdigest(),
                            'byte_count': len(raw)}, 'declared_attribution': None}

    def context(self, **overrides):
        values = dict(writer_app='synthetic_fixture_app', participant_id='agent:test-peer',
                      actor_kind='agent', library_id=LIBRARY_ID, auth_epoch='synthetic_epoch',
                      codec=CODEC, consumer_schema_sha256=PIN)
        values.update(overrides)
        return CaptureContext(**values)

    def fixture_codec(self):
        permitted_requests = {(self.directory / case['request']).read_bytes()
                              for case in self.cases}
        permitted_results = {((self.directory / case['receipt']).read_bytes(),
                              (self.directory / case['request']).read_bytes(),
                              case['outer_state_candidate']) for case in self.cases}
        def request(raw):
            self.assertIn(raw, permitted_requests)
        def result(raw_result, raw_request, outer_state):
            self.assertIn((raw_result, raw_request, outer_state), permitted_results)
        return CaptureCodec(CODEC, PIN, request, result)

    def outer_receipt(self, binding, raw_result, state):
        receipt = {'schema_version': 1, **binding.wire(), 'state': state,
                   'commit': {'transaction_id': 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
                              'committed_at_ms': 1},
                   'result_ref': {'payload_id': PAYLOAD_ID,
                                  'sha256': hashlib.sha256(raw_result).hexdigest(),
                                  'byte_count': len(raw_result)}}
        # Test-only acknowledgement: no real writer or receipt journal is used.
        confirmation = CommitConfirmation(LIBRARY_ID, REQUEST_ID,
            receipt['commit']['transaction_id'], hashlib.sha256(encode(receipt)).hexdigest())
        return receipt, confirmation

    def test_frozen_manifest_and_exact_schema_bytes(self):
        self.assertEqual(self.manifest['codec'], CODEC)
        self.assertEqual(self.manifest['consumer_schema_sha256'], PIN)
        self.assertEqual(self.evidence['consumer_schema_sha256'], PIN)
        self.assertEqual(self.evidence['outer_metadata_sha256'], CONTRACT_SHA256)
        self.assertEqual(hashlib.sha256((ROOT / self.evidence['copied_manifest']).read_bytes()).hexdigest(),
                         self.evidence['copied_manifest_sha256'])
        for item in self.manifest['fixtures']:
            raw = (ROOT / item['path']).read_bytes()
            self.assertEqual(len(raw), item['bytes'], item['path'])
            self.assertEqual(hashlib.sha256(raw).hexdigest(), item['sha256'], item['path'])
        raw_schema = (ROOT / self.manifest['schema_file']).read_bytes()
        self.assertTrue(raw_schema.endswith(b'\n'))
        self.assertEqual(hashlib.sha256(raw_schema).hexdigest(), PIN)
        schema = json.loads(raw_schema)
        self.assertEqual(schema['x-codec'], CODEC)
        for ref in self.manifest['schema_entries'].values():
            self.assertTrue(ref.startswith('#/$defs/'))
            self.assertIn(ref[8:], schema['$defs'])
        self.assertIn('stock JSON Schema alone is insufficient',
                      schema['x-semantic-constraints']['wire']['x-keywords'])

    def test_consumer_pairs_fit_stricter_complete_byte_limits(self):
        self.assertEqual(len(self.cases), 8)
        for case in self.cases:
            self.assertLessEqual(len((self.directory / case['request']).read_bytes()), MAX_REQUEST_BYTES)
            self.assertLessEqual(len((self.directory / case['receipt']).read_bytes()), MAX_RESULT_BYTES)

    def test_frozen_pin_does_not_install_authority_or_default_validator(self):
        raw = (self.directory / 'metadata-request.json').read_bytes()
        for context, expected in ((self.context(), 'capture_disabled'),
                                  (self.context(active=True), 'capture_not_authorized'),
                                  (self.context(active=True, write_granted=True), 'capture_codec_unavailable')):
            with self.assertRaises(Fault) as result:
                validate_request(self.params(raw), raw, context)
            self.assertEqual(result.exception.code, expected)

    def test_all_pinned_receipt_cases_preserve_exact_bytes_with_doubles(self):
        for case in self.cases:
            with self.subTest(case=case['receipt']):
                raw = (self.directory / case['request']).read_bytes()
                result = (self.directory / case['receipt']).read_bytes()
                binding = validate_request(self.params(raw), raw,
                    self.context(active=True, write_granted=True), codec=self.fixture_codec())
                receipt, confirmation = self.outer_receipt(binding, result, case['outer_state_candidate'])
                self.assertEqual(validated_result(receipt, binding, result, raw,
                    codec=self.fixture_codec(), confirmation=confirmation), result)
                self.assertEqual(replay_decision(binding, binding, receipt,
                    confirmation=confirmation), 'cached_receipt')

    def test_partial_cannot_be_success_and_recovery_keeps_completed_ids(self):
        raw = (self.directory / 'partial-request.json').read_bytes()
        result = (self.directory / 'partial.receipt.json').read_bytes()
        binding = validate_outer(self.params(raw), raw, self.context(active=True, write_granted=True))
        for state in ('created', 'deduplicated'):
            receipt, confirmation = self.outer_receipt(binding, result, state)
            with self.assertRaises(Fault) as rejected:
                validated_result(receipt, binding, result, raw,
                    codec=self.fixture_codec(), confirmation=confirmation)
            self.assertEqual(rejected.exception.code, 'capture_inner_invalid')
        partial = json.loads(result)
        recovered = json.loads((self.directory / 'recovered.receipt.json').read_bytes())
        self.assertTrue(partial['failures'])
        self.assertFalse(recovered['failures'])
        for earlier, later in ((partial['source'], recovered['source']),
                               (partial['contributions'][0], recovered['contributions'][0])):
            for key in ('record_id', 'revision', 'content_hash', 'provenance_blob_hash',
                        'content_kind', 'body_state', 'writer', 'writer_trust'):
                self.assertEqual(earlier[key], later[key], key)

    def test_different_peer_dedup_retains_stored_first_writer(self):
        original = json.loads((self.directory / 'metadata-created.receipt.json').read_bytes())
        retry = json.loads((self.directory / 'peer-retry-request.json').read_bytes())
        duplicate = json.loads((self.directory / 'peer-deduplicated.receipt.json').read_bytes())
        self.assertNotEqual(retry['writer'], original['source']['writer'])
        self.assertEqual(retry['writer']['actor_kind'], 'human')
        self.assertEqual(original['source']['writer']['actor_kind'], 'agent')
        self.assertEqual(duplicate['source']['outcome'], 'unchanged')
        for key in ('record_id', 'revision', 'content_hash', 'provenance_blob_hash',
                    'writer', 'writer_trust'):
            self.assertEqual(duplicate['source'][key], original['source'][key], key)


if __name__ == '__main__':
    unittest.main()
