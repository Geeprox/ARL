import json,subprocess
from unittest.mock import Mock
from arl.modules import MioMetadata
from arl.service import Runtime
from arl.host import metadata_policies
from arl.client import Client
from tests.test_runtime import RuntimeCase,running

class ModulesTests(RuntimeCase):
    def probe(self,data=None,code=0):
        return Mock(return_value=subprocess.CompletedProcess([],code,json.dumps(data or {}).encode()))
    def test_public_metadata_api_no_scope_escalation(self):
        probe=MioMetadata(self.probe({'healthz':'live','readyz':'ready'}))
        r=Runtime(self.home,policies=metadata_policies(),identity_verifier=lambda c,a:None,execute_jobs=False,modules=probe)
        def rpc(app='settings',params=None,verified=None):return r.dispatch({'protocol':'arl/1','app':app,'method':'settings.modules_snapshot','params':params or {}},verified_app=verified)
        d=rpc();self.assertEqual(d['schema_version'],1);self.assertEqual(d['modules'][0]['readiness'],'ready')
        self.assertIsNone(d['modules'][0]['tool_count']);self.assertEqual(d['modules'][0]['tool_publication'],'not_checked')
        for params in ({'url':'http://evil'},{'owner':'mio'},{'pid':1}):self.assert_fault('invalid_arguments',lambda:rpc(params=params))
        self.assert_fault('app_identity_unverified',lambda:rpc('mio'))
        self.assert_fault('app_identity_unverified',lambda:rpc(verified='mio'))
        self.assertEqual(r.policies['settings'].tools,frozenset());self.assertFalse(r.execute_jobs);r.control.close()
    def test_cache_preserves_check_time_and_runs_only_fixed_worker(self):
        clock=[1000];ticks=[0];run=self.probe({'healthz':'live','readyz':'ready','secret':'unsafe'})
        p=MioMetadata(run,lambda:clock[0],lambda:ticks[0]);a=p.snapshot();clock[0]=2000;ticks[0]=1;b=p.snapshot()
        self.assertEqual(b['modules'][0]['checked_at_ms'],1000);self.assertEqual(b['checked_at_ms'],2000);self.assertEqual(run.call_count,1)
        self.assertNotIn('secret',json.dumps(b));self.assertNotIn('unsafe',json.dumps(b));self.assertEqual(run.call_args.kwargs['timeout'],2)
        ticks[0]=6;p.snapshot();self.assertEqual(run.call_count,2)
    def test_malformed_failures_and_deadline_never_become_ready(self):
        for data,code in (({'healthz':'live','readyz':'other'},0),(['secret'],0),({},1)):
            m=MioMetadata(self.probe(data,code)).module();self.assertNotEqual(m['readiness'],'ready')
        p=MioMetadata(Mock(side_effect=subprocess.TimeoutExpired('secret',2)))
        self.assertEqual(p.module()['error_code'],'probe_deadline_exceeded');self.assertNotIn('secret',json.dumps(p.snapshot()))
    def test_busy_probe_returns_unknown_without_blocking(self):
        p=MioMetadata(Mock(side_effect=AssertionError()));p.lock.acquire()
        try:self.assertIsNone(p.module()['checked_at_ms'])
        finally:p.lock.release()
    def test_actual_isolated_rpc_with_double(self):
        with running(self.home,execute_jobs=False,modules=MioMetadata(self.probe({'healthz':'live','readyz':'ready'}))) as (r,_):
            d=Client(self.home,'settings').rpc('settings.modules_snapshot');self.assertEqual(d['modules'][0]['liveness'],'live')
            self.assertEqual(Client(self.home,'settings').rpc('overview')['schema_version'],1)
            self.assertEqual(sum(Client(self.home,'settings').rpc('overview')['queue']['counts'].values()),0)
