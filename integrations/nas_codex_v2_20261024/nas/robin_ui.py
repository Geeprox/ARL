"""Enter Streamlit in the process that owns the scoped model client factory."""
from pathlib import Path
import json,os,sys,time
sys.path.insert(0,'/robin-source');sys.path.insert(0,'/robin-bridge')
import llm_utils
from robin_client import configure,ENDPOINT
configure(llm_utils)
import llm
original=llm.get_llm

def get_llm(*args,**kwargs):
    client=original(*args,**kwargs)
    if str(getattr(client,'openai_api_base','')).rstrip('/')==ENDPOINT:
        # Read back actual constructed client properties, never keys or input.
        receipt={'at':time.time(),'scope':'owned_loopback','request_timeout_seconds':client.request_timeout,'automatic_retries':client.max_retries,'pid':os.getpid()}
        target=Path('/robin-state/client-transport.json');temporary=target.with_suffix('.tmp');temporary.write_text(json.dumps(receipt)+'\n');os.replace(temporary,target)
    return client
llm.get_llm=get_llm
import pipeline
from robin_timing import configure as configure_timing
configure_timing(pipeline,Path('/robin-state/performance'))
from streamlit.web import cli
sys.argv=['streamlit','run','/robin-source/ui.py',*sys.argv[1:]]
raise SystemExit(cli.main())
