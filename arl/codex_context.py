"""Codex-native context policy; transport framing is not a model token limit.

Model tokenization, full prompt overhead, reasoning/output reservations and
context rejection belong to the provider. Never truncate or guess tokens from
bytes. The private transport has a separate 64 MiB resource envelope.
"""
import datetime,json,os,stat,time
from pathlib import Path
TRANSPORT_FRAME_BYTES=64*1024*1024
INPUT_POLICY='provider_context_window'
def context_rows(catalog,cache_path=None):
    rows={}
    path=Path(cache_path) if cache_path is not None else Path.home()/'.codex/models_cache.json'
    try:
        fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW)
        with os.fdopen(fd,'rb') as stream:
            info=os.fstat(stream.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_uid!=os.getuid() or info.st_size>8*1024*1024:return {}
            value=json.load(stream)
        fetched=value['fetched_at'];at=datetime.datetime.fromisoformat(fetched.replace('Z','+00:00')).timestamp()
        if not -60<=time.time()-at<=24*3600:return {}
        visible={m['model'] for m in catalog}
        for row in value.get('models',[]):
            if row.get('slug') not in visible:continue
            window=row.get('context_window');percent=row.get('effective_context_window_percent',100)
            if type(window)!=int or window<=0 or type(percent)!=int or not 0<percent<=100:continue
            maximum=row.get('max_context_window')
            rows[row['slug']]={'context_window_tokens':window,'effective_context_window_tokens':window*percent//100,
                'max_context_window_tokens':maximum if type(maximum)==int and maximum>=window else None,
                'context_source':'codex_model_cache','context_fetched_at':fetched,'input_policy':INPUT_POLICY,
                'provider_enforced':True}
    except (OSError,ValueError,TypeError,KeyError,AttributeError):return {}
    return rows
def context_error(error):
    if type(error)!=dict:return None
    code=error.get('codexErrorInfo')
    names=list(code) if type(code)==dict else [code]
    if any(type(name)==str and ''.join(c for c in name.lower() if c.isalpha())=='contextwindowexceeded' for name in names):return 'model_context_window_exceeded'
    return None
def token_receipt(params,thread_id,turn_id):
    if params.get('threadId')!=thread_id or params.get('turnId')!=turn_id:return None
    usage=params.get('tokenUsage')
    if type(usage)!=dict:return None
    last=usage.get('last');window=usage.get('modelContextWindow')
    if type(last)!=dict:return None
    fields={name:last.get(name) for name in ('inputTokens','outputTokens','reasoningOutputTokens','cachedInputTokens','totalTokens')}
    if any(type(value)!=int or value<0 for value in fields.values()):return None
    if window is not None and (type(window)!=int or window<=0):return None
    return {'source':'thread/tokenUsage/updated','model_context_window_tokens':window,'last':fields}
