"""Typed rerank descriptor/SDK on the existing codex RPC family; no enrollment."""
from __future__ import annotations
import sys
from .contracts import Fault, encode
from .research import exact, integer, uid, digest, sha
from . import codex_selected_contract as rank
from . import codex_sourced_contract as sourced
from .codex_contract import PROVIDER, BINDING_KEYS, NATIVE_TERMINALS, _parse, _identifier, _same, native_body
from .codex_research_client import CodexResearchClient, CodexSourcedResearchClient

NAME, REQUEST, RESPONSE, HISTORY = rank.NAME, rank.REQUEST, rank.RESPONSE, rank.HISTORY
FORMATS, CONTRACT_SHA256 = rank.FORMATS, rank.CONTRACT_SHA256
DESCRIPTOR = 'tisra.codex.rerank.descriptor.v1'
LIMITS = {REQUEST: rank.MAX_INPUT, DESCRIPTOR: 32768, RESPONSE: rank.MAX_ENVELOPE}
MAX_TEXT_BYTES = rank.MAX_BODY
RENDERER = 'tisra.codex.rerank.raw-json.v1'
DESCRIPTOR_KEYS = frozenset({'version', 'executionID', 'threadID', 'sequence', 'parentRunID',
    'parentFingerprint', 'startsAlternatePath', 'model', 'format', 'requestDigest', 'requestBytes',
    'maximumResponseBytes', 'maximumOutputTokens', 'maximumTextBytes', 'evidence'})
request_body = rank.request_body
reviewed_bindings = rank.reviewed_bindings
reviewed_body = sourced.reviewed_body


def snapshot_bindings(request):
    parts = [p for c in request['candidates'] for p in c['parts']]
    return sourced.snapshot_bindings({'evidence': parts})


def descriptor(raw, args):
    value = _parse(raw, LIMITS[DESCRIPTOR], 'rerank_descriptor_invalid')
    try:
        exact(value, DESCRIPTOR_KEYS)
        integer(value['version'], 1, 1)
        uid(value['executionID']); uid(value['threadID'])
        integer(value['sequence'], 0, 1000000)
        _identifier(value['model'], 150)
        if (value['format'] != NAME or value['maximumOutputTokens'] is not None or
                value['parentRunID'] is not None or value['parentFingerprint'] is not None or
                value['startsAlternatePath'] is not False):
            raise Fault('invalid_arguments')
        digest(value['requestDigest'])
        integer(value['requestBytes'], 1, rank.MAX_INPUT)
        integer(value['maximumTextBytes'], 128, rank.MAX_BODY)
        integer(value['maximumResponseBytes'], 1, rank.MAX_ENVELOPE)
        if type(value['evidence']) is not list or not 1 <= len(value['evidence']) <= 100:
            raise Fault('invalid_arguments')
        seen = set()
        for item in value['evidence']:
            exact(item, {'evidenceID', 'snapshotDigest'})
            uid(item['evidenceID']); digest(item['snapshotDigest'])
            if item['evidenceID'] in seen:
                raise Fault('invalid_arguments')
            seen.add(item['evidenceID'])
        pairs = [('executionID', args['run_id']), ('model', args['model']),
                 ('requestDigest', args['request']['sha256']), ('requestBytes', args['request']['byte_count']),
                 ('maximumTextBytes', args['max_output_bytes'])]
        if any(not _same(value[k], v) for k, v in pairs):
            raise Fault('descriptor_mismatch')
    except (Fault, KeyError, TypeError, ValueError, UnicodeError):
        raise Fault('rerank_descriptor_invalid') from None
    return value


def result_body(raw, args, *, request, binding, native=None, model_evidence=None, reviewed_evidence=None):
    value = rank.result_body(raw, args, request=request, binding=binding,
                             native=native, model_evidence=model_evidence)
    if reviewed_evidence is not None and not _same(value['reviewed_evidence_bindings'], reviewed_evidence):
        raise Fault('rerank_result_invalid')
    return value


TRANSPORT_CONTRACT = {'name': NAME, 'common_contract_sha256': CONTRACT_SHA256,
    'rpc_methods': 'existing codex.research.*.v1 and codex.payload.*.v1; single explicitly composed profile',
    'descriptor_purpose': DESCRIPTOR, 'descriptor_exact_keys': sorted(DESCRIPTOR_KEYS),
    'descriptor_version': 1, 'descriptor_format': NAME, 'descriptor_parent_fields': 'null/null/false',
    'descriptor_evidence': 'ordered unique evidenceID/snapshotDigest from complete candidate parts',
    'renderer': RENDERER, 'limits': LIMITS,
    'profile_selection': 'host-only; no caller fallback or v2 reinterpretation',
    'submit': 'explicit review required before upload; current exact host review before queue/execution/publication',
    'capability': 'common contract digest plus exact formats, tool and renderer; model fingerprints independently checked'}
TRANSPORT_SHA256 = sha(encode(TRANSPORT_CONTRACT))


class SelectedRerankClient(CodexSourcedResearchClient):
    name = NAME
    renderer_version = RENDERER
    structured_generated_citations = True

    def __init__(self, client, *, current_selection):
        if not callable(current_selection):
            raise Fault('selected_review_not_admitted')
        self.contract = sys.modules[__name__]
        self.expected_contract_sha256 = CONTRACT_SHA256
        self.current_selection = current_selection
        CodexResearchClient.__init__(self, client)

    def submit(self, raw, descriptor, *, reviewed_request_sha256, **kwargs):
        # The UI must review the complete exact bytes. This is a local fence,
        # never a substitute for the host's independent authorization/review.
        if (type(raw) is not bytes or reviewed_request_sha256 != sha(raw) or
                kwargs.get('priority', 'explicit') != 'explicit' or self.current_selection(raw) is not True):
            raise Fault('selected_review_not_admitted')
        self.capabilities()  # Reject old v2/unknown profile before any payload upload.
        return super().submit(raw, descriptor, **kwargs)

    def _response_options(self, receipt, args, source_request):
        self._validate(receipt, args)
        with self._pin_lock:
            record = self._submissions.get(self._key(receipt))
            cached = record.get('source_request') if record is not None else None
        raw = cached if source_request is None else source_request
        if raw is None or self.current_selection(raw) is not True:
            raise Fault('selected_review_not_admitted')
        request_body(raw, args)
        self._baseline(receipt, args)
        return {'request': raw}

    def read_response(self, receipt, args, *, source_request=None):
        options = self._response_options(receipt, args, source_request)
        raw = super().read_response(receipt, args, source_request=options['request'])
        if self.current_selection(options['request']) is not True:
            raise Fault('selected_review_not_admitted')
        return raw
