"""After explicit event approval, seal only the exact proposed one-event request."""
import argparse,hashlib,json,os,pwd,time
from pathlib import Path
ROOT=Path(__file__).resolve().parent
def encode(value):return json.dumps(value,ensure_ascii=False,sort_keys=True,allow_nan=False).encode()
def checked(value):
 assert type(value) is dict and set(value)=={'operation_id','title','start','end'},'invalid_proposal'
 assert all(type(v) is str for v in value.values()),'invalid_proposal'
 return value
parser=argparse.ArgumentParser();parser.add_argument('--approved-request-sha256',required=True);parser.add_argument('--apply',action='store_true');a=parser.parse_args()
proposal=json.loads((ROOT/'approval-proposal.json').read_text());args=checked(proposal['args']);digest=hashlib.sha256(encode(args)).hexdigest()
assert a.approved_request_sha256==digest,'approval_digest_mismatch'
import datetime
assert datetime.datetime.fromisoformat(args['start']).timestamp()>time.time(),'suggested_time_no_longer_future'
review={'args':args,'expires_at_ms':int(time.time()*1000)+600000}
target=Path(pwd.getpwuid(os.geteuid()).pw_dir)/'Library/Application Support/ARL/calendar-once/review.json'
if not a.apply:print(json.dumps({'status':'review_plan_verified','request_sha256':digest,'expires_in_ms':600000}));raise SystemExit(0)
fd=os.open(str(target),os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
try:os.write(fd,encode(review));os.fsync(fd)
finally:os.close(fd)
print(json.dumps({'status':'sealed_one_review','request_sha256':digest,'permissions_requested':False}))
