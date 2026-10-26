"""Offline protocol double; echoes actual thread/turn preferences, no model."""
import json,sys
mode=sys.argv[1] if len(sys.argv)>1 else 'ok'
state={}
def emit(value):print(json.dumps(value,separators=(',',':')),flush=True)
for line in sys.stdin:
 d=json.loads(line);method=d.get('method');p=d.get('params',{});i=d.get('id')
 if method=='initialize':emit({'id':i,'result':{'userAgent':'offline'}})
 elif method=='model/list':
  emit({'id':i,'result':{'data':[{'model':'synthetic-model','defaultReasoningEffort':'high',
   'supportedReasoningEfforts':[{'reasoningEffort':e} for e in ['low','medium','high','xhigh']],
   'serviceTiers':[{'id':'fast'}]}],'nextCursor':None}})
 elif method=='thread/start':
  state={'effort':p.get('config',{}).get('model_reasoning_effort'),'tier':p.get('serviceTier')}
  ack=dict(model=p['model'],thread={'id':'thread-execution','ephemeral':True},
   reasoningEffort='high' if mode=='bad_ack' else state['effort'],serviceTier=state['tier'])
  emit({'id':i,'result':ack})
 elif method=='turn/start':
  if p.get('effort')!=state['effort'] or p.get('serviceTierForTurn')!=state['tier']:
   emit({'id':i,'error':{'code':-1,'message':'option drift'}});continue
  emit({'id':i,'result':{'turn':{'id':'turn-execution','status':'inProgress'}}})
  body={'text':'effort='+str(p.get('effort'))+';tier='+str(p.get('serviceTierForTurn')),'citations':[]}
  emit({'method':'item/completed','params':{'threadId':'thread-execution','turnId':'turn-execution',
   'item':{'type':'agentMessage','text':json.dumps(body)}}})
  emit({'method':'turn/completed','params':{'threadId':'thread-execution','turn':{'id':'turn-execution','status':'completed'}}})
 elif method=='turn/interrupt':emit({'id':i,'result':{}})
