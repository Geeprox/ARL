"""Bounded macOS platform for the ARL app-owned installation transaction.
No shell, global process enumeration, account creation, key lookup or TCC reset.
"""
import ctypes
import base64
import uuid
import json
import os
from pathlib import Path
import plistlib
import re
import socket
import stat
import sqlite3
import subprocess
import time
import fcntl
from .install_transaction import (InstallFault,Layout,Transaction,require,sha,encode,inventory,private_file,load,atomic,unique,no_links,failure)
from .identity import process_identity, BSDInfo
from .contracts import Fault

CORE='local.arl.runtime'
MIO='com.mio.readonly-travel-tunnel'
_UNSPECIFIED_SERVICE=object()

class MacPlatform:
    def __init__(self,layout,host,management_parent=None):
        self.layout=layout;self.host=Path(host).absolute();self.domain=f'gui/{os.geteuid()}'
        self.management_parent=process_identity(management_parent) if management_parent else None
        self.management_parent_pid=management_parent
    def command(self,args,seconds=20,allowed=(0,)):
        self.checkpoint('command');args=list(map(str,args));category='other'
        if args[0]=='/bin/launchctl' and args[1] in {'print','bootout','bootstrap'}:category='launchctl_'+args[1]
        elif args[0]=='/usr/bin/codesign':category='code_signature'
        elif args[0]=='/usr/bin/open':category='open_app'
        elif args[0]==str(self.host):category={'--internal-app-state':'app_state','--internal-app-quit':'app_quit','--internal-reminders-state':'reminders_state','--internal-reminders-quit':'reminders_quit'}.get(args[1],'app_internal')
        try:
            result=subprocess.run(args,stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=seconds,env={'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','HOME':str(self.layout.account),'LANG':'C'})
        except subprocess.TimeoutExpired:
            raise InstallFault('install_platform_command_timeout',{'command':category,'cause_type':'TimeoutExpired','timeout_seconds':seconds}) from None
        except OSError as error:
            # errno is numeric; the original message may include private paths.
            raise InstallFault('install_platform_command_unavailable',{'command':category,'last_failure':failure(error,'command','install_platform_command_unavailable')}) from None
        if result.returncode not in allowed:
            raise InstallFault('install_platform_command_failed',{'command':category,'returncode':result.returncode})
        return result
    def checkpoint(self,phase):
        if self.management_parent:
            try:live=process_identity(self.management_parent_pid)==self.management_parent
            except (OSError,Fault):live=False
            require(live,'install_parent_exited')
    def record_worker(self,folder):
        if not self.management_parent:return
        self.checkpoint('worker_start')
        atomic(folder/'worker.json',encode({'schema':1,'owner':{'pid':self.management_parent_pid,**self.management_parent},'worker':{'pid':os.getpid(),**process_identity(os.getpid())}}))
    def management_quiet(self,folder,owner,seconds=15,required_worker=False):
        deadline=time.monotonic()+seconds
        while time.monotonic()<deadline:
            receipt=folder/'worker.json'
            if receipt.exists():
                value=load(receipt);require(value.get('schema')==1 and value.get('owner')==owner,'install_worker_generation_unproven')
                if self.current(value['worker']):time.sleep(.05);continue
            elif required_worker:
                time.sleep(.05);continue
            lock=self.layout.lock_path;no_links(lock)
            fd=os.open(lock,os.O_RDWR|os.O_NOFOLLOW)
            try:
                try:fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
                except BlockingIOError:time.sleep(.05);continue
                return
            finally:os.close(fd)
        raise InstallFault('install_worker_cleanup_unproven')
    def management(self,identifier,action,plan_sha256=None,seconds=180):
        require(action in {'apply','rollback'},'invalid_install_action')
        folder=self.layout.folder(identifier);load(folder/'journal.json')
        args=[str(self.host),'--manage',action,'--transaction',identifier]
        if action=='apply':
            require(type(plan_sha256) is str and re.fullmatch(r'[a-f0-9]{64}',plan_sha256),'reviewed_plan_digest_required')
            args+=['--plan-sha256',plan_sha256]
        child=subprocess.Popen(args,stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        try:
            owner={'pid':child.pid,**process_identity(child.pid)};owner['birth']=list(owner['birth'])
        except (Fault,OSError):
            child.terminate()
            try:child.communicate(timeout=5)
            except subprocess.TimeoutExpired:raise InstallFault('install_management_stop_unproven') from None
            raise InstallFault('install_worker_generation_unproven') from None
        try:
            raw,_=child.communicate(timeout=seconds)
        except (subprocess.TimeoutExpired,KeyboardInterrupt) as interruption:
            child.terminate()
            try:child.communicate(timeout=5)
            except subprocess.TimeoutExpired:raise InstallFault('install_management_stop_unproven') from None
            self.management_quiet(folder,owner,required_worker=True)
            raise InstallFault('install_management_interrupted_drained' if isinstance(interruption,KeyboardInterrupt) else 'install_management_timeout_drained') from None
        self.management_quiet(folder,owner)
        require(len(raw)<=65536,'invalid_management_response')
        return child.returncode,json.loads(raw)

    def signature(self,app,rule):
        self.command(['/usr/bin/codesign','--verify','--deep','--strict','-R','='+rule,app])
    def cdhash(self,app):
        r=self.command(['/usr/bin/codesign','-d','--verbose=4',app])
        match=re.search(rb'^CDHash=([a-f0-9]{40})$',r.stderr,re.M)
        require(match is not None,'install_cdhash_unavailable');return match[1].decode()
    def service(self,label):
        require(label in {CORE,MIO},'unowned_install_service')
        r=self.command(['/bin/launchctl','print',self.domain+'/'+label],allowed=(0,113))
        if r.returncode!=0:return None
        match=re.search(rb'^\s*pid = ([0-9]+)\s*$',r.stdout,re.M)
        require(match is not None,'install_service_not_running')
        pid=int(match[1]);identity=process_identity(pid)
        require(identity['uid']==os.geteuid(),'install_service_owner_changed')
        return {'pid':pid,'birth':list(identity['birth']),'executable':identity['executable']}
    def core_entry(self):
        """Distinguish a registered idle job from its independently opened GUI."""
        try:return self.service(CORE),False
        except InstallFault as error:
            if error.code!='install_service_not_running':raise
        r=self.command(['/bin/launchctl','print',self.domain+'/'+CORE],allowed=(0,113))
        program=re.search(rb'^\s*program = (.+)\s*$',r.stdout,re.M)
        require(r.returncode==0 and re.search(rb'^\s*pid = ',r.stdout,re.M) is None
                and re.search(rb'^\s*state = not running\s*$',r.stdout,re.M) is not None
                and program is not None and program.group(1).decode().strip()==str(self.layout.targets['app']/'Contents/MacOS/ARL'),'install_idle_entry_changed')
        return None,True
    def verify_foreground_runtime(self,expected):
        apps=self.app_state()
        require(len(apps)==1 and apps[0].get('drain_supported') is True,'install_gui_owner_unverified')
        owner={key:apps[0][key] for key in ('pid','birth','executable')}
        require(owner['executable']==str(self.layout.targets['app']/'Contents/MacOS/ARL') and self.current(owner),'install_gui_owner_unverified')
        receipt=load(self.layout.state/'owned-runtime.json')
        require(receipt.get('owner')==owner,'install_owner_receipt_mismatch')
        for role,relative in [('core','Contents/Resources/NASRuntime/python/bin/python3.12'),('mio','Contents/Library/LoginItems/ARLMioAppleBridge.app/Contents/MacOS/ARLMioAppleBridge')]:
            record=receipt.get('children',{}).get(role)
            require(record and self.current(record) and record['executable']==str(self.layout.targets['app']/relative) and self.parent(record['pid'])==owner['pid'],'install_child_path_mismatch')
        data=self.metadata('runtime.describe')
        require(data.get('ready') is True and data.get('version')==expected['version'] and data.get('source_sha256')==expected['source_sha256'] and data.get('features',{}).get('app_sessions')==1,'install_runtime_generation_mismatch')
        return owner
    def unload_idle_core(self):
        require(self.core_entry()==(None,True),'install_idle_entry_changed')
        self.command(['/bin/launchctl','bootout',self.domain+'/'+CORE])
        deadline=time.monotonic()+5
        while time.monotonic()<deadline:
            current,inactive=self.core_entry()
            require(current is None,'install_service_generation_changed')
            if not inactive:return
            time.sleep(.05)
        raise InstallFault('install_service_drain_unproven')
    def parent(self,pid):
        library=ctypes.CDLL('/usr/lib/libproc.dylib',use_errno=True)
        info=BSDInfo();library.proc_pidinfo.argtypes=[ctypes.c_int,ctypes.c_int,ctypes.c_uint64,ctypes.c_void_p,ctypes.c_int]
        require(library.proc_pidinfo(pid,3,0,ctypes.byref(info),ctypes.sizeof(info))==ctypes.sizeof(info),'install_process_unverified')
        return info.ppid
    def current(self,record):
        try:
            actual=process_identity(record['pid'])
            return actual['uid']==os.geteuid() and list(actual['birth'])==record['birth'] and actual['executable']==record['executable']
        except Exception:return False
    def stop_service(self,label,expected=_UNSPECIFIED_SERVICE):
        current=self.service(label)
        # Explicit None is an expected absence, not permission to stop a new owner.
        if expected is not _UNSPECIFIED_SERVICE:require(current==expected,'install_service_generation_changed')
        if current is None:return
        if label==CORE and current.get('executable')==str(self.layout.targets['app']/'Contents/MacOS/ARL'):
            # Normal App termination drains SDK work and removes its own read
            # socket. bootout alone sends SIGTERM and bypasses that lifecycle.
            self.quit_app({**current,'drain_supported':True})
            deadline=time.monotonic()+40
            while time.monotonic()<deadline:
                try:
                    require(self.service(label) is None,'install_service_generation_changed')
                    break
                except InstallFault as error:
                    if error.code=='install_service_not_running':break # Original loaded job, no running PID.
                    raise
                except Fault as error:
                    if error.code!='peer_identity_unavailable':raise
                time.sleep(.05)
            else:raise InstallFault('install_service_drain_unproven')
        self.command(['/bin/launchctl','bootout',self.domain+'/'+label],seconds=60,allowed=(0,113))
        deadline=time.monotonic()+40
        while time.monotonic()<deadline:
            if not self.current(current):
                try:
                    if self.service(label) is None:return
                except Fault as error:
                    # launchd can briefly retain a PID after its process exits.
                    # An unavailable identity is pending, never proof of absence.
                    if error.code!='peer_identity_unavailable':raise
            time.sleep(.05)
        raise InstallFault('install_service_drain_unproven')
    def bootstrap(self):
        self.command(['/bin/launchctl','bootstrap',self.domain,self.layout.targets['core_agent']])
    def app_state(self):
        r=self.command([self.host,'--internal-app-state'],seconds=10,allowed=(0,2))
        data=json.loads(r.stdout)
        if r.returncode!=0:
            code=data.get('error')
            raise InstallFault(code if type(code) is str and re.fullmatch(r'install_[a-z_]+',code) else 'install_app_state_failed')
        require(set(data)=={'schema_version','instances'} and data['schema_version']==1,'install_app_state_invalid')
        return data['instances']
    def quit_app(self,record):
        require(record.get('drain_supported') is True,'legacy_app_drain_unsupported')
        require(self.current(record),'install_app_generation_changed')
        r=self.command([self.host,'--internal-app-quit',str(record['pid']),str(record['birth'][0]),str(record['birth'][1])],seconds=45)
        require(json.loads(r.stdout).get('terminated') is True and not self.current(record),'install_app_drain_unproven')
    def reminders_image_path(self,value):
        if type(value) is not str:return False
        suffix='Contents/Library/LoginItems/ARLRemindersBridge.app/Contents/MacOS/ARLRemindersBridge'
        if value==str(self.layout.targets['app']/suffix):return True
        # The signed native inspector additionally verifies the exact retained
        # file hash/mode against its private terminal transaction plan.
        for root in (self.layout.legacy_root,self.layout.noindex_root):
            prefix=str(root)+'/'
            if value.startswith(prefix):
                relative=value[len(prefix):]
                return re.fullmatch('[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}/(before|after)/app/'+re.escape(suffix),relative) is not None
        return False
    def reminders_state(self):
        r=self.command([self.host,'--internal-reminders-state'],seconds=15)
        value=json.loads(r.stdout)
        require(set(value)=={'schema_version','instance','admissions_sha256','admissions_count','pending'} and type(value['schema_version']) is int and value['schema_version']==1,'install_reminders_state_invalid')
        require(type(value['pending']) is int and value['pending']==0 and type(value['admissions_count']) is int and 0<=value['admissions_count']<=512,'install_reminders_work_active')
        record=value['instance']
        if record is None:
            require(value['admissions_sha256'] is None and value['admissions_count']==0,'install_reminders_state_invalid')
        else:
            require(type(record) is dict and set(record)=={'pid','birth','executable'} and type(record['pid']) is int and record['pid']>1 and type(record['birth']) is list and len(record['birth'])==2 and all(type(x) is int and x>=0 for x in record['birth']) and self.reminders_image_path(record['executable']) and type(value['admissions_sha256']) is str and re.fullmatch('[a-f0-9]{64}',value['admissions_sha256']),'install_reminders_state_invalid')
        return value
    def quit_reminders(self,observed):
        record=observed['instance']
        if record is not None:
            r=self.command([self.host,'--internal-reminders-quit',str(record['pid']),str(record['birth'][0]),str(record['birth'][1]),observed['admissions_sha256']],seconds=20)
            require(json.loads(r.stdout).get('terminated') is True,'install_reminders_exit_unproven')
        require(self.reminders_state()['instance'] is None,'install_reminders_restarted')
    def metadata(self,method):
        frame=encode({'protocol':'arl/1','app':'settings','method':method,'params':{}}).replace(b'\n',b'')+b'\n'
        with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as connection:
            connection.settimeout(3);connection.connect(str(self.layout.state/'runtime.sock'));connection.sendall(frame)
            with connection.makefile('rb') as stream:raw=stream.readline(131073)
        require(len(raw)<=131072 and raw.endswith(b'\n'),'invalid_install_runtime_response')
        value=json.loads(raw);require(value.get('protocol')=='arl/1' and value.get('ok') is True,'install_runtime_not_ready')
        return value['result']
    def idle(self):
        data=self.metadata('overview');queue=data.get('queue',{})
        require(queue.get('available') is True,'install_queue_unavailable')
        counts=queue.get('counts',{})
        require(type(counts.get('running')) is int and type(counts.get('queued')) is int and counts['running']==counts['queued']==0,'active_work_requires_drain')
    def verify_readonly_preconditions(self,plan):
        expected=plan['details'].get('readonly_preconditions',{})
        owner=plan['details']['old_services'].get(CORE)
        unified=bool(plan['details'].get('old_gui_owner')) or owner and owner['executable']==str(self.layout.targets['app']/'Contents/MacOS/ARL')
        require(type(expected) is dict and (set(expected)=={'mio_activation','mio_profile'} if unified else not expected),'invalid_readonly_install_preconditions')
        for key,pin in expected.items():
            require(type(pin) is str and re.fullmatch(r'[a-f0-9]{64}',pin) and self.layout.targets[key] is not None,'invalid_readonly_install_preconditions')
            require(sha(private_file(self.layout.targets[key]))==pin,'install_readonly_preimage_changed')
    def verify_plan(self,plan,folder):
        if 'codex_scope_before_sha256' in plan['details']:
            path = self.layout.targets['codex_scope']
            observed = sha(private_file(path, 4096)) if path.exists() else None
            require(observed == plan['details']['codex_scope_before_sha256'], 'codex_scope_preimage_changed')
        if 'read_owner_transition' in plan['details']:
            require(reviewed_read_owner_transition(self.layout.targets['app'], folder/'after/app') == plan['details']['read_owner_transition'], 'read_owner_transition_changed')
        self.verify_readonly_preconditions(plan)
        # Re-check candidate signature and code-only authority against retained
        # preimages, never against a scope-changing proposal.
        changes=plan['changes'];app=folder/'after/app'
        old=json.loads(private_file(self.layout.targets['authority']))
        new=json.loads(private_file(folder/'after/authority'))
        require(set(old)==set(new) and all(new[k]==old[k] for k in old if k!='executableSHA256'),'install_authority_scope_changed')
        require(sha((app/'Contents/MacOS/ARL').read_bytes())==new['executableSHA256'],'install_candidate_code_changed')
        self.signature(app,old['designatedRequirement'])
        self.signature(self.layout.targets['app'],old['designatedRequirement'])
        if plan['details'].get('legacy_nas_preimage'):
            require(legacy_nas_preimage(self.layout.targets['app'])==plan['details']['legacy_nas_preimage'],'legacy_nas_preimage_changed')
        self.idle()
        current=self.app_state()
        require(all(x.get('drain_supported') is True for x in current),'legacy_app_drain_unsupported')
        require(current==plan['details']['old_apps'],'install_app_generation_changed')
        for label,record in plan['details']['old_services'].items():
            if label==CORE and plan['details'].get('old_gui_owner'):
                require(record is None and plan['details'].get('old_core_job_inactive') is True and self.core_entry()==(None,True),'install_idle_entry_changed')
                owner=self.verify_foreground_runtime({'version':plan['details']['old_version'],'source_sha256':plan['details']['old_source_sha256']})
                require(owner==plan['details']['old_gui_owner'],'install_app_generation_changed')
            else:require(self.service(label)==record,'install_service_generation_changed')
    def quiesce_old(self,plan):
        self.idle()
        reminders=self.reminders_state()
        self.verify_readonly_preconditions(plan)
        # Legacy Mio has its own service; unified Mio is a child of ARL.
        services=plan['details']['old_services'];children=[]
        owner=services.get(CORE) or plan['details'].get('old_gui_owner')
        if owner and owner['executable']==str(self.layout.targets['app']/'Contents/MacOS/ARL'):
            receipt=load(self.layout.state/'owned-runtime.json')
            require(services.get(MIO) is None and receipt.get('owner')==owner,'install_owner_receipt_mismatch')
            for role,relative in [('core','Contents/Resources/NASRuntime/python/bin/python3.12'),('mio','Contents/Library/LoginItems/ARLMioAppleBridge.app/Contents/MacOS/ARLMioAppleBridge')]:
                record=receipt.get('children',{}).get(role)
                require(record and self.current(record) and record['executable']==str(self.layout.targets['app']/relative) and self.parent(record['pid'])==owner['pid'],'install_child_path_mismatch')
                children.append(record)
        self.stop_service(MIO,services.get(MIO))
        if plan['details'].get('old_gui_owner'):
            require(self.core_entry()==(None,True),'install_idle_entry_changed')
            self.quit_app({**owner,'drain_supported':True})
            self.unload_idle_core()
        else:self.stop_service(CORE,owner)
        self.wait_owned_children(children)
        require(not (self.layout.state/'mio-apple/owned-child.json').exists(),'mio_child_cleanup_unproven')
        for app in plan['details']['old_apps']:
            if self.current(app):self.quit_app(app)
        require(not self.app_state(),'install_app_drain_unproven')
        self.quit_reminders(reminders)
    def codex_scope_candidate(self, app):
        info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
        require(info.get('ARLCodexServicePolicyVersion') == 1, 'codex_scope_not_declared')
        # The already signature-verified candidate emits metadata only; writes
        # belong to the transaction's fixed codex_scope target and rollback.
        result = self.command([app/'Contents/MacOS/ARL', '--internal-codex-plan'], seconds=10)
        value = json.loads(result.stdout, object_pairs_hook=unique)
        require(set(value) == {'schema_version','configuration_base64','configuration_sha256','previous_sha256','production_changed','inference_started'}
                and value['schema_version'] == 1 and value['production_changed'] is False and value['inference_started'] is False, 'codex_scope_plan_invalid')
        try: raw = base64.b64decode(value['configuration_base64'], validate=True)
        except (ValueError,TypeError):raise InstallFault('codex_scope_plan_invalid') from None
        require(1 <= len(raw) <= 4096 and sha(raw) == value['configuration_sha256'], 'codex_scope_plan_invalid')
        config = json.loads(raw, object_pairs_hook=unique)
        require(set(config) == {'schema_version','caller','provider','model','reasoning_effort','service_tier','scope_generation','max_calls','max_output_bytes','core_manifest_sha256','caller_requirement','explicit_submission_only'}
                and type(config['schema_version']) is int and config['schema_version'] in (1, 2) and config['caller'] == 'arl-control' and config['provider'] == 'codex_app_server'
                and config['model'] == 'gpt-6.1-sol' and config['reasoning_effort'] == 'xhigh' and config['service_tier'] == 'default'
                and (type(config['max_calls']) is int and 1 <= config['max_calls'] <= 1000 or config['schema_version'] == 2 and config['max_calls'] is None) and type(config['max_output_bytes']) is int and config['max_output_bytes'] == 32768
                and config['explicit_submission_only'] is True and config['core_manifest_sha256'] == info['ARLCoreRuntimeManifestSHA256'], 'codex_scope_plan_invalid')
        try: require(str(uuid.UUID(config['scope_generation'])) == config['scope_generation'], 'codex_scope_plan_invalid')
        except (ValueError,TypeError,AttributeError):raise InstallFault('codex_scope_plan_invalid') from None
        authority = json.loads((app/'Contents/Resources/CredentialReadOwner/authority.json').read_bytes(), object_pairs_hook=unique)
        pin = authority['owner']; seal = info['ARLCredentialReadOwnerAuthoritySHA256']
        requirement = f'identifier "{pin["identifier"]}" and certificate leaf = H"{pin["certificateSHA1"]}" and info[ARLCredentialReadOwnerAuthoritySHA256] = "{seal}"'
        require(config['caller_requirement'] == requirement, 'codex_scope_plan_invalid')
        previous = self.layout.targets['codex_scope']
        current = sha(private_file(previous, 4096)) if previous.exists() else None
        require(value['previous_sha256'] == current, 'codex_scope_preimage_changed')
        return raw, current
    def start_maintenance(self,plan):self.bootstrap()
    def start_final(self,plan):self.bootstrap()
    def quiesce_new(self,plan):
        if inventory(self.layout.targets['app'],legacy_nas=plan['details'].get('legacy_nas_preimage')) != plan['changes']['app']['after']:return
        current,inactive=self.core_entry()
        if current:
            require(current['executable']==str(self.layout.targets['app']/'Contents/MacOS/ARL'),'install_new_owner_unverified')
            self.stop_service(CORE,current)
        elif inactive:self.unload_idle_core()
        for app in self.app_state():self.quit_app(app)
        # The owner's receipt is not proof alone; verify the original process
        # birth and executable for each reported child until all are gone.
        path=self.layout.state/'owned-runtime.json'
        if path.exists():
            data=load(path)
            self.wait_owned_children(list(data.get('children',{}).values()))
    def wait_owned_children(self,records,seconds=15):
        # Parent death triggers the bundled Core/Mio shutdown paths. Service
        # removal precedes that bounded cleanup; it is not proof of child exit.
        deadline=time.monotonic()+seconds
        while any(self.current(record) for record in records):
            self.checkpoint('wait_owned_children')
            require(time.monotonic()<deadline,'install_child_cleanup_unproven')
            time.sleep(.05)
    def assert_new_idle(self,plan):
        current=self.service(CORE)
        if current and current['executable']==str(self.layout.targets['app']/'Contents/MacOS/ARL'):self.idle()
        require(all(x.get('drain_supported') is True for x in self.app_state()),'install_app_drain_unsupported')
    def verify_new(self,plan,maintenance):
        expected=plan['details'];deadline=time.monotonic()+15;last=None
        while time.monotonic()<deadline:
            try:
                owner=self.service(CORE);require(owner and owner['executable']==str(self.layout.targets['app']/'Contents/MacOS/ARL'),'install_owner_path_mismatch')
                d=self.metadata('runtime.describe')
                require(d.get('ready') is True and d.get('source_sha256')==expected['source_sha256'] and d.get('version')==expected['version'] and d.get('features',{}).get('app_sessions')==1,'install_runtime_generation_mismatch')
                receipt=load(self.layout.state/'owned-runtime.json')
                require(receipt.get('owner')==owner,'install_owner_receipt_mismatch')
                children=receipt.get('children',{})
                for key,exe in [('core',self.layout.targets['app']/'Contents/Resources/NASRuntime/python/bin/python3.12'),('mio',self.layout.targets['app']/'Contents/Library/LoginItems/ARLMioAppleBridge.app/Contents/MacOS/ARLMioAppleBridge')]:
                    record=children.get(key)
                    require(record and self.current(record) and record['executable']==str(exe) and self.parent(record['pid'])==owner['pid'],'install_child_path_mismatch')
                require(self.service(MIO) is None,'duplicate_mio_owner')
                if maintenance:
                    self.idle();require(self.metadata('overview')['health']['ready'] is True,'install_maintenance_not_ready')
                return
            except (InstallFault,Fault,OSError,ValueError) as error:
                last=failure(error,'verify_new','install_readback_invalid');time.sleep(.1)
        diagnostic={'last_failure':last}
        # A child failure receipt is supplemental evidence, never readiness.
        try:
            child=load(self.layout.state/'runtime-startup-failure.json')
            if child.get('schema_version')==1 and child.get('phase') in {'verify_package','import_runtime','check_maintenance','start_maintenance','start_runtime'} and child.get('code')=='bundled_runtime_start_failed':
                owner=self.service(CORE)
                if owner and child.get('parent_pid')==owner['pid'] and child.get('at',0)>=owner['birth'][0]:
                    diagnostic['last_failure']['child_startup']={k:child[k] for k in ('phase','code','type','errno') if k in child and (k not in {'type','errno'} or (k=='type' and type(child[k]) is str and re.fullmatch(r'[A-Za-z]{1,64}',child[k])) or (k=='errno' and type(child[k]) is int))}
        except (InstallFault,Fault,OSError,ValueError,TypeError):pass
        raise InstallFault('install_new_readback_failed',diagnostic)
    def verify_gui_recovery_owner(self,plan):
        require(plan['details']['old_services'].get(MIO) is None and self.service(MIO) is None,'install_old_service_conflict')
        owner=self.verify_foreground_runtime({'version':plan['details']['old_version'],'source_sha256':plan['details']['old_source_sha256']})
        core,inactive=self.core_entry()
        require(core==owner or (core is None and inactive),'install_old_owner_conflict')
        return owner
    def restore_old(self,plan):
        if plan['details'].get('old_gui_owner'):
            require(plan['details']['old_services'].get(MIO) is None and self.service(MIO) is None,'install_old_service_conflict')
            owner,inactive=self.core_entry()
            if owner is None:
                if self.app_state():
                    require(inactive,'install_old_entry_registration_unproven')
                    self.verify_gui_recovery_owner(plan)
                    return
                if inactive:self.command(['/bin/launchctl','kickstart',self.domain+'/'+CORE])
                else:self.bootstrap()
            else:self.verify_gui_recovery_owner(plan)
            # Recover one formal owner using the existing unchanged entry; do
            # not also open a second GUI app after launchd has restored it.
            return
        for label in [CORE,MIO]:
            if plan['details']['old_services'].get(label) is not None:
                path=self.layout.targets['core_agent' if label==CORE else 'mio_agent']
                if self.service(label) is None:self.command(['/bin/launchctl','bootstrap',self.domain,path])
        owner=plan['details']['old_services'].get(CORE)
        foreground=[app for app in plan['details']['old_apps'] if not owner or any(app.get(k)!=owner.get(k) for k in ['pid','birth','executable'])]
        if foreground:
            if owner and owner['executable']==str(self.layout.targets['app']/'Contents/MacOS/ARL'):self.verify_old(plan)
            self.command(['/usr/bin/open','-g',self.layout.targets['app']],seconds=10)
    def verify_old(self,plan):
        deadline=time.monotonic()+15;last=None
        while time.monotonic()<deadline:
            try:
                require(self.metadata('ready').get('version')==plan['details']['old_version'],'install_old_readback_failed')
                if plan['details'].get('old_gui_owner'):self.verify_gui_recovery_owner(plan)
                for label,record in plan['details']['old_services'].items():
                    if record:require(self.service(label)['executable']==record['executable'],'install_old_owner_path_mismatch')
                return
            except (InstallFault,Fault,OSError,ValueError,TypeError) as error:
                last=failure(error,'verify_old','install_readback_invalid');time.sleep(.1)
        raise InstallFault('install_old_restore_unproven',{'last_failure':last})

READ_OWNER_OLD = frozenset({'travel_read','music_read','music_status','music_playlist_create','music_playlist_append','taobao_connection_metadata','taobao_search_read'})
READ_OWNER_PRE_PRODUCT = frozenset({'travel_read','music_read','music_status','music_playlist_create','music_playlist_append','apple_reminders_task','nas_saved_scope_read'})
READ_OWNER_PRE_COVER = READ_OWNER_PRE_PRODUCT | frozenset({'apple_product_v1'})
READ_OWNER_NEW = READ_OWNER_PRE_COVER | frozenset({'music_playlist_cover'})

def reviewed_read_owner_transition(old_app, new_app):
    observations = []
    for relative in ['', 'Contents/Library/LoginItems/ARLMioAppleBridge.app']:
        pair = []
        for base in [Path(old_app), Path(new_app)]:
            bundle = base/relative
            info = plistlib.loads((bundle/'Contents/Info.plist').read_bytes())
            raw = (bundle/'Contents/Resources/CredentialReadOwner/authority.json').read_bytes()
            require(1 <= len(raw) <= 4096 and sha(raw) == info['ARLCredentialReadOwnerAuthoritySHA256'], 'read_owner_resource_unbound')
            value = json.loads(raw, object_pairs_hook=unique)
            require(set(value) == {'schema','executionAllowed','reviewID','owner','mio','capabilities'} and type(value['schema']) is int and value['schema'] == 2
                    and value['executionAllowed'] is True and type(value['capabilities']) is list
                    and all(type(capability) is str for capability in value['capabilities'])
                    and len(value['capabilities']) in {7,8,9} and len(set(value['capabilities'])) == len(value['capabilities']), 'read_owner_transition_invalid')
            try:
                require(type(value['reviewID']) is str, 'read_owner_transition_invalid')
                uuid.UUID(value['reviewID'])
            except (ValueError,TypeError,AttributeError):raise InstallFault('read_owner_transition_invalid') from None
            for role,identifier in [('owner','local.arl.control'),('mio','local.arl.mioapplebridge')]:
                pin = value[role]
                require(type(pin) is dict and set(pin) == {'identifier','certificateSHA1'} and pin['identifier'] == identifier
                        and type(pin['certificateSHA1']) is str and re.fullmatch(r'[A-F0-9]{40}',pin['certificateSHA1']), 'read_owner_transition_invalid')
            pair.append((value,sha(raw)))
        old,new = pair[0][0],pair[1][0]
        require(old['owner'] == new['owner'] and old['mio'] == new['mio'] and frozenset(old['capabilities']) in {READ_OWNER_OLD,READ_OWNER_PRE_PRODUCT,READ_OWNER_PRE_COVER,READ_OWNER_NEW}
                and frozenset(new['capabilities']) == READ_OWNER_NEW, 'read_owner_transition_invalid')
        observations.append({'before_sha256':pair[0][1], 'after_sha256':pair[1][1]})
    require(observations[0] == observations[1], 'read_owner_pair_mismatch')
    return observations[0]

def metadata_file(path,limit=1024*1024):
    data=path.read_bytes();require(len(data)<=limit,'install_manifest_limit')
    require(inventory(path) is not None,'install_metadata_missing')
    return json.loads(data)

def legacy_nas_preimage(app):
    """Read-only recognition after caller verifies the existing app signature.
    Only the known 0.1.2/build52 packaging defect is admissible. The signed
    Info seal, complete NAS inventory and exact file hashes/modes must agree.
    The returned map authorizes preserving a rollback image, never execution
    of a new candidate or mutation of the installed bundle.
    """
    info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
    require(info.get('CFBundleShortVersionString')=='0.1.2' and info.get('CFBundleVersion')=='52','unsupported_legacy_permissions')
    root=app/'Contents/Resources/NASRuntime';raw=(root/'inventory.json').read_bytes()
    require(sha(raw)==info.get('ARLNASRuntimeInventorySHA256'),'legacy_nas_seal_changed')
    rows=json.loads(raw,object_pairs_hook=unique);allowed={}
    no_links(root)
    actual={str(p.relative_to(root)) for p in root.rglob('*') if p.is_file() and p!=root/'inventory.json'}
    require(actual==set(rows),'legacy_nas_contents_changed')
    for rel,row in rows.items():
        require(type(rel) is str and rel and not Path(rel).is_absolute() and '..' not in Path(rel).parts,'invalid_legacy_nas_path')
        path=root/rel;no_links(path);st=path.stat()
        require(st.st_uid==os.geteuid() and st.st_nlink==1 and path.is_file() and st.st_size==row.get('bytes') and sha(path.read_bytes())==row.get('sha256') and stat.S_IMODE(st.st_mode)==row.get('mode'),'legacy_nas_contents_changed')
        if st.st_mode&0o022:
            require(rel.startswith('python/') and row['mode'] in (0o664,0o775),'unsupported_legacy_permissions')
            allowed['Contents/Resources/NASRuntime/'+rel]={'sha256':row['sha256'],'mode':row['mode']}
    inventory(app,legacy_nas=allowed)
    return allowed

def prepare_payloads(layout,platform,package):
    package=Path(package).absolute();app=package/'ARL.app'
    manifest=metadata_file(package/'manifest.json');info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
    current=layout.targets['app'];old_authority=json.loads(private_file(layout.targets['authority']))
    authority=metadata_file(package/'ARL.authority.candidate.json')
    require(set(old_authority)==set(authority) and all(old_authority[k]==authority[k] for k in old_authority if k!='executableSHA256'),'install_authority_scope_changed')
    require(old_authority['bundlePath']==str(current),'install_target_binding_mismatch')
    require(old_authority['executableSHA256']==sha((current/'Contents/MacOS/ARL').read_bytes()),'installed_code_binding_changed')
    require(authority['executableSHA256']==sha((app/'Contents/MacOS/ARL').read_bytes()),'candidate_code_binding_mismatch')
    platform.signature(current,old_authority['designatedRequirement']);platform.signature(app,old_authority['designatedRequirement'])
    require(info['CFBundleIdentifier']=='local.arl.control' and int(info['CFBundleVersion'])>int(plistlib.loads((current/'Contents/Info.plist').read_bytes())['CFBundleVersion']),'install_version_not_newer')
    # Candidates must be safe before execution; legacy exception is not used.
    expected=manifest['bundle_files'];actual=inventory(app)['files']
    legacy=legacy_nas_preimage(current) if info.get('CFBundleShortVersionString')=='0.1.2' and plistlib.loads((current/'Contents/Info.plist').read_bytes()).get('CFBundleVersion')=='52' else {}
    inventory(current,legacy_nas=legacy)
    require(actual==expected,'install_bundle_manifest_mismatch')
    core=metadata_file(app/'Contents/Resources/CoreRuntime/manifest.json')
    require(sha((app/'Contents/Resources/CoreRuntime/manifest.json').read_bytes())==info['ARLCoreRuntimeManifestSHA256'] and core['source_sha256']==info['ARLCoreRuntimeSourceSHA256'] and core['store_version']==4 and core['profile']=='local-compatibility','install_core_binding_mismatch')
    # Only schema/queue counts are read; no task arguments or result bodies.
    database=layout.state/'state.sqlite'
    if database.exists():
        with sqlite3.connect('file:'+str(database)+'?mode=ro',uri=True) as db:require(db.execute('PRAGMA user_version').fetchone()[0]==4,'install_store_version_unsupported')
    if layout.targets['unified_marker'].exists():
        return prepare_unified_update(layout,platform,app,authority,info,core)
    installation=load(layout.state/'runtime/installation.json');active=load(layout.state/'runtime/active.json')
    require(installation['profile']=='research-product-optin' and installation['label']==CORE and active['release']==installation['current'],'unsupported_existing_installation')
    old_release=layout.state/'runtime/releases'/installation['current'];old_manifest=load(old_release/'manifest.json')
    require(old_manifest['profile']=='research-product-optin' and old_manifest['store_version']==4,'unsupported_existing_profile')
    require(sha(private_file(layout.targets['legacy_entry']))==old_manifest['files']['runtime_entry.py'] and sha(private_file(layout.targets['legacy_manager']))==old_manifest['files']['manage.py'],'old_runtime_ownership_changed')
    platform.idle();old_version=platform.metadata('ready')['version']
    old_services={label:platform.service(label) for label in [CORE,MIO]}
    for label,key in [(CORE,'core_agent'),(MIO,'mio_agent')]:
        value=plistlib.loads(private_file(layout.targets[key]));require(value['Label']==label,'install_agent_owner_changed')
        args=value['ProgramArguments']
        if label==CORE:require(args==['/usr/bin/python3','-I',str(layout.targets['legacy_entry'])],'old_core_entry_changed')
        else:require(len(args)==5 and args[0]==str(layout.targets['legacy_mio_app']/'Contents/MacOS/ARLMioAppleBridge') and args[1]=='--host' and args[2]==str(layout.targets['mio_activation']) and args[3]=='--approved-policy-sha256','old_mio_entry_changed')
    mio_old=layout.targets['legacy_mio_app'];mio_new=app/'Contents/Library/LoginItems/ARLMioAppleBridge.app'
    old_mio_info=plistlib.loads((mio_old/'Contents/Info.plist').read_bytes());new_mio_info=plistlib.loads((mio_new/'Contents/Info.plist').read_bytes())
    for resource in ['CredentialReadOwner/authority.json','MioRuntime/manifest.json']:
        require((mio_old/'Contents/Resources'/resource).read_bytes()==(mio_new/'Contents/Resources'/resource).read_bytes(),'mio_authority_or_client_changed')
    status=json.loads(private_file(layout.targets['mio_status']));platform.signature(mio_old,status['helper_requirement']);platform.signature(mio_new,status['helper_requirement'])
    require(status['helper_cdhash']==platform.cdhash(mio_old) and status['helper_executable_sha256']==sha((mio_old/'Contents/MacOS/ARLMioAppleBridge').read_bytes()),'old_mio_binding_changed')
    activation_raw=private_file(layout.targets['mio_activation']);activation=json.loads(activation_raw)
    require(sha(activation_raw)==old_mio_info['ARLApprovedPolicySHA256'],'old_mio_policy_changed')
    layout.bind_profile(activation['profile']);profile_raw=private_file(layout.targets['mio_profile'])
    old_exe=str(mio_old/'Contents/MacOS/ARLMioAppleBridge').encode();new_exe=str(current/'Contents/Library/LoginItems/ARLMioAppleBridge.app/Contents/MacOS/ARLMioAppleBridge').encode()
    require(profile_raw.count(old_exe)==1 and sha(profile_raw)==activation['profile_sha256'],'mio_profile_preimage_changed')
    next_profile=profile_raw.replace(old_exe,new_exe);next_activation=dict(activation);next_activation['profile_sha256']=sha(next_profile)
    require({k for k in activation if activation[k]!=next_activation[k]}=={'profile_sha256'},'mio_scope_changed')
    next_activation_raw=encode(next_activation)
    require(sha(next_activation_raw)==new_mio_info['ARLApprovedPolicySHA256'],'candidate_mio_policy_seal_mismatch')
    next_status=dict(status);next_status.update(helper_cdhash=platform.cdhash(mio_new),helper_executable_sha256=sha((mio_new/'Contents/MacOS/ARLMioAppleBridge').read_bytes()))
    control=json.loads(private_file(layout.targets['reminders_control']));closure_raw=private_file(layout.targets['reminders_closure']);closure=json.loads(closure_raw)
    require(sha(closure_raw)==control['closure_sha256'],'old_reminders_closure_changed')
    helper=current/'Contents/Library/LoginItems/ARLRemindersBridge.app';new_helper=app/'Contents/Library/LoginItems/ARLRemindersBridge.app'
    platform.signature(helper,control['helper_requirement']);platform.signature(new_helper,control['helper_requirement'])
    require(set(closure)=={'Contents/Info.plist','Contents/MacOS/ARLRemindersBridge','Contents/_CodeSignature/CodeResources'},'unsupported_reminders_closure')
    new_closure={path:sha((new_helper/path).read_bytes()) for path in closure}
    require(all(sha((helper/path).read_bytes())==value for path,value in closure.items()),'old_reminders_code_changed')
    require({p for p in closure if closure[p]!=new_closure[p]}<={'Contents/MacOS/ARLRemindersBridge'},'reminders_policy_or_identity_changed')
    next_control=dict(control);next_control.update(helper_executable_sha256=new_closure['Contents/MacOS/ARLRemindersBridge'],closure_sha256=sha(encode(new_closure)))
    require({k for k in control if control[k]!=next_control[k]}<={'helper_executable_sha256','closure_sha256'},'reminders_scope_changed')
    agent={'Label':CORE,'ProgramArguments':[str(current/'Contents/MacOS/ARL'),'--background'],'RunAtLoad':True,'KeepAlive':{'SuccessfulExit':False},'ExitTimeOut':45,'ProcessType':'Interactive','WorkingDirectory':str(layout.state),'ThrottleInterval':10,'Umask':63,'StandardOutPath':str(layout.state/'app.stdout.log'),'StandardErrorPath':str(layout.state/'app.stderr.log')}
    details={'version':info['CFBundleShortVersionString'],'build':info['CFBundleVersion'],'source_sha256':core['source_sha256'],'core_manifest_sha256':info['ARLCoreRuntimeManifestSHA256'],'old_version':old_version,'old_services':old_services,'old_apps':platform.app_state(),'authority_scope_preserved':True,'mio_scope_preserved':True,'store_schema_preserved':True,'legacy_nas_preimage':legacy}
    marker={'schema_version':1,'enabled':1,'core_manifest_sha256':info['ARLCoreRuntimeManifestSHA256'],'mio_enabled':1}
    payloads={'app':app,'authority':encode(authority),'core_agent':plistlib.dumps(agent),'mio_agent':None,'legacy_mio_app':None,'legacy_entry':None,'legacy_manager':None,'mio_activation':next_activation_raw,'mio_profile':next_profile,'mio_status':encode(next_status),'reminders_control':encode(next_control),'reminders_closure':encode(new_closure),'unified_marker':encode(marker),'maintenance':encode({'schema_version':1,'enabled':1}),'installation':encode({k:details[k] for k in ['version','build','source_sha256','core_manifest_sha256','authority_scope_preserved','mio_scope_preserved','store_schema_preserved']})}
    return payloads,details


def prepare_unified_update(layout,platform,app,authority,info,core):
    """Existing unified owner only. Keep identity, policy, profile and data.
    Called after shared signature/inventory/newer-build/CoreRuntime checks.
    """
    current=layout.targets['app'];old_info=plistlib.loads((current/'Contents/Info.plist').read_bytes())
    marker=load(layout.targets['unified_marker']);installation=load(layout.targets['installation'])
    require(set(marker)=={'schema_version','enabled','core_manifest_sha256','mio_enabled'} and marker['schema_version']==marker['enabled']==marker['mio_enabled']==1 and marker['core_manifest_sha256']==old_info['ARLCoreRuntimeManifestSHA256'],'unsupported_unified_installation')
    require(all(installation.get(key) is True for key in ['authority_scope_preserved','mio_scope_preserved','store_schema_preserved']),'unsupported_unified_installation')
    require(installation.get('build')==old_info['CFBundleVersion'] and installation.get('version')==old_info['CFBundleShortVersionString'] and installation.get('source_sha256')==old_info['ARLCoreRuntimeSourceSHA256'] and installation.get('core_manifest_sha256')==old_info['ARLCoreRuntimeManifestSHA256'],'install_core_binding_mismatch')
    agent_raw=private_file(layout.targets['core_agent']);agent=plistlib.loads(agent_raw)
    require(agent.get('Label')==CORE and agent.get('ProgramArguments')==[str(current/'Contents/MacOS/ARL'),'--background'],'old_core_entry_changed')
    require(all(not layout.targets[k].exists() for k in ['mio_agent','legacy_mio_app','legacy_entry','legacy_manager']),'duplicate_legacy_owner')
    platform.idle();core_owner,inactive=platform.core_entry();services={CORE:core_owner,MIO:platform.service(MIO)}
    require(services[MIO] is None,'install_owner_path_mismatch')
    old_runtime={'version':old_info['CFBundleShortVersionString'],'source_sha256':old_info['ARLCoreRuntimeSourceSHA256']}
    gui_owner=None
    if inactive:
        gui_owner=platform.verify_foreground_runtime(old_runtime)
    else:
        require(core_owner and core_owner['executable']==str(current/'Contents/MacOS/ARL'),'install_owner_path_mismatch')
        platform.verify_new({'details':old_runtime},maintenance=False)
    old_apps=platform.app_state();require(all(row.get('drain_supported') is True for row in old_apps),'legacy_app_drain_unsupported')
    old_mio=current/'Contents/Library/LoginItems/ARLMioAppleBridge.app';new_mio=app/'Contents/Library/LoginItems/ARLMioAppleBridge.app'
    old_mio_info=plistlib.loads((old_mio/'Contents/Info.plist').read_bytes());new_mio_info=plistlib.loads((new_mio/'Contents/Info.plist').read_bytes())
    resource='MioRuntime/manifest.json'
    require((old_mio/'Contents/Resources'/resource).read_bytes()==(new_mio/'Contents/Resources'/resource).read_bytes(),'mio_client_changed')
    read_owner_transition = reviewed_read_owner_transition(current, app)
    activation_raw=private_file(layout.targets['mio_activation'])
    require(sha(activation_raw)==old_mio_info['ARLApprovedPolicySHA256']==new_mio_info['ARLApprovedPolicySHA256'],'candidate_mio_policy_seal_mismatch')
    activation=json.loads(activation_raw);layout.bind_profile(activation['profile'])
    profile_pin=sha(private_file(layout.targets['mio_profile']))
    require(profile_pin==activation.get('profile_sha256'),'mio_profile_preimage_changed')
    # The profile and activation stay read-only, bound by the plan digest.
    status=load(layout.targets['mio_status']);platform.signature(old_mio,status['helper_requirement']);platform.signature(new_mio,status['helper_requirement'])
    require(status['helper_cdhash']==platform.cdhash(old_mio) and status['helper_executable_sha256']==sha((old_mio/'Contents/MacOS/ARLMioAppleBridge').read_bytes()),'old_mio_binding_changed')
    next_status=dict(status);next_status.update(helper_cdhash=platform.cdhash(new_mio),helper_executable_sha256=sha((new_mio/'Contents/MacOS/ARLMioAppleBridge').read_bytes()))
    control=load(layout.targets['reminders_control']);closure_raw=private_file(layout.targets['reminders_closure']);closure=json.loads(closure_raw)
    require(sha(closure_raw)==control['closure_sha256'] and set(closure)=={'Contents/Info.plist','Contents/MacOS/ARLRemindersBridge','Contents/_CodeSignature/CodeResources'},'old_reminders_closure_changed')
    helper=current/'Contents/Library/LoginItems/ARLRemindersBridge.app';new_helper=app/'Contents/Library/LoginItems/ARLRemindersBridge.app'
    platform.signature(helper,control['helper_requirement']);platform.signature(new_helper,control['helper_requirement'])
    require(all(sha((helper/path).read_bytes())==value for path,value in closure.items()),'old_reminders_code_changed')
    new_closure={path:sha((new_helper/path).read_bytes()) for path in closure}
    require({p for p in closure if closure[p]!=new_closure[p]}<={'Contents/MacOS/ARLRemindersBridge'},'reminders_policy_or_identity_changed')
    next_control=dict(control);next_control.update(helper_executable_sha256=new_closure['Contents/MacOS/ARLRemindersBridge'],closure_sha256=sha(encode(new_closure)))
    require({k for k in control if control[k]!=next_control[k]}<={'helper_executable_sha256','closure_sha256'},'reminders_scope_changed')
    details={'version':info['CFBundleShortVersionString'],'build':info['CFBundleVersion'],'source_sha256':core['source_sha256'],'core_manifest_sha256':info['ARLCoreRuntimeManifestSHA256'],'old_version':old_info['CFBundleShortVersionString'],'old_services':services,'old_apps':old_apps,'authority_scope_preserved':True,'mio_scope_preserved':True,'store_schema_preserved':True}
    next_marker={**marker,'core_manifest_sha256':info['ARLCoreRuntimeManifestSHA256']}
    require(set(installation)==set(details)-{'old_version','old_services','old_apps'},'unsupported_unified_installation')
    if gui_owner is not None:details.update(old_gui_owner=gui_owner,old_core_job_inactive=True,old_source_sha256=old_info['ARLCoreRuntimeSourceSHA256'])
    details['readonly_preconditions']={'mio_activation':sha(activation_raw),'mio_profile':profile_pin}
    payloads={'app':app,'authority':encode(authority),'core_agent':agent_raw,'mio_status':encode(next_status),'reminders_control':encode(next_control),'reminders_closure':encode(new_closure),'unified_marker':encode(next_marker),'maintenance':encode({'schema_version':1,'enabled':1}),'installation':encode({k:details[k] for k in installation})}
    details['read_owner_transition'] = read_owner_transition
    if info.get('ARLCodexServicePolicyVersion') == 1:
        scope, previous_scope = platform.codex_scope_candidate(app)
        payloads['codex_scope'] = scope
        details['codex_scope_before_sha256'] = previous_scope
    return payloads,details
