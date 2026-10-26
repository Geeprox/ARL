"""Plan by default; create an exact, expiring review only after explicit approval."""
import argparse,hashlib,json,os,pwd,stat,time
from pathlib import Path
ROOT=Path(__file__).resolve().parent
p=argparse.ArgumentParser();p.add_argument('--approved-request-sha256',required=True);p.add_argument('--apply',action='store_true');args=p.parse_args()
proposal=json.loads((ROOT/'approval-proposal.json').read_text())
raw=json.dumps(proposal['args'],sort_keys=True,ensure_ascii=False,allow_nan=False).encode()
digest=hashlib.sha256(raw).hexdigest()
assert digest==args.approved_request_sha256==proposal['request_sha256'],'approval_digest_mismatch'
home=Path(pwd.getpwuid(os.geteuid()).pw_dir)/'Library/Application Support/ARL/reminders-once'
review={'args':proposal['args'],'expires_at_ms':int(time.time()*1000)+600000}
if not args.apply:
    print(json.dumps({'status':'review_plan_only','request_sha256':digest,'expires_in_ms':600000,'permissions_requested':False}));raise SystemExit(0)
for part in (home,*home.parents):
    info=part.lstat();assert not stat.S_ISLNK(info.st_mode) and stat.S_ISDIR(info.st_mode),'unsafe_review_home'
info=home.lstat();assert info.st_uid==os.geteuid() and not info.st_mode&0o077,'unsafe_review_home'
assert not (home/'native-consumed.json').exists() and not (home/'native-consumed.json').is_symlink(),'operation_consumed'
fd=os.open(str(home/'review.json'),os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
try:
    data=json.dumps(review,sort_keys=True,ensure_ascii=False,allow_nan=False).encode()
    assert os.write(fd,data)==len(data) and os.fsync(fd) is None,'review_write_uncertain'
finally:os.close(fd)
directory=os.open(str(home),os.O_RDONLY|os.O_DIRECTORY)
try:os.fsync(directory)
finally:os.close(directory)
print(json.dumps({'status':'sealed_one_review','request_sha256':digest,'permissions_requested':False}))
