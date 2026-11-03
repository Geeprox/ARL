"""Finite provider diagnostics: no input, output, reasoning or raw error text."""
import time
READ_METHODS=frozenset({'config/read','account/read','model/list'})
METHODS=READ_METHODS|{'initialize','thread/start','turn/start','turn/interrupt'}
def rpc_error(method,error):
 value=error if type(error)==dict else {}
 code=value.get('code');code=code if type(code)==int else None
 message=value.get('message','');message=message.lower() if type(message)==str else ''
 if code==-32001:category='overloaded'
 elif any(v in message for v in ('timed out','timeout','temporarily unavailable','database is locked','database is busy')):category='temporary_unavailable'
 elif code==-32602 or 'requires experimentalapi' in message:category='invalid_request'
 elif any(v in message for v in ('unauthorized','not authenticated','login required','sign in required')):category='authentication_required'
 else:category='request_rejected'
 return {'method':method if method in METHODS else 'unknown','jsonrpc_code':code,'category':category,
  'safe_read_retry':method in READ_METHODS and category in {'overloaded','temporary_unavailable'}}
class Timing:
 def __init__(self):
  self.start=time.monotonic();self.started_at=time.time();self.points={};self.counts={}
 def mark(self,name):
  if name not in self.points:self.points[name]=round((time.monotonic()-self.start)*1000,3)
 def count(self,name):self.counts[name]=self.counts.get(name,0)+1
 def receipt(self):
  return {'schema_version':1,'started_at':self.started_at,'elapsed_ms':round((time.monotonic()-self.start)*1000,3),'milestones_ms':dict(self.points),'counts':dict(self.counts)}
