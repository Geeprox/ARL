import json,hashlib
from pathlib import Path
root=Path(__file__).resolve().parent
UUID={'type':'string','format':'uuid'}
DIGEST={'type':'string','pattern':'^[a-f0-9]{64}$'}
ID={'type':'string','pattern':'^[A-Za-z0-9][A-Za-z0-9._/-]{0,149}$'}
EFFORT={'type':'string','pattern':'^[A-Za-z0-9][A-Za-z0-9_-]{0,39}$'}
PACKAGES=['low','medium','high','very_high','highest']
def obj(properties,required=None):return {'type':'object','additionalProperties':False,'properties':properties,'required':list(properties) if required is None else required}
def schema(name,body):return {'$schema':'https://json-schema.org/draft/2020-12/schema','$id':'urn:arl:codex:'+name,**body}
selector={'oneOf':[obj({'kind':{'const':'package'},'package_id':{'enum':PACKAGES}}),obj({'kind':{'const':'model'},'model':ID,'reasoning_effort':EFFORT},['kind','model'])]}
request=schema('selection-request:v2',obj({'schema_version':{'const':2},'session_id':{'type':'string','minLength':32,'maxLength':256},'request_id':UUID,'catalog_version':DIGEST,'content_sha256':DIGEST,'task_kind':{'enum':['text.generate','text.translate','text.summarize']},'selector':selector,'schedule':obj({'priority':{'enum':['background','explicit','interactive']},'execution_timeout_ms':{'type':'integer','minimum':1000,'maximum':600000},'queue_timeout_ms':{'type':'integer','minimum':0,'maximum':3600000}}),'output':obj({'max_bytes':{'type':'integer','minimum':128,'maximum':1048576}}),'service_tier':{'enum':['default','fast']}}))
config=schema('package-config:v2',obj({'schema_version':{'const':2},'base_revision':{'type':'integer','minimum':0},'catalog_version':DIGEST,'packages':obj({key:obj({'display_name':{'type':'string','minLength':1,'maxLength':40},'model':ID,'reasoning_effort':EFFORT}) for key in PACKAGES})}))
message=obj({'role':{'enum':['system','developer','user','assistant']},'content':{'type':'string','maxLength':1048576}})
submit=schema('submit:v2',obj({'protocol':{'const':'arl/1'},'app':ID,'method':{'const':'submit'},'params':obj({'tool':{'const':'codex.text.generate.v2'},'key':UUID,'args':obj({'schema_version':{'const':2},'resolution_id':{'type':'string','pattern':'^[a-f0-9]{64}$'},'messages':{'type':'array','minItems':1,'maxItems':128,'items':message}})})}))
for name,value in [('selection-request.schema.json',request),('package-config.schema.json',config),('submit.schema.json',submit)]: (root/name).write_text(json.dumps(value,ensure_ascii=False,indent=2)+'\n')
messages=[{'role':'user','content':'Translate the following sentence into Chinese: A home portal has two addresses.'}];content=json.dumps({'messages':messages},sort_keys=True,separators=(',',':'),ensure_ascii=False,allow_nan=False).encode();digest=hashlib.sha256(content).hexdigest();base={'schema_version':2,'session_id':'1'*64,'request_id':'c65d163b-d81f-48fe-8ab0-997b02e36cda','catalog_version':'a'*64,'content_sha256':digest,'task_kind':'text.translate','selector':{'kind':'package','package_id':'medium'},'schedule':{'priority':'explicit','execution_timeout_ms':180000,'queue_timeout_ms':300000},'output':{'max_bytes':32768},'service_tier':'default'}
examples={'package-request.json':base,'explicit-request.json':dict(base,selector={'kind':'model','model':'demo-model-a','reasoning_effort':'high'}),'package-config.json':{'schema_version':2,'base_revision':7,'catalog_version':'a'*64,'packages':{key:{'display_name':name,'model':'demo-model-a' if n<3 else 'demo-model-b','reasoning_effort':effort} for n,(key,name,effort) in enumerate(zip(PACKAGES,['低','中','高','极高','最高'],['low','medium','high','xhigh','max']))}},'submit.json':{'protocol':'arl/1','app':'example.pdf-client','method':'submit','params':{'tool':'codex.text.generate.v2','key':base['request_id'],'args':{'schema_version':2,'resolution_id':'b'*64,'messages':messages}}}}
(root/'examples').mkdir(exist_ok=True)
for name,value in examples.items():(root/'examples'/name).write_text(json.dumps(value,ensure_ascii=False,indent=2)+'\n')
(root/'examples/README.md').write_text('所有 session、catalog、resolution、request ID 及 demo-model-* 都是合成示例，不是现网凭据或模型目录。JSON Schema 验证形状；目录支持、应用权限、内容字节与哈希、套餐版本、额度、Fast 授权和原子受理仍由真实 host 检查。\n')
print('3 schemas and 4 synthetic examples generated')
