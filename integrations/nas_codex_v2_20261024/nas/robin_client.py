"""Scoped ARL transport settings; Robin's collection defaults stay upstream."""
ENDPOINT='http://127.0.0.1:19421/v1'
REQUEST_TIMEOUT_SECONDS=740

def configure(utilities):
    original=utilities.resolve_model_config
    if getattr(original,'arl_transport_configured',False):return
    def resolve(*args,**kwargs):
        value=original(*args,**kwargs)
        if value is None:return None
        params=value.get('constructor_params',{})
        if params.get('base_url','').rstrip('/')!=ENDPOINT:return value
        # A network timeout can happen after durable admission. Never create a
        # second operation automatically; inspect the original task instead.
        return {**value,'constructor_params':{**params,'timeout':REQUEST_TIMEOUT_SECONDS,'max_retries':0}}
    resolve.arl_transport_configured=True
    utilities.resolve_model_config=resolve
