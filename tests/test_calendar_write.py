import json,subprocess,time,uuid
from pathlib import Path
from unittest.mock import Mock
from arl.calendar_write import CalendarWriteAdapter,CalendarWriteTransport,NAME,checked
from arl.contracts import AppPolicy,Fault
from arl.client import Client
from arl.service import default_policies
from tests.test_runtime import RuntimeCase,running
ARGS={'operation_id':'ba69dd86-d9f3-4c6d-8490-c8dbce36525d','title':'ARL synthetic review','start':'2026-10-03T10:00:00+08:00','end':'2026-10-03T10:10:00+08:00'}
class CalendarWriteTests(RuntimeCase):
    def policy(self):
        p=default_policies();p['tisra']=AppPolicy(frozenset({NAME}));return p
    def terminal(self,c,id):
        end=time.monotonic()+5
        while time.monotonic()<end:
            d=c.rpc('get',{'id':id})
            if d['state'] in {'succeeded','failed','needs_review','cancelled'}:return d
            time.sleep(.01)
        self.fail('job did not terminate')
    def test_strict_args_offset_dates_title_and_single_event(self):
        self.assertEqual(checked(ARGS),ARGS)
        for change in ({'title':'\nprivate'},{'title':' '},{'start':'2026-10-03T10:00:00'}, {'end':'2026-10-05T10:00:00+08:00'},{'start':'2026-02-30T10:00:00+08:00'}, {'end':ARGS['start']},{'calendar':'private'},{'recurrence':'daily'},{'operation_id':'not-uuid'}):
            self.assert_fault('invalid_arguments',lambda:checked(dict(ARGS,**change)))
    def test_not_present_in_default_host(self):
        with running(self.home,execute_jobs=False) as (r,c):
            self.assertNotIn(NAME,r.tools);self.assert_fault('unknown_tool',lambda:c.submit(NAME,ARGS,ARGS['operation_id']))
    def test_verified_only_scoped_write_and_dedupe_real_rpc(self):
        write=Mock(return_value={'schema_version':1,'operation_id':ARGS['operation_id'],'persistence':'saved_local','cloud_sync':'not_checked'})
        with running(self.home,policies=self.policy(),extra_tools=[CalendarWriteAdapter(write).tool()],identity_verifier=lambda c,a:'tisra' if a=='tisra' else None) as (r,c):
            self.assert_fault('operation_key_mismatch',lambda:c.submit(NAME,ARGS,'another-key'))
            self.assert_fault('app_identity_unverified',lambda:Client(self.home,'friday').submit(NAME,ARGS,ARGS['operation_id']))
            self.assert_fault('app_identity_unverified',lambda:r.dispatch({'protocol':'arl/1','app':'tisra','method':'submit','params':{'tool':NAME,'args':ARGS,'key':ARGS['operation_id']}}))
            a=c.submit(NAME,ARGS,ARGS['operation_id']);b=c.submit(NAME,ARGS,ARGS['operation_id'])
            self.assertEqual(a['id'],b['id']);self.assertEqual(self.terminal(c,a['id'])['state'],'succeeded');self.assertEqual(write.call_count,1)
            self.assert_fault('idempotency_conflict',lambda:c.submit(NAME,dict(ARGS,title='changed'),ARGS['operation_id']));self.assertEqual(write.call_count,1)
    def test_uncertain_write_not_replayed_after_restart(self):
        write=Mock(side_effect=Fault('outcome_unknown'));settings=dict(policies=self.policy(),extra_tools=[CalendarWriteAdapter(write).tool()],identity_verifier=lambda c,a:'tisra' if a=='tisra' else None)
        with running(self.home,**settings) as (r,c):
            job=c.submit(NAME,ARGS,ARGS['operation_id']);self.assertEqual(self.terminal(c,job['id'])['state'],'needs_review');self.assertEqual(write.call_count,1)
        with running(self.home,**settings) as (r,c):
            again=c.submit(NAME,ARGS,ARGS['operation_id']);self.assertEqual(again['id'],job['id']);self.assertEqual(again['state'],'needs_review');self.assertEqual(write.call_count,1)
    def test_transport_pin_finite_receipt_deadline_and_no_raw_errors(self):
        p=self.home/'helper';p.write_bytes(b'synthetic');p.chmod(0o700)
        run=Mock(return_value=subprocess.CompletedProcess([],0,json.dumps({'status':'saved_local','operation_id':ARGS['operation_id']}).encode()))
        t=CalendarWriteTransport(p,runner=run);self.assertEqual(t(ARGS)['persistence'],'saved_local');self.assertEqual(run.call_args.kwargs['timeout'],8)
        for result in ({'status':'saved_local','operation_id':str(uuid.uuid4())},{'status':'saved_local','operation_id':ARGS['operation_id'],'secret':'private'}, {'status':'private'}):
            run.return_value=subprocess.CompletedProcess([],0,json.dumps(result).encode());self.assert_fault('outcome_unknown',lambda:t(ARGS))
        run.side_effect=subprocess.TimeoutExpired('private',8);self.assert_fault('outcome_unknown',lambda:t(ARGS));p.write_bytes(b'changed');self.assert_fault('calendar_helper_changed',lambda:t(ARGS))
    def test_cancellation_before_save_does_not_call_transport(self):
        from arl.contracts import Cancelled
        context=Mock();context.check_cancelled.side_effect=Cancelled();write=Mock()
        self.assert_fault('cancelled',lambda:CalendarWriteAdapter(write).run(ARGS,context));write.assert_not_called()
class NativeValidationTests(RuntimeCase):
    def test_swift_native_validation_has_no_permission_or_data_calls(self):
        binary=Path(__file__).resolve().parents[1]/'integrations/apple_calendar/dist/ARLCalendarBridge.app/Contents/MacOS/ARLCalendarBridge'
        if not binary.exists():self.skipTest('run integrations/apple_calendar/build.sh first')
        for args,want in ((ARGS,'valid'),(dict(ARGS,start='2026-10-03T10:00:00'),'invalid_arguments'),(dict(ARGS,title='\n'),'invalid_arguments'),(dict(ARGS,recurrence='daily'),'invalid_arguments'),(dict(ARGS,start='2026-02-30T10:00:00+08:00'),'invalid_arguments'),(dict(ARGS,start=ARGS['start']+'\n'),'invalid_arguments')):
            p=subprocess.run([str(binary),'--validate-only'],input=json.dumps({'tool':NAME,'args':args}).encode(),stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=3);self.assertEqual(json.loads(p.stdout)['status'],want)
