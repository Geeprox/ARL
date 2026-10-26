"""Existing Runtime/Store/JobContext domain, generated POSIX bytes only.

No Runtime.run(), listener, real peer, native journal, credential broker,
provider/vendor or NAS executes. Only process_identity is a deterministic
fixture; registration/capture/revocation logic, queue, budget, worker, deadlines
and cancellation are the actual candidate ARL implementations.
"""
from dataclasses import asdict, replace
import hashlib
import json
import os
from pathlib import Path
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
import uuid

from arl import PROTOCOL
from arl.contracts import AppPolicy, Fault
from arl.identity import RegisteredPeerVerifier
from arl.nas_upload_consumer import NAME, JournalPolicy, RuntimeUploadConsumer, UploadResources
from arl.providers import MockProvider
from arl.service import JobContext, Runtime, default_policies
from arl.storage import Store
from arl_nas_upload_new.contracts import OwnerBinding, UploadFault, UploadPlan
from controlled_upload_medium import ControlledMedium

OBSERVATIONS = []


class NoTools:
    def tools(self):
        return []
    descriptors = ()


class Fixture:
    def __init__(self, *, max_calls=1, admitted=True, size=131079, policy_budget=1,
                 native_available=True, medium_available=True):
        self.temp = tempfile.TemporaryDirectory(prefix='arl-upload-domain-', dir='/tmp')
        self.home = Path(self.temp.name)
        self.owner, self.pid = 'upload_fixture', 41001
        self.identity = {'uid': os.geteuid(), 'birth': (1, 2), 'executable': '/usr/bin/true'}
        self.mock = patch('arl.identity.process_identity', return_value=self.identity)
        self.mock.start()
        self.registrations = RegisteredPeerVerifier({self.owner})
        self.registrations.register(self.owner, self.pid, '/usr/bin/true')
        self.peer = self.registrations.capture_registration(self.owner, self.pid)
        self.plan = UploadPlan(str(uuid.uuid4()), str(uuid.uuid4()), 'a' * 64, 'b' * 64,
            'c' * 32, self.peer.epoch, 'album/new.bin', size,
            hashlib.sha256(self.data(size)).hexdigest())
        self.binding = OwnerBinding.for_plan(self.plan)
        self.write_admitted, self.verify_hook, self.consume_hook = admitted, None, None
        self.verify_reply = None
        self.consume_calls, self.verified_stages = [], []
        self.root, self.stage, self.jhome = [self.home / n for n in ('root', 'stage', 'existing_journal')]
        for p in (self.root, self.stage, self.jhome, self.root / 'album'):
            p.mkdir(mode=0o700)
        self.source_path = self.home / 'sealed_source.bin'
        self.source_path.write_bytes(self.data(size))
        self.source_path.chmod(0o600)
        self.sfd = os.open(self.source_path, os.O_RDONLY | os.O_NOFOLLOW)
        self.jfd = os.open(self.jhome, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        self.spin, self.jpin = os.fstat(self.sfd), os.fstat(self.jfd)
        self.medium = ControlledMedium(self.root, self.stage, namespace_hash=self.plan.namespace_hash)
        resources = UploadResources(self.sfd, self.jfd, self.verify_source, self.verify_journal,
            lambda: self.binding, self.verify_write, self.consume if native_available else None,
            self.medium if medium_available else None)
        self.consumer = RuntimeUploadConsumer(plan=self.plan, peer=self.peer, resources=resources,
            journal_policy=JournalPolicy(self.owner, 17, policy_budget))
        self.policy = AppPolicy(frozenset({NAME}), frozenset({'mock'}), max_pending=2, max_calls=max_calls,
            methods=frozenset({'submit', 'get', 'cancel', 'resume'}))
        self.runtime = Runtime(self.home / 'runtime', policies={self.owner: self.policy},
            extra_tools=[self.consumer.tool()], admission=self.consumer.admit,
            identity_verifier=self.registrations, apple=NoTools(), travel=NoTools(),
            providers={'mock': MockProvider()})
        self.runtime.store = Store(self.runtime.home / 'state.sqlite')
        self.runtime.ready.set()
        self.consumer.attach(self.runtime)
        self.job = None

    @staticmethod
    def data(size):
        return (bytes(range(256)) * (size // 256 + 1))[:size]

    def verify_source(self):
        st = self.source_path.lstat()
        if (st.st_dev, st.st_ino) != (self.spin.st_dev, self.spin.st_ino):
            raise UploadFault('source_changed')

    def verify_journal(self):
        st = self.jhome.lstat()
        if (st.st_dev, st.st_ino) != (self.jpin.st_dev, self.jpin.st_ino):
            raise UploadFault('journal_uncertain')

    def verify_write(self, stage):
        self.verified_stages.append(stage)
        if self.verify_hook:
            self.verify_hook(stage)
        if not self.write_admitted:
            raise UploadFault('revoked')
        return self.verify_reply

    def consume(self, operation, permit, subject, epoch, budget):
        # Synthetic native five-argument stand-in. Not Swift/native proof.
        self.consume_calls.append((operation, permit, subject, epoch, budget))
        if self.consume_hook:
            self.consume_hook()

    def request(self, method='submit', params=None, verified=True):
        if params is None:
            params = {'tool': NAME, 'args': self.consumer.arguments(), 'key': self.plan.operation_id}
        return self.runtime.dispatch({'protocol': PROTOCOL, 'app': self.owner,
            'method': method, 'params': params}, verified_app=self.owner if verified else None)

    def submit(self):
        self.job = self.request()
        return self.job

    def run_worker(self):
        errors = []
        def run():
            try:
                self.runtime.work()
            except BaseException as error:
                errors.append(type(error).__name__)
        thread = threading.Thread(target=run)
        thread.start()
        try:
            deadline = time.monotonic() + 4
            while time.monotonic() < deadline:
                result = self.runtime.store.get(self.owner, self.job['id'])
                if result['state'] in {'succeeded', 'failed', 'cancelled', 'needs_review'}:
                    return result
                threading.Event().wait(.005)
            raise AssertionError('bounded_worker_timeout')
        finally:
            self.runtime.stopping.set()
            self.runtime.job_signal.set()
            thread.join(2)
            assert not thread.is_alive() and not errors

    @property
    def final(self):
        return self.root / self.plan.target

    def observe(self, name, result):
        OBSERVATIONS.append({'name': name, 'result': result, 'medium_calls': dict(self.medium.calls),
            'native_consume_is_synthetic': True, 'consume_calls': self.consume_calls,
            'final': None if not self.final.exists() else {'size': self.final.stat().st_size,
                'sha256': hashlib.sha256(self.final.read_bytes()).hexdigest()},
            'runtime_budget': self.runtime.store.db.execute(
                'SELECT calls FROM budget WHERE owner=?', (self.owner,)).fetchone()[0]})

    def close(self):
        self.runtime.stopping.set()
        self.medium.hooks.clear()
        self.medium.close()
        self.runtime.store.close()
        os.close(self.sfd)
        os.close(self.jfd)
        self.mock.stop()
        self.temp.cleanup()


class ConsumerChecks(unittest.TestCase):
    def fixture(self, **kwargs):
        f = Fixture(**kwargs)
        self.addCleanup(f.close)
        return f

    def fault(self, code, call):
        with self.assertRaises(Fault) as result:
            call()
        self.assertEqual(result.exception.code, code)

    def test_default_runtime_has_no_upload_tool_or_grant(self):
        self.assertTrue(all(NAME not in p.tools for p in default_policies().values()))
        consumer = RuntimeUploadConsumer()
        self.assertFalse(consumer.tool().idempotent)
        self.assertTrue(consumer.tool().requires_identity)
        self.fault('nas_upload_invalid_arguments', lambda: consumer.admit('friday', NAME, {}))
        with tempfile.TemporaryDirectory(prefix='upload-default-', dir='/tmp') as home:
            runtime = Runtime(home, apple=NoTools(), travel=NoTools(), providers={'mock': MockProvider()})
            self.assertNotIn(NAME, runtime.tools)

    def test_unverified_app_or_boolean_write_admission_cannot_enter(self):
        f = self.fixture()
        self.fault('app_identity_unverified', lambda: f.request(verified=False))
        f.verify_reply = True
        self.fault('nas_upload_unsupported', f.submit)
        self.assertEqual(f.consume_calls, [])
        self.assertEqual(sum(f.medium.calls.values()), 0)

    def test_real_worker_exact_bytes_and_distinct_logical_budget(self):
        f = self.fixture()
        f.medium.partial_limit = 10000
        f.submit()
        result = f.run_worker()
        self.assertEqual(result['state'], 'succeeded')
        self.assertEqual(result['result']['status'], 'committed')
        self.assertEqual(f.final.read_bytes(), f.data(f.plan.size))
        self.assertGreater(f.medium.calls['write'], 1)
        self.assertEqual(f.consume_calls, [(f.plan.operation_id, f.plan.permit_id, f.owner, 17, 1)])
        self.assertTrue(os.fstat(f.sfd) and os.fstat(f.jfd))
        f.observe('worker_committed_actual_generated_bytes', result)

    def test_runtime_budget_persists_and_duplicate_submit_does_not_charge(self):
        f = self.fixture()
        first = f.submit()
        self.assertEqual(f.request()['id'], first['id'])
        self.fault('call_budget_exceeded', lambda: f.request(params={
            'tool': NAME, 'args': f.consumer.arguments(), 'key': 'second-key'}))
        path = f.runtime.home / 'state.sqlite'
        f.runtime.store.close()
        f.runtime.store = Store(path)
        self.fault('nas_upload_revoked', f.request)  # consumer's captured Store cannot be replaced
        self.assertEqual(f.runtime.store.db.execute('SELECT calls FROM budget').fetchone()[0], 1)
        self.assertEqual(f.consume_calls, [])
        f.observe('budget_1_persists_no_generation_reset', first)

    def test_actual_cancel_queued_has_zero_medium_effects(self):
        f = self.fixture()
        f.submit()
        result = f.request('cancel', {'id': f.job['id']})
        self.assertEqual(result['state'], 'cancelled')
        self.assertIsNone(f.runtime.store.claim())
        self.assertEqual(f.consume_calls, [])
        self.assertFalse(f.final.exists())
        f.observe('queued_cancel_actual_store', result)

    def test_actual_cancel_running_before_write_blocks_effect_and_retry(self):
        f = self.fixture()
        f.medium.hooks['before_write'] = lambda _: f.request('cancel', {'id': f.job['id']})
        f.submit()
        result = f.run_worker()
        self.assertEqual((result['state'], result['error']), ('needs_review', 'nas_upload_cancelled'))
        self.assertEqual(f.medium.calls['write'], 0)
        self.assertEqual(len(f.consume_calls), 1)
        self.fault('not_resumable', lambda: f.runtime.store.resume(f.owner, f.job['id']))
        f.runtime.store.recover({NAME: f.consumer.tool()})
        self.assertIsNone(f.runtime.store.claim())
        f.observe('running_cancel_no_write_no_replay', result)

    def test_peer_reregister_same_pid_invalidates_captured_epoch(self):
        f = self.fixture()
        f.submit()
        f.registrations.register(f.owner, f.pid, '/usr/bin/true')
        self.assertTrue(f.registrations.is_registered(f.owner, f.pid))
        self.assertFalse(f.peer.is_current())
        result = f.run_worker()
        self.assertEqual(result['state'], 'failed')
        self.assertEqual(f.consume_calls, [])
        self.assertEqual(sum(f.medium.calls.values()), 0)
        f.observe('same_pid_new_registration_not_old_authority', result)

    def test_policy_revoked_after_claim_before_effect(self):
        f = self.fixture()
        f.medium.hooks['before_create'] = lambda _: f.runtime.policies.pop(f.owner)
        f.submit()
        result = f.run_worker()
        self.assertEqual((result['state'], result['error']), ('needs_review', 'nas_upload_revoked'))
        self.assertEqual(f.medium.calls['create'], 0)
        f.observe('policy_revoked_before_stage_effect', result)

    def test_source_binding_change_before_write_blocks_actual_effect(self):
        f = self.fixture()
        f.medium.hooks['before_write'] = lambda _: setattr(f, 'binding', replace(f.binding,
            credential_generation='d' * 32))
        f.submit()
        result = f.run_worker()
        self.assertEqual((result['state'], result['error']), ('needs_review', 'nas_upload_source_changed'))
        self.assertEqual(f.medium.calls['write'], 0)
        f.observe('credential_generation_changed_before_write', result)

    def test_slow_write_authorizer_renews_actual_deadline(self):
        f = self.fixture()
        captured = []
        def capture(runtime, row):
            context = JobContext(runtime, row)
            captured.append(context)
            return context
        def verify(stage):
            if stage == 'write_effect':
                # Actual claimed JobContext expiry, at the host verification return.
                captured[0].deadline = time.monotonic() - 1
        f.verify_hook = verify
        f.submit()
        with patch('arl.service.JobContext', side_effect=capture):
            result = f.run_worker()
        self.assertEqual((result['state'], result['error']), ('needs_review', 'nas_upload_expired'))
        self.assertEqual(f.medium.calls['write'], 0)
        f.observe('deadline_renewed_after_write_authorizer', result)

    def test_native_budget_denial_consumes_no_medium_effect(self):
        f = self.fixture(policy_budget=2)
        def deny():
            raise Fault('effect_budget_exceeded')
        f.consume_hook = deny
        f.submit()
        result = f.run_worker()
        self.assertEqual((result['state'], result['error']), ('needs_review', 'nas_upload_budget_exceeded'))
        self.assertEqual(len(f.consume_calls), 1)
        self.assertEqual(f.consume_calls[0][-1], 2)
        self.assertEqual(sum(f.medium.calls.values()), 0)
        f.observe('native_logical_budget_denial_is_not_io_128', result)

    def test_shutdown_at_effect_keeps_uncertainty_and_claims(self):
        f = self.fixture()
        f.medium.hooks['before_write'] = lambda _: f.runtime.stopping.set()
        f.submit()
        result = f.run_worker()
        self.assertEqual(result['state'], 'needs_review')
        self.assertEqual(f.medium.calls['write'], 0)
        self.assertEqual(len(f.consume_calls), 1)
        self.assertTrue(any(p.name.startswith('upload_new_op_') for p in f.jhome.iterdir()))
        f.observe('runtime_shutdown_no_late_write', result)

    def test_late_cancel_after_commit_withholds_positive_and_no_replay(self):
        f = self.fixture()
        f.medium.hooks['after_commit'] = lambda _: f.request('cancel', {'id': f.job['id']})
        f.submit()
        result = f.run_worker()
        self.assertEqual(result['state'], 'needs_review')
        self.assertEqual(f.medium.calls['commit'], 1)
        self.assertEqual(f.final.read_bytes(), f.data(f.plan.size))
        self.assertEqual(f.consumer.last_result.status, 'uncertain')
        f.runtime.store.recover({NAME: f.consumer.tool()})
        self.assertIsNone(f.runtime.store.claim())
        f.observe('actual_bytes_published_late_cancel_no_positive_no_replay', result)

    def test_unavailable_medium_and_native_bridge_are_closed_before_loans(self):
        f = self.fixture(native_available=False, medium_available=False)
        self.fault('nas_upload_unsupported', f.submit)
        self.assertEqual(sum(f.medium.calls.values()), 0)
        self.assertEqual(list(f.jhome.iterdir()), [])

    def test_client_cannot_change_plan_path_subject_epoch_or_budget(self):
        f = self.fixture()
        for field in ('source_path', 'target', 'subject', 'policy_epoch', 'budget', 'approved'):
            args = dict(f.consumer.arguments(), **{field: 1})
            self.fault('invalid_arguments', lambda: f.request(params={
                'tool': NAME, 'args': args, 'key': f.plan.operation_id}))
        self.assertEqual(f.consume_calls, [])
        self.assertEqual(sum(f.medium.calls.values()), 0)
        self.fault('nas_upload_invalid_policy', lambda: JournalPolicy(f.owner, 17, 128))

    def test_different_job_key_cannot_reexecute_captured_operation(self):
        f = self.fixture(max_calls=2)
        first = f.submit()
        f.job = f.request(params={'tool': NAME, 'args': f.consumer.arguments(), 'key': 'different-key'})
        result = f.run_worker()
        self.assertEqual((result['state'], result['error']), ('needs_review', 'nas_upload_binding_mismatch'))
        self.assertEqual(f.runtime.store.get(f.owner, first['id'])['state'], 'succeeded')
        self.assertEqual(len(f.consume_calls), 1)
        self.assertEqual(f.medium.calls['create'], 1)
        self.assertEqual(f.medium.calls['commit'], 1)
        f.observe('new_job_key_does_not_replay_captured_operation', result)

    def test_peer_revoked_during_write_authorization_blocks_effect(self):
        f = self.fixture()
        f.verify_hook = lambda stage: f.registrations.revoke(f.pid) if stage == 'write_effect' else None
        f.submit()
        result = f.run_worker()
        self.assertEqual((result['state'], result['error']), ('needs_review', 'nas_upload_revoked'))
        self.assertEqual(f.medium.calls['write'], 0)
        f.observe('peer_revoked_inside_blocking_authorizer', result)

    def test_replaced_host_resource_bundle_is_not_current_authority(self):
        f = self.fixture()
        f.medium.hooks['before_write'] = lambda _: setattr(f.consumer, 'resources', replace(f.consumer.resources))
        f.submit()
        result = f.run_worker()
        self.assertEqual((result['state'], result['error']), ('needs_review', 'nas_upload_unsupported'))
        self.assertEqual(f.medium.calls['write'], 0)
        f.observe('equal_descriptor_new_resource_bundle_rejected', result)


if __name__ == '__main__':
    unittest.main()
