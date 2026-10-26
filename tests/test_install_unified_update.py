"""Unified update plan/owner ordering with synthetic files, no launchd or accounts."""
import json,plistlib,sqlite3,tempfile,unittest
from unittest.mock import patch
from pathlib import Path
from arl.install_platform import MacPlatform,prepare_payloads,CORE,MIO,READ_OWNER_OLD,READ_OWNER_PRE_PRODUCT,READ_OWNER_NEW,reviewed_read_owner_transition
from arl.install_transaction import Layout,Transaction,InstallFault,encode,sha,inventory

class FixturePlatform(MacPlatform):
 def __init__(self,layout,host):
  super().__init__(layout,host);self.events=[]
  app=layout.targets['app'];self.owner={'pid':101,'birth':[1,2],'executable':str(app/'Contents/MacOS/ARL')}
  self.children={'core':{'pid':102,'birth':[3,4],'executable':str(app/'Contents/Resources/NASRuntime/python/bin/python3.12')},'mio':{'pid':103,'birth':[5,6],'executable':str(app/'Contents/Library/LoginItems/ARLMioAppleBridge.app/Contents/MacOS/ARLMioAppleBridge')}}
  self.live={101,102,103}
 def signature(self,app,rule):self.events.append('signature')
 def cdhash(self,app):return sha((app/'Contents/MacOS/ARLMioAppleBridge').read_bytes())[:40]
 def service(self,label):return self.owner if label==CORE and 101 in self.live else None
 def current(self,record):
  expected=next((r for r in [self.owner,*self.children.values()] if r['pid']==record['pid']),None)
  return record['pid'] in self.live and expected is not None and all(record[k]==expected[k] for k in ['pid','birth','executable'])
 def parent(self,pid):return 101
 def app_state(self):return [{**self.owner,'drain_supported':True}] if 101 in self.live else []
 def metadata(self,method):
  info=plistlib.loads((self.layout.targets['app']/'Contents/Info.plist').read_bytes())
  if method=='runtime.describe':return {'ready':True,'version':info['CFBundleShortVersionString'],'source_sha256':info['ARLCoreRuntimeSourceSHA256'],'features':{'app_sessions':1}}
  if method=='overview':return {'queue':{'available':True,'counts':{'running':0,'queued':0}}}
  raise AssertionError(method)
 def stop_service(self,label,expected=None):
  self.events.append('stop_'+label)
  if label==MIO:
   assert self.layout.state.joinpath('mio-apple/owned-child.json').exists()
  else:
   assert expected==self.owner
   self.live.clear();self.layout.state.joinpath('mio-apple/owned-child.json').unlink()
 def wait_owned_children(self,records,seconds=15):
  self.events.append('wait_children');assert {r['pid'] for r in records}=={102,103}
  super().wait_owned_children(records,seconds)
 def reminders_state(self):return {'schema_version':1,'instance':None,'admissions_sha256':None,'admissions_count':0,'pending':0}
 def quit_reminders(self,observed):
  assert 101 not in self.live
  self.events.append('reminders_drained')
 def quit_app(self,record):raise AssertionError('owner already drained; must not quit stale PID')

class InactiveGUIPlatform(FixturePlatform):
 def __init__(self,layout,host):super().__init__(layout,host);self.loaded=True
 def core_entry(self):return None,self.loaded
 def quit_app(self,record):
  assert record=={**self.owner,'drain_supported':True}
  self.events.append('quit_gui');self.live.clear();self.layout.state.joinpath('mio-apple/owned-child.json').unlink()
 def command(self,args,**kwargs):
  import subprocess
  if args[:2]==['/bin/launchctl','bootout']:
   self.events.append('unload_idle_core');self.loaded=False
   return subprocess.CompletedProcess(args,0,b'',b'')
  raise AssertionError(args)

class UnifiedUpdateTests(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory(prefix='arl-unified-update-');self.root=Path(self.temp.name).resolve();self.layout=Layout(self.root)
  self.package=self.root/'candidate.noindex/package';self.package.mkdir(parents=True)
  self.app=self.package/'ARL.app';self.old=self.layout.targets['app']
  def write(path,data):
   path.parent.mkdir(parents=True,exist_ok=True,mode=0o700);path.write_bytes(data);path.chmod(0o600)
  self.write=write;profile=self.root/'mio/profile.json';profile_raw=b'synthetic unchanged profile';write(profile,profile_raw)
  activation=encode({'schema':1,'profile':str(profile),'profile_sha256':sha(profile_raw)})
  for app,build,source in [(self.old,'66','old-source'),(self.app,'70','new-source')]:
   core=encode({'source_sha256':source,'store_version':4,'profile':'local-compatibility'})
   write(app/'Contents/Resources/CoreRuntime/manifest.json',core)
   info={'CFBundleIdentifier':'local.arl.control','CFBundleVersion':build,'CFBundleShortVersionString':'0.1.2','ARLCoreRuntimeManifestSHA256':sha(core),'ARLCoreRuntimeSourceSHA256':source}
   write(app/'Contents/Info.plist',plistlib.dumps(info));write(app/'Contents/MacOS/ARL',('main-'+build).encode())
   mio=app/'Contents/Library/LoginItems/ARLMioAppleBridge.app'
   write(mio/'Contents/Info.plist',plistlib.dumps({'CFBundleVersion':build,'ARLApprovedPolicySHA256':sha(activation)}))
   write(mio/'Contents/MacOS/ARLMioAppleBridge',('mio-'+build).encode())
   for rel in ['CredentialReadOwner/authority.json','MioRuntime/manifest.json']:write(mio/'Contents/Resources'/rel,b'stable synthetic identity')
   owner={'schema':2,'executionAllowed':True,'reviewID':'00000000-0000-4000-8000-000000000001',
          'owner':{'identifier':'local.arl.control','certificateSHA1':'A'*40},'mio':{'identifier':'local.arl.mioapplebridge','certificateSHA1':'B'*40},
          'capabilities':sorted(READ_OWNER_OLD if app==self.old else READ_OWNER_NEW)}
   owner_raw=encode(owner)
   for bundle in [app,mio]:
    write(bundle/'Contents/Resources/CredentialReadOwner/authority.json',owner_raw)
    info_path=bundle/'Contents/Info.plist';owner_info=plistlib.loads(info_path.read_bytes());owner_info['ARLCredentialReadOwnerAuthoritySHA256']=sha(owner_raw)
    write(info_path,plistlib.dumps(owner_info))
   helper=app/'Contents/Library/LoginItems/ARLRemindersBridge.app'
   for rel in ['Contents/Info.plist','Contents/MacOS/ARLRemindersBridge','Contents/_CodeSignature/CodeResources']:write(helper/rel,b'stable helper')
  old_info=plistlib.loads((self.old/'Contents/Info.plist').read_bytes())
  self.authority={'bundlePath':str(self.old),'designatedRequirement':'SYNTHETIC-STABLE-IDENTITY','executableSHA256':sha((self.old/'Contents/MacOS/ARL').read_bytes())}
  write(self.layout.targets['authority'],encode(self.authority));write(self.package/'ARL.authority.candidate.json',encode({**self.authority,'executableSHA256':sha((self.app/'Contents/MacOS/ARL').read_bytes())}))
  write(self.layout.targets['unified_marker'],encode({'schema_version':1,'enabled':1,'mio_enabled':1,'core_manifest_sha256':old_info['ARLCoreRuntimeManifestSHA256']}))
  write(self.layout.targets['installation'],encode({'version':'0.1.2','build':'66','source_sha256':'old-source','core_manifest_sha256':old_info['ARLCoreRuntimeManifestSHA256'],'authority_scope_preserved':True,'mio_scope_preserved':True,'store_schema_preserved':True}))
  write(self.layout.targets['core_agent'],plistlib.dumps({'Label':CORE,'ProgramArguments':[str(self.old/'Contents/MacOS/ARL'),'--background'],'RunAtLoad':True}))
  write(self.layout.targets['mio_activation'],activation)
  self.platform=FixturePlatform(self.layout,self.app/'Contents/MacOS/ARL')
  old_mio=self.old/'Contents/Library/LoginItems/ARLMioAppleBridge.app'
  write(self.layout.targets['mio_status'],encode({'helper_requirement':'SYNTHETIC-STABLE-MIO','helper_cdhash':self.platform.cdhash(old_mio),'helper_executable_sha256':sha((old_mio/'Contents/MacOS/ARLMioAppleBridge').read_bytes()),'grants':['unchanged']}))
  helper=self.old/'Contents/Library/LoginItems/ARLRemindersBridge.app';closure={rel:sha((helper/rel).read_bytes()) for rel in ['Contents/Info.plist','Contents/MacOS/ARLRemindersBridge','Contents/_CodeSignature/CodeResources']}
  write(self.layout.targets['reminders_closure'],encode(closure));write(self.layout.targets['reminders_control'],encode({'helper_requirement':'SYNTHETIC-STABLE-HELPER','helper_executable_sha256':closure['Contents/MacOS/ARLRemindersBridge'],'closure_sha256':sha(encode(closure)),'grants':['unchanged']}))
  write(self.layout.state/'owned-runtime.json',encode({'owner':self.platform.owner,'children':self.platform.children}));write(self.layout.state/'mio-apple/owned-child.json',encode({'synthetic':True}))
  write(self.package/'manifest.json',encode({'bundle_files':inventory(self.app)['files']}))
  with sqlite3.connect(self.layout.state/'state.sqlite') as db:db.execute('PRAGMA user_version=4')
 def tearDown(self):self.temp.cleanup()
 def reseal_capabilities(self,app,capabilities):
  for bundle in [app,app/'Contents/Library/LoginItems/ARLMioAppleBridge.app']:
   resource=bundle/'Contents/Resources/CredentialReadOwner/authority.json'
   value=json.loads(resource.read_bytes());value['capabilities']=list(capabilities);raw=encode(value);self.write(resource,raw)
   info_path=bundle/'Contents/Info.plist';info=plistlib.loads(info_path.read_bytes());info['ARLCredentialReadOwnerAuthoritySHA256']=sha(raw);self.write(info_path,plistlib.dumps(info))
 def test_product_transition_accepts_exact_90_seven_to_91_eight(self):
  self.reseal_capabilities(self.old,sorted(READ_OWNER_PRE_PRODUCT))
  result=reviewed_read_owner_transition(self.old,self.app)
  self.assertNotEqual(result['before_sha256'],result['after_sha256'])
 def test_product_transition_accepts_exact_eight_to_eight(self):
  self.reseal_capabilities(self.old,sorted(READ_OWNER_NEW))
  result=reviewed_read_owner_transition(self.old,self.app)
  self.assertEqual(result['before_sha256'],result['after_sha256'])
 def test_product_transition_rejects_unreviewed_extra_and_duplicate(self):
  for invalid in [sorted(READ_OWNER_NEW|{'unreviewed_exec'}),sorted(READ_OWNER_PRE_PRODUCT)+['apple_reminders_task']]:
   self.reseal_capabilities(self.app,invalid)
   with self.assertRaisesRegex(InstallFault,'read_owner_transition_invalid'):reviewed_read_owner_transition(self.old,self.app)
 def test_product_transition_rejects_rollback_to_seven(self):
  self.reseal_capabilities(self.old,sorted(READ_OWNER_NEW))
  self.reseal_capabilities(self.app,sorted(READ_OWNER_PRE_PRODUCT))
  with self.assertRaisesRegex(InstallFault,'read_owner_transition_invalid'):reviewed_read_owner_transition(self.old,self.app)
 def test_unified_prepare_keeps_scope_profile_and_originals(self):
  before={p:inventory(p) for p in [*self.layout.targets.values(),self.root/'mio/profile.json'] if p is not None}
  payloads,details=prepare_payloads(self.layout,self.platform,self.package)
  self.assertEqual(set(payloads),{'app','authority','core_agent','mio_status','reminders_control','reminders_closure','unified_marker','maintenance','installation'})
  self.assertEqual(payloads['core_agent'],self.layout.targets['core_agent'].read_bytes())
  self.assertEqual(json.loads(payloads['mio_status'])['grants'],['unchanged'])
  self.assertEqual(json.loads(payloads['reminders_control'])['grants'],['unchanged'])
  self.assertEqual(details['old_services'],{CORE:self.platform.owner,MIO:None});self.assertEqual(details['build'],'70')
  self.assertEqual(before,{p:inventory(p) for p in before})
 def test_changed_scope_policy_or_schema_rejected_before_stop(self):
  original=self.layout.targets['mio_activation'].read_bytes();self.write(self.layout.targets['mio_activation'],encode({'changed':True}))
  with self.assertRaisesRegex(InstallFault,'candidate_mio_policy_seal_mismatch'):prepare_payloads(self.layout,self.platform,self.package)
  self.write(self.layout.targets['mio_activation'],original)
  candidate=json.loads((self.package/'ARL.authority.candidate.json').read_bytes());candidate['designatedRequirement']='different identity';self.write(self.package/'ARL.authority.candidate.json',encode(candidate))
  with self.assertRaisesRegex(InstallFault,'install_authority_scope_changed'):prepare_payloads(self.layout,self.platform,self.package)
  candidate['designatedRequirement']=self.authority['designatedRequirement'];self.write(self.package/'ARL.authority.candidate.json',encode(candidate))
  with sqlite3.connect(self.layout.state/'state.sqlite') as db:db.execute('PRAGMA user_version=3')
  with self.assertRaisesRegex(InstallFault,'install_store_version_unsupported'):prepare_payloads(self.layout,self.platform,self.package)
  self.assertFalse(any(e.startswith('stop_') for e in self.platform.events))
 def test_unified_owner_stops_before_child_cleanup_check(self):
  _,details=prepare_payloads(self.layout,self.platform,self.package);self.platform.events=[]
  self.platform.quiesce_old({'details':details})
  self.assertEqual(self.platform.events,['stop_'+MIO,'stop_'+CORE,'wait_children','reminders_drained']);self.assertFalse(self.platform.live)
 def test_changed_child_identity_blocks_before_any_stop(self):
  _,details=prepare_payloads(self.layout,self.platform,self.package)
  receipt=json.loads((self.layout.state/'owned-runtime.json').read_bytes());receipt['children']['mio']['executable']='unowned';self.write(self.layout.state/'owned-runtime.json',encode(receipt));self.platform.events=[]
  with self.assertRaisesRegex(InstallFault,'install_child_path_mismatch'):self.platform.quiesce_old({'details':details})
  self.assertEqual(self.platform.events,[])
 def test_plan_readonly_profile_and_activation_drift_blocks_before_stop(self):
  payloads,details=prepare_payloads(self.layout,self.platform,self.package)
  self.assertEqual(set(details['readonly_preconditions']),{'mio_activation','mio_profile'})
  engine=Transaction(self.layout,self.platform);parameters=engine.prepare(payloads,details)
  folder,plan,_=engine.read(parameters['transaction'],parameters['plan_sha256'])
  self.platform.verify_plan(plan,folder)
  for key in ['mio_profile','mio_activation']:
   target=self.layout.targets[key];original=target.read_bytes();self.write(target,original+b' ');self.platform.events=[]
   with self.assertRaisesRegex(InstallFault,'install_readonly_preimage_changed'):
    engine.apply(parameters['transaction'],parameters['plan_sha256'])
   self.assertEqual(self.platform.events,[]);self.assertEqual(self.platform.live,{101,102,103})
   self.write(target,original)
  self.platform.verify_plan(plan,folder)
 def test_new_unexpected_mio_service_blocks_without_bootout_or_owner_stop(self):
  payloads,details=prepare_payloads(self.layout,self.platform,self.package)
  engine=Transaction(self.layout,self.platform);parameters=engine.prepare(payloads,details)
  folder,plan,_=engine.read(parameters['transaction'],parameters['plan_sha256'])
  self.platform.verify_plan(plan,folder)
  intruder={'pid':999,'birth':[77,88],'executable':'unowned-service'};original=self.platform.service
  with patch.object(self.platform,'service',side_effect=lambda label:intruder if label==MIO else original(label)),patch.object(self.platform,'command') as command,patch.object(self.platform,'stop_service',side_effect=lambda *args:MacPlatform.stop_service(self.platform,*args)) as stop:
   with self.assertRaisesRegex(InstallFault,'install_service_generation_changed'):self.platform.quiesce_old(plan)
   command.assert_not_called();stop.assert_called_once_with(MIO,None);self.assertEqual(self.platform.live,{101,102,103})
 def test_finite_transport_cutover_preserves_pair_and_rejects_extra_capability(self):
  transition=reviewed_read_owner_transition(self.old,self.app)
  self.assertNotEqual(transition['before_sha256'],transition['after_sha256'])
  nested=self.app/'Contents/Library/LoginItems/ARLMioAppleBridge.app'
  raw=json.loads((self.app/'Contents/Resources/CredentialReadOwner/authority.json').read_bytes());raw['capabilities'].append('arbitrary_write');raw=encode(raw)
  for bundle in [self.app,nested]:
   self.write(bundle/'Contents/Resources/CredentialReadOwner/authority.json',raw)
   path=bundle/'Contents/Info.plist';info=plistlib.loads(path.read_bytes());info['ARLCredentialReadOwnerAuthoritySHA256']=sha(raw);self.write(path,plistlib.dumps(info))
  with self.assertRaisesRegex(InstallFault,'read_owner_transition_invalid'):reviewed_read_owner_transition(self.old,self.app)
 def test_cutover_rejects_unpaired_bundle_resource(self):
  nested=self.app/'Contents/Library/LoginItems/ARLMioAppleBridge.app'
  raw=(self.old/'Contents/Resources/CredentialReadOwner/authority.json').read_bytes()
  self.write(nested/'Contents/Resources/CredentialReadOwner/authority.json',raw)
  path=nested/'Contents/Info.plist';info=plistlib.loads(path.read_bytes());info['ARLCredentialReadOwnerAuthoritySHA256']=sha(raw);self.write(path,plistlib.dumps(info))
  with self.assertRaisesRegex(InstallFault,'read_owner_transition_invalid|read_owner_pair_mismatch'):reviewed_read_owner_transition(self.old,self.app)
 def make_gui_platform(self):
  self.platform=InactiveGUIPlatform(self.layout,self.app/'Contents/MacOS/ARL')
  return self.platform
 def test_inactive_registered_entry_binds_real_signed_gui_and_children(self):
  platform=self.make_gui_platform();payloads,details=prepare_payloads(self.layout,platform,self.package)
  self.assertEqual(details['old_services'],{CORE:None,MIO:None})
  self.assertEqual(details['old_gui_owner'],platform.owner);self.assertTrue(details['old_core_job_inactive'])
  engine=Transaction(self.layout,platform);prepared=engine.prepare(payloads,details)
  folder,plan,_=engine.read(prepared['transaction'],prepared['plan_sha256']);platform.verify_plan(plan,folder)
  platform.events=[];platform.quiesce_old(plan)
  self.assertEqual(platform.events,['stop_'+MIO,'quit_gui','unload_idle_core','wait_children','reminders_drained'])
  self.assertFalse(platform.live);self.assertFalse(platform.loaded)
 def test_gui_or_job_generation_drift_blocks_before_quit(self):
  platform=self.make_gui_platform();payloads,details=prepare_payloads(self.layout,platform,self.package)
  engine=Transaction(self.layout,platform);prepared=engine.prepare(payloads,details);folder,plan,_=engine.read(prepared['transaction'])
  with patch.object(platform,'core_entry',return_value=(platform.owner,False)),patch.object(platform,'quit_app') as quit,self.assertRaisesRegex(InstallFault,'install_idle_entry_changed'):
   platform.verify_plan(plan,folder)
  quit.assert_not_called()
  with patch.object(platform,'verify_foreground_runtime',return_value={**platform.owner,'birth':[8,9]}),patch.object(platform,'quit_app') as quit,self.assertRaisesRegex(InstallFault,'install_app_generation_changed'):
   platform.verify_plan(plan,folder)
  quit.assert_not_called()
 def test_foreground_owner_receipt_and_child_identity_are_not_inferred(self):
  platform=self.make_gui_platform();receipt=json.loads((self.layout.state/'owned-runtime.json').read_bytes())
  receipt['children']['mio']['executable']='unowned';self.write(self.layout.state/'owned-runtime.json',encode(receipt))
  with self.assertRaisesRegex(InstallFault,'install_child_path_mismatch'):prepare_payloads(self.layout,platform,self.package)
  self.assertFalse(any(x.startswith('stop_') for x in platform.events))
 def test_gui_recovery_uses_one_unchanged_entry_without_extra_open(self):
  platform=self.make_gui_platform();_,details=prepare_payloads(self.layout,platform,self.package)
  platform.live.clear();plan={'details':details}
  with patch.object(platform,'command') as command:platform.restore_old(plan)
  command.assert_called_once_with(['/bin/launchctl','kickstart',platform.domain+'/'+CORE])
  platform.loaded=False
  with patch.object(platform,'bootstrap') as bootstrap,patch.object(platform,'command') as command:platform.restore_old(plan)
  bootstrap.assert_called_once();command.assert_not_called()
 def test_gui_recovery_refuses_foreign_core_or_mio_without_touching_jobs(self):
  platform=self.make_gui_platform();_,details=prepare_payloads(self.layout,platform,self.package);plan={'details':details}
  owner={**platform.owner,'pid':501,'birth':[50,1]}
  for conflict in ['core','mio']:
   foreign={**owner,'pid':999,'birth':[99,1]}
   with self.subTest(conflict=conflict),patch.object(platform,'verify_foreground_runtime',return_value=owner),patch.object(platform,'core_entry',return_value=(foreign,False) if conflict=='core' else (None,True)),patch.object(platform,'service',side_effect=lambda label:foreign if conflict=='mio' and label==MIO else None),patch.object(platform,'command') as command:
    code='install_old_owner_conflict' if conflict=='core' else 'install_old_service_conflict'
    with self.assertRaisesRegex(InstallFault,code):platform.restore_old(plan)
    with patch.object(platform,'metadata',return_value={'version':details['old_version']}),patch('arl.install_platform.time.monotonic',side_effect=[0,1,16]),patch('arl.install_platform.time.sleep'),self.assertRaisesRegex(InstallFault,'install_old_restore_unproven') as context:
     platform.verify_old(plan)
    self.assertEqual(context.exception.diagnostic['last_failure']['code'],code)
    command.assert_not_called()
 def test_gui_recovery_accepts_only_current_exact_owner_or_idle_entry(self):
  platform=self.make_gui_platform();_,details=prepare_payloads(self.layout,platform,self.package);plan={'details':details}
  owner={**platform.owner,'pid':501,'birth':[50,1]}
  for core,inactive in [(None,True),(owner,False)]:
   with patch.object(platform,'verify_foreground_runtime',return_value=owner),patch.object(platform,'core_entry',return_value=(core,inactive)),patch.object(platform,'service',return_value=None),patch.object(platform,'command') as command,patch.object(platform,'metadata',return_value={'version':details['old_version']}):
    platform.restore_old(plan);platform.verify_old(plan);command.assert_not_called()
  for field,value in [('pid',999),('birth',[9,9]),('executable','unowned')]:
   with self.subTest(field=field),patch.object(platform,'verify_foreground_runtime',return_value=owner),patch.object(platform,'core_entry',return_value=({**owner,field:value},False)),patch.object(platform,'service',return_value=None),patch.object(platform,'command') as command,self.assertRaisesRegex(InstallFault,'install_old_owner_conflict'):
    platform.restore_old(plan)
   command.assert_not_called()
if __name__=='__main__':unittest.main()
