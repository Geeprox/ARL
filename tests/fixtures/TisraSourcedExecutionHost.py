"""Private cross-language offline fixture. No socket, production home or model.

Runs the actual versioned engine, SQLite queue and a separate synthetic stdio
provider. Only this fixture's source/main checkout and owned temp DB are used.
"""
import json,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT))
from arl.contracts import Fault
from tests.test_codex_sourced_execution import ExecutionContractTests
mode=sys.argv[1] if len(sys.argv)>1 else 'ok'
case=ExecutionContractTests('test_selected_priority_effort_reach_actual_thread_turn_and_receipt')
case.setUp()
if mode=='empty':case.snapshot.update(selection_enabled=False,models=[])
turns=[]
case.text.observer=turns.append
try:
 for line in sys.stdin:
  try:
   d=json.loads(line);method=d['method'];params=d.get('params',{})
   if mode=='legacy' and method=='codex.research.capabilities.v1' and params:
    raise Fault('invalid_arguments')
   if method=='codex.research.status.v1':
    row=case.runtime.store.row('tisra',params['job_id'])
    if row['state']=='queued':case.execute()
   if method=='fixture.counts':
    row=case.runtime.store.db.execute('SELECT calls FROM budget').fetchone()
    value={'calls':0 if row is None else row[0],'turns':sum(e['event']=='turn_started' for e in turns)}
   else:value=case.rpc(method,params)
   if mode=='bad_receipt' and method=='codex.research.submit.v1' and 'execution_options' in value:
    value['execution_options']['thinking_effort']='high'
   reply={'ok':True,'result':value}
  except Fault as error:reply={'ok':False,'error':{'code':error.code}}
  except Exception:reply={'ok':False,'error':{'code':'fixture_failed'}}
  print(json.dumps(reply,separators=(',',':')),flush=True)
finally:
 case.runtime.control.close();case.runtime.service_portal.close();case.tearDown()
