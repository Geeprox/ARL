"""Synthetic RPC rejections and burst frames. Never accesses accounts."""
import sys,json
mode=sys.argv[1];counts={}
def emit(v):print(json.dumps(v),flush=True)
for line in sys.stdin:
 d=json.loads(line);method=d.get('method');key=d.get('id');p=d.get('params',{});counts[method]=counts.get(method,0)+1
 if method=='initialize':emit({'id':key,'result':{}})
 elif method=='account/read':
  if mode=='recover' and counts[method]==1 or mode=='exhausted':emit({'id':key,'error':{'code':-32603,'message':'request timed out secret sk-synthetic-should-not-log'}})
  elif mode=='auth':emit({'id':key,'error':{'code':-32000,'message':'Unauthorized secret'}})
  else:emit({'id':key,'result':{'account':{'type':'chatgpt'},'requests':counts[method]}})
 elif method=='thread/start':
  if mode=='thread_rejected':emit({'id':key,'error':{'code':-32001,'message':'Server overloaded; retry later.'}})
  else:emit({'id':key,'result':{'model':p['model'],'thread':{'id':'synthetic','ephemeral':True}}})
 elif method=='turn/start':
  if mode=='cancel_on_output':
   emit({'id':key,'result':{'turn':{'id':'turn-synthetic','status':'inProgress'}}})
   emit({'method':'item/completed','params':{'threadId':'synthetic','turnId':'turn-synthetic','item':{'type':'agentMessage','text':json.dumps({'text':'synthetic answer'})}}})
   emit({'method':'turn/completed','params':{'threadId':'synthetic','turn':{'id':'turn-synthetic','status':'completed'}}})
  else:emit({'id':key,'error':{'code':-32001,'message':'Server overloaded; retry later.'}})
 elif method=='burst':
  values=[{'method':'synthetic/delta','params':{'index':i}} for i in range(200)]+[{'id':key,'result':{'requests':counts[method]}}]
  print(''.join(json.dumps(v)+'\n' for v in values),end='',flush=True)
