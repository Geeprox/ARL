"""Pinned NAS audience consumer over confirmed ARL SDK v2 sessions."""
import hashlib,json,os,sys,time,uuid
from pathlib import Path
ROOT=Path(__file__).resolve().parent
sys.path.insert(0,str(ROOT));sys.path.insert(0,str(ROOT/'core'))
from arl.client import Client
from arl.contracts import Fault
from contract import APPS,encode
from local_api import atomic,read_json
NAME='codex.text.generate.v2'
def archive_terminal(queue):
    for app in APPS:
        directory=queue/app;archive=directory/'archive'
        try:
            if archive.is_symlink():continue
            archive.mkdir(mode=0o700,exist_ok=True)
            for path in (directory/'requests').glob('*.json'):
                response=directory/'responses'/path.name
                if not response.exists():continue
                answer=read_json(response,131072);request=read_json(path,6*8192+4096)
                if answer.get('state') not in {'succeeded','failed','cancelled','needs_review'} or answer.get('app')!=app or answer.get('id')!=path.stem:continue
                if time.time()-answer.get('at',time.time())<600 or time.time()-response.stat().st_mtime<600 or request.get('expires_at',time.time())>time.time():continue
                saved=archive/path.name
                if not saved.exists():atomic(saved,answer)
                if read_json(saved,131072)!=answer:continue
                response.unlink();path.unlink()
        except (OSError,ValueError,KeyError,TypeError):pass
def publish_metadata(client,queue):
    client.ping_app_session()
    catalog=client.rpc('application.models.discover.v2',{'session_id':client.app_session})
    options=[]
    for model in catalog['models']:
        for effort in model.get('reasoning_efforts',[]):
            selector={'kind':'model','model':model['id'],'reasoning_effort':effort}
            options.append({'id':'arl/option/'+model['id']+'/'+effort,'object':'model','owned_by':'arl','selector':selector,'display_name':model['id']+' · '+effort})
    catalog['models'].extend(options)
    catalog['published_at']=time.time()
    for app in APPS:
        if (queue/app).is_dir():atomic(queue/app/'catalog.json',catalog)
    return catalog
def run(config):
    home=Path(config['state_home']);queue=Path(config['queue_root']);ledger=home/'requests';ledger.mkdir(mode=0o700,exist_ok=True)
    client=Client(home,config['caller']);client.connect(timeout=10)
    accepted=client.open_app_session('Friday NAS text adapter',(NAME,),icon_ref='sf:doc.text')
    if accepted!=[NAME]:raise Fault('capability_not_accepted')
    atomic(home/'handshake.json',{'at':time.time(),'protocol':'arl/1','identity':'registered_kernel_peer_and_pinned_signature','accepted_capabilities':accepted,'confirmed':True})
    last_metadata=last_archive=0
    while True:
        if time.monotonic()-last_metadata>15:
            catalog=publish_metadata(client,queue)
            last_metadata=time.monotonic()
        for app in APPS:
            directory=queue/app
            if not (directory/'requests').is_dir():continue
            for path in sorted((directory/'requests').glob('*.json'))[:128]:
                identity=None
                try:
                    identity=str(uuid.UUID(path.stem))
                    if path.name!=identity+'.json':continue
                    response=directory/'responses'/path.name
                    if response.exists():continue
                    request=read_json(path,6*8192+4096)
                    # Preserve v1 uncertain work. Never upgrade/replay old intents.
                    if request.get('schema')==1:continue
                    if set(request)!={'schema','app','id','selector','messages','content_sha256','max_output_bytes','created_at','expires_at'} or request['schema']!=2 or request['app']!=app or request['id']!=identity or request['max_output_bytes']!=32768:raise ValueError('request_binding_invalid')
                    messages=request['messages']
                    if not isinstance(messages,list) or not messages or messages[0]!={'role':'developer','content':'ARL application: '+app} or len(encode(messages))>8192 or hashlib.sha256(encode({'messages':messages})).hexdigest()!=request['content_sha256']:raise ValueError('content_binding_invalid')
                    now=time.time()
                    if type(request['created_at']) not in (int,float) or type(request['expires_at']) not in (int,float) or request['created_at']>now+30 or request['expires_at']>request['created_at']+301:raise ValueError('deadline_invalid')
                    saved=ledger/(app+'-'+path.name)
                    record=read_json(saved,131072) if saved.exists() else {'app':app,'id':identity,'content_sha256':request['content_sha256'],'state':'prepared'}
                    if record.get('content_sha256')!=request['content_sha256']:raise ValueError('intent_changed')
                    archived=directory/'archive'/path.name
                    if archived.exists():
                        answer=read_json(archived,131072)
                        if answer.get('id')!=identity or answer.get('app')!=app or answer.get('state') not in {'succeeded','failed','cancelled','needs_review'}:raise ValueError('archive_binding_invalid')
                        atomic(response,answer);continue
                    if request['expires_at']<now and not record.get('job_id'):raise ValueError('request_expired')
                    if not record.get('job_id'):
                        lookup=client.rpc('codex.requests.lookup.v2',{'session_id':client.app_session,'request_id':identity})
                        if lookup['found']:
                            resolution=lookup['resolution']
                            if lookup['job']:record['job_id']=lookup['job']['id']
                        else:
                            resolution=client.rpc('application.models.request.v2',{'schema_version':2,'session_id':client.app_session,'request_id':identity,'catalog_version':catalog['catalog_version'],'content_sha256':request['content_sha256'],'task_kind':'text.translate' if app=='pdf2zh' else 'text.summarize','selector':request['selector'],'schedule':{'priority':'explicit','execution_timeout_ms':180000,'queue_timeout_ms':0},'output':{'max_bytes':32768},'service_tier':'default'})
                        record['resolution_id']=resolution['resolution_id'];atomic(saved,record)
                        if not record.get('job_id'):
                            job=client.submit(NAME,{'schema_version':2,'resolution_id':record['resolution_id'],'messages':messages},identity)
                            record['job_id']=job['id'];record['state']=job['state'];atomic(saved,record)
                    deadline=time.monotonic()+190
                    while True:
                        job=client.rpc('get',{'id':record['job_id']})
                        if job['state'] not in {'queued','running'}:break
                        if (directory/'cancelled'/path.name).exists() or time.time()>request['expires_at'] or time.monotonic()>deadline:
                            client.rpc('cancel',{'id':record['job_id']});job=client.rpc('get',{'id':record['job_id']});break
                        if time.monotonic()-last_metadata>15:
                            catalog=publish_metadata(client,queue);last_metadata=time.monotonic()
                        time.sleep(.25)
                    answer={'schema':2,'app':app,'id':identity,'job_id':record['job_id'],'state':job['state'],'at':time.time()}
                    if job['state']=='succeeded':
                        result=job['result'];receipt=result['selection_receipt']
                        if result.get('simulated') is not False or result.get('model')!=receipt['resolved']['model'] or receipt['content_sha256']!=request['content_sha256'] or receipt['selector']!=request['selector']:raise ValueError('provider_receipt_invalid')
                        answer.update(text=result['text'],output_sha256=result['output_sha256'],thread_id=result['thread_id'],turn_id=result['turn_id'],simulated=False,selection_receipt=receipt,execution_preferences=result['execution_preferences'])
                    else:answer['error']=job.get('error') or 'arl_task_not_completed'
                    record.update({k:v for k,v in answer.items() if k!='text'});atomic(saved,record);atomic(response,answer)
                except (ValueError,UnicodeError,KeyError,TypeError,Fault) as error:
                    if identity and path.stem==identity:atomic(directory/'responses'/path.name,{'app':app,'id':identity,'state':'failed','error':error.code if isinstance(error,Fault) else 'invalid_queue_request','at':time.time()})
                except OSError:pass
        if time.monotonic()-last_archive>30:last_archive=time.monotonic();archive_terminal(queue)
        time.sleep(.5)
if __name__=='__main__':
    config=json.loads((ROOT/'config.json').read_text());print('prepared',flush=True)
    if sys.stdin.readline()!='go\n':raise SystemExit(1)
    run(config)
