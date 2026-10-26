"""Reviewed current-user one-shot install plan. Never launches or requests TCC."""
import argparse,hashlib,json,os,pwd,shutil,stat
from pathlib import Path
ROOT=Path(__file__).resolve().parent;REPO=ROOT.parents[1]
p=argparse.ArgumentParser();p.add_argument('--manifest-sha256',required=True);p.add_argument('--apply',action='store_true');args=p.parse_args()
raw=(ROOT/'reminders-release.json').read_bytes()
assert hashlib.sha256(raw).hexdigest()==args.manifest_sha256,'manifest_mismatch'
plan=json.loads(raw);release=REPO/plan['release_directory']
assert release==ROOT/'dist/reminders-release-source-v3','unexpected_release'
actual={}
for path in release.rglob('*'):
    info=path.lstat();assert not stat.S_ISLNK(info.st_mode) and info.st_uid==os.geteuid() and not info.st_mode&0o022,'unsafe_package'
    if path.is_file():actual[str(path.relative_to(release))]=hashlib.sha256(path.read_bytes()).hexdigest()
assert actual==plan['files'],'payload_mismatch'
home=Path(pwd.getpwuid(os.geteuid()).pw_dir)
target=home/'Applications/ARLRemindersBridge.app';state=home/'Library/Application Support/ARL/reminders-once'
assert str(target)==plan['app_target'] and str(state)==plan['state_home'],'target_mismatch'
assert not any(path.exists() or path.is_symlink() for path in (target,state)),'existing_target_stop'
for parent in (target.parent,state.parent):
    for component in (parent,*parent.parents):
        info=component.lstat();assert stat.S_ISDIR(info.st_mode) and not stat.S_ISLNK(info.st_mode),'unsafe_parent'
    info=parent.lstat();assert info.st_uid==os.geteuid() and not info.st_mode&0o022,'unsafe_parent'
if not args.apply:
    print(json.dumps({'status':'plan_verified','app':str(target),'state':str(state),'launch':False,'autostart':False,'permissions_requested':False}));raise SystemExit(0)
os.umask(0o077);created_state=created_app=False
try:
    state.mkdir(mode=0o700);created_state=True
    shutil.copytree(release/'code',state/'code')
    for name in ('launch_reminders.py','reminders-package.json'):
        shutil.copy2(release/name,state/name);(state/name).chmod(0o600)
    target.mkdir(mode=0o700);created_app=True
    shutil.copytree(release/'ARLRemindersBridge.app',target,dirs_exist_ok=True)
    print(json.dumps({'status':'installed_not_launched','permissions_requested':False}))
except BaseException:
    if created_app:shutil.rmtree(target)
    if created_state:shutil.rmtree(state)
    raise
