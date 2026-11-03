"""Offline provider fixture: exact input echo, native token metadata, typed error."""
import json,sys
def emit(v):print(json.dumps(v),flush=True)
mode=sys.argv[1] if len(sys.argv)>1 else 'ok'
for line in sys.stdin:
 d=json.loads(line);p=d.get('params',{});key=d.get('id');method=d.get('method')
 if method=='initialize':emit({'id':key,'result':{}})
 elif method=='thread/start':emit({'id':key,'result':{'model':p['model'],'thread':{'id':'thread-context','ephemeral':True}}})
 elif method=='turn/start':
  emit({'id':key,'result':{'turn':{'id':'turn-context','status':'inProgress'}}})
  emit({'method':'item/completed','params':{'threadId':'thread-context','turnId':'turn-context','item':{'id':'receipt','type':'userMessage','content':p['input']}}})
  if mode=='context_exceeded':
   error={'codexErrorInfo':'contextWindowExceeded','message':'synthetic overflow'}
   emit({'method':'error','params':{'threadId':'thread-context','error':error}})
   emit({'method':'turn/completed','params':{'threadId':'thread-context','turn':{'id':'turn-context','status':'failed','error':error}}});continue
  count=len(p['input'][0]['text'])//4
  emit({'method':'thread/tokenUsage/updated','params':{'threadId':'thread-context','turnId':'turn-context','tokenUsage':{'modelContextWindow':500000,'last':{'inputTokens':count,'outputTokens':3,'reasoningOutputTokens':0,'cachedInputTokens':0,'totalTokens':count+3}}}})
  emit({'method':'item/completed','params':{'threadId':'thread-context','turnId':'turn-context','item':{'type':'agentMessage','text':json.dumps({'text':'CONTEXT_OK'})}}})
  emit({'method':'turn/completed','params':{'threadId':'thread-context','turn':{'id':'turn-context','status':'completed'}}})
