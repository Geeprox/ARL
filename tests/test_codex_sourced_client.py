"""Native sourced SDK tests: memory-only transports, no listener or inference."""
import copy
import json
import unittest

from arl import codex_sourced_contract as contract
from arl.codex_research_client import CodexResearchClient, CodexSourcedResearchClient
from arl.contracts import Fault, encode
from arl.research import CHUNK, sha
from tests.test_codex_research_client import (RPCDouble, MODEL, MODEL_EVIDENCE,
    FINGERPRINT, capabilities as v1_capabilities, new_id)


def parts():
    snapshot, record = new_id(), new_id()
    base = {'evidence_id': snapshot, 'snapshot_digest': 'c' * 64, 'record_id': record,
            'revision': 3, 'title': 'Synthetic selected record', 'extraction_state': 'ready'}
    return [dict(base, unit=None, attachment_sha256=None, locator=None, text='前言 Café 🦊\n第二行'),
            dict(base, unit=0, attachment_sha256='e' * 64, locator='page 1', text='Excerpt αβ — verified evidence.'),
            dict(base, record_id=new_id(), revision=4, title='Another selected record',
                 extraction_state='partial', unit=1, attachment_sha256='f' * 64,
                 locator='page 2', text='Other exact selected text.')]


def request(selected=None):
    return encode({'schema_version': 2, 'text': 'Answer using the selected sources.',
                   'public_history': [], 'evidence': selected or [], 'migration': None})


def descriptor(raw, selected=None):
    seen = set(); snapshots = []
    for item in selected or []:
        if item['evidence_id'] not in seen:
            snapshots.append({'evidenceID': item['evidence_id'], 'snapshotDigest': item['snapshot_digest']})
            seen.add(item['evidence_id'])
    return {'version': 2, 'executionID': new_id(), 'threadID': new_id(), 'sequence': 0,
        'parentRunID': None, 'parentFingerprint': None, 'startsAlternatePath': False,
        'model': MODEL, 'format': 'tisra.codex.v2', 'requestDigest': sha(raw),
        'requestBytes': len(raw), 'maximumResponseBytes': 262144,
        'maximumOutputTokens': None, 'maximumTextBytes': 32768, 'evidence': snapshots}


def citation(source, quote=None):
    quote = source['text'] if quote is None else quote
    start = source['text'].encode().index(quote.encode())
    return {**{key: source[key] for key in contract.EVIDENCE_KEYS}, 'quote': quote,
            'start_utf8': start, 'end_utf8': start + len(quote.encode())}


def capabilities():
    value = v1_capabilities()
    value.update(tool=contract.NAME, renderer_version='tisra.codex.raw-json.v2',
        formats=dict(zip(('request', 'output', 'history'), contract.FORMATS)),
        contract_sha256=contract.CONTRACT_SHA256, structured_generated_citations=True)
    return value


class SourcedRPCDouble(RPCDouble):
    def __init__(self):
        super().__init__(); self.capability_value = capabilities()

    def dispatch(self, method, params):
        if method == 'codex.payload.begin.v1':
            assert params['purpose'] in {contract.REQUEST, contract.DESCRIPTOR}
            pid = new_id()
            self.payloads[pid] = {'begin': copy.deepcopy(params), 'data': bytearray(), 'revoked': False}
            return {'schema_version': 1, 'payload_id': pid, 'expires_at_ms': 1000, 'chunk_bytes': CHUNK}
        return super().dispatch(method, params)

    def complete(self, args, selected=None, generated=None):
        self.receipt.update(state='succeeded', external_stop='completed', native={
            'thread_id': 'acknowledged-thread', 'turn_id': 'acknowledged-turn',
            'terminal': 'completed', 'interrupt': 'not_requested'})
        generated = generated or {'text': 'A sourced synthetic answer.',
            'citations': [citation(item) for item in (selected or [])]}
        value = {'schema_version': 2,
            **{key: self.receipt[key] for key in contract.BINDING_KEYS},
            'provider_input_sha256': self.receipt['request_sha256'],
            'model_evidence': copy.deepcopy(MODEL_EVIDENCE),
            'native': copy.deepcopy(self.receipt['native']),
            'text': generated['text'], 'citations': copy.deepcopy(generated['citations']),
            'output_sha256': contract.output_digest(generated),
            'reviewed_evidence_bindings': [{key: item[key] for key in contract.EVIDENCE_KEYS}
                                         for item in (selected or [])],
            'usage': {'tokens': None, 'cost': None}, 'token_hard_cap_supported': False}
        self.install_result(value)
        return value


class CodexSourcedClientTests(unittest.TestCase):
    def setUp(self):
        self.rpc = SourcedRPCDouble(); self.sdk = CodexSourcedResearchClient(self.rpc)

    def fault(self, code, action):
        with self.assertRaises(Fault) as caught:
            action()
        self.assertEqual(caught.exception.code, code)

    def submit(self, selected=None, raw=None, metadata=None, **kwargs):
        raw = raw if raw is not None else request(selected)
        metadata = metadata if metadata is not None else descriptor(raw, selected)
        options = {'epoch': 0, 'provider': contract.PROVIDER, 'model_fingerprint': FINGERPRINT}
        options.update(kwargs)
        return self.sdk.submit(raw, metadata, **options)

    def count(self, name):
        return sum(method == 'codex.' + name for method, _ in self.rpc.calls)

    def test_constructor_and_capabilities_pin_exact_v2_contract(self):
        self.assertEqual(self.rpc.calls, [])
        self.assertEqual(self.sdk.capabilities(), capabilities())
        CodexSourcedResearchClient(self.rpc, sourced_contract_sha256=contract.CONTRACT_SHA256)
        self.fault('invalid_arguments', lambda: CodexSourcedResearchClient(self.rpc, sourced_contract_sha256='0' * 64))
        for patch in [{'contract_sha256': '0' * 64}, {'structured_generated_citations': False},
                      {'renderer_version': 'tisra.codex.raw-json.v1'}, {'tool': 'tisra.codex.research.v1'}]:
            with self.subTest(patch=patch):
                self.rpc.capability_value = dict(capabilities(), **patch)
                self.fault('invalid_response', self.sdk.capabilities)
        self.rpc.capability_value = capabilities(); generic = CodexResearchClient(self.rpc)
        self.fault('invalid_response', generic.capabilities)

    def test_submit_preserves_original_complete_request_and_deduplicates_descriptor_snapshots(self):
        selected = parts(); raw = b' \n' + request(selected) + b'\n'; metadata = descriptor(raw, selected)
        saved = []; receipt, args = self.submit(selected, raw, metadata, on_payload_created=saved.append)
        self.assertEqual(bytes(self.rpc.payloads[args['request']['payload_id']]['data']), raw)
        self.assertEqual(bytes(self.rpc.payloads[args['descriptor']['payload_id']]['data']), encode(metadata))
        self.assertEqual(len(metadata['evidence']), 1)
        self.assertEqual([item['purpose'] for item in saved], [contract.REQUEST, contract.DESCRIPTOR])
        self.assertEqual(args['request_format'], 'tisra.codex.request.v2')
        self.assertEqual(receipt['schema_version'], 1)
        self.assertIsNone(args['max_output_tokens'])
        self.assertEqual(len(self.sdk._submissions[self.sdk._key(receipt)]['reviewed']), 3)

    def test_multiple_parts_of_one_snapshot_validate_generated_multibyte_citations(self):
        selected = parts(); receipt, args = self.submit(selected)
        generated = {'text': 'A sourced answer.', 'citations': [
            citation(selected[0], 'Café 🦊'), citation(selected[1], 'αβ'), citation(selected[2]) ]}
        value = self.rpc.complete(args, selected, generated)
        raw = self.sdk.read_response(receipt, args)
        self.assertEqual(raw, encode(value)); self.assertEqual(json.loads(raw)['citations'], generated['citations'])
        self.assertIsNone(generated['citations'][0]['attachment_sha256'])
        self.assertEqual(generated['citations'][1]['attachment_sha256'], 'e' * 64)
        self.assertEqual(value['output_sha256'], contract.output_digest(generated))
        self.assertNotEqual(value['output_sha256'], sha(generated['text'].encode()))

    def test_zero_citations_valid_without_invented_source_claim(self):
        receipt, args = self.submit([])
        value = self.rpc.complete(args, [], {'text': 'No selected source citations.', 'citations': []})
        self.assertEqual(self.sdk.read_response(receipt, args), encode(value))

    def test_malformed_source_bindings_reject_before_any_upload(self):
        patches = [{'evidence_id': 'bad'}, {'snapshot_digest': 'A' * 64}, {'record_id': 'bad'},
            {'revision': 0}, {'revision': True}, {'unit': 'page 1'}, {'unit': True}, {'unit': 2000},
            {'unit': None, 'locator': 'wrong'}, {'unit': 0, 'locator': None},
            {'title': '\ud800'}, {'extraction_state': 'unknown'}, {'attachment_sha256': 'e' * 64}]
        for patch in patches:
            with self.subTest(patch=patch):
                selected = parts(); selected[0].update(patch)
                data = json.dumps({'schema_version': 2, 'text': 'Question', 'public_history': [],
                    'evidence': selected, 'migration': None}, ensure_ascii=True).encode()
                with self.assertRaises(Fault):
                    self.submit(selected, raw=data)
                self.assertEqual(self.rpc.calls, [])
        selected = parts(); selected[1]['snapshot_digest'] = 'd' * 64
        with self.assertRaises(Fault):
            self.submit(selected)
        self.assertEqual(self.rpc.calls, [])

    def test_descriptor_snapshot_order_and_native_content_versions_are_strict(self):
        selected = parts(); raw = request(selected); good = descriptor(raw, selected)
        for metadata in [dict(good, evidence=[]), dict(good, evidence=good['evidence'] * 2),
                         dict(good, version=1), dict(good, format='tisra.codex.v1')]:
            with self.subTest(metadata=metadata):
                with self.assertRaises(Fault):
                    self.submit(selected, raw, metadata)
                self.assertEqual(self.rpc.calls, [])
        self.fault('codex_input_too_large', lambda: self.sdk.upload(b'x' * 8193, contract.REQUEST, new_id(), 0))
        self.assertEqual(self.rpc.calls, [])

    def test_extracted_sources_require_one_canonical_attachment_pin_per_record(self):
        for attachment in (None, True, 'A' * 64, 'not-a-digest'):
            with self.subTest(attachment=attachment):
                selected = parts(); selected[1]['attachment_sha256'] = attachment
                with self.assertRaises(Fault):
                    self.submit(selected)
                self.assertEqual(self.rpc.calls, [])
        selected = parts(); selected[1].pop('attachment_sha256')
        with self.assertRaises(Fault):
            self.submit(selected)
        self.assertEqual(self.rpc.calls, [])
        selected = parts(); selected.append(dict(selected[1], unit=2, attachment_sha256='d' * 64))
        with self.assertRaises(Fault):
            self.submit(selected)
        self.assertEqual(self.rpc.calls, [])

    def test_generated_and_restored_unit_bindings_match_original_attachment(self):
        selected = parts(); raw = request(selected); receipt, args = self.submit(selected, raw)
        value = self.rpc.complete(args, selected, {'text': 'Answer', 'citations': [citation(selected[1], 'αβ')]})
        value['citations'][0]['attachment_sha256'] = 'd' * 64
        value['output_sha256'] = contract.output_digest(value)
        self.rpc.install_result(value)
        self.fault('codex_result_invalid', lambda: self.sdk.read_response(receipt, args))
        durable = self.sdk.durable_record(receipt, args); metadata = json.loads(durable)
        metadata['reviewed_evidence_bindings'][1]['attachment_sha256'] = 'd' * 64
        changed = encode(metadata); restored = CodexSourcedResearchClient(self.rpc)
        restored.restore_submission(changed, sha(changed))
        before = len(self.rpc.calls)
        self.fault('research_restore_mismatch', lambda: restored.read_response(receipt, args, source_request=raw))
        self.assertEqual(len(self.rpc.calls), before)

    def test_citation_binding_quote_byte_ranges_and_boolean_offsets_are_rejected(self):
        mutations = [lambda item: item.update(evidence_id=new_id()),
            lambda item: item.update(snapshot_digest='0' * 64),
            lambda item: item.update(record_id=new_id()), lambda item: item.update(revision=4),
            lambda item: item.update(revision=True), lambda item: item.update(unit=0),
            lambda item: item.update(unit='0'), lambda item: item.update(unit=True),
            lambda item: item.update(attachment_sha256='0' * 64),
            lambda item: item.update(quote='Invented quote'), lambda item: item.update(quote=''),
            lambda item: item.update(start_utf8=True), lambda item: item.update(end_utf8=False),
            lambda item: item.update(start_utf8=item['start_utf8'] + 1),
            lambda item: item.update(end_utf8=item['end_utf8'] - 1),
            lambda item: item.update(start_utf8=-1), lambda item: item.update(end_utf8=100000),
            lambda item: item.update(extra=None)]
        for mutate in mutations:
            with self.subTest(mutate=mutate):
                self.setUp(); selected = parts(); receipt, args = self.submit(selected)
                value = self.rpc.complete(args, selected, {'text': 'Answer', 'citations': [citation(selected[0], 'Café 🦊')]})
                mutate(value['citations'][0])
                value['output_sha256'] = contract.output_digest(value)
                self.rpc.install_result(value)
                with self.assertRaises(Fault):
                    self.sdk.read_response(receipt, args)

    def test_duplicate_citation_identity_and_text_only_hash_cannot_publish(self):
        for duplicate in (False, True):
            with self.subTest(duplicate=duplicate):
                self.setUp(); selected = parts(); receipt, args = self.submit(selected)
                value = self.rpc.complete(args, selected)
                if duplicate:
                    value['citations'].append(copy.deepcopy(value['citations'][0]))
                    value['output_sha256'] = contract.output_digest(value)
                else:
                    value['output_sha256'] = sha(value['text'].encode())
                self.rpc.install_result(value)
                with self.assertRaises(Fault):
                    self.sdk.read_response(receipt, args)

    def test_read_after_restart_requires_trusted_original_raw_before_any_rpc(self):
        selected = parts(); raw = request(selected); receipt, args = self.submit(selected, raw)
        durable = self.sdk.durable_record(receipt, args)
        fresh = CodexSourcedResearchClient(self.rpc); restored = fresh.restore_submission(durable, sha(durable))
        before = len(self.rpc.calls)
        self.fault('codex_source_unavailable', lambda: fresh.read_response(*restored))
        self.assertEqual(len(self.rpc.calls), before)
        different = request([dict(selected[0], text='Changed selected text')])
        with self.assertRaises(Fault):
            fresh.read_response(*restored, source_request=different)
        self.assertEqual(len(self.rpc.calls), before)
        value = self.rpc.complete(args, selected)
        self.assertEqual(fresh.read_response(*restored, source_request=raw), encode(value))

    def test_explicit_wrong_source_never_falls_back_to_cached_valid_source(self):
        selected = parts(); receipt, args = self.submit(selected); self.rpc.complete(args, selected)
        before = len(self.rpc.calls)
        for data in [b'not-json', b'x' * 8193, request([]), bytearray(request(selected))]:
            with self.subTest(data=type(data)):
                with self.assertRaises(Fault):
                    self.sdk.read_response(receipt, args, source_request=data)
                self.assertEqual(len(self.rpc.calls), before)

    def test_durable_record_has_no_plaintext_and_accepts_repeated_snapshot_metadata(self):
        selected = parts(); raw = request(selected); receipt, args = self.submit(selected, raw)
        durable = self.sdk.durable_record(receipt, args)
        self.assertLessEqual(len(durable), 8192)
        for item in selected:
            self.assertNotIn(item['text'].encode(), durable); self.assertNotIn(item['title'].encode(), durable)
        self.assertNotIn(b'Answer using the selected sources.', durable)
        value = json.loads(durable); self.assertEqual(len(value['reviewed_evidence_bindings']), 3)
        self.assertEqual(len({item['evidence_id'] for item in value['reviewed_evidence_bindings']}), 1)
        fresh_rpc = SourcedRPCDouble(); fresh = CodexSourcedResearchClient(fresh_rpc)
        self.assertEqual(fresh.restore_submission(durable, sha(durable)), (receipt, args))
        self.assertEqual(fresh.durable_record(receipt, args), durable); self.assertEqual(fresh_rpc.calls, [])

    def test_restore_metadata_types_scope_and_original_source_order_are_strict(self):
        selected = parts(); raw = request(selected); receipt, args = self.submit(selected, raw)
        durable = self.sdk.durable_record(receipt, args); original = json.loads(durable)
        patches = [{'revision': True}, {'revision': 0}, {'unit': '0'}, {'unit': True},
                   {'unit': 2000}, {'snapshot_digest': 'A' * 64}, {'extra': 'plaintext'},
                   {'attachment_sha256': 'e' * 64}]
        for patch in patches:
            with self.subTest(patch=patch):
                value = copy.deepcopy(original); value['reviewed_evidence_bindings'][0].update(patch)
                data = encode(value); fresh_rpc = SourcedRPCDouble(); fresh = CodexSourcedResearchClient(fresh_rpc)
                self.fault('research_restore_mismatch', lambda: fresh.restore_submission(data, sha(data)))
                self.assertEqual(fresh_rpc.calls, [])
        value = copy.deepcopy(original); value['reviewed_evidence_bindings'].reverse(); data = encode(value)
        fresh = CodexSourcedResearchClient(self.rpc); fresh.restore_submission(data, sha(data))
        before = len(self.rpc.calls)
        self.fault('research_restore_mismatch', lambda: fresh.read_response(receipt, args, source_request=raw))
        self.assertEqual(len(self.rpc.calls), before)

    def test_result_original_evidence_order_auth_model_and_native_pins_stay_exact(self):
        mutations = [lambda value: value['reviewed_evidence_bindings'].reverse(),
            lambda value: value.update(auth_epoch='changed'),
            lambda value: value['native'].update(turn_id='changed'),
            lambda value: value['model_evidence'].update(adapter_binary_sha256='0' * 64),
            lambda value: value.update(schema_version=1), lambda value: value.update(request_format='tisra.codex.request.v1')]
        for mutate in mutations:
            with self.subTest(mutate=mutate):
                self.setUp(); selected = parts(); receipt, args = self.submit(selected)
                value = self.rpc.complete(args, selected); mutate(value); self.rpc.install_result(value)
                with self.assertRaises(Fault):
                    self.sdk.read_response(receipt, args)

    def test_first_auth_cancellation_and_cleanup_reuse_native_guards(self):
        selected = parts(); receipt, args = self.submit(selected)
        self.rpc.receipt['auth_epoch'] = 'changed'
        self.fault('research_receipt_mismatch', lambda: self.sdk.status(receipt, args))
        self.fault('research_receipt_mismatch', lambda: self.sdk.cancel(receipt, args))
        self.setUp(); receipt, args = self.submit(selected); self.rpc.complete(args, selected)
        self.sdk.status(receipt, args)
        cancelled = self.sdk.cancel(receipt, args)
        self.assertTrue(cancelled['cancel_requested'])
        self.fault('research_not_completed', lambda: self.sdk.read_response(receipt, args))
        self.setUp()
        def lose(method, params, result):
            if method == 'codex.research.submit.v1':
                raise Fault('disconnected')
            return result
        self.rpc.after = lose
        self.fault('disconnected', lambda: self.submit(selected))
        self.assertEqual(self.count('research.submit.v1'), 1)
        self.assertEqual(self.count('payload.revoke.v1'), 2)
        self.assertTrue(all(item['revoked'] and not item['data'] for item in self.rpc.payloads.values()))


if __name__ == '__main__':
    unittest.main()
