import time
from dataclasses import replace
from unittest.mock import patch
from arl.contracts import AppPolicy,Tool,object_schema
from arl.storage import Store
from arl.scheduling import MAX_PRIORITY_BYPASSES, resolve
from arl.service import default_policies
from tests.test_runtime import RuntimeCase,running
class SchedulingTests(RuntimeCase):
 def setUp(self):
  super().setUp();self.tool=Tool('test.read',object_schema(),lambda a,c:{'ok':True});self.policy=AppPolicy(frozenset({'test.read'}),priority_bands=frozenset({'background','explicit','interactive'}),methods=frozenset({'health','ready','submit_scheduled','get','cancel'}))
 def test_bands_fifo_aging_and_restart_persistence(self):
  s=Store(self.home/'s');ids=[]
  for band in ('background','explicit','interactive'):
   ids.append(s.submit('tisra',band,self.tool,{},self.policy,verified=True,schedule={'priority':band,'deadline_ms':60000})['id'])
  s.db.execute('UPDATE jobs SET created=? WHERE id=?',(time.time()-65,ids[0]));s.close();s=Store(self.home/'s')
  self.assertEqual(s.claim()['id'],ids[0]);self.assertEqual(s.claim()['id'],ids[2]);self.assertEqual(s.claim()['id'],ids[1]);s.close()
 def test_ungranted_interactive_and_deadline_rejected(self):
  p=replace(self.policy,priority_bands=frozenset({'background'}),default_priority='background')
  self.assert_fault('priority_not_authorized',lambda:resolve(p,{'priority':'interactive'}))
  for n in (True,0,60001):self.assert_fault('deadline_not_authorized',lambda:resolve(p,{'deadline_ms':n}))
  for requested in ([],False,0,'',{'extra':1}):
   self.assert_fault('invalid_arguments',lambda:resolve(p,requested))
 def test_expired_queued_job_never_executes_or_renews_on_reconnect(self):
  s=Store(self.home/'s');a=s.submit('tisra','same',self.tool,{},self.policy,verified=True,schedule={'priority':'background','deadline_ms':10})
  time.sleep(.02);b=s.submit('tisra','same',self.tool,{},self.policy,verified=True,schedule={'priority':'background','deadline_ms':10});self.assertEqual(a['id'],b['id']);self.assertIsNone(s.claim());self.assertEqual(s.get('tisra',a['id'])['error'],'deadline_exceeded');s.close()
 def test_new_wire_requires_identity_and_policy_not_claim(self):
  policies=default_policies();policies['tisra']=replace(self.policy,priority_bands=frozenset({'explicit'}))
  with running(self.home,policies=policies,extra_tools=[self.tool],identity_verifier=lambda c,a:'tisra' if a=='tisra' else None) as (r,c):
   params={'tool':'test.read','args':{},'key':'key','priority':'interactive','deadline_ms':1000}
   self.assert_fault('priority_not_authorized',lambda:c.rpc('submit_scheduled',params));params['priority']='explicit'
   self.assert_fault('app_identity_unverified',lambda:r.dispatch({'protocol':'arl/1','app':'tisra','method':'submit_scheduled','params':params}))
   job=c.rpc('submit_scheduled',params);self.assertEqual(c.wait(job['id'])['state'],'succeeded')

 def test_single_active_tool_nonpreemptible_read_deadline_then_interactive(self):
  import threading
  started=threading.Event();release=threading.Event();second=threading.Event()
  def slow(a,c):started.set();release.wait(2);return {'ok':True}
  tools=[Tool('test.read',object_schema(),slow),Tool('test.fast',object_schema(),lambda a,c:(second.set() or {'ok':True}))]
  p=replace(self.policy,tools=frozenset({'test.read','test.fast'}))
  with running(self.home,policies={'tisra':p},extra_tools=tools,identity_verifier=lambda c,a:'tisra') as (r,c):
   low=c.rpc('submit_scheduled',{'tool':'test.read','args':{},'key':'low','priority':'background','deadline_ms':30});self.assertTrue(started.wait(1))
   high=c.rpc('submit_scheduled',{'tool':'test.fast','args':{},'key':'high','priority':'interactive','deadline_ms':1000})
   time.sleep(.04);self.assertFalse(second.is_set());release.set()
   self.assertEqual(c.wait(low['id'])['error'],'deadline_exceeded');self.assertEqual(c.wait(high['id'])['state'],'succeeded')

 def enqueue(self,store,owner,key,band,created=1000):
  with patch('arl.storage.time.time',return_value=created):
   return store.submit(owner,key,self.tool,{},self.policy,verified=True,
    schedule={'priority':band,'deadline_ms':60000})['id']

 def claim_finished(self,store):
  row=store.claim()
  self.assertIsNotNone(row)
  store.finish(row,'succeeded',{'ok':True})
  return row

 def test_priority_then_bounded_service_for_another_app(self):
  with StoreContext(self.home/'fair') as store,patch('arl.storage.time.time',return_value=1000):
   low=self.enqueue(store,'quiet','background','background')
   high=sorted(self.enqueue(store,'busy',str(n),'interactive') for n in range(20))
   for job in high[:MAX_PRIORITY_BYPASSES]:
    self.assertEqual(self.claim_finished(store)['id'],job)
   self.assertEqual(self.claim_finished(store)['id'],low)
   self.assertEqual(self.claim_finished(store)['id'],high[MAX_PRIORITY_BYPASSES])

 def test_equal_priority_backlog_cannot_monopolize_apps(self):
  with StoreContext(self.home/'fifo') as store,patch('arl.storage.time.time',return_value=1000):
   old=sorted(self.enqueue(store,'busy',str(n),'interactive',999) for n in range(20))
   peer=self.enqueue(store,'peer','one','interactive')
   for job in old[:MAX_PRIORITY_BYPASSES]:
    self.assertEqual(self.claim_finished(store)['id'],job)
   self.assertEqual(self.claim_finished(store)['id'],peer)

 def test_overdue_fifo_survives_restart_and_new_interactive_app(self):
  path=self.home/'durable'
  store=Store(path)
  try:
   with patch('arl.storage.time.time',return_value=1000):
    first=self.enqueue(store,'first','one','background',999)
    second=self.enqueue(store,'second','one','background')
    for n in range(20):self.enqueue(store,'busy',str(n),'interactive')
    for n in range(MAX_PRIORITY_BYPASSES):
     self.assertEqual(self.claim_finished(store)['owner'],'busy')
     # The fairness clock cannot be reset by a service restart.
     store.close();store=Store(path)
    fresh=self.enqueue(store,'newcomer','fresh','interactive')
    self.assertEqual(self.claim_finished(store)['id'],first)
    self.assertEqual(self.claim_finished(store)['id'],second)
    self.assertEqual(store.get('newcomer',fresh)['state'],'queued')
  finally:store.close()

 def test_bound_under_continuous_arrivals_from_multiple_apps(self):
  with StoreContext(self.home/'arrival') as store,patch('arl.storage.time.time',return_value=1000):
   target=self.enqueue(store,'target','one','background')
   competing=4
   for n in range(competing-1):
    self.enqueue(store,'busy'+str(n),'first','interactive')
   claim_count=0
   while True:
    row=self.claim_finished(store)
    if row['id']==target:break
    claim_count+=1
    self.assertLessEqual(claim_count,MAX_PRIORITY_BYPASSES+competing-1)
    self.enqueue(store,row['owner'],'arrival'+str(claim_count),'interactive')
   self.assertLessEqual(claim_count,MAX_PRIORITY_BYPASSES+competing-1)

 def test_backoff_unlock_cancel_and_deadline_do_not_reserve_turns(self):
  with StoreContext(self.home/'eligibility') as store,patch('arl.storage.time.time',return_value=1000):
   deferred=self.enqueue(store,'deferred','one','background',999)
   unlocked=self.enqueue(store,'unlock','one','background')
   cancelled=self.enqueue(store,'cancel','one','background')
   expired=self.enqueue(store,'expired','one','background',939)
   for n in range(20):self.enqueue(store,'busy',str(n),'interactive')
   self.assertEqual(self.claim_finished(store)['owner'],'busy')
   store.db.execute('UPDATE jobs SET next_at=1002 WHERE id=?',(deferred,))
   store.set_state(unlocked,'needs_unlock')
   store.cancel('cancel',cancelled)
   for n in range(MAX_PRIORITY_BYPASSES):
    self.assertEqual(self.claim_finished(store)['owner'],'busy')
   self.assertEqual(store.get('expired',expired)['error'],'deadline_exceeded')
   self.assertEqual(store.get('cancel',cancelled)['state'],'cancelled')
   self.assertEqual(store.db.execute('SELECT COUNT(*) FROM scheduler_apps').fetchone()[0],0)
   store.db.execute('UPDATE jobs SET next_at=0 WHERE id=?',(deferred,))
   store.resume('unlock',unlocked)
   # Returning from ineligibility starts a fresh wait; it cannot jump priority.
   self.assertEqual(self.claim_finished(store)['owner'],'busy')
   for n in range(MAX_PRIORITY_BYPASSES-1):self.claim_finished(store)
   self.assertEqual(self.claim_finished(store)['id'],deferred)
   self.assertEqual(self.claim_finished(store)['id'],unlocked)

 def test_v3_store_adds_metadata_without_changing_jobs_or_deadlines(self):
  path=self.home/'migration'
  store=Store(path)
  job=self.enqueue(store,'quiet','same','explicit')
  deadline=store.row('quiet',job)['deadline_at']
  store.db.execute('DROP TABLE scheduler_apps')
  store.db.execute('DROP TABLE scheduler_state')
  store.close()
  with StoreContext(path) as store,patch('arl.storage.time.time',return_value=1000):
   self.assertEqual(store.db.execute('PRAGMA user_version').fetchone()[0],4)
   self.assertEqual(store.row('quiet',job)['deadline_at'],deadline)
   self.assertEqual(self.claim_finished(store)['id'],job)

 def test_failed_claim_rolls_back_job_and_fairness_counter_together(self):
  with StoreContext(self.home/'atomic') as store,patch('arl.storage.time.time',return_value=1000):
   low=self.enqueue(store,'quiet','one','background')
   for n in range(20):self.enqueue(store,'busy',str(n),'interactive')
   for n in range(MAX_PRIORITY_BYPASSES):self.claim_finished(store)
   with patch.object(store,'audit',side_effect=RuntimeError('synthetic failure')):
    with self.assertRaises(RuntimeError):store.claim()
   self.assertEqual(store.get('quiet',low)['state'],'queued')
   self.assertEqual(store.db.execute('SELECT dispatch_seq FROM scheduler_state').fetchone()[0],MAX_PRIORITY_BYPASSES)
   self.assertEqual(store.db.execute("SELECT waiting_since FROM scheduler_apps WHERE owner='quiet'").fetchone()[0],0)
   self.assertEqual(self.claim_finished(store)['id'],low)


class StoreContext:
 def __init__(self,path):self.store=Store(path)
 def __enter__(self):return self.store
 def __exit__(self,*args):self.store.close()
