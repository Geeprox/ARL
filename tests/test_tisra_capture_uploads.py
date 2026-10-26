"""Concrete finite upload storage over the actual Store/SQLite and arl/1.

Native capture effects use the existing synthetic consumer; these tests prove
upload byte/authority binding, not native Ledger semantics. The macOS socket
case additionally exercises genuine kernel source identity with the existing
RegisteredPeerVerifier, including rejection of an unregistered process.
"""
from __future__ import annotations

import base64
import json
import os
import socket
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from dataclasses import replace
from pathlib import Path

from arl import PROTOCOL
from arl.contracts import AppPolicy, Fault, encode
from arl.identity import RegisteredPeerVerifier, process_identity
from arl.service import Handler, JobContext, Runtime, Server, default_policies
from arl.storage import Store
from arl.tisra_capture_contract import MAX_REQUEST_BYTES, NAME, CaptureCodec
from arl.tisra_capture_runtime import (
    CODEC, SCHEMA_SHA256, CaptureConsumerPin,
    CapturePayloadRequest, RegisteredCaptureParticipant,
)
from arl.tisra_capture_uploads import CHUNK_BYTES, METHODS, UploadedCaptureRuntime
from tests.test_tisra_capture_runtime import ConsumerDouble, FIXTURES, sha, uid


class CaptureUploadTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='arl-capture-upload-v2-')
        self.home = Path(self.temp.name)
        self.raw = (FIXTURES / 'metadata-request.json').read_bytes()
        self.result = (FIXTURES / 'metadata-created.receipt.json').read_bytes()
        self.library, self.instance = uid(), uid()
        self.participant = RegisteredCaptureParticipant('upload-peer-opaque', 'agent', 'Epoch/7:λ')
        self.pin = CaptureConsumerPin(self.library, self.instance, 'b' * 64)
        self.consumer = ConsumerDouble(self.pin, self.result)
        self.registered = self.allowed = True
        self.valid_requests = {self.raw}
        def validate_request(raw):
            if raw not in self.valid_requests:
                raise ValueError('fixture only')
        self.codec = CaptureCodec(CODEC, SCHEMA_SHA256, validate_request, lambda *_: None)
        self.policy = AppPolicy(frozenset({NAME}), methods=METHODS, max_pending=16)
        self.engine = self.make_engine()
        self.runtime = self.make_runtime(self.engine)
        self.runtime.store = Store(self.home / 'state.sqlite')
        self.engine.attach(self.runtime.store)
        self.runtime.ready.set()

    def make_engine(self, **overrides):
        args = dict(active=True, participants={'tisra': self.participant},
            library_grants={('tisra', self.participant.participant_id): {self.library}},
            method_grants={('tisra', self.participant.participant_id, self.library): METHODS},
            pins={self.library: self.pin}, consumers={self.library: self.consumer}, codec=self.codec,
            registered_peer=lambda *_: self.registered, authorizer=lambda *_: self.allowed)
        args.update(overrides)
        return UploadedCaptureRuntime(**args)

    def make_runtime(self, engine):
        return Runtime(self.home, policies={'tisra': self.policy, 'other': self.policy},
                       capture=engine, identity_verifier=lambda *_: None)

    def tearDown(self):
        self.runtime.store.close()
        self.temp.cleanup()

    def rpc(self, method, params, *, owner='tisra', verified=True):
        return self.runtime.dispatch(dict(protocol=PROTOCOL, app=owner, method=method, params=params),
                                     verified_app=owner if verified else None)

    def fault(self, code, callback):
        with self.assertRaises(Fault) as raised:
            callback()
        self.assertEqual(raised.exception.code, code)

    def begin(self, raw=None, capture_id=None, **changes):
        raw = self.raw if raw is None else raw
        params = dict(capture_request_id=capture_id or uid(), library_id=self.library,
                      sha256=sha(raw), byte_count=len(raw))
        params.update(changes)
        return self.rpc('capture.upload.begin.v2', params), params

    def append(self, payload, raw, offset=0):
        return self.rpc('capture.upload.append.v2', dict(payload_id=payload['payload_id'],
            offset=offset, data_base64=base64.b64encode(raw).decode()))

    def seal(self, payload):
        return self.rpc('capture.upload.seal.v2', {'payload_id': payload['payload_id']})

    def upload(self, raw=None, capture_id=None):
        raw = self.raw if raw is None else raw
        payload, params = self.begin(raw, capture_id)
        for offset in range(0, len(raw), CHUNK_BYTES):
            next_offset = self.append(payload, raw[offset:offset + CHUNK_BYTES], offset)
            self.assertEqual(next_offset['offset'], min(len(raw), offset + CHUNK_BYTES))
        return self.seal(payload), params

    def request(self, ref, params, **changes):
        request = CapturePayloadRequest('tisra', params['capture_request_id'],
                                        self.participant.auth_epoch, **ref)
        return replace(request, **changes)

    def row(self, ref):
        return self.runtime.store.db.execute('SELECT * FROM capture_uploads_v2 WHERE id=?',
                                            (ref['payload_id'],)).fetchone()

    def submission(self, ref, params, **changes):
        request = dict(schema_version=1, capture_request_id=params['capture_request_id'],
                       library_id=self.library, codec=CODEC, consumer_schema_sha256=SCHEMA_SHA256,
                       payload=ref, declared_attribution=None)
        request.update(changes)
        return dict(key=params['capture_request_id'], request=request)

    def restart(self):
        self.runtime.store.close()
        self.engine = self.make_engine()
        self.runtime = self.make_runtime(self.engine)
        self.runtime.store = Store(self.home / 'state.sqlite')
        self.engine.attach(self.runtime.store)
        self.runtime.store.recover(self.runtime.tools)
        self.engine.recover()
        self.runtime.ready.set()

    def test_optional_default_has_no_tables_routes_or_grants(self):
        with tempfile.TemporaryDirectory(prefix='arl-no-capture-upload-') as home:
            runtime = Runtime(Path(home))
            store = Store(Path(home) / 'state.sqlite')
            try:
                self.assertFalse(any('capture' in row[0] for row in store.db.execute(
                    "SELECT name FROM sqlite_master WHERE type='table'")))
                self.assertNotIn(NAME, runtime.tools)
                for policy in default_policies().values():
                    self.assertFalse(METHODS.intersection(policy.methods))
                self.fault('unknown_method', lambda: runtime.dispatch(dict(protocol=PROTOCOL,
                    app='tisra', method='capture.upload.begin.v2', params={}), verified_app='tisra'))
            finally:
                store.close()
        disabled = UploadedCaptureRuntime()
        disabled.bind_runtime(self.runtime)
        disabled.attach(self.runtime.store)
        self.fault('capture_disabled', lambda: disabled.dispatch('tisra', 'capture.upload.begin.v2',
            dict(capture_request_id=uid(), library_id=self.library, sha256=sha(self.raw), byte_count=len(self.raw)),
            self.policy, verified_app='tisra'))

    def test_complete_full_request_limit_and_sealed_immutability(self):
        raw = b'x' * MAX_REQUEST_BYTES
        ref, params = self.upload(raw)
        self.assertEqual(self.engine.payload_resolver.resolve(self.request(ref, params)).raw, raw)
        self.assertEqual(self.seal(ref), ref)
        self.fault('capture_upload_immutable', lambda: self.append(ref, b'x', len(raw)))
        with self.assertRaises(sqlite3.IntegrityError):
            with self.runtime.store.transaction():
                self.runtime.store.db.execute('UPDATE capture_uploads_v2 SET data=? WHERE id=?',
                                               (b'changed', ref['payload_id']))
        self.assertEqual(bytes(self.row(ref)['data']), raw)

    def test_exact_fields_no_owner_path_epoch_purpose_or_enrollment(self):
        for extra in ('owner', 'path', 'purpose', 'auth_epoch', 'participant', 'callback', 'register'):
            with self.subTest(extra=extra):
                self.fault('capture_invalid_arguments', lambda: self.begin(**{extra: 'caller-controlled'}))
        payload, _ = self.begin()
        self.fault('capture_invalid_arguments', lambda: self.rpc('capture.upload.append.v2',
            dict(payload_id=payload['payload_id'], offset=0, data_base64='YQ==', library_id=self.library)))
        self.fault('capture_invalid_arguments', lambda: self.rpc('capture.upload.seal.v2',
            dict(payload_id=payload['payload_id'], sha256=sha(self.raw))))
        self.assertEqual(self.row(payload)['auth_epoch'], self.participant.auth_epoch)
        self.assertEqual(self.row(payload)['purpose'], 'tisra.capture.request.v1')
        self.assertEqual(self.row(payload)['library_id'], self.library)

    def test_begin_declared_hash_size_uuid_and_hard_byte_bounds(self):
        for value in (0, -1, True, 1.0, MAX_REQUEST_BYTES + 1):
            with self.subTest(size=value):
                self.fault('capture_invalid_arguments', lambda: self.begin(byte_count=value))
        for changes in ({'sha256': 'A' * 64}, {'capture_request_id': uid().upper()}, {'library_id': 'no'}):
            self.fault('capture_invalid_arguments', lambda: self.begin(**changes))
        self.assertEqual(self.runtime.store.db.execute('SELECT COUNT(*) FROM capture_uploads_v2').fetchone()[0], 0)

    def test_append_is_exact_contiguous_bounded_canonical_base64(self):
        ref, _ = self.begin(b'abcdef')
        for encoded in ('', 'YQ=', 'YR==', 'YQ==\n', 'é', '!!!!', base64.b64encode(b'x' * 8193).decode()):
            with self.subTest(encoded=encoded[:20]):
                self.fault('capture_invalid_arguments', lambda: self.rpc('capture.upload.append.v2',
                    dict(payload_id=ref['payload_id'], offset=0, data_base64=encoded)))
        for offset in (True, 0.0, -1, MAX_REQUEST_BYTES + 1):
            self.fault('capture_invalid_arguments', lambda: self.append(ref, b'a', offset))
        self.fault('capture_upload_offset_mismatch', lambda: self.append(ref, b'a', 1))
        self.assertEqual(self.append(ref, b'abc')['offset'], 3)
        self.fault('capture_upload_offset_mismatch', lambda: self.append(ref, b'abc', 0))
        self.fault('capture_upload_size_exceeded', lambda: self.append(ref, b'defg', 3))
        self.assertEqual(bytes(self.row(ref)['data']), b'abc')
        self.append(ref, b'def', 3)
        self.seal(ref)

    def test_seal_requires_exact_count_and_hash_before_resolver(self):
        ref, params = self.begin(b'abc')
        self.fault('capture_upload_not_sealed', lambda: self.engine.payload_resolver.resolve(
            self.request({k: ref[k] for k in ('payload_id', 'sha256', 'byte_count')}, params)))
        self.fault('capture_upload_hash_mismatch', lambda: self.seal(ref))
        self.append(ref, b'ab')
        self.fault('capture_upload_hash_mismatch', lambda: self.seal(ref))
        self.append(ref, b'x', 2)
        self.fault('capture_upload_hash_mismatch', lambda: self.seal(ref))
        self.assertEqual(self.row(ref)['state'], 'staging')

    def test_owner_capture_epoch_purpose_hash_count_are_exactly_bound(self):
        ref, params = self.upload()
        for changes in ({'owner': 'other'}, {'capture_request_id': uid()},
                        {'auth_epoch': 'Epoch/7:Λ'}, {'purpose': 'research.request'},
                        {'sha256': '0' * 64}, {'byte_count': len(self.raw) + 1}):
            with self.subTest(changes=changes):
                self.fault('capture_upload_not_found' if 'owner' in changes else 'capture_upload_binding_mismatch',
                    lambda: self.engine.payload_resolver.resolve(self.request(ref, params, **changes)))
        self.fault('capture_upload_not_found', lambda: self.rpc('capture.upload.seal.v2',
            {'payload_id': ref['payload_id']}, owner='other'))

    def test_submission_cannot_rebind_same_owner_upload_to_other_library(self):
        ref, params = self.upload()
        library = uid(); pin = CaptureConsumerPin(library, uid(), 'c' * 64)
        consumer = ConsumerDouble(pin, self.result)
        self.engine.configure(library_grants={('tisra', self.participant.participant_id): {self.library, library}},
            method_grants={('tisra', self.participant.participant_id, self.library): METHODS,
                           ('tisra', self.participant.participant_id, library): METHODS},
            pins={self.library: self.pin, library: pin}, consumers={self.library: self.consumer, library: consumer})
        self.fault('capture_upload_binding_mismatch', lambda: self.rpc('capture.submit.v1',
            self.submission(ref, params, library_id=library)))
        self.assertEqual(consumer.calls, 0)
        receipt = self.rpc('capture.submit.v1', self.submission(ref, params))
        self.assertEqual(receipt['state'], 'queued')

    def test_upload_composes_frozen_execution_confirmation_ack_and_receipt_read(self):
        ref, params = self.upload()
        admitted = self.rpc('capture.submit.v1', self.submission(ref, params))
        job = self.runtime.store.claim()
        context = JobContext(self.runtime, job)
        self.engine.complete(job, self.engine.execute(json.loads(job['args']), context))
        binding = {key: admitted['binding'][key] for key in ('capture_request_id', 'admission_sha256')}
        status = self.rpc('capture.status.v1', binding)
        self.assertEqual(status['state'], 'succeeded')
        self.assertEqual(status['receipt']['writer_app'], 'tisra')
        self.assertEqual(status['receipt']['auth_epoch'], self.participant.auth_epoch)
        result = self.rpc('capture.result.read.v1', dict(binding, offset=0, limit=CHUNK_BYTES))
        self.assertEqual(base64.b64decode(result['data_base64']), self.result)
        self.assertTrue(result['eof'])
        self.assertEqual(self.consumer.writes, 1)
        self.assertEqual(self.consumer.acks, 1)

    def test_status_receipt_stays_coherent_during_terminal_worker_transition(self):
        ref, params = self.upload()
        admitted = self.rpc('capture.submit.v1', self.submission(ref, params))
        job = self.runtime.store.claim()
        commit = self.engine.execute(json.loads(job['args']), JobContext(self.runtime, job))
        binding = {key: admitted['binding'][key] for key in ('capture_request_id', 'admission_sha256')}
        state_read, transition_probed = threading.Event(), threading.Event()
        failures = []
        reader = threading.get_ident()
        original_row = self.runtime.store.row
        paused = False

        def pause_after_state_read(owner, job_id):
            nonlocal paused
            row = original_row(owner, job_id)
            if threading.get_ident() == reader and job_id == job['id'] and not paused:
                paused = True
                state_read.set()
                if not transition_probed.wait(2):
                    raise AssertionError('completion worker did not probe the status transition')
            return row

        def complete_while_status_is_paused():
            acquired = False
            try:
                if not state_read.wait(2):
                    raise AssertionError('status reader did not reach its state read')
                # Give the real completion path a deterministic opportunity to
                # publish between the first state read and the projection. If
                # status holds the publication lock, completion waits until the
                # snapshot returns; otherwise it finishes before that return.
                acquired = self.engine._configuration_lock.acquire(blocking=False)
                if not acquired:
                    transition_probed.set()
                self.engine.complete(job, commit)
            except BaseException as exc:
                failures.append(exc)
            finally:
                if acquired:
                    self.engine._configuration_lock.release()
                transition_probed.set()

        worker = threading.Thread(target=complete_while_status_is_paused, daemon=True)
        self.runtime.store.row = pause_after_state_read
        worker.start()
        try:
            during_transition = self.rpc('capture.status.v1', binding)
        finally:
            self.runtime.store.row = original_row
            worker.join(3)
        self.assertFalse(worker.is_alive(), 'completion worker remained blocked')
        self.assertEqual(failures, [])
        self.assertEqual(during_transition['state'], 'running')
        self.assertIsNone(during_transition['receipt'])
        completed = self.rpc('capture.status.v1', binding)
        self.assertEqual(completed['state'], 'succeeded')
        self.assertIsNotNone(completed['receipt'])
        self.assertEqual(completed['receipt']['result_ref']['sha256'], sha(self.result))
        self.assertEqual(self.consumer.writes, 1)
        self.assertEqual(self.consumer.acks, 1)

    def test_current_app_policy_revocation_blocks_each_byte_effect(self):
        ref, params = self.upload()
        self.runtime.policies['tisra'] = replace(self.policy, tools=frozenset())
        self.fault('capture_not_authorized', lambda: self.seal(ref))
        self.fault('capture_not_authorized', lambda: self.engine.payload_resolver.resolve(self.request(ref, params)))
        self.runtime.policies['tisra'] = self.policy
        staging, _ = self.begin()
        self.runtime.policies['tisra'] = replace(self.policy, methods=METHODS - {'capture.upload.append.v2'})
        self.fault('capture_not_authorized', lambda: self.engine.dispatch('tisra', 'capture.upload.append.v2',
            dict(payload_id=staging['payload_id'], offset=0, data_base64=base64.b64encode(self.raw).decode()),
            self.policy, verified_app='tisra'))
        self.assertEqual(bytes(self.row(staging)['data']), b'')

    def test_registration_independent_grants_and_native_pins_at_each_stage(self):
        for stage in ('begin', 'append', 'seal', 'resolve'):
            for variation in ('registered', 'library', 'method', 'allowed', 'pin', 'epoch', 'actor', 'participant'):
                with self.subTest(stage=stage, variation=variation):
                    engine = self.make_engine()
                    engine.bind_runtime(self.runtime); engine.attach(self.runtime.store)
                    self.engine = engine
                    self.runtime.capture = engine
                    ref, params = self.begin()
                    if stage in {'seal', 'resolve'}:
                        self.append(ref, self.raw)
                    if stage == 'resolve':
                        ref = self.seal(ref)
                    method = {'begin': 'capture.upload.begin.v2', 'append': 'capture.upload.append.v2',
                              'seal': 'capture.upload.seal.v2', 'resolve': 'capture.submit.v1'}[stage]
                    self.runtime.capture = engine
                    if variation == 'registered': self.registered = False; code = 'capture_participant_unregistered'
                    elif variation == 'allowed': self.allowed = False; code = 'capture_not_authorized'
                    elif variation == 'library': engine.configure(library_grants={}); code = 'capture_library_not_authorized'
                    elif variation == 'method':
                        engine.configure(method_grants={('tisra', self.participant.participant_id, self.library): METHODS - {method}})
                        code = 'capture_method_not_authorized'
                    elif variation == 'pin':
                        self.consumer.pin = replace(self.pin, code_sha256='d' * 64); code = 'capture_consumer_pin_mismatch'
                    else:
                        changes = {'epoch': {'auth_epoch': 'new-opaque-epoch'},
                                   'actor': {'actor_kind': 'human'},
                                   'participant': {'participant_id': 'new-participant'}}[variation]
                        replacement = replace(self.participant, **changes)
                        engine.configure(participants={'tisra': replacement},
                            library_grants={('tisra', replacement.participant_id): {self.library}},
                            method_grants={('tisra', replacement.participant_id, self.library): METHODS})
                        code = 'capture_upload_binding_mismatch' if stage != 'begin' else None
                    before = bytes(self.row(ref)['data'])
                    action = {'begin': lambda: self.begin(), 'append': lambda: self.append(ref, self.raw),
                              'seal': lambda: self.seal(ref),
                              'resolve': lambda: engine.payload_resolver.resolve(self.request(ref, params))}[stage]
                    if code is None:
                        # A fresh allocation is bound to the newly authorized host
                        # epoch/participant; existing allocations cannot follow it.
                        action()
                    else:
                        self.fault(code, action)
                    self.assertEqual(bytes(self.row(ref)['data']), before)
                    self.registered = self.allowed = True; self.consumer.pin = self.pin
                    self.engine.revoke('tisra')
        self.engine = self.runtime.capture = self.make_engine()
        self.engine.bind_runtime(self.runtime); self.engine.attach(self.runtime.store)

    def test_continuations_read_only_owned_metadata_before_authority(self):
        ref, _ = self.begin()
        self.registered = False
        statements = []
        self.runtime.store.db.set_trace_callback(statements.append)
        try:
            self.fault('capture_participant_unregistered', lambda: self.append(ref, self.raw))
            self.fault('capture_upload_not_found', lambda: self.rpc('capture.upload.seal.v2',
                {'payload_id': ref['payload_id']}, owner='other'))
        finally:
            self.runtime.store.db.set_trace_callback(None)
        self.assertFalse(any('SELECT data ' in query or 'SET data=' in query for query in statements))
        selects = [query for query in statements if 'FROM capture_uploads_v2' in query]
        self.assertTrue(selects)
        self.assertTrue(all('WHERE owner=' in query for query in selects))

    def test_pin_snapshot_cannot_follow_new_consumer_image_or_library_instance(self):
        for alteration in ({'code_sha256': 'c' * 64}, {'instance_id': uid()}):
            ref, params = self.upload()
            changed = replace(self.pin, **alteration)
            self.consumer.pin = changed
            self.engine.configure(pins={self.library: changed})
            self.fault('capture_upload_binding_mismatch', lambda: self.seal(ref))
            self.fault('capture_upload_binding_mismatch', lambda: self.engine.payload_resolver.resolve(self.request(ref, params)))
            self.consumer.pin = self.pin; self.engine.configure(pins={self.library: self.pin})

    def test_finite_owner_and_global_reservations_count_declared_bytes(self):
        self.engine.owner_byte_cap = 6
        self.engine.global_byte_cap = 10
        first, _ = self.begin(b'abc')
        self.begin(b'def')
        self.fault('capture_upload_budget_exceeded', lambda: self.begin(b'g'))
        self.engine.revoke('tisra', payload_id=first['payload_id'])
        self.begin(b'gh')
        other = RegisteredCaptureParticipant('other-peer', 'human', 'opaque')
        self.engine.configure(participants={'tisra': self.participant, 'other': other},
            library_grants={('tisra', self.participant.participant_id): {self.library}, ('other', other.participant_id): {self.library}},
            method_grants={('tisra', self.participant.participant_id, self.library): METHODS,
                           ('other', other.participant_id, self.library): METHODS})
        args = dict(capture_request_id=uid(), library_id=self.library, sha256=sha(b'12345'), byte_count=5)
        self.rpc('capture.upload.begin.v2', args, owner='other')
        args.update(capture_request_id=uid(), byte_count=1, sha256=sha(b'1'))
        self.fault('capture_upload_budget_exceeded', lambda: self.rpc('capture.upload.begin.v2', args, owner='other'))

    def test_finite_owner_and_global_upload_counts_and_config(self):
        self.engine.owner_upload_cap = self.engine.global_upload_cap = 1
        ref, _ = self.begin()
        self.fault('capture_upload_budget_exceeded', lambda: self.begin())
        self.engine.revoke('tisra', payload_id=ref['payload_id'])
        self.begin()
        for overrides in ({'upload_ttl': float('inf')}, {'upload_ttl': float('nan')},
                          {'upload_ttl': True}, {'owner_byte_cap': 0}, {'global_byte_cap': float('inf')},
                          {'owner_upload_cap': True}, {'global_upload_cap': 4097}, {'payload_resolver': object()}):
            self.fault('capture_upload_configuration_invalid', lambda: UploadedCaptureRuntime(**overrides))

    def test_expiry_reclaims_bytes_and_capacity_without_reusing_ids(self):
        clock = [1000.0]
        self.engine.clock = lambda: clock[0]
        self.engine.owner_upload_cap = 1
        ref, params = self.upload()
        clock[0] += self.engine.upload_ttl
        self.fault('capture_upload_expired', lambda: self.seal(ref))
        self.fault('capture_upload_expired', lambda: self.engine.payload_resolver.resolve(self.request(ref, params)))
        newer, _ = self.begin()
        self.assertNotEqual(newer['payload_id'], ref['payload_id'])
        self.assertEqual(self.row(ref)['state'], 'expired')
        self.assertEqual(bytes(self.row(ref)['data']), b'')

    def test_host_revocation_is_irreversible_and_owner_scoped(self):
        ref, params = self.upload()
        self.assertEqual(self.engine.revoke('other', payload_id=ref['payload_id']), 0)
        self.assertEqual(self.engine.payload_resolver.resolve(self.request(ref, params)).raw, self.raw)
        self.assertEqual(self.engine.revoke('tisra', payload_id=ref['payload_id']), 1)
        self.fault('capture_upload_revoked', lambda: self.seal(ref))
        self.fault('capture_upload_revoked', lambda: self.engine.payload_resolver.resolve(self.request(ref, params)))
        self.assertEqual(bytes(self.row(ref)['data']), b'')

    def test_capture_cancel_revokes_all_bound_uploads_and_blocks_fresh_begin(self):
        ref, params = self.upload()
        staging, _ = self.begin(capture_id=params['capture_request_id'])
        receipt = self.rpc('capture.submit.v1', self.submission(ref, params))
        result = self.rpc('capture.cancel.v1', {key: receipt['binding'][key]
            for key in ('capture_request_id', 'admission_sha256')})
        self.assertEqual(result['state'], 'cancelled')
        self.fault('capture_upload_revoked', lambda: self.append(staging, self.raw))
        self.fault('capture_upload_revoked', lambda: self.engine.payload_resolver.resolve(self.request(ref, params)))
        self.fault('capture_upload_cancelled', lambda: self.begin(capture_id=params['capture_request_id']))
        self.assertEqual(bytes(self.row(ref)['data']), b'')
        self.assertEqual(self.consumer.calls, 0)

    def test_restart_invalidates_unsealed_keeps_exact_sealed_and_holds_jobs(self):
        sealed, params = self.upload()
        staging, _ = self.begin(); self.append(staging, self.raw[:10])
        queued, queue_params = self.upload()
        receipt = self.rpc('capture.submit.v1', self.submission(queued, queue_params))
        self.restart()
        self.assertEqual(self.engine.payload_resolver.resolve(self.request(sealed, params)).raw, self.raw)
        self.assertEqual(self.row(staging)['state'], 'invalidated')
        self.assertEqual(bytes(self.row(staging)['data']), b'')
        self.fault('capture_upload_revoked', lambda: self.append(staging, self.raw[10:], 10))
        self.assertEqual(self.runtime.store.row('tisra', receipt['job_id'])['state'], 'needs_review')
        self.assertIsNone(self.runtime.store.claim())
        self.assertEqual(self.consumer.calls, 0)
        self.assertEqual(self.consumer.lookups, 0)
        self.assertEqual(bytes(self.row(queued)['data']), self.raw)
        self.assertEqual(self.row(queued)['state'], 'sealed')

    def test_restart_clears_expired_sealed_bytes_and_denies_changed_epoch(self):
        clock = [1000.0]
        self.engine.clock = lambda: clock[0]
        expired, _ = self.upload()
        clock[0] += self.engine.upload_ttl
        self.engine.recover()
        self.assertEqual(self.row(expired)['state'], 'expired')
        self.assertEqual(bytes(self.row(expired)['data']), b'')
        self.engine.clock = time.time
        sealed, params = self.upload()
        request = self.request(sealed, params)
        self.participant = replace(self.participant, auth_epoch='new-host-epoch')
        self.restart()
        self.fault('capture_upload_binding_mismatch', lambda: self.engine.payload_resolver.resolve(request))
        self.assertEqual(bytes(self.row(sealed)['data']), self.raw)
        self.assertEqual(self.consumer.calls, 0)

    def test_declared_identity_does_not_authorize_bytes(self):
        payload, _ = self.begin()
        self.fault('app_identity_unverified', lambda: self.rpc('capture.upload.append.v2',
            dict(payload_id=payload['payload_id'], offset=0, data_base64=base64.b64encode(self.raw).decode()), verified=False))
        self.fault('app_identity_unverified', lambda: self.engine.dispatch('tisra', 'capture.upload.seal.v2',
            {'payload_id': payload['payload_id']}, self.policy, verified_app='other'))
        self.assertEqual(bytes(self.row(payload)['data']), b'')

    @unittest.skipUnless(sys.platform == 'darwin', 'kernel peer registration requires macOS')
    def test_handler_uses_genuine_registered_peer_and_rejects_other_process(self):
        verifier = RegisteredPeerVerifier({'tisra', 'other'})
        verifier.register('tisra', os.getpid(), process_identity(os.getpid())['executable'])
        self.runtime.identity_verifier = verifier
        self.engine.registered_peer = lambda owner, _: verifier.is_registered(owner, os.getpid())
        endpoint = str(self.home / 'upload.sock')
        server = Server(endpoint, Handler); server.runtime = self.runtime
        worker = threading.Thread(target=server.serve_forever, kwargs={'poll_interval': .02}, daemon=True)
        worker.start()
        def wire(method, params, app='tisra', raw=None):
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
                connection.settimeout(5); connection.connect(endpoint)
                connection.sendall(raw if raw is not None else encode(dict(protocol=PROTOCOL, app=app, method=method, params=params)) + b'\n')
                with connection.makefile('rb') as stream:
                    return json.loads(stream.readline())
        try:
            args = dict(capture_request_id=uid(), library_id=self.library, sha256=sha(self.raw), byte_count=len(self.raw))
            beginning = wire('capture.upload.begin.v2', args)
            self.assertTrue(beginning['ok'])
            payload = beginning['result']
            self.assertTrue(wire('capture.upload.append.v2', dict(payload_id=payload['payload_id'],
                offset=0, data_base64=base64.b64encode(self.raw).decode()))['ok'])
            self.assertTrue(wire('capture.upload.seal.v2', {'payload_id': payload['payload_id']})['ok'])
            self.assertEqual(wire('capture.upload.begin.v2', args, 'other')['error']['code'], 'app_identity_unverified')
            program = ('import json,socket,sys\n'
                's=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);s.connect(sys.argv[1]);'
                's.sendall(sys.argv[2].encode()+b"\\n");print(s.makefile("rb").readline().decode())')
            rejected = subprocess.run([sys.executable, '-c', program, endpoint,
                encode(dict(protocol=PROTOCOL, app='tisra', method='capture.upload.begin.v2', params=args)).decode()],
                capture_output=True, text=True, timeout=5)
            self.assertEqual(rejected.returncode, 0, rejected.stderr)
            self.assertEqual(json.loads(rejected.stdout)['error']['code'], 'app_identity_unverified')
            duplicate = (encode(dict(protocol=PROTOCOL, app='tisra', method='capture.upload.seal.v2',
                params={'payload_id': payload['payload_id']})).decode().replace('"params":', '"app":"tisra","params":') + '\n').encode()
            self.assertEqual(wire('capture.upload.seal.v2', {}, raw=duplicate)['error']['code'], 'invalid_payload')
            verifier.revoke(os.getpid())
            self.assertEqual(wire('capture.upload.seal.v2', {'payload_id': payload['payload_id']})['error']['code'], 'app_identity_unverified')
        finally:
            server.shutdown(); server.server_close(); worker.join(2)


if __name__ == '__main__':
    unittest.main()
