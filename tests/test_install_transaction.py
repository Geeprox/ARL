"""Filesystem/ownership fault injection only; no real launchctl or user state."""
import json
from pathlib import Path
import tempfile
import unittest
from arl.install_transaction import Layout,Transaction,InstallFault,encode,inventory,atomic

class Crash(BaseException):pass
class Platform:
    def __init__(self):self.calls=[];self.fail=None;self.crash=None;self.new_busy=False
    def checkpoint(self,phase):
        self.calls.append(phase)
        if phase==self.crash:raise Crash()
        if phase==self.fail:self.fail=None;raise InstallFault('injected_failure')
    def verify_plan(self,p,f):self.calls.append('verify_plan')
    def quiesce_old(self,p):self.calls.append('old_stopped')
    def start_maintenance(self,p):self.calls.append('maintenance_started')
    def verify_new(self,p,maintenance):self.calls.append('verify_'+str(maintenance))
    def quiesce_new(self,p):self.calls.append('new_stopped')
    def start_final(self,p):self.calls.append('final_started')
    def assert_new_idle(self,p):
        if self.new_busy:raise InstallFault('active_work_requires_drain')
    def restore_old(self,p):self.calls.append('old_restored')
    def verify_old(self,p):self.calls.append('old_verified')

class TransactionTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='arl-transaction-');self.root=Path(self.temp.name).resolve()
        self.layout=Layout(self.root);self.layout.state.mkdir(parents=True,mode=0o700)
        self.layout.targets['app'].mkdir(parents=True);(self.layout.targets['app']/'code').write_bytes(b'old app')
        self.layout.targets['core_agent'].parent.mkdir(parents=True)
        self.layout.targets['core_agent'].write_bytes(b'old agent');self.layout.targets['core_agent'].chmod(0o600)
        self.layout.targets['authority'].write_bytes(b'old authority');self.layout.targets['authority'].chmod(0o600)
        self.candidate=self.root/'candidate';self.candidate.mkdir();(self.candidate/'code').write_bytes(b'new app')
        self.before={k:inventory(self.layout.targets[k]) for k in ['app','core_agent','authority','maintenance']}
        self.platform=Platform();self.engine=Transaction(self.layout,self.platform)
        self.plan=self.engine.prepare({'app':self.candidate,'core_agent':b'new agent','authority':b'code-only binding','maintenance':encode({'enabled':1})},{'synthetic':True})
    def tearDown(self):self.temp.cleanup()
    def assert_restored(self):
        self.assertEqual(self.before,{k:inventory(self.layout.targets[k]) for k in self.before})
    def test_new_reader_barrier_and_legacy_journal_compatibility(self):
        folder,plan,journal=self.engine.read(self.plan['transaction'])
        self.assertEqual((plan['schema'],journal['schema']),(2,2))
        # Historical journal/schema1 recovery remains available.
        plan['schema']=journal['schema']=1
        atomic(folder/'plan.json',encode(plan));atomic(folder/'journal.json',encode(journal))
        self.engine.read(self.plan['transaction'])
        for bad in [True,3]:
            plan['schema']=journal['schema']=bad
            atomic(folder/'plan.json',encode(plan));atomic(folder/'journal.json',encode(journal))
            with self.assertRaisesRegex(InstallFault,'invalid_install_journal'):self.engine.read(self.plan['transaction'])

    def test_success_idempotency_and_explicit_rollback(self):
        first=self.engine.apply(self.plan['transaction'],self.plan['plan_sha256'])
        self.assertEqual(first['phase'],'committed');self.assertFalse(self.layout.targets['maintenance'].exists())
        self.assertEqual(self.engine.apply(self.plan['transaction'],self.plan['plan_sha256'])['result'],'already_applied')
        self.assertEqual(self.engine.rollback(self.plan['transaction'])['result'],'restored');self.assert_restored()
        self.assertEqual(self.engine.rollback(self.plan['transaction'])['result'],'already_restored')
    def test_codex_scope_joins_atomic_snapshot_and_rollback(self):
        original=b'synthetic original reviewed scope'
        atomic(self.layout.targets['codex_scope'],original)
        payloads={'app':self.candidate,'core_agent':b'new agent','codex_scope':b'synthetic new scope','maintenance':encode({'enabled':1})}
        plan=self.engine.prepare(payloads,{'synthetic':True})
        self.engine.apply(plan['transaction'],plan['plan_sha256'])
        self.assertEqual(self.layout.targets['codex_scope'].read_bytes(),b'synthetic new scope')
        self.engine.rollback(plan['transaction'])
        self.assertEqual(self.layout.targets['codex_scope'].read_bytes(),original)
    def test_new_codex_scope_is_removed_on_failed_publication(self):
        self.assertFalse(self.layout.targets['codex_scope'].exists())
        plan=self.engine.prepare({'app':self.candidate,'core_agent':b'new agent','codex_scope':b'synthetic new scope','maintenance':encode({'enabled':1})},{'synthetic':True})
        self.platform.fail='after_publish_codex_scope'
        self.assertEqual(self.engine.apply(plan['transaction'],plan['plan_sha256'])['phase'],'rolled_back')
        self.assertFalse(self.layout.targets['codex_scope'].exists())
    def test_unreviewed_digest_or_changed_preimage_never_stops_services(self):
        with self.assertRaisesRegex(InstallFault,'unreviewed_install_plan'):self.engine.apply(self.plan['transaction'],'0'*64)
        self.assertNotIn('old_stopped',self.platform.calls)
        atomic(self.layout.targets['authority'],b'user changed binding')
        with self.assertRaisesRegex(InstallFault,'install_preimage_changed'):self.engine.apply(self.plan['transaction'],self.plan['plan_sha256'])
        self.assertNotIn('old_stopped',self.platform.calls)
    def test_backup_publish_and_readback_failures_restore_original(self):
        self.platform.fail='after_backup_authority'
        result=self.engine.apply(self.plan['transaction'],self.plan['plan_sha256'])
        self.assertEqual(result['phase'],'rolled_back');self.assert_restored()
    def test_apply_and_recovery_first_failures_survive_later_rollback(self):
        from unittest.mock import patch
        import errno
        self.platform.fail='start_maintenance'
        with patch.object(self.platform,'quiesce_new',side_effect=OSError(errno.EBUSY,'private token text')):
            with self.assertRaisesRegex(InstallFault,'install_recovery_unproven'):
                self.engine.apply(self.plan['transaction'],self.plan['plan_sha256'])
        folder,_,journal=self.engine.read(self.plan['transaction'])
        self.assertEqual(journal['apply_failure'],{'phase':'start_maintenance','code':'injected_failure','type':'InstallFault'})
        self.assertEqual(journal['recovery_failure'],{'phase':'rollback_quiesce','code':'install_recovery_unproven','type':'OSError','errno':errno.EBUSY})
        self.assertNotIn('private token',json.dumps(journal))
        self.engine.rollback(self.plan['transaction']);self.assert_restored()
        after=json.loads((folder/'journal.json').read_text())
        self.assertEqual(after['apply_failure'],journal['apply_failure'])
        self.assertEqual(after['recovery_failure'],journal['recovery_failure'])

    def test_readback_failure_preserves_the_verification_phase(self):
        from unittest.mock import patch
        with patch.object(self.platform,'verify_new',side_effect=InstallFault('install_new_readback_failed',{'last_failure':{'phase':'verify_new','code':'peer_identity_unavailable','type':'Fault'}})):
            self.assertEqual(self.engine.apply(self.plan['transaction'],self.plan['plan_sha256'])['phase'],'rolled_back')
        journal=self.engine.read(self.plan['transaction'])[2]
        self.assertEqual(journal['apply_failure']['phase'],'verify_maintenance')
        self.assertEqual(journal['apply_failure']['last_failure']['code'],'peer_identity_unavailable')

    def test_crash_between_rename_and_journal_reconciles_after_restart(self):
        self.platform.crash='after_publish_app'
        with self.assertRaises(Crash):self.engine.apply(self.plan['transaction'],self.plan['plan_sha256'])
        restarted=Transaction(self.layout,Platform())
        result=restarted.rollback(self.plan['transaction'])
        self.assertEqual(result['phase'],'rolled_back');self.assert_restored()
    def test_external_change_is_retained_and_reports_uncertain_recovery(self):
        self.platform.crash='after_publish_authority'
        with self.assertRaises(Crash):self.engine.apply(self.plan['transaction'],self.plan['plan_sha256'])
        atomic(self.layout.targets['authority'],b'new external change')
        with self.assertRaisesRegex(InstallFault,'install_restore_conflict'):self.engine.rollback(self.plan['transaction'])
        self.assertEqual(self.layout.targets['authority'].read_bytes(),b'new external change')
        self.assertTrue((self.layout.folder(self.plan['transaction'])/'before/authority').is_file())
    def test_final_business_admission_requires_idle_before_rollback(self):
        self.engine.apply(self.plan['transaction'],self.plan['plan_sha256']);self.platform.new_busy=True
        with self.assertRaisesRegex(InstallFault,'active_work_requires_drain'):self.engine.rollback(self.plan['transaction'])
        self.assertEqual((self.layout.targets['app']/'code').read_bytes(),b'new app')
        failure=self.engine.read(self.plan['transaction'])[2]['recovery_failure']
        self.assertEqual(failure['phase'],'rollback_check_idle');self.assertEqual(failure['code'],'active_work_requires_drain')
    def test_simultaneous_operations_are_refused(self):
        with self.engine.lock():
            with self.assertRaisesRegex(InstallFault,'install_busy'):Transaction(self.layout,Platform()).rollback(self.plan['transaction'])
    def test_symlink_target_is_not_read_or_overwritten(self):
        target=self.layout.targets['authority'];target.unlink();target.symlink_to(self.root/'outside')
        with self.assertRaisesRegex(InstallFault,'install_symlink'):self.engine.apply(self.plan['transaction'],self.plan['plan_sha256'])
        self.assertFalse((self.root/'outside').exists())

    def test_legacy_preimage_retains_modes_but_candidate_stays_strict(self):
        legacy=self.layout.targets['app']/'Contents/Resources/NASRuntime/python/bin/python3.12'
        legacy.parent.mkdir(parents=True);legacy.write_bytes(b'signed legacy bytes');legacy.chmod(0o775)
        rel=str(legacy.relative_to(self.layout.targets['app']))
        from arl.install_transaction import sha
        allowed={rel:{'sha256':sha(legacy.read_bytes()),'mode':0o775}}
        with self.assertRaisesRegex(InstallFault,'unsafe_install_bundle'):inventory(self.layout.targets['app'])
        details={'synthetic':True,'legacy_nas_preimage':allowed}
        plan=self.engine.prepare({'app':self.candidate,'core_agent':b'new agent','maintenance':encode({'enabled':1})},details)
        self.platform.crash='after_publish_app'
        with self.assertRaises(Crash):self.engine.apply(plan['transaction'],plan['plan_sha256'])
        self.engine.platform=Platform();self.engine.rollback(plan['transaction'])
        self.assertEqual(legacy.read_bytes(),b'signed legacy bytes');self.assertEqual(legacy.stat().st_mode&0o777,0o775)
        (self.candidate/'code').chmod(0o664)
        with self.assertRaisesRegex(InstallFault,'unsafe_install_bundle'):
            self.engine.prepare({'app':self.candidate,'core_agent':b'x','maintenance':encode({'enabled':1})},details)

    def test_legacy_read_allowlist_refuses_changed_bytes_and_new_writable_file(self):
        app=self.layout.targets['app'];p=app/'Contents/Resources/NASRuntime/python/file';p.parent.mkdir(parents=True);p.write_bytes(b'old');p.chmod(0o664)
        from arl.install_transaction import sha
        allowed={str(p.relative_to(app)):{'sha256':sha(b'old'),'mode':0o664}}
        inventory(app,legacy_nas=allowed);p.write_bytes(b'changed')
        with self.assertRaisesRegex(InstallFault,'unsafe_install_bundle'):inventory(app,legacy_nas=allowed)
        p.write_bytes(b'old');q=app/'unsealed';q.write_bytes(b'x');q.chmod(0o664)
        with self.assertRaisesRegex(InstallFault,'unsafe_install_bundle'):inventory(app,legacy_nas=allowed)

    def test_real_sized_plan_reads_without_relaxing_other_metadata_limits(self):
        details={'synthetic':True,'bounded_inventory_fixture':'x'*(1024*1024)}
        plan=self.engine.prepare({'app':self.candidate,'core_agent':b'new agent','maintenance':encode({'enabled':1})},details)
        folder,value,journal=self.engine.read(plan['transaction'],plan['plan_sha256'])
        self.assertEqual(value['details'],details);self.assertEqual(journal['phase'],'prepared')
        from arl.install_transaction import private_file
        with self.assertRaisesRegex(InstallFault,'unsafe_install_metadata'):private_file(folder/'plan.json')

    def test_later_recovery_reports_current_failure_and_keeps_first(self):
        from unittest.mock import patch
        self.platform.fail='start_maintenance'
        with patch.object(self.platform,'quiesce_new',side_effect=InstallFault('first_recovery')):
            with self.assertRaisesRegex(InstallFault,'first_recovery'):self.engine.apply(self.plan['transaction'],self.plan['plan_sha256'])
        self.platform.new_busy=True
        with self.assertRaisesRegex(InstallFault,'active_work_requires_drain'):self.engine.rollback(self.plan['transaction'])
        journal=self.engine.read(self.plan['transaction'])[2]
        self.assertEqual(journal['recovery_failure']['code'],'first_recovery')
        self.assertEqual(journal['latest_recovery_failure']['code'],'active_work_requires_drain')
        self.assertEqual(journal['error'],'active_work_requires_drain')
        self.platform.new_busy=False;self.engine.rollback(self.plan['transaction'])
        self.assertIsNone(self.engine.read(self.plan['transaction'])[2]['error'])
    def test_parent_exit_pauses_without_starting_recovery(self):
        from unittest.mock import patch
        with patch.object(self.platform,'start_maintenance',side_effect=InstallFault('install_parent_exited')):
            with self.assertRaisesRegex(InstallFault,'install_parent_exited'):self.engine.apply(self.plan['transaction'],self.plan['plan_sha256'])
        self.assertNotIn('new_stopped',self.platform.calls)
        journal=self.engine.read(self.plan['transaction'])[2];self.assertEqual(journal['phase'],'needs_attention')
        self.assertEqual(journal['apply_failure']['phase'],'start_maintenance')
