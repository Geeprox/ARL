"""Strict offline protocol double. No model, network or credential access."""
import json,sys
def emit(v):print(json.dumps(v),flush=True)
thread=None
for line in sys.stdin:
 d=json.loads(line);p=d.get('params',{});method=d.get('method');key=d.get('id')
 if method=='initialize':emit({'id':key,'result':{}})
 elif method=='model/list':
  emit({'id':key,'result':{'data':[{'model':m,'displayName':m,'description':'offline fixture','hidden':False,
   'defaultReasoningEffort':'medium','supportedReasoningEfforts':[{'reasoningEffort':e,'description':e} for e in efforts],
   'serviceTiers':[{'id':'fast','name':'Fast','description':'synthetic Fast metadata'}] if fast else []}
   for m,efforts,fast in [('synthetic-model',['medium','xhigh'],True),('synthetic-small',['low','medium'],False)]],'nextCursor':None}})
 elif method=='thread/start':
  thread=p
  assert p['serviceTier'] in ['default','fast'] and p['config']['model_reasoning_effort'] in ['low','medium','xhigh']
  emit({'id':key,'result':{'model':p['model'],'thread':{'id':'thread-options','ephemeral':True},
   'reasoningEffort':p['config']['model_reasoning_effort'],'serviceTier':p['serviceTier']}})
 elif method=='turn/start':
  assert thread is not None and p['model']==thread['model'] and p['effort']==thread['config']['model_reasoning_effort']
  assert p['serviceTierForTurn']==thread['serviceTier']
  emit({'id':key,'result':{'turn':{'id':'turn-options','status':'inProgress'}}})
  emit({'method':'item/completed','params':{'threadId':'thread-options','turnId':'turn-options',
   'item':{'type':'agentMessage','text':json.dumps({'text':json.dumps({'model':p['model'],'effort':p['effort'],'tier':p['serviceTierForTurn']})})}}})
  emit({'method':'turn/completed','params':{'threadId':'thread-options','turn':{'id':'turn-options','status':'completed'}}})
