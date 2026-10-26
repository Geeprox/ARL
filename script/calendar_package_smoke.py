"""Consume packaged code+signed native app only; effect is an explicit test double."""
import json,sys,tempfile,time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]/'integrations/apple_calendar'
sys.path.insert(0,str(ROOT/'dist/calendar-release-v2/code'))
from arl.calendar_review import CalendarPackage,ReviewGate,run_review
args={'operation_id':'ba69dd86-d9f3-4c6d-8490-c8dbce36525d','title':'synthetic package acceptance','start':'2026-10-03T10:00:00+08:00','end':'2026-10-03T10:05:00+08:00'}
p=CalendarPackage(ROOT/'dist/calendar-release-v2/ARLCalendarBridge.app',json.loads((ROOT/'dist/calendar-release-v2/calendar-package.json').read_text()))
with tempfile.TemporaryDirectory(prefix='arl-calendar-package-') as temp:
 called=[]
 def save(a):called.append(a);return {'schema_version':1,'operation_id':a['operation_id'],'persistence':'saved_local','cloud_sync':'not_checked'}
 receipt=run_review(p,ReviewGate(args,int(time.time()*1000)+120000),home=Path(temp),transport=save)
 assert receipt['state']=='succeeded' and len(called)==1
 print(json.dumps({'state':'passed','package_code_only':True,'real_signed_caller':True,'effect':'test_double','calendar_writes':0,'tcc_prompts':0,'installed_changes':False,'cdhash':p.manifest['cdhash']}))
