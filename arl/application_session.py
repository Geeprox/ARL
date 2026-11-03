"""Supported-app SDK lifecycle: discover, challenge/confirm, heartbeat, reconnect.

No application list, implicit app launch, OS permission or non-model tool grant.
A client must keep this session alive while its declared tasks are executing.
"""
from __future__ import annotations
import copy,threading,time,uuid
from .client import Client
from .contracts import Fault
from .application_platform import scenarios as validate_scenarios

class ApplicationSession:
    def __init__(self,home,app_id,name,scenarios=(),*,icon_ref='sf:app',version=None,icon=None,client_factory=Client):
        self.client=client_factory(home,app_id);self.name=name;self.icon_ref=icon_ref;self.version=version
        self.scenarios=validate_scenarios(list(scenarios));self.icon=copy.deepcopy(icon)
        self.connected=False;self.error=None;self.accepted=[]
        self._lock=threading.RLock();self._stop=threading.Event();self._thread=None
    def register(self):
        with self._lock:
            # Discovery uses the published read-only identity, not a task grant.
            Client(self.client.home,'settings').connect(timeout=5)
            self.accepted=self.client.open_app_session(self.name,('codex.text.plan.v1',) if self.scenarios else (),self.icon_ref,self.version,scenarios=self.scenarios)
            if self.icon is not None:
                self.client.rpc('application.icon.register.v1',{'schema_version':1,'session_id':self.client.app_session,'icon':self.icon})
            self.connected=True;self.error=None
            return list(self.accepted)
    def start(self):
        if self._thread is not None and self._thread.is_alive():return self
        self._stop.clear()
        def maintain():
            delay=0
            while not self._stop.wait(delay):
                try:
                    with self._lock:
                        if self.connected:self.client.ping_app_session()
                        else:self.register()
                    delay=10
                except (Fault,OSError) as error:
                    self.connected=False;self.error=getattr(error,'code','disconnected')
                    delay=min(30,2 if delay in (0,10) else delay*2)
        self._thread=threading.Thread(target=maintain,name='ARL application session',daemon=True);self._thread.start()
        return self
    def close(self):
        self._stop.set()
        if self._thread is not None:self._thread.join(timeout=6)
        with self._lock:
            try:self.client.close_app_session()
            except (Fault,OSError):pass
            self.connected=False
    def submit(self,scenario_id,text,*,request_id=None):
        with self._lock:
            if not self.connected:self.register()
            key=request_id or str(uuid.uuid4())
            return self.client.rpc('application.tasks.submit.v1',{'schema_version':1,'session_id':self.client.app_session,'scenario_id':scenario_id,'request_id':key,'input':text})
    def get(self,job_id):
        with self._lock:
            return self.client.rpc('application.tasks.get.v1',{'schema_version':1,'session_id':self.client.app_session,'job_id':job_id})
    def cancel(self,job_id):
        with self._lock:
            return self.client.rpc('application.tasks.cancel.v1',{'schema_version':1,'session_id':self.client.app_session,'job_id':job_id})
    def wait(self,job,*,timeout=180):
        deadline=time.monotonic()+timeout
        while job['state'] in {'queued','running'}:
            if time.monotonic()>=deadline:raise Fault('task_wait_timeout')
            if self._stop.wait(.2):raise Fault('application_session_closed')
            job=self.get(job['id'])
        return job
    def __enter__(self):self.register();self.start();return self
    def __exit__(self,*_):self.close()
