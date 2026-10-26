import json
import os
import subprocess
import struct
import sys
import threading
import time
import unittest
from dataclasses import replace
from unittest.mock import Mock

from arl.capabilities import AppleAdapter
from arl.client import Client
from arl.control import AppDescriptor, AppRegistry, CredentialReferences, ProviderStatus
from arl.contracts import Fault
from arl.diagnostics import Diagnostics
from arl.host import metadata_policies
from arl.identity import RegisteredPeerVerifier, process_identity
from arl.metrics import ResourceSampler, mac_system
from arl.providers import MockProvider
from arl.service import Runtime
from arl.supervisor import ControlledSupervisor, LaunchSpec, pin_sources
from pathlib import Path
from tests.test_runtime import RuntimeCase, running

class FixedClock:
    def __init__(self): self.seconds=0; self.millis=1000000
    def advance(self, seconds): self.seconds+=seconds; self.millis+=int(seconds*1000)

def fake_resources():
    return ResourceSampler(system_reader=lambda:{},process_reader=lambda pid:{},
        identity_reader=lambda pid: {'uid':os.geteuid(),'birth':(1,0),'executable':'synthetic'},include_runtime=False)

class ControlUnitTests(RuntimeCase):
    def runtime(self, **kwargs):
        return Runtime(self.home,providers={'mock':MockProvider()},resources=fake_resources(),**kwargs)
    def request(self,runtime,method,params=None,app='settings',verified=None):
        return runtime.dispatch({'protocol':'arl/1','app':app,'method':method,'params':params or {}},verified_app=verified)

    def establish(self,runtime,app,descriptor):
        binding=('synthetic-generation',lambda:True)
        reply=runtime.app_connections.dispatch(app,'connection.open',{'client_nonce':'a'*64,'name':descriptor.name,
            'icon_ref':descriptor.icon_ref,'version':descriptor.version,'capabilities':list(runtime.policies[app].tools | set(descriptor.capabilities))},binding,runtime.policies[app])
        runtime.app_connections.dispatch(app,'connection.confirm',{k:reply[k] for k in ('session_id','challenge')},binding,runtime.policies[app])

    def test_v1_shape_preserved_v2_has_no_fake_registration_or_credential(self):
        runtime=self.runtime(execute_jobs=False)
        old=self.request(runtime,'overview')
        self.assertEqual(old['schema_version'],1)
        self.assertNotIn('apps',old)
        new=self.request(runtime,'settings.snapshot')
        self.assertEqual(new['schema_version'],2)
        self.assertIsNone(new['runtime']['started_at_ms'])
        self.assertIsNone(new['runtime']['uptime_seconds'])
        self.assertFalse(new['runtime']['task_execution_enabled'])
        self.assertEqual(new['credentials'],[])
        for app in new['apps']:
            self.assertEqual((app['registration'],app['connection'],app['authentication'],app['authorization']),
                ('unregistered','never_seen','unverified','none'))
        self.assertEqual(new['household']['state'],'not_registered')
        self.assertNotIn(str(self.home),json.dumps(new))
        runtime.control.close()

    def test_forged_registration_owner_pid_and_auth_are_rejected(self):
        runtime=self.runtime(identity_verifier=lambda c,a:None)
        for method in ('settings.snapshot','settings.logs','settings.logs_export'):
            for params in ({'owner':'friday'},{'pid':os.getpid()},{'authenticated':True}):
                self.assert_fault('invalid_arguments',lambda:self.request(runtime,method,params))
        self.assert_fault('unknown_method',lambda:self.request(runtime,'register',{'app':'friday'}))
        self.assert_fault('app_identity_unverified',lambda:self.request(runtime,'heartbeat',app='tisra'))
        self.assert_fault('app_identity_unverified',lambda:self.request(runtime,'settings.snapshot',app='friday'))
        self.assert_fault('app_identity_unverified',lambda:self.request(runtime,'settings.snapshot',verified='friday'))
        self.assert_fault('app_identity_unverified',lambda:self.request(runtime,'get',{'id':'private'}))
        self.assertEqual(runtime.control.credentials.snapshot(),[])

    def test_verified_registration_stale_and_revoked_are_independent(self):
        clock=FixedClock(); runtime=self.runtime()
        runtime.control.apps.clock=lambda:clock.millis
        runtime.control.apps.monotonic=lambda:clock.millis
        descriptor=AppDescriptor('tisra','Tisra','sf:sparkle','alpha.1',('research.read',))
        runtime.control.apps.register(descriptor)
        self.assert_fault('app_identity_unverified',lambda:self.request(runtime,'heartbeat',app='tisra'))
        self.assertTrue(self.request(runtime,'heartbeat',app='tisra',verified='tisra')['accepted'])
        self.assertIsNone(next(a for a in runtime.control.apps.snapshot(runtime.policies) if a['id']=='tisra')['handshake_session'])
        self.establish(runtime,'tisra',descriptor)
        app=next(a for a in runtime.control.apps.snapshot(runtime.policies) if a['id']=='tisra')
        self.assertEqual((app['connection'],app['authentication'],app['authorization']),('connected','verified','limited'))
        self.assertEqual(app['version'],'alpha.1')
        clock.advance(31)
        app=next(a for a in runtime.control.apps.snapshot(runtime.policies) if a['id']=='tisra')
        self.assertEqual((app['connection'],app['authentication'],app['authorization']),('stale','stale','none'))
        runtime.control.apps.revoke('tisra')
        self.assert_fault('method_not_authorized',lambda:self.request(runtime,'heartbeat',app='tisra',verified='tisra'))
        app=next(a for a in runtime.control.apps.snapshot(runtime.policies) if a['id']=='tisra')
        self.assertEqual((app['registration'],app['connection'],app['authentication']),('revoked','disconnected','unverified'))

    def test_host_grant_and_public_metadata_do_not_enroll_or_authorize(self):
        runtime=self.runtime(policies=metadata_policies(),identity_verifier=lambda c,a:None,execute_jobs=False)
        runtime.control.apps.register(AppDescriptor('friday','Friday','sf:house','1'))
        runtime.control.apps.observe_verified('friday')
        app=next(a for a in self.request(runtime,'settings.snapshot')['apps'] if a['id']=='friday')
        self.assertEqual(app['authentication'],'verified')
        self.assertEqual(app['authorization'],'none')
        self.assertEqual(app['authorized_tools'],[])
        self.assert_fault('app_identity_unverified',lambda:self.request(runtime,'submit',{'tool':'runtime.ping','args':{},'key':'key'}))
        self.assert_fault('method_not_authorized',lambda:self.request(runtime,'heartbeat',app='friday',verified='friday'))
        runtime.control.close()

    def test_live_guard_death_revokes_metadata_and_descriptors_are_bounded(self):
        runtime=self.runtime(); alive=[True]
        runtime.control.apps.register(AppDescriptor('friday','Friday','sf:house'),active_guard=lambda:alive[0])
        runtime.control.apps.observe_verified('friday'); alive[0]=False
        app=next(a for a in runtime.control.apps.snapshot(runtime.policies) if a['id']=='friday')
        self.assertEqual(app['registration'],'revoked')
        for descriptor in (AppDescriptor('attacker','Bad','sf:app'),AppDescriptor('tisra','Bad','file:/private/key'),
                AppDescriptor('tisra','x'*201,'sf:app'),AppDescriptor('tisra','Bad','sf:app',capabilities=([],))):
            self.assert_fault('unknown_app' if descriptor.id=='attacker' else 'invalid_app_descriptor',lambda:runtime.control.apps.register(descriptor))

    def test_friday_household_requires_verified_and_action_specific_health(self):
        runtime=self.runtime(); registry=runtime.control.apps
        clock=FixedClock(); registry.clock=lambda:clock.millis; registry.monotonic=lambda:clock.millis
        registry.register(AppDescriptor('friday','Friday','sf:house','1',('household.state.read','household.actuate')))
        def household(): return registry.household(registry.snapshot(runtime.policies))
        self.assertEqual(household()['state'],'not_registered')
        registry.observe_verified('friday')
        self.assertEqual(household()['state'],'not_registered')
        self.establish(runtime,'friday',registry.entries['friday']['descriptor'])
        self.assertEqual(household()['state'],'unavailable')
        registry.observe_capability('friday','household.state.read',True)
        self.assertEqual(household()['state'],'available')
        self.assertEqual(household()['actuation_capabilities'],['household.actuate'])
        self.assertNotIn('endpoint',household())
        self.assert_fault('invalid_capability_observation',lambda:registry.observe_capability('friday','ha.token',True))
        clock.advance(31)
        self.assertEqual(household()['state'],'not_registered')

    def test_apple_action_status_never_calls_transport_or_implies_write(self):
        transport=Mock(side_effect=AssertionError('must not read Apple data'))
        runtime=self.runtime(apple=AppleAdapter(transport),identity_verifier=lambda c,a:None)
        runtime.control.observe_apple('apple.calendar.list',permission='authorized',lock='unlocked')
        apps=runtime.control.apple_snapshot()
        calendar=next(app for app in apps if app['id']=='calendar')
        read=next(a for a in calendar['actions'] if a['id']=='apple.calendar.list')
        self.assertEqual(read['state'],'ready')
        self.assertTrue(read['authorized'])
        for app in apps:
            for action in app['actions']:
                if action['id'] not in {'apple.calendar.list','apple.reminders.list'}:
                    self.assertEqual(action['state'],'not_implemented')
        runtime.control.observe_apple('apple.calendar.list',permission='authorized',lock='locked')
        self.assertEqual(runtime.control.apple_snapshot()[0]['actions'][0]['state'],'locked')
        self.assert_fault('invalid_apple_observation',lambda:runtime.control.observe_apple('apple.notes.append',permission='authorized',lock='unlocked'))
        transport.assert_not_called()

    def test_credential_fixture_removal_is_not_provider_revocation(self):
        refs=CredentialReferences(); identity=refs.fixture('amap','bounded travel read')
        before=refs.snapshot()[0]
        self.assertEqual(before['state'],'fixture'); self.assertIsNotNone(before['reference_id'])
        refs.remove(identity)
        after=refs.snapshot()[0]
        self.assertEqual(after['state'],'removed'); self.assertIsNone(after['reference_id'])
        self.assertEqual(after['provider_revocation'],'not_performed')
        self.assert_fault('invalid_credential_descriptor',lambda:refs.fixture('https://private','bad'))

    def test_apple_authorized_with_unknown_lock_is_not_ready(self):
        transport=Mock(side_effect=AssertionError('must not read Apple data'))
        runtime=self.runtime(apple=AppleAdapter(transport),identity_verifier=lambda c,a:None)
        runtime.control.observe_apple('apple.calendar.list',permission='authorized',lock='unknown')
        read=runtime.control.apple_snapshot()[0]['actions'][0]
        self.assertTrue(read['authorized'])
        self.assertEqual(read['state'],'unknown')
        runtime.control.observe_apple('apple.calendar.list',permission='authorized',lock='not_applicable')
        self.assertEqual(runtime.control.apple_snapshot()[0]['actions'][0]['state'],'ready')
        transport.assert_not_called()

class DiagnosticTests(unittest.TestCase):
    def setUp(self):
        self.clock=FixedClock(); self.logs=Diagnostics({'tisra','friday'},clock=lambda:self.clock.millis)
    def test_redaction_filter_cursor_and_export(self):
        self.logs.emit('runtime_ready')
        self.logs.emit('rpc_rejected',code='token=synthetic-secret',app='/private/key',level='warning')
        self.logs.emit('app_verified',app='tisra')
        page=self.logs.query({'limit':1,'level':'warning'})
        self.assertEqual(len(page['records']),1)
        self.assertEqual(page['records'][0]['code'],None)
        self.assertEqual(page['records'][0]['app_id'],None)
        self.logs.emit('app_verified',app='tisra')
        follow=self.logs.query({'cursor':page['next_cursor']})
        self.assertEqual(follow['records'][0]['event'],'app_verified')
        output=self.logs.query({},export=True)
        self.assertEqual(output['records_count'],4)
        self.assertEqual([json.loads(line)['sequence'] for line in output['content'].splitlines()],[1,2,3,4])
        for secret in ('synthetic-secret','/private/key','token='):
            self.assertNotIn(secret,json.dumps(output))
    def test_count_byte_age_limit_and_invalid_cursor(self):
        for _ in range(1200): self.logs.emit('rpc_rejected',code='identity_unverified',app='friday',level='warning')
        page=self.logs.query({'limit':100})
        self.assertTrue(page['truncated']); self.assertTrue(page['more']); self.assertEqual(len(page['records']),100)
        self.assertEqual([r['sequence'] for r in page['records']],sorted(r['sequence'] for r in page['records']))
        output=self.logs.query({},export=True)
        self.assertLessEqual(len(output['content'].encode()),65536)
        self.assertLessEqual(output['records_count'],500); self.assertTrue(output['more'])
        for params in ({'cursor':'a'*32+':1'},{'cursor':self.logs.boot+':9999'}):
            with self.assertRaises(Fault) as caught:self.logs.query(params)
            self.assertEqual(caught.exception.code,'invalid_cursor')
        for params in ({'limit':101},{'since_ms':self.clock.millis+1},{'level':'secret'},{'until_ms':0,'since_ms':1}):
            with self.assertRaises(Fault):self.logs.query(params)
        self.clock.advance(86401)
        expired=self.logs.query({'cursor':self.logs.boot+':0'})
        self.assertTrue(expired['truncated']); self.assertEqual(expired['records'],[])
    def test_filtered_empty_pages_advance_cursor(self):
        for _ in range(4): self.logs.emit('runtime_ready')
        page=self.logs.query({'level':'error'})
        self.assertEqual(page['records'],[]); self.assertTrue(page['next_cursor'].endswith(':4'))
        self.logs.emit('rpc_rejected',level='error')
        next_page=self.logs.query({'level':'error','cursor':page['next_cursor']})
        self.assertEqual(len(next_page['records']),1)

class ResourceTests(unittest.TestCase):
    def test_interval_cpu_cache_shared_attribution_and_pid_reuse(self):
        clock=FixedClock(); birth=[1]; cpu=[0]; calls=[0]
        def identity(pid): return {'uid':os.geteuid(),'birth':(birth[0],0),'executable':'private-not-output'}
        def system():
            calls[0]+=1
            return {'ticks':[int(clock.seconds*50),0,int(clock.seconds*50),0],
                'cpu_logical_count':4,'memory_total_bytes':16000,'swap_used_bytes':10,'memory_pressure':'warning'}
        sampler=ResourceSampler(system_reader=system,identity_reader=identity,
            process_reader=lambda pid:{'cpu_ns':cpu[0],'rss_bytes':200},
            clock=lambda:clock.seconds,wall_clock=lambda:clock.millis,include_runtime=False)
        sampler.register('friday',42,['friday']); sampler.register('tisra',42,['tisra'])
        first=sampler.sample()
        self.assertIsNone(first['system_cpu_percent']); self.assertIsNone(first['processes'][0]['cpu_percent'])
        self.assertEqual(len(first['processes']),1)
        self.assertEqual(first['processes'][0]['app_ids'],['friday','tisra'])
        self.assertNotIn('42',json.dumps(first)); self.assertNotIn('private-not-output',json.dumps(first))
        clock.advance(1); self.assertEqual(sampler.sample()['sampled_at_ms'],first['sampled_at_ms']); self.assertEqual(calls[0],1)
        clock.advance(4); cpu[0]=10000000000
        second=sampler.sample(); self.assertEqual(second['system_cpu_percent'],50)
        self.assertEqual(second['processes'][0]['cpu_percent'],200); self.assertEqual(second['state'],'available')
        clock.advance(5); birth[0]=2
        reused=sampler.sample(); self.assertEqual(reused['processes'][0]['state'],'unavailable')
        self.assertIsNone(reused['processes'][0]['rss_bytes'])
    def test_unavailable_data_and_uid_rejected_not_fabricated(self):
        sampler=ResourceSampler(system_reader=lambda:(_ for _ in ()).throw(OSError('secret')),
            identity_reader=lambda pid:{'uid':os.geteuid()+1})
        with self.assertRaises(Fault): sampler.register('friday',42,['friday'])
        result=sampler.sample()
        self.assertEqual(result['state'],'unavailable')
        self.assertIsNone(result['swap_used_bytes']); self.assertEqual(result['memory_pressure'],'unknown')
        self.assertEqual(result['gpu_allocation'],'unavailable')
        self.assertNotIn('secret',json.dumps(result))

class ProviderTests(RuntimeCase):
    def test_catalog_is_discovered_not_loaded_and_disabled_policy_no_inference(self):
        class Catalog:
            paid=False
            def discover(self):return {'availability':'ready','evidence':'local_http','models':['qwen3.8:27b','/private/secret','https://secret'],'token':'secret'}
        runtime=Runtime(self.home,providers={'ollama':Catalog()},policies=metadata_policies(),execute_jobs=False)
        status=runtime.control.providers
        status.snapshot(); status.thread.join(2)
        row=status.snapshot()[0]
        self.assertEqual(row['state'],'discovered'); self.assertEqual(row['model_load_state'],'unknown')
        self.assertFalse(row['inference_enabled']); self.assertEqual(row['catalog_models'],['qwen3.8:27b'])
        stamp=row['checked_at_ms']; self.assertEqual(status.snapshot()[0]['checked_at_ms'],stamp)
        self.assertNotIn('secret',json.dumps(row)); status.close()
    def test_stuck_provider_does_not_block_rpc_or_spawn_unbounded_probe_threads(self):
        event=threading.Event(); started=threading.Event()
        class Stuck:
            paid=False
            def discover(self):started.set(); event.wait(5); return {}
        runtime=Runtime(self.home,providers={'local':Stuck()})
        status=runtime.control.providers; now=[0]; status.monotonic=lambda:now[0]
        stamp=time.monotonic(); status.snapshot(); self.assertLess(time.monotonic()-stamp,0.2)
        self.assertTrue(started.wait(1)); worker=status.thread
        now[0]=3; self.assertEqual(status.snapshot()[0]['state'],'degraded'); self.assertIs(status.thread,worker)
        status.close(); event.set(); worker.join(2)

@unittest.skipUnless(sys.platform=='darwin','real macOS kernel peer and metrics')
class ControlNativeTests(RuntimeCase):
    def test_controlled_supervisor_real_registration_metrics_and_exit_revoke(self):
        root=Path(__file__).resolve().parents[1]
        fixture=root/'tests/controlled_metadata_fixture.py'
        registry=RegisteredPeerVerifier({'tisra','friday'})
        registry.register('tisra',os.getpid(),process_identity(os.getpid())['executable'])
        holder=[]
        def verify(connection,app):
            if struct.unpack('i',connection.getsockopt(0,2,4))[0] == os.getpid():
                return registry(connection,app)
            return holder[0].peer_verifier(connection,app) if holder else None
        with running(self.home,identity_verifier=verify,providers={'mock':MockProvider()}) as (runtime,_):
            # Xcode's sys.executable can be a trampoline. Pin/launch the kernel-
            # observed actual interpreter; never weaken verifier path equality.
            native=Path(process_identity(os.getpid())['executable'])
            spec=LaunchSpec('friday',native,(str(fixture),str(self.home)),root,
                           pin_sources([fixture,root/'arl/client.py']),python_paths=(root,))
            supervisor=ControlledSupervisor([spec],registry,control=runtime.control,
                descriptors=[AppDescriptor('friday','Friday','sf:house','test.1',('household.state.read',))])
            holder.append(supervisor)
            try:
                child=supervisor.launch('friday')
                # Bound child handshake/read, no indefinite UI or stdin wait.
                import selectors
                selector=selectors.DefaultSelector(); selector.register(child.stdout,selectors.EVENT_READ)
                self.assertTrue(selector.select(timeout=3)); line=child.stdout.readline(); selector.close()
                self.assertTrue(json.loads(line)['accepted'])
                snapshot=Client(self.home,'settings').rpc('settings.snapshot')
                friday=next(app for app in snapshot['apps'] if app['id']=='friday')
                self.assertEqual(friday['authentication'],'verified')
                process=next(p for p in snapshot['resources']['processes'] if p['id']=='friday')
                self.assertGreater(process['rss_bytes'],0)
                self.assertEqual(process['app_ids'],['friday'])
                self.assertTrue(any(p['id']=='runtime' for p in snapshot['resources']['processes']))
                # Even while the controlled process is alive, verifier revocation
                # must stop presenting registered/verified metadata immediately.
                registry.revoke(child.pid)
                apps=runtime.control.apps.snapshot(runtime.policies)
                self.assertEqual(next(a for a in apps if a['id']=='friday')['registration'],'revoked')
                child.stdin.write('exit\n'); child.stdin.flush(); child.wait(timeout=3)
                apps=runtime.control.apps.snapshot(runtime.policies)
                self.assertEqual(next(a for a in apps if a['id']=='friday')['registration'],'revoked')
            finally: supervisor.close()

    def test_real_verified_heartbeat_spoof_revoke_and_public_metadata(self):
        verifier=RegisteredPeerVerifier({'tisra','friday'})
        verifier.register('tisra',os.getpid(),process_identity(os.getpid())['executable'])
        with running(self.home,identity_verifier=verifier,providers={'mock':MockProvider()},resources=fake_resources()) as (runtime,client):
            runtime.control.apps.register(AppDescriptor('tisra','Tisra','sf:sparkle','alpha.1'))
            self.assertTrue(client.rpc('heartbeat')['accepted'])
            settings=Client(self.home,'settings')
            snapshot=settings.rpc('settings.snapshot')
            self.assertEqual(next(a for a in snapshot['apps'] if a['id']=='tisra')['authentication'],'verified')
            self.assertEqual(settings.rpc('overview')['schema_version'],1)
            self.assert_fault('app_identity_unverified',lambda:Client(self.home,'friday').rpc('heartbeat'))
            program="from arl.client import Client; from arl.contracts import Fault; import sys\ntry: Client(sys.argv[1],'tisra').rpc('heartbeat')\nexcept Fault as e: print(e.code)"
            result=subprocess.run([sys.executable,'-B','-c',program,str(self.home)],capture_output=True,timeout=5)
            self.assertEqual(result.stdout.decode().strip(),'app_identity_unverified')
            verifier.revoke(os.getpid()); runtime.control.apps.revoke('tisra')
            self.assert_fault('app_identity_unverified',lambda:client.rpc('heartbeat'))
            logs=settings.rpc('settings.logs')
            self.assertTrue(any(row['code']=='identity_unverified' for row in logs['records']))
            exported=settings.rpc('settings.logs_export')
            self.assertLessEqual(len(exported['content'].encode()),65536)
    def test_real_macos_read_only_system_and_own_process_metrics(self):
        sampler=ResourceSampler(); first=sampler.sample()
        self.assertGreater(first['memory_total_bytes'],0)
        self.assertGreater(first['cpu_logical_count'],0)
        own=next(row for row in first['processes'] if row['id']=='runtime')
        self.assertGreater(own['rss_bytes'],0)
        self.assertIsNone(own['cpu_percent'])
        self.assertEqual(sampler.sample()['sampled_at_ms'],first['sampled_at_ms'])
