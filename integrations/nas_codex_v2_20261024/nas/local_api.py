"""Container-loopback OpenAI compatibility over one app's private file queue."""
import hashlib,hmac,json,os,socket,sys,time,uuid
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parent))
from contract import MODEL,APPS,encode,normalize

def atomic(path, value):
    raw=encode(value); temporary=path.with_name('.'+path.name+'.'+uuid.uuid4().hex)
    fd=os.open(temporary,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'wb') as f:f.write(raw);f.flush();os.fsync(f.fileno())
    os.replace(temporary,path)

def read_json(path, limit):
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW)
    with os.fdopen(fd,'rb') as f:
        if os.fstat(f.fileno()).st_size>limit:raise ValueError('frame_too_large')
        return json.loads(f.read(limit+1))

def server(app, root, secret):
    if app not in APPS:raise ValueError('app')
    class Handler(BaseHTTPRequestHandler):
        protocol_version='HTTP/1.1'
        def log_message(self,*args):pass
        def reply(self,status,value):
            raw=encode(value);self.send_response(status);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(raw)));self.send_header('Cache-Control','no-store');self.end_headers();self.wfile.write(raw)
        def authorized(self):
            return hmac.compare_digest(self.headers.get('Authorization',''),'Bearer '+secret)
        def do_GET(self):
            if not self.authorized():return self.reply(401,{'error':{'code':'unauthorized'}})
            if self.path=='/v1/models':
                try:
                    from contract import time_stale
                    catalog=read_json(root/'catalog.json',131072)
                    if time_stale(catalog):return self.reply(503,{'error':{'code':'catalog_stale'}})
                    return self.reply(200,{'object':'list','data':catalog['models'],'arl':{k:catalog[k] for k in ('schema_version','catalog_version','package_revision','quota_policy','local_lifetime_call_limit')}})
                except (OSError,ValueError,KeyError):return self.reply(503,{'error':{'code':'catalog_unavailable'}})
            if self.path=='/health':return self.reply(200,{'ok':True,'app':app,'transport':'arl-file-queue','inference_verified':False})
            return self.reply(404,{'error':{'code':'not_found'}})
        def do_POST(self):
            if not self.authorized():return self.reply(401,{'error':{'code':'unauthorized'}})
            if self.path!='/v1/chat/completions':return self.reply(404,{'error':{'code':'not_found'}})
            try:
                self.connection.settimeout(10)
                length=int(self.headers.get('Content-Length','0'))
                if not 0<length<=6*8192+4096 or self.headers.get('Transfer-Encoding'):raise ValueError('invalid_frame')
                raw=self.rfile.read(length)
                if len(raw)!=length:raise ValueError('invalid_frame')
                value=json.loads(raw);catalog=read_json(root/'catalog.json',131072);request=normalize(app,value,catalog,request_id=self.headers.get('Idempotency-Key'))
                target=root/'requests'/(request['id']+'.json');response=root/'responses'/(request['id']+'.json')
                # Identical requests retain their original deadline and operation UUID.
                if not target.exists():
                    pending=[p for p in (root/'requests').glob('*.json') if not (root/'responses'/p.name).exists()]
                    if len(pending)>=128:return self.reply(503,{'error':{'code':'queue_capacity_reached'}})
                    request['created_at']=time.time();request['expires_at']=time.time()+300
                    atomic(target,request)
                original=read_json(target,6*8192+4096)
                if original.get('content_sha256')!=request['content_sha256'] or original.get('selector')!=request['selector']:
                    return self.reply(409,{'error':{'code':'request_id_conflict'}})
                deadline=time.monotonic()+305
                while not response.exists():
                    if time.monotonic()>deadline:
                        atomic(root/'cancelled'/(request['id']+'.json'),{'id':request['id']})
                        return self.reply(503,{'error':{'code':'arl_task_pending_or_cancelled','message':'Inspect original task; no automatic replay.'}})
                    time.sleep(.4)
                result=read_json(response,131072)
                if result.get('id')!=request['id'] or result.get('app')!=app:raise ValueError('response_mismatch')
                if result.get('state')!='succeeded':return self.reply(503,{'error':{'code':result.get('error','arl_task_failed'),'message':'Original ARL task retained; no automatic new call.'}})
                text=result['text'];now=int(time.time());identity='chatcmpl-'+request['id'];selected_model=value['model']
                if result.get('schema')!=2 or result.get('selection_receipt',{}).get('content_sha256')!=request['content_sha256'] or result['selection_receipt']['selector']!=request['selector']:raise ValueError('response_mismatch')
                if value.get('stream'):
                    chunks=[{'id':identity,'object':'chat.completion.chunk','created':now,'model':selected_model,'choices':[{'index':0,'delta':{'role':'assistant','content':text},'finish_reason':None}]},
                            {'id':identity,'object':'chat.completion.chunk','created':now,'model':selected_model,'choices':[{'index':0,'delta':{},'finish_reason':'stop'}]}]
                    body=b''.join(b'data: '+encode(c)+b'\n\n' for c in chunks)+b'data: [DONE]\n\n'
                    self.send_response(200);self.send_header('Content-Type','text/event-stream');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
                else:self.reply(200,{'id':identity,'object':'chat.completion','created':now,'model':selected_model,'choices':[{'index':0,'message':{'role':'assistant','content':text},'finish_reason':'stop'}],'arl':{'request_id':request['id'],'job_id':result['job_id'],'selection_mode':request['selector']['kind'],'package_id':request['selector'].get('package_id'),'package_revision':result['selection_receipt']['package_revision']}})
            except (ValueError,UnicodeError,KeyError):self.reply(400,{'error':{'code':'invalid_or_unsupported_text_request'}})
            except (BrokenPipeError,ConnectionResetError,socket.timeout):pass
            except OSError:self.reply(503,{'error':{'code':'queue_unavailable'}})
    return ThreadingHTTPServer(('127.0.0.1',19421),Handler)

if __name__=='__main__':
    app=sys.argv[1];root=Path('/friday-queue');secret=Path('/friday-secret/token').read_text().strip()
    if os.geteuid()==0:os.setgid(100);os.setuid(1026)
    server(app,root,secret).serve_forever()
