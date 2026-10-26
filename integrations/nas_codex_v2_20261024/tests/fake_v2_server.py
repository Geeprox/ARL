"""Synthetic stdio Codex protocol fixture. Never uses a network/model/credential."""
import json,sys,time
mode=sys.argv[1] if len(sys.argv)>1 else 'ok'
def emit(d):print(json.dumps(d),flush=True)
def sourced_output(p):
 # A protocol double, not generated evidence: derive references only from the
 # explicitly supplied synthetic request. No files, auth or model calls.
 schema=p.get('outputSchema',{});props=schema.get('properties',{})
 expected={'evidence_id','snapshot_digest','record_id','revision','unit','attachment_sha256','quote','start_utf8','end_utf8'}
 if (set(props)!={'text','citations'} or schema.get('additionalProperties') is not False or
     set(props['citations']['items'].get('properties',{}))!=expected):
  return {'error':'unexpected sourced schema'}
 raw=json.loads(p['input'][0]['text']);parts=[e for e in raw['evidence'] if e['text']]
 citations=[]
 if parts:
  e=parts[0];quote=e['text']
  citation={k:e[k] for k in ('evidence_id','snapshot_digest','record_id','revision','unit','attachment_sha256')}
  citation.update(quote=quote,start_utf8=0,end_utf8=len(quote.encode('utf-8')));citations=[citation]
 if mode=='sourced_no_citations':citations=[]
 if citations:
  c=citations[0]
  if mode=='sourced_id':c['evidence_id']='99999999-9999-4999-8999-999999999999'
  if mode=='sourced_digest':c['snapshot_digest']='0'*64
  if mode=='sourced_record':c['record_id']='99999999-9999-4999-8999-999999999999'
  if mode=='sourced_revision':c['revision']+=1
  if mode=='sourced_unit':c['unit']='0'
  if mode=='sourced_quote':c['quote']='invented quotation'
  if mode=='sourced_range':c['end_utf8']-=1
  if mode=='sourced_split_utf8':c['start_utf8']=1
  if mode=='sourced_duplicate':citations.append(dict(c))
  if mode=='sourced_range_bool':c['start_utf8']=False
  if mode=='sourced_attachment':c['attachment_sha256']='0'*64
 body={'text':'synthetic plan','citations':citations}
 if mode=='sourced_extra':body['unexpected']='rejected'
 if mode=='sourced_large':body['text']='x'*32769
 if mode=='sourced_refusal':body={'refusal':'synthetic refusal'}
 return body
for line in sys.stdin:
 d=json.loads(line);id=d.get('id');method=d.get('method');p=d.get('params',{})
 if method=='initialize':emit({'id':id,'result':{'userAgent':'synthetic'}})
 elif method=='model/list':
  emit({'id':id,'result':{'data':[{'model':'synthetic-model','displayName':'Synthetic','defaultReasoningEffort':'medium','supportedReasoningEfforts':[{'reasoningEffort':e,'description':''} for e in ('low','medium','high','xhigh','ultra')],'inputModalities':['text']}],'nextCursor':None}})
 elif method=='thread/start':
  if mode=='lost_thread_ack':sys.exit(0)
  emit({'id':id,'result':{'model':p['model'],'reasoningEffort':p.get('config',{}).get('model_reasoning_effort'),'serviceTier':p.get('serviceTier'),'thread':{'id':'thread-synthetic','ephemeral':True}}})
 elif method=='turn/start':
  if mode=='lost_turn_ack':sys.exit(0)
  emit({'id':id,'result':{'turn':{'id':'turn-synthetic','status':'inProgress'}}})
  if mode in {'user_receipt','bad_user_receipt'}:
   content=p['input'] if mode=='user_receipt' else [{'type':'text','text':'unexpected input'}]
   emit({'method':'item/completed','params':{'threadId':'thread-synthetic','turnId':'turn-synthetic','item':{'type':'userMessage','content':content,'id':'user-fixture'}}})
  if mode in {'wait','wait_interrupt','wait_ack_only','wait_wrong_terminal','late_completed'}:
   # Wait for interrupt/termination; exposes no fake upstream-stop acknowledgement.
   continue
  if mode=='failed_turn':
   emit({'method':'turn/completed','params':{'threadId':'thread-synthetic','turn':{'id':'turn-synthetic','status':'failed'}}});continue
  if mode=='action':emit({'id':1000,'method':'item/commandExecution/requestApproval','params':{}});continue
  turn='wrong-turn' if mode=='mismatch' else 'turn-synthetic'
  text='x'*400 if mode=='large' else 'synthetic plan'
  body=sourced_output(p) if 'citations' in p.get('outputSchema',{}).get('properties',{}) else ({'text':text,'extra':'bad'} if mode=='extra' else {'text':text})
  envelope=json.dumps(body)
  emit({'method':'item/completed','params':{'threadId':'thread-synthetic','turnId':turn,'item':{'type':'agentMessage','text':envelope}}})
  emit({'method':'turn/completed','params':{'threadId':'thread-synthetic','turn':{'id':'turn-synthetic','status':'completed'}}})
 elif method=='turn/interrupt':
  emit({'id':id,'result':{}})
  if mode in {'wait_interrupt','wait_wrong_terminal','late_completed'}:
   turn='wrong-turn' if mode=='wait_wrong_terminal' else 'turn-synthetic'
   emit({'method':'turn/completed','params':{'threadId':'thread-synthetic','turn':{'id':turn,'status':'completed' if mode=='late_completed' else 'interrupted'}}})
