from unittest.mock import patch
from arl.codex_server import CodexTextAdapter, Session
from arl.contracts import Fault
from tests.test_runtime import RuntimeCase


class Context:
    def check_cancelled(self): pass
    def remaining(self, maximum): return maximum


class AbsoluteDeadlineTests(RuntimeCase):
    def test_mcp_discovery_replacement_uses_original_absolute_deadline(self):
        binary=self.home/'synthetic-binary';binary.write_bytes(b'not executable')
        adapter=CodexTextAdapter(binary,enabled=True);created=[];clock=[100.0]
        class DoubleSession:
            turn_id=None
            process=type('P',(),{'returncode':0})()
            def __init__(self,*a,**kwargs):
                self.options=kwargs;self.seq=0;created.append(self)
            def initialize(self):
                if len(created)==2:raise Fault('provider_unavailable')
            def send(self,*a):self.seq+=1;return self.seq
            def response(self,*a):return {'config':{'mcp_servers':{'synthetic_server':{}}}}
            def close(self):clock[0]+=7
        with patch('arl.codex_server.Session',DoubleSession),patch('arl.codex_server.time.monotonic',lambda:clock[0]):
            self.assert_fault('provider_unavailable',lambda:adapter.run(
                {'model':'synthetic-model','input':'synthetic','max_output_bytes':128},Context()))
        self.assertEqual(len(created),2)
        self.assertEqual([s.options['absolute_deadline'] for s in created],[130,130])
        self.assertEqual(created[1].options['overrides'],{'mcp_servers.synthetic_server.enabled':False})

    def test_expired_absolute_deadline_prevents_even_first_process_launch(self):
        with patch('arl.codex_server.subprocess.Popen') as launch:
            self.assert_fault('provider_deadline_exceeded',lambda:Session('/never/launched',self.home,
                absolute_deadline=0,context=Context()))
        launch.assert_not_called()

    def test_expired_write_cannot_send_turn_or_extend_deadline(self):
        session=Session.__new__(Session);session.deadline=0
        with patch('arl.codex_server.os.write') as write:
            self.assert_fault('provider_deadline_exceeded',lambda:session.write({'method':'turn/start'}))
        write.assert_not_called()
