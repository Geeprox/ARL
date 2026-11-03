"""Content-free timing around the upstream investigation stage callback."""
from pathlib import Path
import functools,json,os,time,uuid
STAGES=frozenset({'load_llm','refine','search','filter','scrape','summarize','pivots','save'})
def configure(pipeline,root):
 original=pipeline.run_investigation
 if getattr(original,'arl_timing_configured',False):return
 @functools.wraps(original)
 def run(*args,**kwargs):
  directory=Path(root);identity=uuid.uuid4().hex;start=time.monotonic();events=[];callback=kwargs.get('on_stage')
  record={'schema_version':1,'id':identity,'started_at':time.time(),'status':'running','events':events}
  def save():
   try:
    directory.mkdir(parents=True,exist_ok=True)
    target=directory/(identity+'.json');temporary=target.with_suffix('.tmp');temporary.write_text(json.dumps(record)+'\n');os.replace(temporary,target)
   except OSError:pass
  def stage(name,investigation):
   if name in STAGES:
    events.append({'stage':name,'elapsed_ms':round((time.monotonic()-start)*1000,3)});save()
   if callback:callback(name,investigation)
  kwargs['on_stage']=stage
  try:
   value=original(*args,**kwargs);record['status']=getattr(value,'status','completed');record['saved_as']=getattr(value,'saved_as',None);return value
  except BaseException:
   record['status']='interrupted';raise
  finally:
   record['elapsed_ms']=round((time.monotonic()-start)*1000,3);record['finished_at']=time.time();save()
 run.arl_timing_configured=True;pipeline.run_investigation=run
