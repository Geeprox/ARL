"""Finite platform diagnostics tests; no launchd, private account or credentials."""
import errno
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch
from arl.contracts import Fault
from arl.install_platform import MacPlatform,CORE
from arl.install_transaction import Layout,InstallFault,failure

class PlatformTests(unittest.TestCase):
    def setUp(self):self.platform=MacPlatform(Layout(Path('/tmp/arl-platform-fixture').resolve()),'/tmp/arl-platform-fixture/host')
    def test_timeout_and_exit_project_command_kind_without_raw_output(self):
        error=subprocess.TimeoutExpired(['/bin/launchctl','bootout','private-label'],20,output=b'secret',stderr=b'secret')
        with patch('arl.install_platform.subprocess.run',side_effect=error),self.assertRaises(InstallFault) as context:
            self.platform.command(['/bin/launchctl','bootout','private-label'])
        d=failure(context.exception,'stop_maintenance','unknown')
        self.assertEqual(d['code'],'install_platform_command_timeout');self.assertEqual(d['command'],'launchctl_bootout')
        self.assertEqual(d['cause_type'],'TimeoutExpired');self.assertNotIn('secret',str(d));self.assertNotIn('private-label',str(d))
        with patch('arl.install_platform.subprocess.run',return_value=subprocess.CompletedProcess([],7,b'secret',b'secret')),self.assertRaises(InstallFault) as context:
            self.platform.command(['/bin/launchctl','bootstrap','private-path'])
        self.assertEqual(context.exception.diagnostic,{'command':'launchctl_bootstrap','returncode':7})
    def test_os_error_projects_errno_without_message(self):
        with patch('arl.install_platform.subprocess.run',side_effect=OSError(errno.EACCES,'private-token')),self.assertRaises(InstallFault) as context:
            self.platform.command(['/bin/launchctl','print','private-label'])
        self.assertEqual(context.exception.diagnostic['last_failure']['errno'],errno.EACCES)
        self.assertNotIn('private-token',str(context.exception.diagnostic))
    def test_identity_fault_retries_until_bounded_deadline_and_never_ready(self):
        with patch.object(self.platform,'service',side_effect=Fault('peer_identity_unavailable','private-token')) as query,patch('arl.install_platform.time.monotonic',side_effect=[0,1,2,16]),patch('arl.install_platform.time.sleep'),self.assertRaises(InstallFault) as context:
            self.platform.verify_new({'details':{}},True)
        self.assertEqual(query.call_count,2);self.assertEqual(context.exception.code,'install_new_readback_failed')
        self.assertEqual(context.exception.diagnostic['last_failure'],{'phase':'verify_new','code':'peer_identity_unavailable','type':'Fault'})
    def test_temporary_identity_failure_can_only_succeed_after_full_verification(self):
        owner={'pid':123,'birth':[1,2],'executable':str(self.platform.layout.targets['app']/'Contents/MacOS/ARL')}
        core={'pid':124,'executable':str(self.platform.layout.targets['app']/'Contents/Resources/NASRuntime/python/bin/python3.12')}
        mio={'pid':125,'executable':str(self.platform.layout.targets['app']/'Contents/Library/LoginItems/ARLMioAppleBridge.app/Contents/MacOS/ARLMioAppleBridge')}
        with patch.object(self.platform,'service',side_effect=[Fault('peer_identity_unavailable'),owner,None]),patch.object(self.platform,'metadata',return_value={'ready':True,'source_sha256':'expected','version':'expected','features':{'app_sessions':1}}),patch('arl.install_platform.load',return_value={'owner':owner,'children':{'core':core,'mio':mio}}),patch.object(self.platform,'current',return_value=True),patch.object(self.platform,'parent',return_value=123),patch('arl.install_platform.time.sleep'):
            self.platform.verify_new({'details':{'source_sha256':'expected','version':'expected'}},False)
    def test_bootout_wait_covers_owned_launchagent_exit_timeout(self):
        with patch.object(self.platform,'service',side_effect=[{'pid':1},None]),patch.object(self.platform,'current',return_value=False),patch.object(self.platform,'command') as command:
            self.platform.stop_service(CORE)
        self.assertEqual(command.call_args.kwargs['seconds'],60)

    def test_bootout_stale_pid_only_finishes_after_confirmed_service_absence(self):
        owner={'pid':1,'birth':[1,2],'executable':'owned'}
        with patch.object(self.platform,'service',side_effect=[owner,Fault('peer_identity_unavailable'),None]) as service,patch.object(self.platform,'current',return_value=False),patch.object(self.platform,'command') as command,patch('arl.install_platform.time.sleep'):
            self.platform.stop_service(CORE,owner)
        self.assertEqual(service.call_count,3);command.assert_called_once()
        self.assertEqual(command.call_args.args[0],['/bin/launchctl','bootout',self.platform.domain+'/'+CORE])

    def test_persistent_post_bootout_identity_failure_never_proves_drain(self):
        owner={'pid':1,'birth':[1,2],'executable':'owned'}
        with patch.object(self.platform,'service',side_effect=[owner,Fault('peer_identity_unavailable'),Fault('peer_identity_unavailable')]),patch.object(self.platform,'current',return_value=False),patch.object(self.platform,'command') as command,patch('arl.install_platform.time.monotonic',side_effect=[0,1,2,41]),patch('arl.install_platform.time.sleep'),self.assertRaisesRegex(InstallFault,'install_service_drain_unproven'):
            self.platform.stop_service(CORE,owner)
        command.assert_called_once()

    def test_unified_stop_normally_quits_before_unloading_exited_job(self):
        owner={'pid':1,'birth':[1,2],'executable':str(self.platform.layout.targets['app']/'Contents/MacOS/ARL')};events=[]
        with patch.object(self.platform,'service',side_effect=[owner,InstallFault('install_service_not_running'),None]),patch.object(self.platform,'quit_app',side_effect=lambda record:events.append('normal_quit')) as quit,patch.object(self.platform,'current',return_value=False),patch.object(self.platform,'command',side_effect=lambda *a,**k:events.append('bootout')):
            self.platform.stop_service(CORE,owner)
        quit.assert_called_once_with({**owner,'drain_supported':True});self.assertEqual(events,['normal_quit','bootout'])

    def test_new_generation_after_normal_quit_is_not_unloaded(self):
        owner={'pid':1,'birth':[1,2],'executable':str(self.platform.layout.targets['app']/'Contents/MacOS/ARL')};replacement={**owner,'pid':2}
        with patch.object(self.platform,'service',side_effect=[owner,replacement]),patch.object(self.platform,'quit_app'),patch.object(self.platform,'command') as command,self.assertRaisesRegex(InstallFault,'install_service_generation_changed'):
            self.platform.stop_service(CORE,owner)
        command.assert_not_called()

    def test_restoring_background_owner_does_not_also_open_second_app(self):
        owner={'pid':1,'birth':[1,2],'executable':str(self.platform.layout.targets['app']/'Contents/MacOS/ARL')}
        plan={'details':{'old_services':{CORE:owner},'old_apps':[{**owner,'drain_supported':True}]}}
        with patch.object(self.platform,'service',return_value=None),patch.object(self.platform,'command') as command:self.platform.restore_old(plan)
        command.assert_called_once_with(['/bin/launchctl','bootstrap',self.platform.domain,self.platform.layout.targets['core_agent']])

    def test_legacy_foreground_restore_still_opens_app(self):
        owner={'pid':1,'birth':[1,2],'executable':'legacy-python'}
        plan={'details':{'old_services':{CORE:owner},'old_apps':[{'pid':2,'birth':[3,4],'executable':str(self.platform.layout.targets['app']/'Contents/MacOS/ARL')}]}}
        with patch.object(self.platform,'service',return_value=None),patch.object(self.platform,'command') as command:self.platform.restore_old(plan)
        self.assertEqual(command.call_count,2);self.assertEqual(command.call_args.args[0][0],'/usr/bin/open')

    def test_timeout_does_not_report_drained_without_worker_receipt(self):
        with patch('arl.install_platform.time.monotonic',side_effect=[0,1,16]),patch('arl.install_platform.time.sleep'),self.assertRaisesRegex(InstallFault,'install_worker_cleanup_unproven'):
            self.platform.management_quiet(Path('/private/tmp/absent-worker-fixture'),{},required_worker=True)

    def test_reminders_gate_rejects_pending_work_before_quit(self):
        import json
        state={'schema_version':1,'instance':None,'admissions_sha256':None,'admissions_count':1,'pending':1}
        with patch.object(self.platform,'command',return_value=subprocess.CompletedProcess([],0,json.dumps(state).encode(),b'')) as command,self.assertRaisesRegex(InstallFault,'install_reminders_work_active'):
            self.platform.reminders_state()
        self.assertEqual(command.call_args.args[0],[self.platform.host,'--internal-reminders-state'])

    def test_reminders_quit_uses_exact_observed_generation_and_checks_absence(self):
        record={'pid':123,'birth':[7,8],'executable':str(self.platform.layout.targets['app']/'Contents/Library/LoginItems/ARLRemindersBridge.app/Contents/MacOS/ARLRemindersBridge')}
        observed={'instance':record,'admissions_sha256':'a'*64}
        with patch.object(self.platform,'command',return_value=subprocess.CompletedProcess([],0,b'{"terminated":true}',b'')) as command,patch.object(self.platform,'reminders_state',return_value={'instance':None}):
            self.platform.quit_reminders(observed)
        self.assertEqual(command.call_args.args[0],[self.platform.host,'--internal-reminders-quit','123','7','8','a'*64])
        with patch.object(self.platform,'command',side_effect=InstallFault('install_platform_command_failed')) as command,patch.object(self.platform,'reminders_state') as state,self.assertRaisesRegex(InstallFault,'install_platform_command_failed'):
            self.platform.quit_reminders(observed)
        state.assert_not_called();self.assertEqual(command.call_count,1)
        with patch.object(self.platform,'command',return_value=subprocess.CompletedProcess([],0,b'{"terminated":true}',b'')),patch.object(self.platform,'reminders_state',return_value={'instance':record}),self.assertRaisesRegex(InstallFault,'install_reminders_restarted'):
            self.platform.quit_reminders(observed)

    def test_reminders_absence_does_not_authorize_stopping_a_new_instance(self):
        with patch.object(self.platform,'command') as command,patch.object(self.platform,'reminders_state',return_value={'instance':{'pid':999}}),self.assertRaisesRegex(InstallFault,'install_reminders_restarted'):
            self.platform.quit_reminders({'instance':None})
        command.assert_not_called()

    def test_core_entry_accepts_only_exact_registered_inactive_program(self):
        expected=str(self.platform.layout.targets['app']/'Contents/MacOS/ARL')
        for raw,valid in [(f'state = not running\nprogram = {expected}\n',True),
                          ('state = not running\nprogram = /unowned\n',False),
                          ('state = not running\n',False),
                          (f'state = not running\nprogram = {expected}\npid = 999\n',False)]:
            with patch.object(self.platform,'service',side_effect=InstallFault('install_service_not_running')),patch.object(self.platform,'command',return_value=subprocess.CompletedProcess([],0,raw.encode(),b'')):
                if valid:self.assertEqual(self.platform.core_entry(),(None,True))
                else:
                    with self.assertRaisesRegex(InstallFault,'install_idle_entry_changed'):self.platform.core_entry()
