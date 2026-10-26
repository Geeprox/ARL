"""Decisive consumer-return/terminal-publication interleavings, local only."""
from dataclasses import replace
import hashlib
import json
import threading
import time
import unittest
from unittest.mock import patch

from arl.contracts import Fault, Tool, encode
import arl.service as service
import arl.storage as storage
from arl.nas_upload_consumer import NAME
from test_upload_consumer import Fixture

OBSERVATIONS = []


def interleaving(action='cancel', *, at='runtime_encode'):
    """Same original reviewer cut: encode after handler return, before finish."""
    f = Fixture(size=1025)
    events = []
    target_module = service if at == 'runtime_encode' else storage
    original_encode = target_module.encode
    try:
        f.submit()
        def intervene(value):
            if type(value) is dict and value.get('status') == 'committed' and not events:
                assert 'runtime_publish' in f.verified_stages
                before = dict(f.runtime.store.row(f.owner, f.job['id']))
                assert before['state'] == 'running' and before['cancel'] == 0
                event = {'point': at + '_after_consumer_return_before_publication',
                         'action': action, 'before_state': before['state'], 'before_cancel': before['cancel']}
                events.append(event)
                if action == 'cancel':
                    event['cancel_reply'] = f.request('cancel', {'id': f.job['id']})
                elif action == 'deadline':
                    with f.runtime.store.transaction():
                        f.runtime.store.db.execute('UPDATE jobs SET deadline_at=? WHERE id=?',
                            (time.time() - 1, f.job['id']))
                elif action == 'peer':
                    f.registrations.revoke(f.pid)
                elif action == 'policy':
                    f.runtime.policies.pop(f.owner)
                elif action == 'binding':
                    f.binding = replace(f.binding, credential_generation='d' * 32)
                elif action == 'consumer':
                    f.consumer.revoke()
                after = dict(f.runtime.store.row(f.owner, f.job['id']))
                event['after_cancel'] = after['cancel']
            return original_encode(value)
        with patch.object(target_module, 'encode', intervene):
            result = f.run_worker()
        row = dict(f.runtime.store.row(f.owner, f.job['id']))
        assert len(events) == 1 and len(f.consume_calls) == 1 and f.medium.calls['commit'] == 1
        assert f.final.read_bytes() == f.source_path.read_bytes() == f.data(1025)
        audit = [dict(row) for row in f.runtime.store.db.execute(
            'SELECT at,event FROM audit WHERE owner=? AND job=? ORDER BY seq', (f.owner, f.job['id']))]
        observation = {'action': action, 'at': at, 'events': events, 'job': result,
            'durable_cancel': row['cancel'], 'attempts': row['attempts'], 'audit': audit,
            'consume_calls': f.consume_calls, 'medium_calls': dict(f.medium.calls),
            'final_bytes': len(f.final.read_bytes()), 'final_sha256': hashlib.sha256(f.final.read_bytes()).hexdigest(),
            'core_receipt': json.loads(next(f.jhome.glob('upload_new_op_*.json')).read_text()),
            'native_consume_write_admission_process_observation_synthetic': True}
        try:
            f.runtime.store.resume(f.owner, f.job['id'])
        except Fault as error:
            observation['resume_error'] = error.code
        f.runtime.store.recover({NAME: f.consumer.tool()})
        observation['replay_claim'] = f.runtime.store.claim()
        OBSERVATIONS.append(observation)
        return observation
    finally:
        f.close()


class CompletionChecks(unittest.TestCase):
    def held_fact(self, action, reason, **kwargs):
        value = interleaving(action, **kwargs)
        job = value['job']
        self.assertEqual((job['state'], job['error']), ('needs_review', 'completion_' + reason))
        self.assertEqual(job['result']['status'], 'needs_review')
        self.assertEqual(job['result']['effect']['status'], 'committed')
        self.assertEqual(job['result']['effect']['bytes_confirmed'], 1025)
        self.assertEqual(job['result']['effect']['content_sha256'], value['final_sha256'])
        self.assertEqual(value['core_receipt']['state'], 'committed')
        self.assertEqual(value['resume_error'], 'not_resumable')
        self.assertIsNone(value['replay_claim'])
        return value

    def test_original_reviewer_post_return_cancel_now_held_with_commit_fact(self):
        value = self.held_fact('cancel', 'cancelled')
        completion = value['job']['result']['completion']
        self.assertEqual(value['durable_cancel'], 1)
        self.assertEqual(completion['cancel_timing'], 'after_consumer_return_before_publication')
        cancel_at = next(row['at'] for row in value['audit'] if row['event'] == 'cancel_requested')
        self.assertEqual(completion['cancel_requested_at'], cancel_at)
        self.assertLess(completion['effect_observed_at'], cancel_at)
        self.assertLessEqual(cancel_at, completion['publication_decided_at'])

    def test_post_return_persistent_deadline_blocks_positive_but_preserves_fact(self):
        self.held_fact('deadline', 'expired')

    def test_post_return_peer_revoke_blocks_positive_but_preserves_fact(self):
        self.held_fact('peer', 'revoked')

    def test_post_return_policy_revoke_blocks_positive_but_preserves_fact(self):
        self.held_fact('policy', 'revoked')

    def test_post_return_credential_binding_change_preserves_committed_effect(self):
        self.held_fact('binding', 'source_changed')

    def test_post_return_consumer_revoke_preserves_committed_effect(self):
        self.held_fact('consumer', 'revoked')

    def test_store_input_encoding_before_transaction_also_fences_cancel(self):
        self.held_fact('cancel', 'cancelled', at='store_encode')

    def test_no_cancel_fenced_completion_publishes_positive(self):
        f = Fixture(size=1025)
        try:
            f.submit()
            result = f.run_worker()
            self.assertEqual(result['state'], 'succeeded')
            self.assertEqual(result['result']['status'], 'committed')
            completion = result['result']['completion']
            self.assertIsNone(completion['reason'])
            self.assertEqual(completion['cancel_timing'], 'none_before_publication')
            self.assertEqual(f.final.read_bytes(), f.data(1025))
            self.assertEqual(f.medium.calls['commit'], 1)
            self.assertEqual(len(f.consume_calls), 1)
            OBSERVATIONS.append({'name': 'fenced_success', 'job': result, 'commit_calls': 1})
        finally:
            f.close()

    def test_cancel_transaction_waiting_on_publication_linearizes_after_it(self):
        f = Fixture(size=1025)
        started, completed = threading.Event(), threading.Event()
        thread = None
        replies = []
        original_encode = storage.encode
        try:
            f.submit()
            def cancel():
                started.set()
                replies.append(f.runtime.store.cancel(f.owner, f.job['id']))
                completed.set()
            def encode_during_transaction(value):
                nonlocal thread
                if (type(value) is dict and value.get('status') == 'committed'
                        and value.get('completion', {}).get('protocol') == 'store.transaction.v1' and thread is None):
                    self.assertTrue(f.runtime.store.db.in_transaction)
                    thread = threading.Thread(target=cancel)
                    thread.start()
                    self.assertTrue(started.wait(1))
                    self.assertFalse(completed.is_set())
                return original_encode(value)
            with patch.object(storage, 'encode', encode_during_transaction):
                result = f.run_worker()
            thread.join(2)
            self.assertFalse(thread.is_alive())
            self.assertTrue(completed.is_set())
            self.assertEqual((result['state'], replies[0]['state']), ('succeeded', 'succeeded'))
            row = dict(f.runtime.store.row(f.owner, f.job['id']))
            self.assertEqual(row['cancel'], 0)
            audit = [dict(row) for row in f.runtime.store.db.execute(
                'SELECT at,event FROM audit WHERE job=? ORDER BY seq', (f.job['id'],))]
            later = next(row for row in audit if row['event'] == 'cancel_after_fenced_completion')
            self.assertGreaterEqual(later['at'], result['result']['completion']['publication_decided_at'])
            self.assertEqual(f.medium.calls['commit'], 1)
            OBSERVATIONS.append({'name': 'cancel_waits_for_same_store_transaction', 'job': result,
                                 'later_cancel_reply': replies[0], 'audit': audit, 'durable_cancel': row['cancel']})
        finally:
            if thread is not None:
                thread.join(2)
            f.close()

    def test_legacy_nonidempotent_and_idempotent_completion_semantics_unchanged(self):
        for idempotent, expected in ((False, 'succeeded'), (True, 'cancelled')):
            with self.subTest(idempotent=idempotent):
                f = Fixture(size=0)
                try:
                    tool = Tool(NAME, f.consumer.tool().schema,
                        lambda args, context: {'status': 'committed'}, idempotent=idempotent,
                        permissions=('fixture_only',))
                    f.runtime.tools[NAME] = tool
                    f.runtime.admission = None
                    f.submit()
                    original_encode = service.encode
                    events = []
                    def cancel_after_return(value):
                        if type(value) is dict and value.get('status') == 'committed' and not events:
                            events.append(f.request('cancel', {'id': f.job['id']}))
                        return original_encode(value)
                    with patch.object(service, 'encode', cancel_after_return):
                        result = f.run_worker()
                    self.assertEqual(result['state'], expected)
                    self.assertEqual(dict(f.runtime.store.row(f.owner, f.job['id']))['cancel'], 1)
                    original_contract = {'name': tool.name, 'version': tool.version, 'schema': tool.schema,
                        'permissions': tool.permissions, 'requires_identity': tool.requires_identity,
                        'idempotent': tool.idempotent}
                    self.assertEqual(tool.contract_digest(), hashlib.sha256(encode(original_contract)).hexdigest())
                    self.assertEqual(f.consume_calls, [])
                    self.assertEqual(sum(f.medium.calls.values()), 0)
                    OBSERVATIONS.append({'name': 'legacy_semantics', 'idempotent': idempotent, 'job': result})
                finally:
                    f.close()

    def test_stale_fenced_completion_cannot_overwrite_terminal_row(self):
        f = Fixture(size=0)
        try:
            f.submit()
            row = f.runtime.store.claim()
            f.runtime.store.finish(row, 'needs_review', error='already_held')
            called = []
            self.assertFalse(f.runtime.store.finish_fenced(row, {'status': 'committed'},
                verify=lambda: called.append(True), effect_observed_at=time.time()))
            self.assertEqual(called, [])
            self.assertEqual(f.runtime.store.get(f.owner, f.job['id'])['error'], 'already_held')
            self.assertEqual(f.consume_calls, [])
        finally:
            f.close()


if __name__ == '__main__':
    unittest.main()
