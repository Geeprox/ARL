"""Real SQLite first-submit regression; no external model or host effects."""
import base64
import hashlib
import json
import tempfile
import unittest
import uuid
from pathlib import Path
from unittest.mock import patch

from arl import codex_sourced_contract as contract
from arl.codex_server import CodexTextAdapter
from arl.codex_sourced_research import NAME
from arl.contracts import Fault, encode
from arl.formal_peer import FormalTisraPeer
from arl.formal_research_host import FormalResearchActivation, compose_formal_research
from arl.identity import RegisteredPeerVerifier
from arl.priority import AppProfilePolicy, ResourcePolicy, TaskPolicy
from arl.priority_host import PriorityHostConfig
from arl.research import sha
from arl.research import ResearchEngine
from arl.storage import Store
from tests.test_codex_sourced_research import request, descriptor


class FormalFirstSubmitTransactionTests(unittest.TestCase):
    def test_real_sqlite_first_submit_retry_and_callback_rollback(self):
        with tempfile.TemporaryDirectory() as root:
            home = Path(root)
            binary = home / 'codex'; binary.write_bytes(b'bounded inert binary')
            helper = home / 'peer'; helper.write_bytes(b'bounded inert peer')
            app = home / 'tisra'; app.write_bytes(b'bounded inert app')
            registry = RegisteredPeerVerifier({'tisra'})
            text = CodexTextAdapter(binary, enabled=True)
            priority = PriorityHostConfig(
                (ResourcePolicy('model', slots=1, realtime_reserved=0,
                                background_start_limit_ms=12000),),
                (TaskPolicy(NAME, 'model.inference', 'model',
                            owners=frozenset({'tisra'}), maximum_class='interactive',
                            estimate_floor_ms=100, execution_budget_ms=12000),),
                {'tisra': AppProfilePolicy(frozenset({'background', 'interactive'}),
                                           max_deadline_ms=30000)}, 10000)
            calls = []
            reject_review = [False]
            def review(owner, tool, args):
                if reject_review[0]: raise Fault('research_review_not_authorized')
                calls.append((owner, tool, args))
            activation = FormalResearchActivation(FormalTisraPeer(helper), registry,
                text, 'synthetic-model', 'auth-v1', priority, review, 'review-v1')
            with patch('arl.formal_research_host.DEFAULT_BINARY', binary), \
                 patch('arl.formal_research_host.TISRA_EXECUTABLE', app), \
                 patch('arl.formal_research_host.HELPER_SHA256', hashlib.sha256(helper.read_bytes()).hexdigest()), \
                 patch('arl.formal_research_host.TISRA_EXECUTABLE_SHA256', hashlib.sha256(app.read_bytes()).hexdigest()), \
                 patch.object(registry, 'registration_subject', return_value='current-subject'):
                runtime = compose_formal_research(home / 'runtime', activation)
                engine = runtime.research_engines[NAME]
                store = Store(home / 'state.sqlite')
                runtime.store = store
                engine.attach(store)
                runtime.bind_priority()
                runtime.ready.set()
                with patch.object(text, 'preflight_model', return_value={
                    'model': 'synthetic-model', 'ephemeral': True,
                    'read_only': True, 'synthetic': False}):
                    runtime.priority_producer.probe_native('tisra', 'synthetic-model')
                runtime.priority_authority.negotiate_v2(
                    'tisra', 'tisra', {'classes': ['background', 'interactive']})
                policy = runtime.policies['tisra']
                def dispatch(method, args):
                    return engine.dispatch('tisra', method, args, policy)
                def upload(raw, purpose, run):
                    value = dispatch('codex.payload.begin.v1', {
                        'purpose': purpose, 'run_id': run, 'epoch': 0,
                        'sha256': sha(raw), 'byte_count': len(raw)})
                    for index, offset in enumerate(range(0, len(raw), 8192)):
                        chunk = raw[offset:offset + 8192]
                        dispatch('codex.payload.write.v1', {
                            'payload_id': value['payload_id'], 'index': index,
                            'data_base64': base64.b64encode(chunk).decode(),
                            'sha256': sha(chunk)})
                    ref = {'payload_id': value['payload_id'], 'sha256': sha(raw),
                           'byte_count': len(raw)}
                    dispatch('codex.payload.seal.v1', ref)
                    return ref
                run = str(uuid.uuid4()); raw = request(); meta = descriptor(raw, run)
                args = {
                    'schema_version': 1, 'run_id': run, 'epoch': 0,
                    'request': upload(raw, contract.REQUEST, run),
                    'descriptor': upload(encode(meta), contract.DESCRIPTOR, run),
                    'provider': 'codex_app_server', 'model': 'synthetic-model',
                    'model_fingerprint': engine.adapters['codex_app_server'].model_fingerprints['synthetic-model'],
                    'request_format': contract.REQUEST,
                    'output_format': contract.RESPONSE,
                    'history_version': contract.FORMATS[2],
                    'max_output_tokens': None, 'max_output_bytes': 128,
                    'priority': 'explicit', 'deadline_ms': 25000,
                }
                first = dispatch('codex.research.submit.v1', args)
                self.assertEqual(first['run_id'], run)
                self.assertEqual(first['state'], 'queued')
                self.assertEqual(calls[-1], ('tisra', NAME, args))
                for table in ('jobs', 'research_runs', 'formal_research_reviews'):
                    self.assertEqual(store.db.execute('SELECT count(*) FROM ' + table).fetchone()[0], 1)
                self.assertEqual(store.db.execute('SELECT count(*) FROM research_native').fetchone()[0], 0)
                self.assertEqual(dispatch('codex.research.submit.v1', args)['job_id'], first['job_id'])
                for table in ('jobs', 'research_runs', 'formal_research_reviews'):
                    self.assertEqual(store.db.execute('SELECT count(*) FROM ' + table).fetchone()[0], 1)

                run2 = str(uuid.uuid4()); raw2 = request(); meta2 = descriptor(raw2, run2)
                second = dict(args, run_id=run2,
                    request=upload(raw2, contract.REQUEST, run2),
                    descriptor=upload(encode(meta2), contract.DESCRIPTOR, run2))
                reject_review[0] = True
                with self.assertRaises(Fault) as blocked:
                    dispatch('codex.research.submit.v1', second)
                reject_review[0] = False
                self.assertEqual(blocked.exception.code, 'research_review_not_authorized')
                for table in ('jobs', 'research_runs', 'formal_research_reviews'):
                    self.assertEqual(store.db.execute('SELECT count(*) FROM ' + table).fetchone()[0], 1)
                self.assertFalse(store.db.in_transaction)
                with self.assertRaises(Fault) as missing:
                    ResearchEngine.dispatch(engine, 'tisra',
                        'research.capabilities.v1', {}, policy, in_transaction=True)
                self.assertEqual(missing.exception.code, 'research_transaction_missing')

                bound = {key: first[key] for key in
                         ('job_id', 'run_id', 'request_sha256', 'epoch')}
                persisted = store.db.execute(
                    'SELECT * FROM research_runs WHERE job=?', (first['job_id'],)).fetchone()
                runtime.admission = runtime.admission  # A new review epoch revokes the old pin.
                self.assertTrue(engine.invalid(persisted))
                with store.transaction():
                    store.db.execute('DELETE FROM formal_research_reviews WHERE job=?',
                                     (first['job_id'],))
                persisted = store.db.execute(
                    'SELECT * FROM research_runs WHERE job=?', (first['job_id'],)).fetchone()
                self.assertTrue(engine.invalid(persisted))
                with self.assertRaises(Fault) as fenced:
                    engine.external_admission(persisted)
                self.assertEqual(fenced.exception.code, 'research_review_not_authorized')
                engine.complete(store.row('tisra', first['job_id']), b'opaque synthetic result')
                self.assertEqual(store.db.execute(
                    "SELECT count(*) FROM research_payloads WHERE state='sealed' AND purpose=?",
                    (contract.RESPONSE,)).fetchone()[0], 0)
                status = dispatch('codex.research.status.v1', bound)
                self.assertIn(status['state'], {'cancelled', 'needs_review'})
                self.assertIsNone(status['result_ref'])
                engine.grants.pop('tisra')
                cancelled = dispatch('codex.research.cancel.v1', bound)
                self.assertIn(cancelled['state'], {'cancelled', 'needs_review'})
                self.assertIsNone(cancelled['result_ref'])
                self.assertEqual(store.db.execute('SELECT count(*) FROM research_native').fetchone()[0], 0)
                store.close()


if __name__ == '__main__':
    unittest.main()
