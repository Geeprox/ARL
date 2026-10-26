import os
import unittest
from dataclasses import replace
from arl.app_connections import AppConnections
from arl.control import AppRegistry, AppDescriptor
from arl.contracts import AppPolicy, Fault
from arl.diagnostics import Diagnostics
from arl.client import Client
from arl.identity import RegisteredPeerVerifier, process_identity
from tests.test_runtime import RuntimeCase, running

class SessionTests(unittest.TestCase):
    def setUp(self):
        self.now=1000000; self.live=True
        self.registry=AppRegistry({'sample_app'},Diagnostics({'sample_app'}),clock=lambda:self.now,monotonic=lambda:self.now)
        self.registry.register(AppDescriptor('sample_app','Host placeholder','sf:app'))
        self.sessions=AppConnections(self.registry)
        self.policy=AppPolicy(frozenset({'runtime.ping'}))
        self.binding=('peer-generation-one',lambda:self.live)
    def call(self,method,params,binding=None):
        return self.sessions.dispatch('sample_app','connection.'+method,params,binding or self.binding,self.policy)
    def open(self,binding=None):
        return self.call('open',{'client_nonce':'a'*64,'name':'示例应用','icon_ref':'sf:doc','version':'1.0',
            'capabilities':['runtime.ping','ungranted.write']},binding)
    def confirm(self,reply,binding=None):
        return self.call('confirm',{k:reply[k] for k in ('session_id','challenge')},binding)
    def row(self): return self.registry.snapshot({'sample_app':self.policy})[0]
    def test_verified_rpc_and_first_leg_never_connect(self):
        self.registry.observe_verified('sample_app')
        self.assertEqual(self.row()['connection'],'never_seen')
        self.open(); self.assertIsNone(self.row()['handshake_session'])
    def test_real_metadata_and_negotiation_only_after_confirmation(self):
        reply=self.open(); self.confirm(reply)
        row=self.row(); self.assertEqual(row['name'],'示例应用'); self.assertEqual(row['icon_ref'],'sf:doc')
        self.assertEqual(row['advertised_capabilities'],['runtime.ping','ungranted.write'])
        self.assertEqual(row['authorized_tools'],['runtime.ping'])
        self.assertNotIn('challenge',row)
    def test_wrong_challenge_and_other_instance_denied(self):
        reply=self.open()
        with self.assertRaises(Fault): self.call('confirm',{'session_id':reply['session_id'],'challenge':'b'*64})
        with self.assertRaises(Fault): self.confirm(reply,('another-peer',lambda:True))
        with self.assertRaises(Fault): self.open(('another-peer',lambda:True))
        self.confirm(reply)
        with self.assertRaises(Fault): self.open(('another-peer',lambda:True))
    def test_refresh_keeps_card_then_old_ping_close_are_isolated(self):
        first=self.open();self.confirm(first);second=self.open()
        self.assertEqual(self.row()['handshake_session'],first['session_id'])
        self.confirm(second)
        for method in ('ping','close'):
            with self.assertRaises(Fault): self.call(method,{'session_id':first['session_id']})
        self.assertEqual(self.row()['handshake_session'],second['session_id'])
        self.call('close',{'session_id':second['session_id']});self.assertIsNone(self.row()['handshake_session'])
    def test_register_revoke_expiry_and_dead_peer(self):
        reply=self.open();self.registry.register(AppDescriptor('sample_app','New host','sf:app'))
        with self.assertRaises(Fault):self.confirm(reply)
        reply=self.open();self.now+=10001
        with self.assertRaises(Fault):self.confirm(reply)
        reply=self.open();self.confirm(reply);self.now+=30001
        self.assertIsNone(self.row()['handshake_session'])
        with self.assertRaises(Fault):self.call('ping',{'session_id':reply['session_id']})
        reply=self.open();self.confirm(reply);self.live=False
        self.assertIsNone(self.row()['handshake_session'])
        self.live=True;reply=self.open();self.registry.revoke('sample_app')
        with self.assertRaises(Fault):self.confirm(reply)
    def test_policy_reduction_cannot_reuse_accepted_capabilities(self):
        reply=self.open(); self.policy=AppPolicy(frozenset())
        with self.assertRaises(Fault):self.confirm(reply)
        self.policy=AppPolicy(frozenset({'runtime.ping'})); reply=self.open();self.confirm(reply)
        self.policy=AppPolicy(frozenset())
        self.assertEqual(self.row()['authorized_tools'],[])

    def test_expired_session_cannot_revive_when_wall_clock_returns(self):
        wall, mono = [1000000], [5000]
        self.registry.clock=lambda:wall[0];self.registry.monotonic=lambda:mono[0]
        reply=self.open();self.confirm(reply)
        mono[0]+=30001;wall[0]+=30001
        self.assertIsNone(self.row()['handshake_session'])
        wall[0]-=30000
        self.assertIsNone(self.row()['handshake_session'])
        with self.assertRaises(Fault):self.call('ping',{'session_id':reply['session_id']})
        fresh=self.open();self.confirm(fresh)
        self.assertNotEqual(fresh['session_id'],reply['session_id'])
        wall[0]-=500000
        self.assertEqual(self.row()['handshake_session'],fresh['session_id'])

    def test_clock_rollback_does_not_extend_lease(self):
        reply=self.open();self.confirm(reply);self.now-=1
        with self.assertRaises(Fault):self.call('ping',{'session_id':reply['session_id']})

@unittest.skipUnless(os.uname().sysname=='Darwin','kernel peer validation requires macOS')
class SocketSessionTests(RuntimeCase):
    def test_socket_consumer_expiry_retirement_survives_wall_rollback(self):
        peer=RegisteredPeerVerifier({'tisra'})
        peer.register('tisra',os.getpid(),process_identity(os.getpid())['executable'])
        mono=[5000];wall=[1000000]
        with running(self.home,identity_verifier=peer) as (runtime,client):
            registry=runtime.control.apps;registry.monotonic=lambda:mono[0];registry.clock=lambda:wall[0]
            registry.register(AppDescriptor('tisra','Host placeholder','sf:app'))
            client.open_app_session('示例应用',('runtime.ping',));old=client.app_session
            mono[0]+=30001;wall[0]+=30001
            row=lambda:next(r for r in Client(self.home,'settings').rpc('settings.snapshot')['apps'] if r['id']=='tisra')
            self.assertIsNone(row()['handshake_session']);wall[0]-=30000
            self.assertIsNone(row()['handshake_session'])
            self.assert_fault('app_session_changed',client.ping_app_session)
            client.open_app_session('示例应用',('runtime.ping',));self.assertNotEqual(old,client.app_session)

    def test_real_client_handshake_registration_generation_and_revocation(self):
        peer=RegisteredPeerVerifier({'tisra'})
        executable=process_identity(os.getpid())['executable']
        peer.register('tisra',os.getpid(),executable)
        with running(self.home,identity_verifier=peer) as (runtime,client):
            runtime.control.apps.register(AppDescriptor('tisra','Host metadata','sf:app'))
            client.rpc('heartbeat')
            self.assertIsNone(runtime.control.apps.snapshot(runtime.policies)[2]['handshake_session'])
            accepted=client.open_app_session('示例应用',('runtime.ping','ungranted.write'),version='1.0')
            self.assertEqual(accepted,['runtime.ping'])
            row=next(r for r in runtime.control.apps.snapshot(runtime.policies) if r['id']=='tisra')
            self.assertEqual(row['name'],'示例应用');self.assertIsNotNone(row['handshake_session'])
            client.ping_app_session()
            peer.register('tisra',os.getpid(),executable)
            self.assert_fault('app_session_changed',client.ping_app_session)
            row=next(r for r in runtime.control.apps.snapshot(runtime.policies) if r['id']=='tisra')
            self.assertIsNone(row['handshake_session'])
            client.open_app_session('示例应用',('runtime.ping',));client.close_app_session()
            peer.revoke(os.getpid())
            self.assert_fault('app_identity_unverified',lambda:client.open_app_session('示例应用'))

@unittest.skipUnless(os.uname().sysname=='Darwin','native SDK requires macOS')
class SwiftConsumerTests(RuntimeCase):
    def test_real_registered_swift_consumer_confirms_pings_and_closes(self):
        import subprocess,sys,selectors,threading
        from pathlib import Path
        from arl.service import Runtime
        root=Path(__file__).resolve().parents[1]
        binary=root/'build/app-session-client'
        subprocess.run(['xcrun','swiftc','-parse-as-library','-swift-version','6','-j','1',
            '-module-cache-path',str(root/'build/cache/ModuleCache'),str(root/'examples/ARLClient.swift'),
            str(root/'tests/AppSessionClient.swift'),'-o',str(binary)],check=True,capture_output=True,timeout=30)
        peer=RegisteredPeerVerifier({'sample_app'})
        policies={'sample_app':AppPolicy(frozenset({'runtime.ping'})),
            'settings':AppPolicy(frozenset(),methods=frozenset({'ready','settings.snapshot'}),public_metadata=True)}
        runtime=Runtime(self.home,policies=policies,identity_verifier=peer,execute_jobs=False,providers={})
        worker=threading.Thread(target=runtime.run);worker.start();child=None
        def line():
            with selectors.DefaultSelector() as selector:
                selector.register(child.stdout,selectors.EVENT_READ)
                self.assertTrue(selector.select(timeout=5),'Swift consumer response missing')
                return child.stdout.readline().strip()
        try:
            Client(self.home,'settings').connect(timeout=5)
            child=subprocess.Popen([str(binary),str(self.home)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
            peer.register('sample_app',child.pid,binary)
            runtime.control.apps.register(AppDescriptor('sample_app','Host placeholder','sf:app'),active_guard=lambda:peer.is_registered('sample_app',child.pid))
            child.stdin.write('go\n');child.stdin.flush();self.assertEqual(line(),'connected')
            row=next(r for r in Client(self.home,'settings').rpc('settings.snapshot')['apps'] if r['id']=='sample_app')
            self.assertEqual(row['name'],'示例应用');self.assertEqual(row['icon_ref'],'sf:doc');self.assertEqual(row['authorized_tools'],['runtime.ping'])
            self.assertIsNotNone(row['handshake_session'])
            child.stdin.write('close\n');child.stdin.flush();self.assertEqual(line(),'closed');child.wait(timeout=5)
            self.assertEqual(child.returncode,0)
            self.assertFalse(any(r['connection']=='connected' for r in Client(self.home,'settings').rpc('settings.snapshot')['apps']))
        finally:
            if child is not None:
                if child.poll() is None:child.terminate();child.wait(timeout=5)
                for stream in (child.stdin,child.stdout,child.stderr):stream.close()
            runtime.shutdown();worker.join(10)
            self.assertFalse(worker.is_alive())
