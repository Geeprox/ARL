"""ARL-owned, current-user installation journal. No credentials or business data.

Only a prepared, hash-bound plan can mutate fixed targets. An interrupted plan
is reconciled from both filesystem inventories before rollback; unknown changes
are retained for review. Platform hooks own signed process/service verification.
"""
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
import plistlib
from pathlib import Path
import re
import shutil
import stat
import uuid
from .contracts import Fault

class InstallFault(Exception):
    def __init__(self, code, diagnostic=None):
        self.code=code;self.diagnostic=diagnostic or {};super().__init__(code)

def failure(error, phase, fallback):
    """Closed diagnostic projection: never exception text, argv, paths or env."""
    code=error.code if isinstance(error,(InstallFault,Fault)) else fallback
    if type(code) is not str or not re.fullmatch(r'[a-z][a-z0-9_]{0,95}',code):code=fallback
    result={'phase':phase,'code':code,'type':type(error).__name__}
    if isinstance(error,OSError) and type(error.errno) is int:result['errno']=error.errno
    if isinstance(error,InstallFault):
        for key in ('command','cause_type','returncode','timeout_seconds','last_failure'):
            if key in error.diagnostic:result[key]=error.diagnostic[key]
    return result

def require(condition, code):
    if not condition: raise InstallFault(code)

def sha(raw): return hashlib.sha256(raw).hexdigest()
def encode(value):return (json.dumps(value,sort_keys=True,indent=2)+'\n').encode()
def unique(pairs):
    result={}
    for key,value in pairs:
        require(key not in result,'duplicate_install_metadata');result[key]=value
    return result

def no_links(path):
    for p in (path,*path.parents):require(not p.is_symlink(),'install_symlink')

def private_file(path,limit=1024*1024):
    no_links(path);s=path.stat()
    require(stat.S_ISREG(s.st_mode) and s.st_uid==os.geteuid() and s.st_nlink==1 and not s.st_mode&0o077 and s.st_size<=limit,'unsafe_install_metadata')
    return path.read_bytes()

PLAN_LIMIT=8*1024*1024

def load(path,limit=1024*1024):return json.loads(private_file(path,limit),object_pairs_hook=unique)
def fsync_dir(path):
    fd=os.open(path,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
    try:os.fsync(fd)
    finally:os.close(fd)

def atomic(path,raw):
    no_links(path);require(path.parent.is_dir(),'install_parent_missing')
    temp=path.parent/('.'+path.name+'.'+uuid.uuid4().hex)
    fd=os.open(temp,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    try:
        with os.fdopen(fd,'wb') as stream:stream.write(raw);stream.flush();os.fsync(stream.fileno())
        os.replace(temp,path);fsync_dir(path.parent)
    finally:
        if temp.exists():temp.unlink()

def inventory(path, *, legacy_nas=None):
    no_links(path)
    if not path.exists():return None
    if path.is_file():
        s=path.stat();require(s.st_uid==os.geteuid() and s.st_nlink==1 and not s.st_mode&0o022,'unsafe_install_target')
        return {'kind':'file','sha256':sha(path.read_bytes()),'mode':stat.S_IMODE(s.st_mode)}
    require(path.is_dir(),'invalid_install_target')
    root_stat=path.stat();require(root_stat.st_uid==os.geteuid() and not root_stat.st_mode&0o022,'unsafe_install_bundle')
    rows={}
    for p in sorted(path.rglob('*')):
        no_links(p);s=p.stat()
        require(s.st_uid==os.geteuid() and (stat.S_ISDIR(s.st_mode) or stat.S_ISREG(s.st_mode)),'unsafe_install_bundle')
        rel=str(p.relative_to(path));mode=stat.S_IMODE(s.st_mode)
        if p.is_file():
            require(s.st_nlink==1,'unsafe_install_bundle')
            row={'sha256':sha(p.read_bytes()),'mode':mode}
            if s.st_mode&0o022:
                # Read/rename only: exact signed legacy NAS files, never a new
                # executable payload. Default inventory remains strict.
                require(legacy_nas is not None and rel.startswith('Contents/Resources/NASRuntime/python/') and mode in (0o664,0o775) and legacy_nas.get(rel)==row,'unsafe_install_bundle')
            rows[rel]=row
        else:require(not s.st_mode&0o022,'unsafe_install_bundle')
    return {'kind':'bundle','files':rows}

def digest(value):return sha(encode(value))

class Layout:
    """No target path is accepted from plan/RPC. Account is fixed by host or marked tests."""
    def __init__(self,account):
        self.account=Path(account).absolute();no_links(self.account)
        self.state=self.account/'Library/Application Support/ARL'
        self.legacy_root=self.state/'runtime/unified-migrations'
        self.noindex_root=self.state/'runtime/unified-migrations.noindex'
        self.lock_path=self.legacy_root/'lock'
        # The first update must remain readable by the currently installed old
        # management CLI. Once the new signed layout marker is installed, all
        # subsequent snapshots are created beneath the noindex directory.
        info=self.account/'Applications/ARL.app/Contents/Info.plist'
        version=2
        if info.is_file():
            no_links(info)
            try:version=plistlib.loads(info.read_bytes()).get('ARLInstallSnapshotLayout',1)
            except (ValueError,TypeError,plistlib.InvalidFileException):raise InstallFault('invalid_snapshot_layout') from None
            require(type(version) is int and version in {1,2},'unsupported_snapshot_layout')
        self.root=self.noindex_root if version==2 else self.legacy_root
        self.targets={
          'app':self.account/'Applications/ARL.app',
          'legacy_mio_app':self.account/'Applications/ARLMioAppleBridge.app',
          'legacy_entry':self.state/'runtime/run_host.py',
          'legacy_manager':self.state/'runtime/manage.py',
          'installation':self.state/'unified-installation.json',
          'authority':self.account/'Applications/ARL.authority.json',
          'core_agent':self.account/'Library/LaunchAgents/local.arl.runtime.plist',
          'mio_agent':self.account/'Library/LaunchAgents/com.mio.readonly-travel-tunnel.plist',
          'mio_activation':self.state/'mio-apple/activation.json',
          'mio_profile':None, # Set only from the existing sealed activation by prepare builder.
          'mio_status':self.state/'mio-apple/status-consumer.json',
          'reminders_control':self.state/'reminders-v3/control.json',
          'reminders_closure':self.state/'reminders-v3/closure.json',
          'unified_marker':self.state/'unified-runtime.json',
          'codex_scope':self.state/'codex-service-v1.json',
          'maintenance':self.state/'install-maintenance.json'}
    def bind_profile(self,path):
        path=Path(path).absolute();no_links(path)
        require(self.account in path.parents,'unowned_mio_profile')
        self.targets['mio_profile']=path
    def folder(self,identifier):
        require(type(identifier) is str and str(uuid.UUID(identifier))==identifier,'invalid_transaction_id')
        candidates=[self.noindex_root/identifier,self.legacy_root/identifier]
        existing=[p for p in candidates if p.exists()]
        require(len(existing)<=1,'ambiguous_install_transaction')
        return existing[0] if existing else self.root/identifier

class Transaction:
    def __init__(self,layout,platform):self.layout,self.platform=layout,platform
    @contextmanager
    def lock(self):
        for root in {self.layout.root,self.layout.legacy_root}:
            no_links(root);root.mkdir(parents=True,exist_ok=True,mode=0o700)
        for p in [self.layout.state,self.layout.root,self.layout.legacy_root]:
            s=p.stat();require(s.st_uid==os.geteuid() and not s.st_mode&0o077,'unsafe_install_state')
        fd=os.open(self.layout.lock_path,os.O_RDWR|os.O_CREAT|os.O_NOFOLLOW,0o600)
        try:
            require(os.fstat(fd).st_uid==os.geteuid() and os.fstat(fd).st_nlink==1,'unsafe_install_lock')
            try:fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
            except BlockingIOError:raise InstallFault('install_busy')
            yield
        finally:os.close(fd)
    def save(self,folder,journal):atomic(folder/'journal.json',encode(journal))
    def original_inventory(self,key,path,details):
        allowed=details.get('legacy_nas_preimage') if key=='app' else None
        return inventory(path,legacy_nas=allowed)
    def prepare(self,payloads,details):
        """Payload builder already verifies signatures, scope and original owned layout."""
        with self.lock():
            require('app' in payloads and 'core_agent' in payloads,'incomplete_install_plan')
            require(set(payloads)<=set(self.layout.targets),'invalid_install_target')
            identifier=str(uuid.uuid4());folder=self.layout.folder(identifier)
            folder.mkdir(mode=0o700);(folder/'before').mkdir(mode=0o700);(folder/'after').mkdir(mode=0o700)
            changes={}
            for key,payload in payloads.items():
                target=self.layout.targets[key];require(target is not None,'unbound_install_target')
                before=self.original_inventory(key,target,details)
                stage=folder/'after'/key
                if payload is None:after=None
                elif key=='app':
                    shutil.copytree(payload,stage,symlinks=False);after=inventory(stage)
                else:
                    atomic(stage,payload);after=inventory(stage)
                changes[key]={'before':before,'after':after}
            # Maintenance is explicit, owned metadata, not an inferred idle state.
            require('maintenance' in changes and changes['maintenance']['before'] is None,'maintenance_already_active')
            plan={'schema':2,'id':identifier,'changes':changes,'details':details,'profile_path':str(self.layout.targets['mio_profile']) if self.layout.targets['mio_profile'] else None}
            require(len(encode(plan))<=PLAN_LIMIT,'install_plan_limit')
            atomic(folder/'plan.json',encode(plan));self.save(folder,{'schema':2,'id':identifier,'phase':'prepared','operations':[],'result':'pending','error':None})
            return {'transaction':identifier,'plan_sha256':sha(encode(plan)),'phase':'prepared','production_changed':False}
    def read(self,identifier,expected=None):
        folder=self.layout.folder(identifier);plan=load(folder/'plan.json',limit=PLAN_LIMIT);journal=load(folder/'journal.json')
        require(plan['schema']==journal['schema'] and type(plan['schema']) is int and type(journal['schema']) is int and plan['schema'] in (1,2) and plan['id']==journal['id']==identifier,'invalid_install_journal')
        require(set(plan['changes'])<=set(self.layout.targets) and 'app' in plan['changes'],'invalid_install_targets')
        if plan.get('profile_path'):self.layout.bind_profile(plan['profile_path'])
        require(expected is None or sha(encode(plan))==expected,'unreviewed_install_plan')
        return folder,plan,journal
    def checkpoint(self,folder,journal,phase):
        journal['phase']=phase;self.save(folder,journal);self.platform.checkpoint(phase)
    def apply_one(self,folder,key,change,journal,details):
        self.checkpoint(folder,journal,'publish_'+key)
        target=self.layout.targets[key];stage=folder/'after'/key;backup=folder/'before'/key
        require(self.original_inventory(key,target,details)==change['before'],'install_preimage_changed')
        require(inventory(stage)==change['after'],'install_payload_changed')
        journal['operations'].append({'target':key,'state':'intending'});self.save(folder,journal)
        require(target.parent.stat().st_dev==folder.stat().st_dev,'install_cross_device')
        if change['before'] is not None:
            require(not backup.exists(),'install_backup_exists');os.rename(target,backup);fsync_dir(target.parent);fsync_dir(backup.parent)
        self.checkpoint(folder,journal,'after_backup_'+key)
        if change['after'] is not None:os.rename(stage,target);fsync_dir(target.parent)
        self.checkpoint(folder,journal,'after_publish_'+key)
        journal['operations'][-1]['state']='published';self.save(folder,journal)
    def reconcile_restore(self,folder,key,change,details):
        target=self.layout.targets[key];backup=folder/'before'/key;after=folder/'after'/key
        now=self.original_inventory(key,target,details);saved=self.original_inventory(key,backup,details)
        if now==change['before'] and saved is None:return
        require(saved==change['before'] and now in (None,change['after']),'install_restore_conflict')
        if now is not None:
            require(not after.exists(),'install_restore_payload_conflict');os.rename(target,after);fsync_dir(target.parent)
        if saved is not None:os.rename(backup,target);fsync_dir(target.parent);fsync_dir(backup.parent)
        require(self.original_inventory(key,target,details)==change['before'],'install_restore_unproven')
    def rollback_locked(self,folder,plan,journal):
        self.checkpoint(folder,journal,'rollback_quiesce')
        self.platform.quiesce_new(plan)
        for operation in reversed(journal['operations']):
            self.checkpoint(folder,journal,'rollback_restore_'+operation['target'])
            self.reconcile_restore(folder,operation['target'],plan['changes'][operation['target']],plan['details'])
        self.checkpoint(folder,journal,'restore_old');self.platform.restore_old(plan)
        self.checkpoint(folder,journal,'verify_old');self.platform.verify_old(plan)
        journal.update(phase='rolled_back',result='restored',error=None);self.save(folder,journal)
        return {'transaction':plan['id'],'phase':'rolled_back','result':'restored','credentials_or_business_data_modified':False}
    def apply(self,identifier,expected):
        with self.lock():
            folder,plan,journal=self.read(identifier,expected)
            if hasattr(self.platform,'record_worker'):self.platform.record_worker(folder)
            if journal['phase']=='committed':return {'transaction':identifier,'phase':'committed','result':'already_applied'}
            require(journal['phase']=='prepared','install_requires_recovery')
            for key,change in plan['changes'].items():require(self.original_inventory(key,self.layout.targets[key],plan['details'])==change['before'],'install_preimage_changed')
            self.platform.verify_plan(plan,folder)
            try:
                self.checkpoint(folder,journal,'quiesce_old');self.platform.quiesce_old(plan)
                self.checkpoint(folder,journal,'publish_maintenance')
                self.apply_one(folder,'maintenance',plan['changes']['maintenance'],journal,plan['details'])
                for key,change in plan['changes'].items():
                    if key!='maintenance':self.apply_one(folder,key,change,journal,plan['details'])
                self.checkpoint(folder,journal,'start_maintenance');self.platform.start_maintenance(plan)
                self.checkpoint(folder,journal,'verify_maintenance');self.platform.verify_new(plan,maintenance=True)
                self.checkpoint(folder,journal,'stop_maintenance');self.platform.quiesce_new(plan)
                # The business admission boundary is durable BEFORE maintenance
                # removal. Recovery beyond here must first prove new work idle.
                self.checkpoint(folder,journal,'activate_final')
                marker=self.layout.targets['maintenance'];require(inventory(marker)==plan['changes']['maintenance']['after'],'maintenance_marker_changed')
                os.rename(marker,folder/'maintenance.retained');fsync_dir(marker.parent)
                self.checkpoint(folder,journal,'start_final');self.platform.start_final(plan)
                self.checkpoint(folder,journal,'verify_final');self.platform.verify_new(plan,maintenance=False)
                journal.update(phase='committed',result='applied');self.save(folder,journal)
                return {'transaction':identifier,'phase':'committed','result':'applied','credentials_or_business_data_modified':False}
            except Exception as error:
                current_failure=failure(error,journal['phase'],'install_step_failed')
                journal.setdefault('apply_failure',current_failure);journal['latest_apply_failure']=current_failure
                journal['error']=current_failure['code'];self.save(folder,journal)
                if isinstance(error,InstallFault) and error.code=='install_parent_exited':
                    journal.update(phase='needs_attention',result='paused');self.save(folder,journal)
                    raise error
                try:
                    self.checkpoint(folder,journal,'rollback_check_idle')
                    if inventory(self.layout.targets['maintenance']) is None and (folder/'maintenance.retained').exists():
                        self.platform.assert_new_idle(plan)
                        os.rename(folder/'maintenance.retained',self.layout.targets['maintenance']);fsync_dir(self.layout.state)
                    return self.rollback_locked(folder,plan,journal)
                except Exception as recovery:
                    current_failure=failure(recovery,journal['phase'],'install_recovery_unproven')
                    journal.setdefault('recovery_failure',current_failure);journal['latest_recovery_failure']=current_failure
                    journal.update(phase='needs_attention',result='paused',error=current_failure['code']);self.save(folder,journal)
                    raise InstallFault(journal['error']) from None
    def rollback(self,identifier):
        with self.lock():
            folder,plan,journal=self.read(identifier)
            if hasattr(self.platform,'record_worker'):self.platform.record_worker(folder)
            if journal['phase']=='rolled_back':return {'transaction':identifier,'phase':'rolled_back','result':'already_restored'}
            try:
                self.checkpoint(folder,journal,'rollback_check_idle');self.platform.assert_new_idle(plan)
                if inventory(self.layout.targets['maintenance']) is None and (folder/'maintenance.retained').exists():
                    os.rename(folder/'maintenance.retained',self.layout.targets['maintenance']);fsync_dir(self.layout.state)
                return self.rollback_locked(folder,plan,journal)
            except Exception as error:
                current_failure=failure(error,journal['phase'],'install_restore_unproven')
                journal.setdefault('recovery_failure',current_failure);journal['latest_recovery_failure']=current_failure
                journal.update(phase='needs_attention',result='paused',error=current_failure['code']);self.save(folder,journal)
                raise InstallFault(journal['error']) from None
