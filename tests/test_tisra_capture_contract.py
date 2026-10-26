"""Pure outer-boundary fixtures; no Tisra writes, URLs, registrations or models."""
import copy
import hashlib
import json
import unittest
from dataclasses import replace

from arl.contracts import Fault, encode
from arl.tisra_capture_contract import (
    CaptureCodec, CaptureContext, CommitConfirmation, MAX_REQUEST_BYTES, MAX_OUTER_BYTES,
    parse_outer, receipt_body, replay_decision, submission_body, validate_outer,
    validate_request, validated_result,
)

REQUEST_ID = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
LIBRARY_ID = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
PARTICIPANT_ID = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
PAYLOAD_ID = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'
CODEC_PIN = 'e' * 64


class CaptureContractTests(unittest.TestCase):
    def setUp(self):
        # Opaque synthetic inner bytes deliberately make no source codec claim.
        self.raw = b'{"fixture":"source codec remains pending"}'
        self.params = {
            'schema_version': 1, 'capture_request_id': REQUEST_ID,
            'library_id': LIBRARY_ID, 'codec': 'synthetic.t3.fixture.v1',
            'consumer_schema_sha256': CODEC_PIN,
            'payload': {'payload_id': PAYLOAD_ID,
                        'sha256': hashlib.sha256(self.raw).hexdigest(),
                        'byte_count': len(self.raw)},
            'declared_attribution': None,
        }
        self.context = CaptureContext('test_registered_app', PARTICIPANT_ID, 'agent',
                                      LIBRARY_ID, 'synthetic_grant_epoch',
                                      'synthetic.t3.fixture.v1', CODEC_PIN,
                                      active=True, write_granted=True)

    def assert_fault(self, code, callback):
        with self.assertRaises(Fault) as result:
            callback()
        self.assertEqual(result.exception.code, code)

    def binding(self, params=None, raw=None, context=None):
        return validate_outer(self.params if params is None else params,
                              self.raw if raw is None else raw,
                              self.context if context is None else context)

    def receipt(self, binding=None, state='created'):
        binding = binding or self.binding()
        return {'schema_version': 1, **binding.wire(), 'state': state,
                'commit': None if state == 'needs_review' else {
                    'transaction_id': 'ffffffff-ffff-4fff-8fff-ffffffffffff',
                    'committed_at_ms': 1000},
                'result_ref': None if state == 'needs_review' else {
                    'payload_id': PAYLOAD_ID, 'sha256': 'a' * 64, 'byte_count': 100}}

    def confirmation(self, receipt):
        return CommitConfirmation(receipt['library_id'], receipt['capture_request_id'],
                                  receipt['commit']['transaction_id'],
                                  hashlib.sha256(encode(receipt)).hexdigest())

    def codec(self):
        def check_request(raw):
            self.assertEqual(raw, self.raw)
        def check_result(result, request, outer_state):
            self.assertEqual(result, b'{"fixture":"committed result"}')
            self.assertEqual(request, self.raw)
            self.assertEqual(outer_state, 'created')
        return CaptureCodec('synthetic.t3.fixture.v1', CODEC_PIN, check_request, check_result)

    def test_exact_payload_binding_and_ref_preserve_bytes(self):
        binding = self.binding()
        self.assertEqual(binding.request_bytes, len(self.raw))
        self.assertEqual(binding.request_sha256, hashlib.sha256(self.raw).hexdigest())
        self.assertEqual(binding.participant_id, PARTICIPANT_ID)
        for body in (self.raw + b' ', b'x' * len(self.raw)):
            self.assert_fault('capture_payload_mismatch', lambda: self.binding(raw=body))

    def test_unknown_root_and_ref_fields_cannot_claim_authority(self):
        for key in ('writer_app', 'participant_id', 'actor_kind', 'role', 'grant',
                    'callback_url', 'file_path', 'fetch_url', 'write', 'retry'):
            params = {**self.params, key: 'administrator'}
            self.assert_fault('capture_invalid_arguments', lambda: self.binding(params=params))
        params = copy.deepcopy(self.params)
        params['payload']['path'] = '/not/a/writer/path'
        self.assert_fault('capture_invalid_arguments', lambda: self.binding(params=params))

    def test_declared_cli_role_does_not_change_registered_writer(self):
        for role in ('human', 'admin', 'root', 'Mio', 'another_agent'):
            params = {**self.params, 'declared_attribution': {
                'role': role, 'display_name': 'untrusted CLI label'}}
            binding = self.binding(params=params)
            self.assertEqual(binding.writer_app, self.context.writer_app)
            self.assertEqual(binding.participant_id, PARTICIPANT_ID)
            self.assertEqual(binding.actor_kind, 'agent')
        context = replace(self.context, write_granted=False)
        self.assert_fault('capture_not_authorized', lambda: self.binding(params=params, context=context))

    def test_human_and_agent_peers_require_independent_grant(self):
        for kind in ('human', 'agent'):
            self.assertEqual(self.binding(context=replace(self.context, actor_kind=kind)).actor_kind, kind)
            self.assert_fault('capture_not_authorized', lambda: self.binding(
                context=replace(self.context, actor_kind=kind, write_granted=False)))
        self.assert_fault('capture_context_unverified', lambda: self.binding(context=self.context.__dict__))

    def test_registered_participant_is_existing_opaque_id_not_required_uuid(self):
        for participant in ('agent:mio', 'human:personal-owner'):
            self.assertEqual(self.binding(context=replace(self.context,
                participant_id=participant)).participant_id, participant)
        for participant in ('', 'claimed user', 'agent:mio\n', '人' * 43):
            self.assert_fault('capture_invalid_arguments', lambda: self.binding(
                context=replace(self.context, participant_id=participant)))

    def test_disabled_missing_and_unsupported_codec_fail_closed(self):
        self.assert_fault('capture_disabled', lambda: self.binding(context=replace(self.context, active=False)))
        self.assert_fault('capture_codec_unavailable', lambda: self.binding(
            context=replace(self.context, codec=None, consumer_schema_sha256=None)))
        for key, value in (('codec', 'not_reviewed.v9'), ('consumer_schema_sha256', 'f' * 64)):
            self.assert_fault('capture_codec_unsupported', lambda: self.binding(params={**self.params, key: value}))

    def test_explicit_library_scope_cannot_be_selected_by_role(self):
        params = {**self.params, 'library_id': REQUEST_ID,
                  'declared_attribution': {'role': 'owner', 'display_name': None}}
        self.assert_fault('capture_library_not_authorized', lambda: self.binding(params=params))

    def test_default_host_configuration_denies_before_any_codec_callback(self):
        context = CaptureContext('test_registered_app', 'agent:mio', 'agent',
                                 LIBRARY_ID, 'synthetic_grant_epoch')
        called = []
        codec = replace(self.codec(), validate_request=lambda raw: called.append(raw))
        self.assert_fault('capture_disabled', lambda: validate_request(
            self.params, self.raw, context, codec=codec))
        self.assert_fault('capture_not_authorized', lambda: validate_request(
            self.params, self.raw, replace(context, active=True), codec=codec))
        self.assert_fault('capture_context_unverified', lambda: validate_request(
            self.params, self.raw, replace(self.context, active=1), codec=codec))
        self.assertEqual(called, [])

    def test_excess_input_and_noninteger_counts_rejected_without_trimming(self):
        params = copy.deepcopy(self.params)
        params['payload']['byte_count'] = MAX_REQUEST_BYTES + 1
        self.assert_fault('capture_invalid_arguments', lambda: self.binding(params=params))
        self.assert_fault('capture_request_too_large', lambda: self.binding(raw=b'x' * (MAX_REQUEST_BYTES + 1)))
        for value in (True, 1.0, 0, -1):
            params['payload']['byte_count'] = value
            self.assert_fault('capture_invalid_arguments', lambda: self.binding(params=params))
        self.assert_fault('capture_outer_too_large', lambda: parse_outer(b' ' * (MAX_OUTER_BYTES + 1)))

    def test_duplicate_keys_nonfinite_and_invalid_unicode_rejected(self):
        for raw in (b'{"schema_version":1,"schema_version":1}', b'{"x":NaN}', b'{"x":1e999}',
                    b'{"x":"\xff"}', b'{"x":"\\ud800"}'):
            self.assert_fault('capture_invalid_arguments', lambda: parse_outer(raw))
        self.assertEqual(submission_body(encode(self.params)), self.params)
        for key, value in (('schema_version', True), ('capture_request_id', REQUEST_ID.upper())):
            self.assert_fault('capture_invalid_arguments', lambda: self.binding(params={**self.params, key: value}))

    def test_idempotent_receipt_is_reused_without_new_effect(self):
        binding = self.binding()
        receipt = self.receipt(binding)
        # Different immutable payload handle, same exact bytes and metadata.
        params = copy.deepcopy(self.params)
        params['payload']['payload_id'] = REQUEST_ID
        current = self.binding(params=params)
        self.assertEqual(current, binding)
        self.assertEqual(replay_decision(current, binding, receipt,
                                        confirmation=self.confirmation(receipt)), 'cached_receipt')
        self.assertEqual(receipt['state'], 'created')

    def test_changed_bytes_metadata_or_actor_conflict_never_retry(self):
        previous = self.binding()
        raw = self.raw + b' '
        params = copy.deepcopy(self.params)
        params['payload'].update(sha256=hashlib.sha256(raw).hexdigest(), byte_count=len(raw))
        changed = [self.binding(params=params, raw=raw),
                   self.binding(params={**self.params, 'declared_attribution': {
                       'role': 'admin', 'display_name': None}}),
                   self.binding(context=replace(self.context, participant_id=REQUEST_ID))]
        for current in changed:
            self.assert_fault('capture_idempotency_conflict', lambda: replay_decision(current, previous))

    def test_lost_or_uncertain_commit_requires_review_not_another_write(self):
        binding = self.binding()
        self.assertEqual(replay_decision(binding), 'first_attempt')
        self.assertEqual(replay_decision(binding, attempt_recorded=True), 'needs_review')
        self.assertEqual(replay_decision(binding, binding), 'needs_review')
        self.assertEqual(replay_decision(binding, binding, self.receipt(binding, 'needs_review')), 'needs_review')

    def test_success_requires_pinned_binding_and_commit_metadata(self):
        binding = self.binding()
        for state in ('created', 'deduplicated'):
            receipt = self.receipt(binding, state)
            self.assertEqual(receipt_body(encode(receipt), binding,
                                          confirmation=self.confirmation(receipt)), receipt)
            bad = {**receipt, 'commit': None}
            self.assert_fault('capture_invalid_arguments', lambda: receipt_body(bad, binding))
        for key, value in (('writer_app', 'claimed_by_cli'), ('auth_epoch', 'new_epoch'),
                           ('writing_participant', {'participant_id': REQUEST_ID, 'actor_kind': 'human'})):
            bad = {**self.receipt(binding), key: value}
            self.assert_fault('capture_receipt_mismatch', lambda: receipt_body(bad, binding))
        bad = {**self.receipt(binding, 'needs_review'), 'result_ref': self.receipt(binding)['result_ref']}
        self.assert_fault('capture_receipt_mismatch', lambda: receipt_body(bad, binding))
        bad = {**self.receipt(binding), 'state': ['created']}
        self.assert_fault('capture_receipt_mismatch', lambda: receipt_body(bad, binding))

    def test_partial_outcome_is_retained_without_retry_only_after_confirmation(self):
        binding = self.binding()
        receipt = self.receipt(binding, 'partial')
        self.assert_fault('capture_commit_unconfirmed', lambda: receipt_body(receipt, binding))
        confirmed = self.confirmation(receipt)
        self.assertEqual(receipt_body(receipt, binding, confirmation=confirmed)['state'], 'partial')
        self.assertEqual(replay_decision(binding, binding, receipt,
                                        confirmation=confirmed), 'cached_receipt')
        self.assertEqual(receipt['state'], 'partial')

    def test_no_matching_frozen_strict_codec_means_no_inner_acceptance(self):
        self.assert_fault('capture_codec_unavailable', lambda: validate_request(
            self.params, self.raw, self.context))
        self.assertEqual(validate_request(self.params, self.raw, self.context,
                                          codec=self.codec()), self.binding())
        codec = replace(self.codec(), consumer_schema_sha256='a' * 64)
        self.assert_fault('capture_codec_unsupported', lambda: validate_request(
            self.params, self.raw, self.context, codec=codec))
        # A callback returning normalized/replaced bytes cannot become a writer plan.
        codec = replace(self.codec(), validate_request=lambda raw: b'transformed')
        self.assert_fault('capture_inner_invalid', lambda: validate_request(
            self.params, self.raw, self.context, codec=codec))

    def test_claimed_commit_without_trusted_confirmation_is_not_action_evidence(self):
        binding = self.binding()
        receipt = self.receipt(binding)
        self.assert_fault('capture_commit_unconfirmed', lambda: receipt_body(receipt, binding))
        self.assert_fault('capture_commit_unconfirmed', lambda: replay_decision(binding, binding, receipt))
        confirmation = replace(self.confirmation(receipt), library_id=REQUEST_ID)
        self.assert_fault('capture_commit_unconfirmed', lambda: receipt_body(
            receipt, binding, confirmation=confirmation))

    def test_result_needs_exact_original_bytes_and_pinned_consumer_validator(self):
        binding = self.binding()
        raw_result = b'{"fixture":"committed result"}'
        receipt = self.receipt(binding)
        receipt['result_ref'].update(sha256=hashlib.sha256(raw_result).hexdigest(), byte_count=len(raw_result))
        confirmation = self.confirmation(receipt)
        self.assertEqual(validated_result(receipt, binding, raw_result, self.raw,
                                          codec=self.codec(), confirmation=confirmation), raw_result)
        self.assert_fault('capture_payload_mismatch', lambda: validated_result(
            receipt, binding, raw_result + b' ', self.raw,
            codec=self.codec(), confirmation=confirmation))
        self.assert_fault('capture_payload_mismatch', lambda: validated_result(
            receipt, binding, raw_result, self.raw + b' ',
            codec=self.codec(), confirmation=confirmation))

    def test_pinned_result_validator_rejects_success_classification_for_partial(self):
        # This synthetic classification fixture does not freeze T3's codec or
        # prescribe how its saved/unchanged/version outcomes must be mapped.
        binding = self.binding()
        raw_result = b'{"fixture_expected_state":"partial","failures":[{"index":0}]}'
        observed = []
        def check_result(result, request, outer_state):
            self.assertEqual(request, self.raw)
            observed.append(outer_state)
            fixture = json.loads(result)
            if outer_state != fixture['fixture_expected_state']:
                raise ValueError('outer state does not match complete inner result')
        codec = replace(self.codec(), validate_result=check_result)
        for state in ('created', 'deduplicated', 'partial'):
            receipt = self.receipt(binding, state)
            receipt['result_ref'].update(sha256=hashlib.sha256(raw_result).hexdigest(),
                                         byte_count=len(raw_result))
            validate = lambda: validated_result(receipt, binding, raw_result,
                self.raw, codec=codec, confirmation=self.confirmation(receipt))
            if state == 'partial':
                self.assertEqual(validate(), raw_result)
            else:
                self.assert_fault('capture_inner_invalid', validate)
        self.assertEqual(observed, ['created', 'deduplicated', 'partial'])


if __name__ == '__main__':
    unittest.main()
