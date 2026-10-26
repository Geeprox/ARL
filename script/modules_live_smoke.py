"""Temporary source runtime: only fixed Mio health metadata, zero tasks."""
import json,sys,tempfile,threading
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from arl.client import Client
from arl.host import make_runtime
with tempfile.TemporaryDirectory(prefix='arl-module-smoke-') as temp:
    runtime=make_runtime(Path(temp));errors=[]
    def run():
        try:runtime.run()
        except Exception as exc:errors.append(type(exc).__name__)
    thread=threading.Thread(target=run);thread.start()
    try:
        client=Client(Path(temp),'settings');client.connect(timeout=5)
        result=client.rpc('settings.modules_snapshot')
        with runtime.store.lock: jobs=runtime.store.db.execute('SELECT count(*) FROM jobs').fetchone()[0]
        result['acceptance']={'transport':'temporary_unix_rpc','task_count':jobs,'task_execution_enabled':runtime.execute_jobs,'installed_runtime_changed':False,'personal_data_read':False}
        assert not jobs and not runtime.execute_jobs
        print(json.dumps(result,ensure_ascii=False,sort_keys=True))
    finally:
        runtime.shutdown();thread.join(5)
        assert not thread.is_alive() and not errors
