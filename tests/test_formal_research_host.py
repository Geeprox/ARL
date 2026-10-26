"""Composition rehearsal only: no app-server, account, model or Tisra launch."""
import hashlib
import json
import tempfile
import threading
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from arl.codex_server import CodexTextAdapter
from arl.codex_research import NativeContext
from arl.codex_sourced_research import NAME, CodexSourcedResearchEngine
from arl.contracts import Fault
from arl.formal_peer import FormalTisraPeer
from arl.formal_research_host import FormalResearchActivation, compose_formal_research
from arl.host import make_runtime
from arl.identity import RegisteredPeerVerifier
from arl.priority import AppProfilePolicy, ResourcePolicy, TaskPolicy
from arl.priority_host import PriorityHostConfig
from arl.storage import Store


class FormalResearchHostTests(unittest.TestCase):
    def test_inactive_entry_and_explicit_complete_composition(self):
        with tempfile.TemporaryDirectory() as root:
            home = Path(root)
            self.assertFalse(make_runtime(home/'inactive').execute_jobs)
            with self.assertRaises(Fault) as denied:
                make_runtime(home/'denied', research_activation=object())
            self.assertEqual(denied.exception.code, 'research_host_not_admitted')
            binary = home/'codex'; binary.write_bytes(b'rehearsal binary')
            helper = home/'peer'; helper.write_bytes(b'rehearsal peer')
            app = home/'tisra'; app.write_bytes(b'rehearsal tisra')
            peer = FormalTisraPeer(helper)
            registry = RegisteredPeerVerifier({'tisra'})
            adapter = CodexTextAdapter(binary, enabled=True)
            resources = (ResourcePolicy('model', slots=1, realtime_reserved=0,
                                        background_start_limit_ms=12000),)
            tasks = (TaskPolicy(NAME, 'model.inference', 'model',
                                owners=frozenset({'tisra'}), maximum_class='interactive',
                                estimate_floor_ms=100, execution_budget_ms=12000),)
            profile = {'tisra': AppProfilePolicy(frozenset({'background', 'interactive'}),
                                                 max_deadline_ms=30000)}
            priority = PriorityHostConfig(resources, tasks, profile, 10000)
            admitted = []
            admission = lambda owner, tool, args: admitted.append((owner, tool, args))
            activation = FormalResearchActivation(peer, registry, adapter, 'reviewed-model',
                                                   'reviewed-epoch', priority, admission, 'review-v1')
            with patch('arl.formal_research_host.DEFAULT_BINARY', binary), \
                 patch('arl.formal_research_host.TISRA_EXECUTABLE', app), \
                 patch('arl.formal_research_host.HELPER_SHA256', hashlib.sha256(helper.read_bytes()).hexdigest()), \
                 patch('arl.formal_research_host.TISRA_EXECUTABLE_SHA256', hashlib.sha256(app.read_bytes()).hexdigest()), \
                 patch.object(registry, 'registration_subject', return_value='reviewed-subject'):
                runtime = compose_formal_research(home/'active', activation)
                runtime.admission.evaluate('tisra', NAME, {'run_id': 'reviewed'})
                self.assertEqual(admitted, [('tisra', NAME, {'run_id': 'reviewed'})])
                helper.write_bytes(b'changed peer')
                with self.assertRaises(Fault) as drift:
                    runtime.admission.evaluate('tisra', NAME, {'run_id': 'reviewed'})
                self.assertEqual(drift.exception.code, 'research_host_identity_changed')
            self.assertTrue(runtime.execute_jobs)
            self.assertEqual(set(runtime.research_engines), {NAME})
            self.assertEqual(len(runtime.priority_producer.domains), 1)
            self.assertEqual(runtime.priority_producer.domains[0].codec, 'codex.appserver.sourced.v2')
            self.assertEqual(runtime.policies['mio'].tools, frozenset())
            self.assertEqual(runtime.policies['friday'].tools, frozenset())
            self.assertEqual(runtime.policies['tisra'].tools, frozenset({NAME}))

    def test_review_revision_fences_native_and_publication(self):
        with tempfile.TemporaryDirectory() as root:
            home=Path(root)
            binary=home/'codex';binary.write_bytes(b'controlled transport')
            helper=home/'peer';helper.write_bytes(b'controlled peer')
            app=home/'tisra';app.write_bytes(b'controlled app')
            registry=RegisteredPeerVerifier({'tisra'})
            text=CodexTextAdapter(binary,enabled=True)
            resource=(ResourcePolicy('model',slots=1,realtime_reserved=0,
                                     background_start_limit_ms=12000),)
            tasks=(TaskPolicy(NAME,'model.inference','model',owners=frozenset({'tisra'}),
                              maximum_class='interactive',estimate_floor_ms=100,
                              execution_budget_ms=12000),)
            profile={'tisra':AppProfilePolicy(frozenset({'background','interactive'}),
                                              max_deadline_ms=30000)}
            seen=[]
            activation=FormalResearchActivation(FormalTisraPeer(helper),registry,text,'reviewed-model',
                'auth-v1',PriorityHostConfig(resource,tasks,profile,10000),
                lambda owner,tool,args:seen.append((owner,tool,args)),'human-review-v1')
            with patch('arl.formal_research_host.DEFAULT_BINARY',binary), \
                 patch('arl.formal_research_host.TISRA_EXECUTABLE',app), \
                 patch('arl.formal_research_host.HELPER_SHA256',hashlib.sha256(helper.read_bytes()).hexdigest()), \
                 patch('arl.formal_research_host.TISRA_EXECUTABLE_SHA256',hashlib.sha256(app.read_bytes()).hexdigest()), \
                 patch.object(registry,'registration_subject',return_value='current-subject'):
                runtime=compose_formal_research(home/'runtime',activation)
                engine=runtime.research_engines[NAME]
                real_store=Store(home/'state.sqlite')
                runtime.store=real_store
                engine.attach(real_store)
                runtime.bind_priority()
                runtime.ready.set()
                self.assertEqual(runtime.priority_producer.snapshot('tisra'),())
                with patch.object(text,'preflight_model',return_value={
                    'model':'reviewed-model','ephemeral':True,'read_only':True,
                    'synthetic':False}) as preflight:
                    runtime.priority_producer.probe_native('tisra','reviewed-model')
                preflight.assert_called_once_with('reviewed-model')
                profile_result=runtime.priority_authority.negotiate_v2(
                    'tisra','tisra',{'classes':['background','interactive']})
                self.assertEqual([(r['tool'],r['task_kind']) for r in profile_result['task_bindings']],
                                 [(NAME,'model.inference')])
                real_store.close()
                args={'run_id':'run-v1','request':{'sha256':'a'*64},'descriptor':{},
                      'provider':'codex_app_server','model':'reviewed-model',
                      'model_fingerprint':engine.adapters['codex_app_server'].model_fingerprints['reviewed-model'],
                      'request_format':engine.formats[0],
                      'output_format':engine.formats[1],'history_version':engine.formats[2]}
                run={'owner':'tisra','job':'job-v1','run_id':'run-v1','epoch':1,
                     'auth_epoch':'auth-v1','external_started':1,'args':json.dumps(args)}
                events=[];pin={'revision':'human-review-v1','review_epoch':runtime.review_epoch,
                               'binding':engine.review_binding(run)}
                class DB:
                    def execute(self,sql,values):
                        events.append(sql)
                        if sql.startswith('SELECT * FROM formal_research_reviews'):
                            return SimpleNamespace(fetchone=lambda:pin)
                        if sql.startswith('SELECT * FROM research_runs'):
                            return SimpleNamespace(fetchone=lambda:run)
                        if sql.startswith('SELECT 1 FROM research_native'):
                            return SimpleNamespace(fetchone=lambda:None)
                        if sql.startswith('INSERT INTO research_native'):
                            events.append('native_insert')
                            return SimpleNamespace(fetchone=lambda:None)
                        raise AssertionError(sql)
                lock=threading.RLock()
                engine.store=SimpleNamespace(db=DB(),lock=lock,transaction=lambda:lock)
                native=engine.adapters['codex_app_server']
                with patch.object(CodexSourcedResearchEngine,'invalid',return_value=False), \
                     patch.object(native,'preflight',side_effect=lambda args:events.append('native_preflight')), \
                     patch.object(engine,'object_bytes',return_value=b'controlled reviewed bytes'), \
                     patch.object(engine,'validate_pair',side_effect=lambda *a:events.append('validate_pair')):
                    engine.external_admission(dict(run,external_started=0))
                    self.assertEqual(events.count('native_preflight'),1)
                    self.assertEqual(events.count('validate_pair'),1)
                    self.assertEqual(events.count('native_insert'),1)
                    self.assertEqual(seen[-1],('tisra',NAME,args))
                    with self.assertRaises(Fault) as replay:
                        engine.external_admission(run)
                    self.assertEqual(replay.exception.code,'research_no_replay')
                    self.assertEqual(events.count('native_insert'),1)
                    review=runtime.admission
                    runtime.admission=None
                    self.assertTrue(engine.invalid(run))
                    with patch.object(engine,'binding',return_value=run), \
                         patch.object(engine,'invalidate',side_effect=lambda run:events.append('invalidated')), \
                         patch.object(engine,'receipt',return_value={'state':'needs_review'}):
                        for method in ('codex.research.status.v1','codex.research.cancel.v1'):
                            self.assertEqual(engine.dispatch('tisra',method,{},None),
                                             {'state':'needs_review'})
                    with self.assertRaises(Fault):engine.external_admission(run)
                    context=SimpleNamespace(owner='tisra',row={'id':'job-v1'},
                                            check_cancelled=lambda:None,remaining=lambda n:n)
                    native_context=NativeContext(engine,context,run)
                    with self.assertRaises(Fault):native_context.check_cancelled()
                    row={'id':'job-v1','owner':'tisra'}
                    with patch.object(engine,'invalidate',side_effect=lambda run:events.append('invalidated')):
                        engine.complete(row,b'controlled placeholder')
                    self.assertIn('invalidated',events)
                    self.assertFalse(any("state='sealed'" in item for item in events))
                    runtime.admission=review
                    self.assertTrue(engine.invalid(run))


if __name__ == '__main__':
    unittest.main()
