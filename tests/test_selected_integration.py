"""Actual SDK/Runtime/Store/engine/adapter consumers with an in-memory provider."""
import copy
from dataclasses import replace
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from arl.contracts import AppPolicy, Fault, encode
from arl.research import sha
from arl.storage import Store
from arl.service import JobContext
from arl.formal_research_host import FormalResearchRuntime
from arl.codex_server import CodexTextAdapter
from arl.codex_research import CodexResearchGrant, METHODS
from arl.codex_research_client import CodexSourcedResearchClient
from arl.codex_selected import SelectedExplanationAdapter, SelectedRerankAdapter
from arl.codex_selected_engine import SelectedReviewProducer, SelectedExplanationEngine, SelectedRerankEngine
from arl.codex_selected_host import authorization_reuse_state, compose_selected_research
from arl import codex_selected_transport as wire
from arl import codex_sourced_contract as sourced
from arl import codex_selected_contract as rank
from arl.priority_host import RegisteredRouteProducer, PriorityHostConfig
from arl.priority import ResourcePolicy, TaskPolicy, AppProfilePolicy
from arl.identity import RegisteredPeerVerifier
from tests.fixtures.selected_memory_fixture import MemorySession, request, ranking, explanation, quote, RUN, MODEL


class SyntheticAuthorization:
    def __init__(self, tool):
        self.tool_name = tool
        self.allowed = True

    def current(self):
        return self.allowed

    def __call__(self, owner, tool, args):
        if not self.allowed or owner != 'tisra' or tool != self.tool_name or args['priority'] != 'explicit':
            raise Fault('research_review_not_authorized')


class RPC:
    app = 'tisra'

    def __init__(self, runtime):
        self.runtime, self.calls = runtime, []
        self.on_read = None

    def rpc(self, method, params=None):
        self.calls.append((method, copy.deepcopy(params)))
        result = self.runtime.dispatch({'protocol': 'arl/1', 'app': self.app, 'method': method,
                                       'params': params or {}}, verified_app=self.app)
        if method == 'codex.payload.read.v1' and self.on_read:
            self.on_read()
        return result


class IntegrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='codex-selected-', dir='/tmp')
        self.addCleanup(self.temp.cleanup)
        for patcher in [patch('subprocess.Popen', side_effect=AssertionError('real process forbidden')),
                        patch('socket.socket', side_effect=AssertionError('real socket forbidden')),
                        patch('arl.codex_server.Session', MemorySession)]:
            patcher.start();self.addCleanup(patcher.stop)
        MemorySession.instances.clear();MemorySession.event_mode = None
        self.subject = 'a' * 64
        self.selection = True
        self.clock = 1.0

    def fixture(self, operation='rerank'):
        codec = wire if operation == 'rerank' else sourced
        adapter_type = SelectedRerankAdapter if operation == 'rerank' else SelectedExplanationAdapter
        engine_type = SelectedRerankEngine if operation == 'rerank' else SelectedExplanationEngine
        text = CodexTextAdapter(enabled=True, test_command=[sys.executable, '-I', str(Path(__file__).resolve())])
        self.adapter = adapter_type([MODEL], text_adapter=text)
        self.auth = SyntheticAuthorization(codec.NAME)
        self.review = SelectedReviewProducer(self.auth, lambda owner: self.subject,
            lambda review, evidence: self.selection, clock=lambda: self.clock)
        self.grant = CodexResearchGrant('codex_app_server', frozenset({MODEL}), 'synthetic-review-epoch', codec.CONTRACT_SHA256)
        self.engine = engine_type({'tisra': self.grant}, {'codex_app_server': self.adapter}, self.review)
        policy = AppPolicy(frozenset({codec.NAME}), frozenset(), 0, 32, 100,
                          methods=METHODS | {'submit', 'submit_scheduled', 'capabilities'}, max_deadline_ms=30000)
        self.runtime = FormalResearchRuntime(Path(self.temp.name), policies={'tisra': policy}, providers={},
            identity_verifier=lambda c, app: app, codex_research=self.engine, admission=self.review)
        self.review.runtime = self.engine.runtime = self.runtime
        self.store = self.runtime.store = Store(Path(self.temp.name) / 'synthetic.sqlite')
        self.store.publication_admission = self.runtime.check_publication_admission
        self.engine.attach(self.store)
        self.runtime.ready.set()
        self.addCleanup(self.store.close)
        self.addCleanup(self.runtime.control.close)
        self.rpc = RPC(self.runtime)
        self.client = (wire.SelectedRerankClient(self.rpc, current_selection=lambda raw: self.selection)
                       if operation == 'rerank' else CodexSourcedResearchClient(self.rpc))
        obj = request() if operation == 'rerank' else explanation()
        self.raw = json.dumps(obj, ensure_ascii=False, indent=2).encode() + b' \n'
        MemorySession.body = ranking(obj) if operation == 'rerank' else {'text': 'Grounded explanation.',
                                                                     'citations': [quote(obj['evidence'][0])]}
        self.descriptor = {'version': 1 if operation == 'rerank' else 2, 'executionID': RUN,
            'threadID': '66666666-6666-4666-8666-666666666666', 'sequence': 0,
            'parentRunID': None, 'parentFingerprint': None, 'startsAlternatePath': False, 'model': MODEL,
            'format': rank.NAME if operation == 'rerank' else 'tisra.codex.v2',
            'requestDigest': sha(self.raw), 'requestBytes': len(self.raw), 'maximumResponseBytes': 262144,
            'maximumOutputTokens': None, 'maximumTextBytes': 32768, 'evidence': codec.snapshot_bindings(obj)}
        self.kwargs = {'epoch': 0, 'provider': 'codex_app_server', 'model_fingerprint': self.adapter.model_fingerprints[MODEL]}
        self.args = {'schema_version': 1, 'run_id': RUN, 'epoch': 0,
            'request': {'payload_id': '00000000-0000-0000-0000-000000000001', 'sha256': sha(self.raw), 'byte_count': len(self.raw)},
            'descriptor': {'payload_id': '00000000-0000-0000-0000-000000000002', 'sha256': sha(encode(self.descriptor)), 'byte_count': len(encode(self.descriptor))},
            'provider': 'codex_app_server', 'model': MODEL, 'model_fingerprint': self.kwargs['model_fingerprint'],
            'request_format': codec.FORMATS[0], 'output_format': codec.FORMATS[1], 'history_version': codec.FORMATS[2],
            'max_output_tokens': None, 'max_output_bytes': 32768, 'priority': 'explicit', 'deadline_ms': 30000}
        self.operation = operation

    def approve(self):
        return self.review.approve_exact('tisra', self.args, self.raw, encode(self.descriptor))

    def submit(self):
        kwargs = dict(self.kwargs)
        if self.operation == 'rerank':
            kwargs['reviewed_request_sha256'] = sha(self.raw)
        return self.client.submit(self.raw, self.descriptor, **kwargs)

    def execute(self, *, publish=True):
        row = self.store.claim();self.assertIsNotNone(row)
        self.runtime.admission(row['owner'], row['tool'], json.loads(row['args']))
        context = JobContext(self.runtime, row)
        output = self.runtime.tools[row['tool']].handler(json.loads(row['args']), context)
        context.check_cancelled()
        if publish:
            self.engine.complete(row, output)
        return row, output

    def test_rank_complete_production_consumer_chain_exact_original_bytes(self):
        self.fixture();self.approve();receipt, args = self.submit()
        self.execute()
        output = json.loads(self.client.read_response(receipt, args))
        self.assertEqual(output['contract_sha256'], rank.CONTRACT_SHA256)
        self.assertEqual(len(output['body']['ranked_candidates']), 2)
        turn = [p for m, p in MemorySession.instances[0].requests if m == 'turn/start'][0]
        self.assertEqual(turn['input'][0]['text'].encode(), self.raw)
        self.assertEqual(self.store.db.execute('SELECT state FROM jobs').fetchone()[0], 'succeeded')
        self.assertEqual(len(MemorySession.instances), 1)

    def test_explanation_v2_same_engine_store_path(self):
        self.fixture('explain');self.approve();receipt, args = self.submit();self.execute()
        output = json.loads(self.client.read_response(receipt, args))
        self.assertEqual(output['schema_version'], 2)
        self.assertEqual(output['request_format'], sourced.REQUEST)
        self.assertEqual(output['text'], 'Grounded explanation.')

    def test_missing_review_rejects_before_queue_and_provider(self):
        self.fixture()
        with self.assertRaises(Fault):self.submit()
        self.assertEqual(self.store.db.execute('SELECT COUNT(*) FROM jobs').fetchone()[0], 0)
        self.assertFalse(MemorySession.instances)

    def test_v2_qualification_cannot_authorize_rank_or_construct_profile(self):
        self.fixture()
        old = replace(self.grant, contract_sha256=sourced.CONTRACT_SHA256)
        old_auth = SyntheticAuthorization(sourced.NAME)
        self.assertEqual(authorization_reuse_state(old, old_auth, 'rerank'), 'contract_scope_not_authorized')
        self.assertEqual(authorization_reuse_state(old, old_auth, 'explain'), 'exact_per_request_review_and_current_sources_required')
        with self.assertRaises(Fault):
            compose_selected_research(Path(self.temp.name), operation='rerank', grant=old, authorization=old_auth,
                signed_peer=None, registered_peer=None, text_adapter=None, priority=None, selection_current=None)
        self.engine.grants['tisra'] = old
        with self.assertRaises(Fault):self.client.capabilities()
        self.assertFalse(MemorySession.instances)

    def test_capability_mismatch_rejected_before_upload(self):
        self.fixture('explain')
        client = wire.SelectedRerankClient(self.rpc, current_selection=lambda raw: True)
        raw = encode(request())
        with self.assertRaises(Fault):
            client.submit(raw, {}, reviewed_request_sha256=sha(raw))
        self.assertEqual([m for m, _ in self.rpc.calls], ['codex.research.capabilities.v1'])

    def test_request_review_bytes_and_background_or_generic_bypass_denied(self):
        self.fixture()
        with self.assertRaises(Fault):
            self.client.submit(self.raw, self.descriptor, reviewed_request_sha256='0' * 64, **self.kwargs)
        self.assertFalse(self.rpc.calls)
        self.args['priority'] = 'background'
        with self.assertRaises(Fault):self.approve()
        with self.assertRaisesRegex(Fault, 'typed_research_method_required'):
            self.rpc.rpc('submit', {'tool': rank.NAME, 'args': {'run_id': RUN}, 'key': RUN})

    def test_revoke_after_acceptance_cancels_without_provider(self):
        self.fixture();self.approve();receipt, args = self.submit()
        self.review.revoke('tisra', RUN, 0)
        self.assertEqual(self.client.status(receipt, args)['state'], 'cancelled')
        self.assertIsNone(self.store.claim());self.assertFalse(MemorySession.instances)

    def test_final_publication_rechecks_source_revision(self):
        self.fixture();self.approve();receipt, args = self.submit()
        row, output = self.execute(publish=False)
        with self.store.lock:self.selection = False
        self.engine.complete(row, output)
        current = self.client.status(receipt, args)
        self.assertEqual(current['state'], 'needs_review');self.assertIsNone(current['result_ref'])
        self.assertEqual(self.store.db.execute("SELECT COUNT(*) FROM research_payloads WHERE purpose=? AND state='sealed'", (wire.RESPONSE,)).fetchone()[0], 0)

    def test_source_change_during_response_read_blocks_consumer_publish(self):
        self.fixture();self.approve();receipt, args = self.submit();self.execute()
        self.rpc.on_read = lambda: setattr(self, 'selection', False)
        with self.assertRaises(Fault):self.client.read_response(receipt, args)

    def test_identity_grant_epoch_and_review_expiry_each_invalidate(self):
        for change in ['subject', 'auth', 'expiry', 'grant', 'review_epoch']:
            with self.subTest(change=change):
                # Independent fixtures and stores, never reuse accepted IDs across runs.
                case = IntegrationTests(methodName='runTest');case.setUp()
                try:
                    case.fixture();case.approve();receipt, args = case.submit()
                    if change == 'subject':case.subject = 'b' * 64
                    elif change == 'auth':case.auth.allowed = False
                    elif change == 'expiry':case.clock = 122.0
                    elif change == 'grant':case.engine.grants['tisra'] = replace(case.grant, auth_epoch='new-epoch')
                    else:case.runtime.admission = case.review
                    current = case.client.status(receipt, args)
                    self.assertEqual(current['state'], 'cancelled')
                finally:case.doCleanups()

    def test_replay_same_run_does_not_create_second_provider_turn(self):
        self.fixture();self.approve();receipt, args = self.submit();self.execute()
        again = self.rpc.rpc('codex.research.submit.v1', args)
        self.assertEqual(again['job_id'], receipt['job_id'])
        self.assertIsNone(self.store.claim());self.assertEqual(len(MemorySession.instances), 1)
        with self.assertRaises(Fault):self.approve()

    def test_rank_priority_registration_uses_exact_rank_codec(self):
        self.fixture()
        config = PriorityHostConfig((ResourcePolicy('model', slots=1, realtime_reserved=0, background_start_limit_ms=30000),),
            (TaskPolicy(rank.NAME, 'model.inference', 'model', owners=frozenset({'tisra'}), maximum_class='interactive',
                        estimate_floor_ms=100, execution_budget_ms=25000),),
            {'tisra': AppProfilePolicy(frozenset({'interactive'}), max_deadline_ms=30000)}, 60000, allow_synthetic=True)
        producer = RegisteredRouteProducer(self.runtime, RegisteredPeerVerifier({'tisra'}), config)
        producer.register_native(self.engine, task_kind='model.inference', resource_kind='model', backend='codex_app_server')
        self.assertEqual(producer.domains[0].codec, 'codex.appserver.rerank.v1')
        self.assertIs(producer.domains[0].target, self.engine)


if __name__ == '__main__':
    unittest.main(verbosity=2)
