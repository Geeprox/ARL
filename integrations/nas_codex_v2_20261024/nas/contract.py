"""Text-only OpenAI compatibility; explicit selection or package, never both."""
import hashlib,json,uuid
APPS=('pdf2zh','bilinote')
MODEL='arl/package/medium'
PREFIX='ARL application: '
def encode(value):return json.dumps(value,ensure_ascii=False,sort_keys=True,separators=(',',':'),allow_nan=False).encode()
def normalize(app,value,catalog,request_id=None):
    if app not in APPS or type(value)!=dict:raise ValueError('invalid_request')
    allowed={'model','messages','reasoning_effort','temperature','top_p','max_tokens','max_completion_tokens','stream','stream_options','frequency_penalty','presence_penalty','seed','stop','n'}
    if set(value)-allowed or value.get('n',1)!=1:raise ValueError('unsupported_request')
    if type(value.get('stream',False))!=bool:raise ValueError('invalid_stream')
    if value.get('max_tokens') is not None or value.get('max_completion_tokens') is not None:raise ValueError('token_hard_cap_unsupported')
    if time_stale(catalog):raise ValueError('catalog_unavailable')
    row=next((m for m in catalog['models'] if m['id']==value.get('model')),None)
    if row is None or row.get('available') is False:raise ValueError('model_unavailable')
    model=value['model'];effort=value.get('reasoning_effort')
    if model.startswith('arl/package/'):
        if effort is not None:raise ValueError('mixed_selector')
        selector={'kind':'package','package_id':model.removeprefix('arl/package/')}
    elif model.startswith('arl/option/'):
        if effort is not None:raise ValueError('mixed_selector')
        selector=row['selector']
    else:
        if effort is not None and effort not in row['reasoning_efforts']:raise ValueError('effort_unavailable')
        selector={'kind':'model','model':model}
        if effort is not None:selector['reasoning_effort']=effort
    messages=value.get('messages')
    if type(messages)!=list or not messages:raise ValueError('invalid_messages')
    clean=[{'role':'developer','content':PREFIX+app}]
    for message in messages:
        if type(message)!=dict or set(message)-{'role','content','name'} or message.get('role') not in {'system','developer','user','assistant'}:raise ValueError('text_only')
        content=message.get('content')
        if type(content)==list:
            if any(type(p)!=dict or set(p)!={'type','text'} or p['type']!='text' or type(p['text'])!=str for p in content):raise ValueError('text_only')
            content='\n'.join(p['text'] for p in content)
        if type(content)!=str:raise ValueError('text_only')
        clean.append({'role':message['role'],'content':content})
    if not 1<=len(encode(clean))<=8192:raise ValueError('input_exceeds_8192_bytes')
    identity=str(uuid.uuid4()) if request_id is None else str(uuid.UUID(request_id))
    if request_id is not None and identity!=request_id:raise ValueError('invalid_request_id')
    return {'schema':2,'app':app,'id':identity,'selector':selector,'messages':clean,'content_sha256':hashlib.sha256(encode({'messages':clean})).hexdigest(),'max_output_bytes':32768}
def time_stale(catalog):
    import time
    return not isinstance(catalog,dict) or time.time()-catalog.get('published_at',0)>90
