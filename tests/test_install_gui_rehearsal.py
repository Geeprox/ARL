"""Whole install/recovery rehearsal for GUI+inactive-job; no OS processes/services."""
import json
import subprocess
import unittest
from unittest.mock import patch
from arl.install_platform import MacPlatform,prepare_payloads,CORE,MIO
from arl.install_transaction import Layout,Transaction,InstallFault,encode,atomic,inventory
from tests import test_install_unified_update as fixture

class RehearsalPlatform(fixture.FixturePlatform):
    def __init__(self,layout,host):
        super().__init__(layout,host)
        self.loaded=True;self.job_pid=None;self.next_pid=1000
        self.helper_live=True;self.refuse_helper=False;self.fail_phase=None;self.bad_ready=False
        self.recovery_conflict=None;self.foreign_core=None;self.foreign_mio=None;self.conflict_index=None
        self.helper={'pid':300,'birth':[300,1],'executable':str(layout.targets['app']/'Contents/Library/LoginItems/ARLRemindersBridge.app/Contents/MacOS/ARLRemindersBridge')}
    # Exercise real MacPlatform gates/order; only the external OS is simulated.
    core_entry=MacPlatform.core_entry
    app_state=MacPlatform.app_state
    quit_app=MacPlatform.quit_app
    stop_service=MacPlatform.stop_service
    wait_owned_children=MacPlatform.wait_owned_children
    reminders_state=MacPlatform.reminders_state
    quit_reminders=MacPlatform.quit_reminders
    def checkpoint(self,phase):
        self.events.append('phase:'+phase)
        if phase==self.fail_phase:self.fail_phase=None;raise InstallFault('rehearsal_interruption')
        if phase=='restore_old' and self.recovery_conflict:
            self._start()  # A legitimate old GUI/runtime is independently healthy.
            foreign={**self.owner,'pid':9999,'birth':[9999,1]}
            if self.recovery_conflict=='core':self.foreign_core=foreign
            else:self.foreign_mio=foreign
            self.conflict_index=len(self.events)
    def service(self,label):
        if label==MIO:return self.foreign_mio
        if self.foreign_core is not None:return self.foreign_core
        if not self.loaded:return None
        if self.job_pid is None:raise InstallFault('install_service_not_running')
        return self.owner
    def current(self,record):
        return record['pid'] in self.live and any(all(record.get(k)==value.get(k) for k in ('pid','birth','executable')) for value in [self.owner,*self.children.values()])
    def parent(self,pid):return self.owner['pid']
    def metadata(self,method):
        import plistlib
        info=plistlib.loads((self.layout.targets['app']/'Contents/Info.plist').read_bytes())
        if method=='overview':return {'queue':{'available':True,'counts':{'running':0,'queued':0}},'health':{'ready':True}}
        if method=='ready':return {'version':info['CFBundleShortVersionString']}
        if method=='runtime.describe':return {'ready':True,'version':info['CFBundleShortVersionString'],'source_sha256':'wrong-generation' if self.bad_ready and info['CFBundleVersion']=='70' else info['ARLCoreRuntimeSourceSHA256'],'features':{'app_sessions':1}}
        raise AssertionError(method)
    def _start(self):
        if self.live:raise AssertionError('would start a second owner')
        self.owner={**self.owner,'pid':self.next_pid,'birth':[self.next_pid,1]}
        self.next_pid+=10
        self.children={role:{**record,'pid':self.owner['pid']+n,'birth':[self.owner['pid']+n,1]} for n,(role,record) in enumerate(self.children.items(),1)}
        self.live={self.owner['pid'],*[x['pid'] for x in self.children.values()]}
        self.job_pid=self.owner['pid'];self.loaded=True
        atomic(self.layout.state/'owned-runtime.json',encode({'owner':self.owner,'children':self.children}))
        atomic(self.layout.state/'mio-apple/owned-child.json',encode({'synthetic':True}))
    def command(self,args,**kwargs):
        args=list(map(str,args));action=args[1]
        if args[0]==str(self.host):
            if action=='--internal-app-state':
                value={'schema_version':1,'instances':[{**self.owner,'drain_supported':True}] if self.owner['pid'] in self.live else []}
            elif action=='--internal-app-quit':
                assert args[2:]==[str(self.owner['pid']),*map(str,self.owner['birth'])]
                self.events.append('normal_owner_quit');self.live.clear();self.job_pid=None
                child=self.layout.state/'mio-apple/owned-child.json'
                if child.exists():child.unlink()
                value={'terminated':True}
            elif action=='--internal-reminders-state':
                value={'schema_version':1,'instance':self.helper if self.helper_live else None,'admissions_sha256':'a'*64 if self.helper_live else None,'admissions_count':7 if self.helper_live else 0,'pending':0}
            elif action=='--internal-reminders-quit':
                assert not self.live and args[2:]==['300','300','1','a'*64]
                self.events.append('normal_helper_quit')
                if self.refuse_helper:raise InstallFault('install_platform_command_failed')
                self.helper_live=False;value={'terminated':True}
            else:raise AssertionError(args)
            return subprocess.CompletedProcess(args,0,json.dumps(value).encode(),b'')
        if args[0]=='/bin/launchctl':
            self.events.append('launchctl:'+action)
            if action=='print':
                if not self.loaded:return subprocess.CompletedProcess(args,113,b'',b'')
                raw='state = not running\nprogram = '+str(self.layout.targets['app']/'Contents/MacOS/ARL')+'\n'
                return subprocess.CompletedProcess(args,0,raw.encode(),b'')
            if action=='bootout':
                assert not self.live;self.loaded=False;self.job_pid=None
            elif action in {'bootstrap','kickstart'}:self._start()
            else:raise AssertionError(args)
            return subprocess.CompletedProcess(args,0,b'',b'')
        raise AssertionError('unexpected external action '+str(args))

class GUITransactionRehearsal(unittest.TestCase):
    setUp=fixture.UnifiedUpdateTests.setUp
    tearDown=fixture.UnifiedUpdateTests.tearDown
    def prepare(self):
        self.layout=Layout(self.root)
        self.platform=RehearsalPlatform(self.layout,self.app/'Contents/MacOS/ARL')
        payloads,details=prepare_payloads(self.layout,self.platform,self.package)
        self.before={key:inventory(self.layout.targets[key]) for key in payloads}
        engine=Transaction(self.layout,self.platform);plan=engine.prepare(payloads,details)
        return engine,plan
    def apply(self,engine,plan):
        clock=[0]
        def tick():clock[0]+=1;return clock[0]
        with patch('arl.install_platform.time.monotonic',side_effect=tick),patch('arl.install_platform.time.sleep'):
            return engine.apply(plan['transaction'],plan['plan_sha256'])
    def test_complete_apply_ready_and_one_final_owner(self):
        engine,plan=self.prepare();result=self.apply(engine,plan)
        self.assertEqual(result['phase'],'committed');self.assertEqual(result['result'],'applied')
        self.assertFalse(self.platform.helper_live);self.assertTrue(self.platform.loaded)
        self.assertEqual(len(self.platform.app_state()),1);self.assertEqual(len(self.platform.live),3)
        self.assertEqual(self.platform.events.count('normal_owner_quit'),2)
        self.assertEqual(self.platform.events.count('normal_helper_quit'),1)
        self.assertLess(self.platform.events.index('normal_helper_quit'),self.platform.events.index('phase:publish_maintenance'))
        self.assertFalse(self.layout.targets['maintenance'].exists())
        self.assertTrue(json.loads(self.layout.targets['installation'].read_bytes())['store_schema_preserved'])
    def test_helper_refusal_restores_old_before_any_publish(self):
        engine,plan=self.prepare();self.platform.refuse_helper=True;result=self.apply(engine,plan)
        self.assertEqual((result['phase'],result['result']),('rolled_back','restored'))
        self.assertNotIn('phase:publish_maintenance',self.platform.events)
        self.assertTrue(self.platform.helper_live);self.assertEqual(len(self.platform.app_state()),1)
        self.assertEqual(self.before,{key:inventory(self.layout.targets[key]) for key in self.before})
    def test_publish_and_final_ready_failures_compensate_with_one_owner(self):
        for phase in ['after_publish_app','verify_maintenance','verify_final']:
            with self.subTest(phase=phase):
                # Each exact file-tree trial needs an independent owned fixture.
                if phase!='after_publish_app':self.tearDown();self.setUp()
                engine,plan=self.prepare();self.platform.fail_phase=phase;result=self.apply(engine,plan)
                self.assertEqual((result['phase'],result['result']),('rolled_back','restored'))
                self.assertEqual(self.before,{key:inventory(self.layout.targets[key]) for key in self.before})
                self.assertEqual(len(self.platform.app_state()),1);self.assertEqual(len(self.platform.live),3)
    def test_actual_new_readiness_gate_rejects_wrong_source_and_restores(self):
        engine,plan=self.prepare();self.platform.bad_ready=True;result=self.apply(engine,plan)
        self.assertEqual((result['phase'],result['result']),('rolled_back','restored'))
        _,_,journal=engine.read(plan['transaction'])
        self.assertEqual(journal['apply_failure']['code'],'install_new_readback_failed')
        self.assertEqual(self.before,{key:inventory(self.layout.targets[key]) for key in self.before})
        self.assertEqual(len(self.platform.app_state()),1)

    def test_recovery_conflicts_pause_and_preserve_foreign_jobs(self):
        for conflict in ['core','mio']:
            with self.subTest(conflict=conflict):
                if conflict=='mio':self.tearDown();self.setUp()
                engine,plan=self.prepare();self.platform.fail_phase='verify_final';self.platform.recovery_conflict=conflict
                with self.assertRaisesRegex(InstallFault,'install_old_owner_conflict' if conflict=='core' else 'install_old_service_conflict'):
                    self.apply(engine,plan)
                _,_,journal=engine.read(plan['transaction'])
                self.assertEqual((journal['phase'],journal['result']),('needs_attention','paused'))
                self.assertEqual(self.before,{key:inventory(self.layout.targets[key]) for key in self.before})
                self.assertEqual(len(self.platform.app_state()),1)
                self.assertFalse(any(x.startswith(('normal_owner_quit','launchctl:bootout','launchctl:bootstrap','launchctl:kickstart')) for x in self.platform.events[self.platform.conflict_index:]))
                self.assertIsNotNone(self.platform.foreign_core if conflict=='core' else self.platform.foreign_mio)
