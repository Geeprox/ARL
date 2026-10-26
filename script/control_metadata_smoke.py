"""Ephemeral metadata-only source host. Never uses installed production home."""
import json
import sys
import tempfile
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT))
from arl.client import Client
from arl.host import make_runtime

def main():
    with tempfile.TemporaryDirectory(prefix='arl-control-smoke-',dir='/tmp') as home:
        runtime=make_runtime(home)
        errors=[]
        def serve():
            try:runtime.run()
            except Exception as error:errors.append(type(error).__name__)
        thread=threading.Thread(target=serve); thread.start()
        try:
            settings=Client(home,'settings'); settings.connect(timeout=5)
            first=settings.rpc('settings.snapshot')
            # A real second interval, no synthetic CPU/time or forced cache invalidation.
            time.sleep(5.1)
            second=settings.rpc('settings.snapshot')
            export=settings.rpc('settings.logs_export')
            old=settings.rpc('overview')
            assert old['schema_version']==1 and second['schema_version']==2
            assert not second['runtime']['task_execution_enabled']
            assert all(not p['inference_enabled'] for p in second['providers'])
            assert sum(old['queue']['counts'].values())==0
            assert all(app['registration']=='unregistered' for app in second['apps'])
            evidence={'source_only':True,'production_home_used':False,
                'first_resources':first['resources'],'snapshot':second,'logs_export':export,
                'old_overview_schema':old['schema_version'],'job_count':0}
            target=ROOT/'docs/evidence/control-metadata-smoke.json'
            target.write_text(json.dumps(evidence,indent=2)+'\n')
            print(json.dumps({'evidence':str(target),'schema_version':2,
                'resources':second['resources'],'provider_states':{p['id']:p['state'] for p in second['providers']},
                'registered_apps':0,'inference':False,'job_count':0},indent=2))
        finally:
            runtime.shutdown(); thread.join(5)
            assert not thread.is_alive() and not errors, errors

if __name__=='__main__':main()
