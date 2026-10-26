"""Immutable Friday local review binding; data is not execution authorization."""
import hashlib,json,re
from dataclasses import dataclass
from .contracts import Fault
from .friday_planning_client import ReviewedRemoval
MODEL='gpt-6.1-sol'
def digest(value):
 return hashlib.sha256(json.dumps(value,sort_keys=True,separators=(',',':'),ensure_ascii=False,allow_nan=False).encode()).hexdigest()
def strict(raw):
 def pairs(items):
  result={}
  for k,v in items:
   if k in result:raise Fault('invalid_friday_review')
   result[k]=v
  return result
 if len(raw)>12000:raise Fault('invalid_friday_review')
 try:return json.loads(raw,object_pairs_hook=pairs,parse_constant=lambda _: (_ for _ in ()).throw(Fault('invalid_friday_review')))
 except (ValueError,TypeError):raise Fault('invalid_friday_review') from None
@dataclass(frozen=True,init=False)
class FridayReviewBinding:
 raw:str
 sha256:str
 def __init__(self,raw):
  value=strict(raw)
  if type(value)!=dict or set(value)!={'request','model','owner_review'} or value['model']!=MODEL:raise Fault('invalid_friday_review')
  action=ReviewedRemoval(value['request'],MODEL);b=value['owner_review']
  if type(b)!=dict or set(b)!={'review_id','boot_id','backend','approval_digest','expires_at_ms'}:raise Fault('invalid_friday_review')
  for name in ('review_id','boot_id'):
   if type(b[name])!=str or not re.fullmatch(r'[A-Za-z0-9_-]{1,128}',b[name]):raise Fault('invalid_friday_review')
  if b['review_id']!=action.execution_id:raise Fault('friday_review_identity_mismatch')
  if b['backend'] not in {'simulator','home_core'} or type(b['expires_at_ms'])!=int or b['expires_at_ms']!=action.request['expires_at_ms']:raise Fault('invalid_friday_review')
  if b['approval_digest']!=digest([b['boot_id'],b['backend'],action.digest,MODEL]):raise Fault('friday_review_digest_mismatch')
  raw=json.dumps(value,ensure_ascii=False,sort_keys=True,allow_nan=False)
  object.__setattr__(self,'raw',raw);object.__setattr__(self,'sha256',hashlib.sha256(raw.encode()).hexdigest())
 @property
 def value(self):return json.loads(self.raw)
 @property
 def action(self):return ReviewedRemoval(self.value['request'],MODEL)
 @classmethod
 def from_review(cls,review):
  r=review.model_dump(mode='json') if hasattr(review,'model_dump') else review
  b={'review_id':r['id'],'boot_id':r['boot_id'],'backend':r['context']['backend'],'approval_digest':r['approval_digest'],'expires_at_ms':r['request']['expires_at_ms']}
  if r['context']['fingerprint']!=r['request']['context_fingerprint'] or r['model']!=MODEL or r['provider']!='codex_app_server' or r['model_inference_attempted'] is not False or r['real_write_attempted'] is not False:raise Fault('invalid_friday_review')
  return cls(json.dumps({'request':r['request'],'model':MODEL,'owner_review':b},ensure_ascii=False))
 def matches(self,review):
  try:return type(self).from_review(review).raw==self.raw
  except (Fault,ValueError,TypeError,KeyError):return False
