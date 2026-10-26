"""Codex SDK tests use in-memory RPC doubles only: no runtime or provider."""
import base64
import copy
import json
import threading
import unittest
import uuid

from arl import codex_contract as contract
from arl.codex_research_client import CodexResearchClient, PayloadCleanupPending
from arl.contracts import Fault, encode
from arl.research import CHUNK, READ_CHUNK, sha

MODEL = 'configured-model'
MODEL_EVIDENCE = {'source': 'thread_start_confirmed_identifier',
    'confirmed_identifier': MODEL, 'adapter_binary_sha256': 'a' * 64,
    'protocol_version': '0.159.0', 'control_contract_sha256': 'b' * 64,
    'backend_weights_revision': None}
FINGERPRINT = contract.model_fingerprint(MODEL_EVIDENCE)


def new_id():
    return str(uuid.uuid4())


def body(evidence=None):
    return encode({'schema_version': 1, 'text': 'A synthetic question',
                   'public_history': [], 'evidence': evidence or [], 'migration': None})


def evidence():
    return {'evidence_id': new_id(), 'snapshot_digest': 'c' * 64, 'record_id': new_id(),
            'revision': 7, 'unit': None, 'text': 'PRIVATE SYNTHETIC EVIDENCE TEXT'}


def descriptor(raw, selected=None):
    return {'version': 1, 'executionID': new_id(), 'threadID': new_id(), 'sequence': 0,
        'parentRunID': None, 'parentFingerprint': None, 'startsAlternatePath': False,
        'model': MODEL, 'format': 'tisra.codex.v1', 'requestDigest': sha(raw),
        'requestBytes': len(raw), 'maximumResponseBytes': 262144,
        'maximumOutputTokens': None, 'maximumTextBytes': 32768,
        'evidence': [{'evidenceID': item['evidence_id'],
                      'snapshotDigest': item['snapshot_digest']} for item in (selected or [])]}


def capabilities():
    return {'schema_version': 1, 'tool': contract.NAME,
        'formats': dict(zip(('request', 'output', 'history'), contract.FORMATS)),
        'renderer_version': 'tisra.codex.raw-json.v1', 'contract_sha256': 'd' * 64,
        'provider': contract.PROVIDER, 'provider_evidence': 'test_double',
        'models': {MODEL: FINGERPRINT},
        'model_evidence_basis': 'pinned_adapter_binary_protocol_controls_confirmed_identifier',
        'backend_weights_revision': None, 'max_request_bytes': 8192,
        'max_descriptor_bytes': 32768, 'max_response_bytes': 262144,
        'max_output_bytes': 32768, 'max_output_tokens': None,
        'token_hard_cap_supported': False, 'cost_hard_cap_supported': False,
        'max_deadline_ms': 30000, 'max_provider_turns': 1, 'automatic_retries': 0,
        'structured_generated_citations': False, 'request_frame_bytes': 16384,
        'response_frame_bytes': 65536}


class RPCDouble:
    app = 'tisra'

    def __init__(self):
        self.calls = []; self.payloads = {}; self.receipt = None
        self.before = None; self.after = None; self.capability_value = capabilities()

    def rpc(self, method, params=None):
        self.calls.append((method, copy.deepcopy(params)))
        if self.before:
            self.before(method, params)
        result = self.dispatch(method, params)
        if self.after:
            result = self.after(method, params, result)
        return copy.deepcopy(result)

    def dispatch(self, method, params):
        if not method.startswith('codex.'):
            raise AssertionError('Native SDK leaked generic scope')
        method = method[len('codex.'):]
        if method == 'research.capabilities.v1':
            self.assert_empty(params)
            return self.capability_value
        if method == 'payload.begin.v1':
            assert params['purpose'] in {contract.REQUEST, contract.DESCRIPTOR}
            pid = new_id()
            self.payloads[pid] = {'begin': copy.deepcopy(params), 'data': bytearray(), 'revoked': False}
            return {'schema_version': 1, 'payload_id': pid, 'expires_at_ms': 1000, 'chunk_bytes': CHUNK}
        if method == 'payload.write.v1':
            payload = self.payloads[params['payload_id']]
            data = base64.b64decode(params['data_base64'])
            assert sha(data) == params['sha256']
            offset = params['index'] * CHUNK
            if len(payload['data']) == offset:
                payload['data'].extend(data)
            else:
                assert bytes(payload['data'][offset:offset + len(data)]) == data
            return {'schema_version': 1, 'accepted_index': params['index']}
        if method == 'payload.seal.v1':
            data = self.payloads[params['payload_id']]['data']
            assert sha(data) == params['sha256'] and len(data) == params['byte_count']
            return dict(schema_version=1, **params)
        if method == 'payload.revoke.v1':
            self.payloads[params['payload_id']]['revoked'] = True
            self.payloads[params['payload_id']]['data'].clear()
            return {'schema_version': 1, 'revoked': True, 'external_stop': 'unknown'}
        if method == 'research.submit.v1':
            self.receipt = {'schema_version': 1, 'job_id': new_id(), 'owner': self.app,
                'run_id': params['run_id'], 'request_sha256': params['request']['sha256'],
                'epoch': params['epoch'], 'auth_epoch': 'first-auth-epoch', 'state': 'queued',
                **{key: params[key] for key in ('provider', 'model', 'model_fingerprint',
                    'request_format', 'output_format', 'history_version')},
                'result_ref': None, 'error_code': None, 'cancel_requested': False,
                'external_stop': 'not_started', 'native': {'thread_id': None, 'turn_id': None,
                    'terminal': 'not_started', 'interrupt': 'not_requested'}}
            return self.receipt
        if method == 'research.status.v1':
            assert params == {key: self.receipt[key] for key in ('job_id', 'run_id', 'request_sha256', 'epoch')}
            return self.receipt
        if method == 'research.cancel.v1':
            self.receipt.update(state='cancelled', result_ref=None, cancel_requested=True,
                                error_code='cancelled')
            return self.receipt
        if method == 'payload.read.v1':
            payload = self.payloads[params['payload_id']]
            data = bytes(payload['data']); offset = params['offset']
            chunk = data[offset:offset + params['limit']]
            assert 1 <= params['limit'] <= READ_CHUNK
            return {'schema_version': 1, 'payload_id': params['payload_id'], 'sha256': sha(data),
                'byte_count': len(data), 'offset': offset,
                'data_base64': base64.b64encode(chunk).decode(), 'eof': offset + len(chunk) == len(data)}
        raise AssertionError(method)

    @staticmethod
    def assert_empty(params):
        assert params == {}

    def complete(self, args, selected=None, output='Synthetic answer'):
        self.receipt.update(state='succeeded', external_stop='completed', native={
            'thread_id': 'acknowledged-thread', 'turn_id': 'acknowledged-turn',
            'terminal': 'completed', 'interrupt': 'not_requested'})
        value = {'schema_version': 1,
            **{key: self.receipt[key] for key in contract.BINDING_KEYS},
            'provider_input_sha256': self.receipt['request_sha256'],
            'model_evidence': copy.deepcopy(MODEL_EVIDENCE),
            'native': copy.deepcopy(self.receipt['native']), 'text': output,
            'output_sha256': sha(output.encode()),
            'reviewed_evidence_bindings': [{key: item[key] for key in contract.EVIDENCE_KEYS}
                                         for item in (selected or [])],
            'usage': {'tokens': None, 'cost': None}, 'token_hard_cap_supported': False}
        self.install_result(value)
        return value

    def install_result(self, value):
        raw = value if type(value) is bytes else encode(value)
        pid = new_id()
        self.payloads[pid] = {'data': bytearray(raw), 'revoked': False}
        self.receipt['result_ref'] = {'payload_id': pid, 'sha256': sha(raw), 'byte_count': len(raw)}
        return raw


class CodexResearchClientTests(unittest.TestCase):
    def setUp(self):
        self.rpc = RPCDouble(); self.sdk = CodexResearchClient(self.rpc)

    def fault(self, code, action):
        with self.assertRaises(Fault) as caught:
            action()
        self.assertEqual(caught.exception.code, code)

    def submit(self, selected=None, raw=None, metadata=None, **kwargs):
        raw = raw if raw is not None else body(selected)
        metadata = metadata if metadata is not None else descriptor(raw, selected)
        options = {'epoch': 0, 'provider': contract.PROVIDER, 'model_fingerprint': FINGERPRINT}
        options.update(kwargs)
        return self.sdk.submit(raw, metadata, **options)

    def count(self, name):
        return sum(method == 'codex.' + name for method, _ in self.rpc.calls)

    def assert_revoked(self, count):
        self.assertEqual(len(self.rpc.payloads), count)
        self.assertTrue(all(item['revoked'] and not item['data'] for item in self.rpc.payloads.values()))

    def test_no_rpc_on_construction_and_strict_truthful_capabilities(self):
        self.assertEqual(self.rpc.calls, [])
        self.assertEqual(self.sdk.name, 'tisra.codex.research.v1')
        self.assertEqual(self.sdk.capabilities(), capabilities())
        patches = [{'provider_evidence': 'upstream_api'}, {'max_output_tokens': 1},
            {'max_provider_turns': True}, {'backend_weights_revision': 'invented'},
            {'token_hard_cap_supported': 0}, {'max_request_bytes': 8192.0},
            {'extra': 1}, {'models': {MODEL: 'not-a-digest'}}]
        for patch in patches:
            with self.subTest(patch=patch):
                self.rpc.capability_value = dict(capabilities(), **patch)
                self.fault('invalid_response', self.sdk.capabilities)
        self.rpc.capability_value = capabilities(); self.rpc.capability_value.pop('max_output_tokens')
        self.fault('invalid_response', self.sdk.capabilities)

    def test_submit_preserves_original_bytes_separate_descriptor_and_native_observer_scope(self):
        selected = [evidence()]
        raw = b'  ' + body(selected) + b'\n'; metadata = descriptor(raw, selected); saved = []
        receipt, args = self.submit(selected, raw, metadata, on_payload_created=saved.append)
        self.assertEqual(bytes(self.rpc.payloads[args['request']['payload_id']]['data']), raw)
        self.assertEqual(bytes(self.rpc.payloads[args['descriptor']['payload_id']]['data']), encode(metadata))
        self.assertEqual([item['purpose'] for item in saved], [contract.REQUEST, contract.DESCRIPTOR])
        self.assertEqual(saved[0]['sha256'], sha(raw)); self.assertEqual(saved[0]['owner'], 'tisra')
        self.assertIsNone(args['max_output_tokens']); self.assertEqual(args['max_output_bytes'], 32768)
        self.assertEqual(args['deadline_ms'], 30000); self.assertEqual(receipt['auth_epoch'], 'first-auth-epoch')
        self.assertTrue(all(method.startswith('codex.') for method, _ in self.rpc.calls))

    def test_overflow_and_malformed_inputs_rejected_before_any_rpc(self):
        raw = body(); good = descriptor(raw)
        invalid = [(b' ' * (8193 - len(raw)) + raw, None, {}, 'codex_input_too_large'),
            (b'{"schema_version":1,"schema_version":1}', None, {}, 'codex_request_invalid'),
            (raw, dict(good, maximumOutputTokens=10), {}, 'codex_request_invalid'),
            (raw, dict(good, maximumTextBytes=127), {}, 'invalid_arguments'),
            (raw, dict(good, maximumTextBytes=True), {}, 'invalid_arguments'),
            (raw, dict(good, maximumResponseBytes=262145), {}, 'codex_request_invalid'),
            (raw, dict(good, model='a' * 33000), {}, 'invalid_arguments'),
            (raw, good, {'deadline_ms': 30001}, 'invalid_arguments'),
            (raw, good, {'deadline_ms': True}, 'invalid_arguments'),
            (raw, good, {'priority': 'unknown'}, 'invalid_arguments')]
        for data, metadata, kwargs, code in invalid:
            with self.subTest(code=code, kwargs=kwargs):
                self.fault(code, lambda: self.submit(raw=data, metadata=metadata, **kwargs))
                self.assertEqual(self.rpc.calls, [])
        self.fault('invalid_arguments', lambda: self.submit(raw=raw, metadata=good, model_fingerprint='changed'))

    def test_descriptor_evidence_must_match_input_in_original_order(self):
        selected = [evidence(), evidence()]; raw = body(selected)
        metadata = descriptor(raw, list(reversed(selected)))
        self.fault('descriptor_mismatch', lambda: self.submit(selected, raw, metadata))
        self.assertEqual(self.rpc.calls, [])

    def test_direct_request_upload_overflow_has_explicit_code_and_zero_rpc(self):
        self.fault('codex_input_too_large', lambda: self.sdk.upload(
            b'x' * 8193, contract.REQUEST, new_id(), 0))
        self.assertEqual(self.rpc.calls, [])

    def test_cancel_on_begin_records_native_id_then_revokes_before_write(self):
        flag = [False]; saved = []
        def persist(record):
            saved.append(record); flag[0] = True
        self.fault('cancelled', lambda: self.submit(cancelled=lambda: flag[0], on_payload_created=persist))
        self.assert_revoked(1); self.assertEqual(self.count('payload.write.v1'), 0)
        self.assertEqual(saved[0]['purpose'], contract.REQUEST)

    def test_lost_submit_ack_is_never_retried_and_known_inputs_revoked(self):
        def lose(method, params, result):
            if method == 'codex.research.submit.v1':
                raise Fault('disconnected')
            return result
        self.rpc.after = lose
        self.fault('disconnected', self.submit)
        self.assertEqual(self.count('research.submit.v1'), 1); self.assert_revoked(2)

    def test_lost_begin_ack_has_no_retry_or_guessed_cleanup(self):
        self.rpc.before = lambda method, params: (_ for _ in ()).throw(Fault('disconnected'))
        self.fault('disconnected', self.submit)
        self.assertEqual(self.count('payload.begin.v1'), 1)
        self.assertEqual(self.count('payload.revoke.v1'), 0)

    def test_existing_idempotent_write_retry_preserved(self):
        failed = [False]
        def lose(method, params, result):
            if method == 'codex.payload.write.v1' and not failed[0]:
                failed[0] = True; raise Fault('disconnected')
            return result
        self.rpc.after = lose; self.submit()
        writes = [params for method, params in self.rpc.calls if method == 'codex.payload.write.v1']
        self.assertEqual(writes[0], writes[1]); self.assertEqual(len(writes), 3)

    def test_cancel_during_write_disables_retry_and_revokes(self):
        flag = [False]
        def lose(method, params, result):
            if method == 'codex.payload.write.v1':
                flag[0] = True; raise Fault('disconnected')
            return result
        self.rpc.after = lose
        self.fault('cancelled', lambda: self.submit(cancelled=lambda: flag[0]))
        self.assertEqual(self.count('payload.write.v1'), 1); self.assert_revoked(1)

    def test_bad_second_begin_ack_and_observer_failure_cleanup(self):
        def bad(method, params, result):
            if method == 'codex.payload.begin.v1' and self.count('payload.begin.v1') == 2:
                return dict(result, chunk_bytes=1)
            return result
        self.rpc.after = bad
        self.fault('invalid_response', self.submit)
        self.assert_revoked(2); self.assertEqual(self.count('research.submit.v1'), 0)
        self.setUp()
        def fail(record):
            raise RuntimeError('synthetic persistence failure')
        with self.assertRaises(RuntimeError):
            self.submit(on_payload_created=fail)
        self.assert_revoked(1); self.assertEqual(self.count('payload.write.v1'), 0)

    def test_cleanup_failure_keeps_opaque_ids_for_explicit_recovery(self):
        ids = []
        def fail(method, params, result):
            if method == 'codex.payload.begin.v1':
                ids.append(result['payload_id'])
            if method == 'codex.research.submit.v1':
                raise Fault('disconnected')
            return result
        def reject(method, params):
            if method == 'codex.payload.revoke.v1' and params['payload_id'] == ids[0]:
                raise Fault('disconnected')
        self.rpc.after = fail; self.rpc.before = reject
        with self.assertRaises(PayloadCleanupPending) as caught:
            self.submit()
        self.assertEqual(caught.exception.payload_ids, (ids[0],))
        self.assertEqual(self.count('payload.revoke.v1'), 2)
        self.rpc.after = None; self.rpc.before = None
        self.sdk.cleanup_payloads(caught.exception.payload_ids)
        self.assert_revoked(2)

    def test_receipt_exact_types_and_native_consistency(self):
        receipt, args = self.submit()
        bad = [{'schema_version': True}, {'epoch': True}, {'job_id': receipt['job_id'].upper()},
            {'auth_epoch': ''}, {'auth_epoch': '\ud800'}, {'extra': None},
            {'native': dict(receipt['native'], extra=None)},
            {'native': dict(receipt['native'], thread_id='unacknowledged')},
            {'native': dict(receipt['native'], terminal='completed')},
            {'external_stop': 'unknown'}, {'state': 'succeeded'},
            {'result_ref': {'payload_id': new_id(), 'sha256': 'a' * 64, 'byte_count': 2}}]
        for patch in bad:
            with self.subTest(patch=patch):
                self.fault('research_receipt_mismatch', lambda: self.sdk.check(dict(receipt, **patch), args))
        missing = copy.deepcopy(receipt); missing['native'].pop('turn_id')
        self.fault('research_receipt_mismatch', lambda: self.sdk.check(missing, args))

    def test_first_auth_and_original_params_never_drift(self):
        receipt, args = self.submit()
        self.rpc.receipt['auth_epoch'] = 'different'
        self.fault('research_receipt_mismatch', lambda: self.sdk.status(receipt, args))
        self.fault('research_receipt_mismatch', lambda: self.sdk.cancel(receipt, args))
        self.fault('research_receipt_mismatch', lambda: self.sdk.status(dict(receipt, auth_epoch='different'), args))
        for patch in [{'deadline_ms': 29999}, {'max_output_bytes': 1024}, {'priority': 'background'}]:
            with self.subTest(patch=patch):
                count = len(self.rpc.calls)
                self.fault('research_receipt_mismatch', lambda: self.sdk.status(receipt, dict(args, **patch)))
                self.assertEqual(len(self.rpc.calls), count)

    def test_external_stop_must_match_independent_native_terminal_for_all_states(self):
        receipt, args = self.submit()
        for state in ('queued', 'running', 'failed', 'cancelled', 'needs_unlock', 'needs_review'):
            with self.subTest(state=state):
                malformed = dict(receipt, state=state, external_stop='completed')
                if state not in {'queued', 'running'}:
                    malformed.update(error_code='synthetic_failure')
                if state == 'cancelled':
                    malformed['cancel_requested'] = True
                fresh = CodexResearchClient(self.rpc)
                self.fault('research_receipt_mismatch', lambda: fresh.check(malformed, args))
                self.assertEqual(fresh._auth_pins, {})
        malformed = dict(receipt, state='cancelled', cancel_requested=True, error_code='cancelled',
            external_stop='interrupted', native=dict(receipt['native'], terminal='unknown'))
        self.fault('research_receipt_mismatch', lambda: self.sdk.check(malformed, args))

    def test_concurrent_first_checks_pin_only_one_epoch(self):
        receipt, args = self.submit(); fresh = CodexResearchClient(self.rpc)
        barrier = threading.Barrier(2); accepted = []; rejected = []
        def run(epoch):
            barrier.wait()
            try:
                fresh.check(dict(receipt, auth_epoch=epoch), args); accepted.append(epoch)
            except Fault as error:
                rejected.append(error.code)
        threads = [threading.Thread(target=run, args=(value,)) for value in ('one', 'two')]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(2); self.assertFalse(thread.is_alive())
        self.assertEqual(len(accepted), 1); self.assertEqual(rejected, ['research_receipt_mismatch'])

    def test_native_ids_terminal_and_interrupt_do_not_regress(self):
        receipt, args = self.submit()
        self.rpc.receipt.update(state='running', external_stop='unknown', native={
            'thread_id': 'thread', 'turn_id': 'turn', 'terminal': 'unknown', 'interrupt': 'not_requested'})
        running = self.sdk.status(receipt, args)
        # The first accepted receipt remains a usable immutable status handle.
        self.assertEqual(self.sdk.status(receipt, args), running)
        for patch in [{'thread_id': None}, {'thread_id': 'other'}, {'turn_id': None},
                      {'turn_id': 'other'}, {'terminal': 'not_started'}]:
            with self.subTest(patch=patch):
                bad = dict(running, native=dict(running['native'], **patch))
                self.fault('research_receipt_mismatch', lambda: self.sdk.check(bad, args))
        stopped = dict(running, state='cancelled', error_code='cancelled', cancel_requested=True,
            external_stop='interrupted', native=dict(running['native'], terminal='interrupted', interrupt='acknowledged'))
        self.sdk.check(stopped, args)
        for patch in [{'terminal': 'unknown'}, {'terminal': 'completed'}, {'interrupt': 'sent'},
                      {'interrupt': 'unknown'}, {'interrupt': 'not_requested'}]:
            with self.subTest(patch=patch):
                self.fault('research_receipt_mismatch', lambda: self.sdk.check(
                    dict(stopped, native=dict(stopped['native'], **patch)), args))

    def test_cancel_gate_closes_even_when_ack_lost_and_restore_cannot_revive_it(self):
        receipt, args = self.submit(); raw = self.sdk.durable_record(receipt, args)
        def lose(method, params, result):
            if method == 'codex.research.cancel.v1':
                raise Fault('disconnected')
            return result
        self.rpc.after = lose
        self.fault('disconnected', lambda: self.sdk.cancel(receipt, args))
        self.sdk.restore_submission(raw, sha(raw))
        self.rpc.after = None
        self.rpc.receipt = copy.deepcopy(receipt); self.rpc.complete(args)
        self.fault('research_receipt_mismatch', lambda: self.sdk.read_response(receipt, args))

    def test_completed_success_cancel_can_return_needs_review_without_native_regression(self):
        receipt, args = self.submit(); self.rpc.complete(args)
        succeeded = self.sdk.status(receipt, args)
        def invalidated(method, params, result):
            if method == 'codex.research.cancel.v1':
                self.rpc.receipt['state'] = 'needs_review'
                return self.rpc.receipt
            return result
        self.rpc.after = invalidated
        cancelled = self.sdk.cancel(receipt, args)
        self.assertEqual(cancelled['state'], 'needs_review')
        self.assertTrue(cancelled['cancel_requested']); self.assertIsNone(cancelled['result_ref'])
        self.assertEqual(cancelled['native'], succeeded['native'])
        self.assertEqual(cancelled['external_stop'], 'completed')
        self.fault('research_not_completed', lambda: self.sdk.read_response(receipt, args))
        self.rpc.after = None; self.rpc.receipt = succeeded
        self.fault('research_receipt_mismatch', lambda: self.sdk.status(receipt, args))

    def test_completed_status_grant_or_revoke_invalidation_closes_gate(self):
        for error_code in ('research_grant_revoked', 'payload_revoked'):
            with self.subTest(error_code=error_code):
                self.setUp(); receipt, args = self.submit(); self.rpc.complete(args)
                succeeded = self.sdk.status(receipt, args)
                # A transition without cancellation evidence is not invalidation.
                malformed = dict(succeeded, state='needs_review', result_ref=None,
                                 error_code=error_code, cancel_requested=False)
                self.fault('research_receipt_mismatch', lambda: self.sdk.check(malformed, args))
                self.rpc.receipt.update(state='needs_review', result_ref=None,
                                        error_code=error_code, cancel_requested=True)
                invalidated = self.sdk.status(receipt, args)
                self.assertEqual(invalidated['native'], succeeded['native'])
                self.assertEqual(invalidated['state'], 'needs_review')
                self.assertTrue(self.sdk._submissions[self.sdk._key(receipt)]['gate_closed'])
                self.rpc.receipt = succeeded
                self.fault('research_receipt_mismatch', lambda: self.sdk.status(receipt, args))

    def test_result_read_checks_envelope_chunks_and_final_status(self):
        selected = [evidence()]; receipt, args = self.submit(selected)
        value = self.rpc.complete(args, selected, output='x' * 32768)
        result = self.sdk.read_response(receipt, args)
        self.assertEqual(result, encode(value)); self.assertEqual(self.count('payload.read.v1'), 2)
        self.assertEqual(self.count('research.status.v1'), 2)

    def test_chunk_eof_offset_types_and_base64_are_strict(self):
        for patch in [{'eof': False}, {'eof': 1}, {'offset': True}, {'byte_count': True},
                      {'schema_version': True}, {'extra': 1}, {'data_base64': '!'}]:
            with self.subTest(patch=patch):
                self.setUp(); receipt, args = self.submit(); self.rpc.complete(args)
                self.rpc.after = lambda method, params, result: dict(result, **patch) if method == 'codex.payload.read.v1' else result
                with self.assertRaises(Fault):
                    self.sdk.read_response(receipt, args)
        self.setUp(); receipt, args = self.submit(); self.rpc.complete(args)
        self.rpc.receipt['result_ref']['sha256'] = 'f' * 64
        def matching_header(method, params, result):
            return dict(result, sha256='f' * 64) if method == 'codex.payload.read.v1' else result
        self.rpc.after = matching_header
        self.fault('payload_hash_mismatch', lambda: self.sdk.read_response(receipt, args))

    def test_result_binding_model_evidence_and_reviewed_input_cannot_be_invented(self):
        selected = [evidence(), evidence()]
        mutations = [lambda value: value.update(owner='other'),
            lambda value: value.update(auth_epoch='different'),
            lambda value: value.update(provider_input_sha256='0' * 64),
            lambda value: value.update(output_sha256='0' * 64),
            lambda value: value.update(request_format='wrong'),
            lambda value: value['native'].update(turn_id='other'),
            lambda value: value['model_evidence'].update(adapter_binary_sha256='0' * 64),
            lambda value: value['model_evidence'].update(backend_weights_revision='invented'),
            lambda value: value['usage'].update(tokens=3),
            lambda value: value.update(token_hard_cap_supported=True),
            lambda value: value['reviewed_evidence_bindings'].reverse(),
            lambda value: value['reviewed_evidence_bindings'][0].update(revision=8)]
        for mutate in mutations:
            with self.subTest(mutate=mutate):
                self.setUp(); receipt, args = self.submit(selected)
                value = self.rpc.complete(args, selected); mutate(value); self.rpc.install_result(value)
                self.fault('codex_result_invalid', lambda: self.sdk.read_response(receipt, args))

    def test_cancel_between_chunks_and_final_status_invalidates_result(self):
        receipt, args = self.submit(); self.rpc.complete(args, output='x' * 32768)
        def cancelled(method, params, result):
            if method == 'codex.payload.read.v1':
                self.rpc.receipt.update(state='cancelled', result_ref=None, cancel_requested=True, error_code='cancelled')
            return result
        self.rpc.after = cancelled
        self.fault('research_invalidated', lambda: self.sdk.read_response(receipt, args))

    def test_durable_export_and_restore_are_metadata_only_immutable_and_zero_rpc(self):
        selected = [evidence()]; receipt, args = self.submit(selected)
        raw = self.sdk.durable_record(receipt, args)
        self.assertLessEqual(len(raw), 8192)
        self.assertNotIn(selected[0]['text'].encode(), raw)
        self.assertNotIn(b'A synthetic question', raw)
        fresh_rpc = RPCDouble(); fresh = CodexResearchClient(fresh_rpc)
        restored = fresh.restore_submission(raw, sha(raw))
        self.assertEqual(restored, (receipt, args)); self.assertEqual(fresh_rpc.calls, [])
        self.assertEqual(fresh.durable_record(*restored), raw)
        fresh_rpc.receipt = copy.deepcopy(receipt)
        fresh_rpc.receipt['auth_epoch'] = 'different'
        self.fault('research_receipt_mismatch', lambda: fresh.status(*restored))
        self.fault('research_receipt_mismatch', lambda: fresh.cancel(*restored))

    def test_restore_then_result_uses_original_ordered_evidence_metadata(self):
        selected = [evidence(), evidence()]; receipt, args = self.submit(selected)
        raw = self.sdk.durable_record(receipt, args); self.sdk = CodexResearchClient(self.rpc)
        restored = self.sdk.restore_submission(raw, sha(raw)); value = self.rpc.complete(args, selected)
        self.assertEqual(self.sdk.read_response(*restored), encode(value))

    def test_durable_record_cannot_replace_first_receipt_or_params_with_latest(self):
        receipt, args = self.submit(); raw = self.sdk.durable_record(receipt, args)
        self.rpc.receipt.update(state='running', external_stop='not_started', native={
            'thread_id': 'thread', 'turn_id': None, 'terminal': 'not_started', 'interrupt': 'not_requested'})
        latest = self.sdk.status(receipt, args)
        self.fault('research_restore_mismatch', lambda: self.sdk.durable_record(latest, args))
        self.fault('research_restore_mismatch', lambda: self.sdk.durable_record(receipt, dict(args, deadline_ms=1)))
        self.assertEqual(self.sdk.durable_record(receipt, args), raw)

    def test_restore_requires_trusted_original_digest_exact_export_and_scope(self):
        receipt, args = self.submit(); raw = self.sdk.durable_record(receipt, args)
        original = copy.deepcopy(json.loads(raw))
        invalid = [b'not-json', b'[]', b'{}', raw + b' ', b' ' + raw, b'x' * 8193,
                   raw[:-1] + b', "schema_version": 1}']
        mutations = [lambda value: value.update(schema_version=True),
            lambda value: value.update(extra=None), lambda value: value['receipt'].pop('error_code'),
            lambda value: value['params'].update(extra=True),
            lambda value: value['params'].update(max_output_tokens=1),
            lambda value: value['params'].update(max_output_bytes=True),
            lambda value: value['params'].update(deadline_ms=30001),
            lambda value: value['params']['request'].update(byte_count=8193),
            lambda value: value['params']['descriptor'].update(byte_count=32769),
            lambda value: value['params'].update(model='changed'),
            lambda value: value['receipt'].update(owner='other'),
            lambda value: value['receipt'].update(epoch=True),
            lambda value: value['reviewed_evidence_bindings'].append({'text': 'PRIVATE'})]
        for mutate in mutations:
            value = copy.deepcopy(original); mutate(value); invalid.append(encode(value))
        for data in invalid:
            with self.subTest(data=data[:50]):
                fresh_rpc = RPCDouble(); fresh = CodexResearchClient(fresh_rpc)
                with self.assertRaises(Fault):
                    fresh.restore_submission(data, sha(data))
                self.assertEqual(fresh_rpc.calls, []); self.assertEqual(fresh._auth_pins, {})
        for pin in ['', 'G' * 64, '0' * 64]:
            self.fault('research_restore_mismatch', lambda: self.sdk.restore_submission(raw, pin))
        changed = copy.deepcopy(original); changed['params']['descriptor']['payload_id'] = new_id()
        self.fault('research_restore_mismatch', lambda: self.sdk.restore_submission(encode(changed), sha(raw)))
        changed = copy.deepcopy(original); changed['receipt']['auth_epoch'] = 'different'
        self.fault('research_receipt_mismatch', lambda: self.sdk.restore_submission(encode(changed), sha(encode(changed))))

    def test_durable_metadata_bound_and_strict_evidence_on_restore(self):
        selected = [dict(evidence(), text='') for _ in range(30)]
        receipt, args = self.submit(selected)
        # Preserve every ordered evidence binding; never trim a recovery record.
        self.fault('research_restore_mismatch', lambda: self.sdk.durable_record(receipt, args))
        self.setUp(); receipt, args = self.submit([evidence()])
        raw = self.sdk.durable_record(receipt, args); original = json.loads(raw)
        patches = [{'revision': True}, {'unit': '\ud800'}, {'unit': 'é' * 101},
                   {'evidence_id': original['reviewed_evidence_bindings'][0]['evidence_id'].upper()}]
        for patch in patches:
            with self.subTest(patch=patch):
                value = copy.deepcopy(original); value['reviewed_evidence_bindings'][0].update(patch)
                # JSON escapes exercise strict UTF-8 validity without Python encoding failure.
                data = json.dumps(value, ensure_ascii=True, sort_keys=True).encode()
                fresh_rpc = RPCDouble(); fresh = CodexResearchClient(fresh_rpc)
                self.fault('research_restore_mismatch', lambda: fresh.restore_submission(data, sha(data)))
                self.assertEqual(fresh_rpc.calls, [])


if __name__ == '__main__':
    unittest.main()
