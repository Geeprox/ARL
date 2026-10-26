"""Exact current-user helper/code installation, pending explicit approval. No launch/TCC."""
import argparse,hashlib,json,os,pwd,shutil,stat
from pathlib import Path
ROOT=Path(__file__).resolve().parent
p=argparse.ArgumentParser();p.add_argument('--apply',action='store_true');p.add_argument('--manifest-sha256',required=True);args=p.parse_args()
raw=(ROOT/'calendar-release.json').read_bytes()
assert hashlib.sha256(raw).hexdigest()==args.manifest_sha256,'manifest_mismatch'
plan=json.loads(raw);release=ROOT/plan['release_directory']
actual={}
for f in release.rglob('*'):
 s=f.lstat();assert not stat.S_ISLNK(s.st_mode) and s.st_uid==os.geteuid() and not s.st_mode&0o022,'unsafe_package'
 if f.is_file():actual[str(f.relative_to(release))]=hashlib.sha256(f.read_bytes()).hexdigest()
assert actual==plan['files'],'payload_mismatch'
home=Path(pwd.getpwuid(os.geteuid()).pw_dir);target=home/'Applications/ARLCalendarBridge.app';state=home/'Library/Application Support/ARL/calendar-once'
assert str(target)==plan['app_target'] and str(state)==plan['state_home'],'target_mismatch'
assert not target.exists() and not target.is_symlink() and not state.exists() and not state.is_symlink(),'existing_target_stop'
for parent in (target.parent,state.parent):
 s=parent.lstat();assert stat.S_ISDIR(s.st_mode) and s.st_uid==os.geteuid() and not s.st_mode&0o022,'unsafe_parent'
if not args.apply:print(json.dumps({'status':'plan_verified','app':str(target),'state':str(state),'launch':False,'autostart':False,'permissions_requested':False}));raise SystemExit(0)
os.umask(0o077)
created_state=created_app=False
try:
 state.mkdir(mode=0o700);created_state=True
 shutil.copytree(release/'code',state/'code')
 shutil.copy2(release/'launch_calendar.py',state/'launch_calendar.py');(state/'launch_calendar.py').chmod(0o600)
 shutil.copy2(release/'calendar-package.json',state/'calendar-package.json');(state/'calendar-package.json').chmod(0o600)
 target.mkdir(mode=0o700);created_app=True
 shutil.copytree(release/'ARLCalendarBridge.app',target,dirs_exist_ok=True)
 print(json.dumps({'status':'installed_not_launched','app':str(target),'state':str(state),'permissions_requested':False}))
except BaseException:
 if created_app:shutil.rmtree(target)
 if created_state:shutil.rmtree(state)
 raise
