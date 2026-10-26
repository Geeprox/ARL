import copy,json,subprocess,sys,time,unittest
from pathlib import Path
from arl.contracts import Cancelled,Fault
from arl.reminders_write import NAME,RemindersWriteAdapter,checked
from arl.reminders_review import APP,ReviewGate
PROPOSAL=json.loads((Path(__file__).resolve().parents[1]/'integrations/apple_reminders/approval-proposal.json').read_text())['args']
class Context:
    def __init__(self,key=None,cancelled=False):self.row={'key':key or PROPOSAL['operation_id']};self.cancelled=cancelled
    def check_cancelled(self):
        if self.cancelled:raise Cancelled()
class RemindersWriteTests(unittest.TestCase):
    def channel_child(self,cancelled=False):
        # Actual private-pipe handshake against the real Python channel.
        script='''import sys,json
from arl.reminders_write import RemindersNativeChannel
from arl.contracts import Fault,Cancelled
class Context:
 def check_cancelled(self):
  if CANCELLED:raise Cancelled()
try:
 result=RemindersNativeChannel()(ARGS,Context());print(json.dumps({'result':result}),flush=True)
except Fault as e:print(json.dumps({'error':e.code}),flush=True)
'''.replace('CANCELLED',repr(cancelled)).replace('ARGS',repr(PROPOSAL))
        return subprocess.Popen([sys.executable,'-B','-c',script],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    def test_channel_rechecks_cancel_after_native_review_and_refuses_uncommitted_success(self):
        for cancelled in (False,True):
            p=self.channel_child(cancelled)
            try:
                self.assertEqual(json.loads(p.stdout.readline())['native_effect']['args'],PROPOSAL)
                p.stdin.write(json.dumps({'status':'awaiting_commit','operation_id':PROPOSAL['operation_id']})+'\n');p.stdin.flush()
                self.assertEqual(json.loads(p.stdout.readline()),{'native_commit':not cancelled,'operation_id':PROPOSAL['operation_id']})
                p.stdin.write(json.dumps({'status':'saved_local','operation_id':PROPOSAL['operation_id'],'target_identifier_sha256':'a'*64} if not cancelled else {'status':'user_cancelled'})+'\n');p.stdin.flush()
                result=json.loads(p.stdout.readline())
                self.assertEqual(result['error'],'user_cancelled') if cancelled else self.assertEqual(result['result']['persistence'],'saved_local')
                p.wait(3);self.assertEqual(p.returncode,0)
            finally:
                if p.poll() is None:p.kill();p.wait()
                p.stdin.close();p.stdout.close();p.stderr.close()
        p=self.channel_child()
        try:
            p.stdout.readline()
            p.stdin.write(json.dumps({'status':'saved_local','operation_id':PROPOSAL['operation_id'],'target_identifier_sha256':'a'*64})+'\n');p.stdin.flush()
            self.assertEqual(json.loads(p.stdout.readline()),{'error':'outcome_unknown'});p.wait(3)
        finally:
            if p.poll() is None:p.kill();p.wait()
            p.stdin.close();p.stdout.close();p.stderr.close()
    def test_schema_rejects_arbitrary_lists_content_and_invalid_title(self):
        for args in (dict(PROPOSAL,list_id='private'),dict(PROPOSAL,notes='body'),dict(PROPOSAL,due='now'),dict(PROPOSAL,target_policy='all'),dict(PROPOSAL,title='\x00'),dict(PROPOSAL,title='x'*301)):
            with self.assertRaises(Fault):checked(args)
    def test_default_disabled_permission_is_full_not_write_only(self):
        tool=RemindersWriteAdapter().tool();self.assertFalse(tool.idempotent)
        self.assertEqual(tool.permissions,('reminders_full_access','reviewed_single_reminder'))
        self.assertEqual(tool.availability,'not_implemented');self.assertTrue(tool.requires_identity)
        with self.assertRaises(Fault) as e:tool.handler(PROPOSAL,Context())
        self.assertEqual(e.exception.code,'reminders_write_not_enabled')
    def test_cancel_key_mismatch_before_transport_and_no_late_cancel_relabel(self):
        calls=[]
        def transport(args,context):calls.append(args);context.cancelled=True;return {'persistence':'saved_local'}
        adapter=RemindersWriteAdapter(transport)
        for ctx in (Context(cancelled=True),Context('different')):
            with self.assertRaises(Fault):adapter.run(PROPOSAL,ctx)
        self.assertFalse(calls)
        self.assertEqual(adapter.run(PROPOSAL,Context()),{'persistence':'saved_local'});self.assertEqual(len(calls),1)
    def test_owner_tool_payload_and_expiry_admission(self):
        clock=[1000];args=copy.deepcopy(PROPOSAL);gate=ReviewGate(args,2000,clock=lambda:clock[0]);args['title']='mutated'
        gate.admit(APP,NAME,PROPOSAL)
        for owner,name,payload in [('settings',NAME,PROPOSAL),(APP,'arbitrary',PROPOSAL),(APP,NAME,args)]:
            with self.assertRaises(Fault) as e:gate.admit(owner,name,payload)
            self.assertEqual(e.exception.code,'review_not_authorized')
        clock[0]=2000
        with self.assertRaises(Fault) as e:gate.admit(APP,NAME,PROPOSAL)
        self.assertEqual(e.exception.code,'review_expired')
