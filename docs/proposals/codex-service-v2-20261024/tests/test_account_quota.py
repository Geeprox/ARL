from tests.test_codex_server import ScopedCodexServiceTests,ARGS,NAME
class AccountQuotaTests(ScopedCodexServiceTests):
 def test_account_inherited_limit_preserves_counter_and_idempotency_past_32(self):
  runtime,service=self.make_route(calls=None)
  try:
   runtime.store.db.execute('INSERT INTO budget(owner,calls) VALUES(?,41)',(service.caller,))
   status=service.status();self.assertIsNone(status['remaining_calls']);self.assertEqual(status['quota_policy'],'inherit_account');self.assertTrue(status['route_enabled'])
   params={'tool':NAME,'args':ARGS,'key':'authorized-42'};job=self.rpc(runtime,'submit',params);result=self.run_job(runtime,job);self.assertEqual(result['state'],'succeeded');runtime.stopping.clear()
   self.assertEqual(self.rpc(runtime,'submit',params)['id'],job['id']);self.assertEqual(service.status()['admitted_requests_total'],42)
   self.assert_fault('app_identity_unverified',lambda:self.rpc(runtime,'submit',dict(params,key='foreign'),verified=False))
   self.rpc(runtime,'submit',dict(params,key='next'))
   self.assert_fault('queue_budget_exceeded',lambda:self.rpc(runtime,'submit',dict(params,key='overflow')))
  finally:runtime.store.close();runtime.control.close();runtime.service_portal.close()
