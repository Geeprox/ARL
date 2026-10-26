"""Fixed Mio metadata probe. No provider query, tool execution, token or arbitrary URL."""
from __future__ import annotations
import json, os, stat, subprocess, sys, threading, time, urllib.parse, urllib.request
from pathlib import Path

HEALTH_FILE = Path.home()/'Library/Application Support/MioReadOnly/travel-tunnel/health-url.txt'

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *_args, **_kwargs): raise ValueError()

def probe_worker():
    try:
        fd=os.open(str(HEALTH_FILE),os.O_RDONLY|os.O_NOFOLLOW)
        try:
            s=os.fstat(fd)
            if not stat.S_ISREG(s.st_mode) or s.st_uid!=os.geteuid() or s.st_mode&0o077: raise ValueError()
            raw=os.read(fd,1025)
        finally: os.close(fd)
        if len(raw)>1024: raise ValueError()
        u=urllib.parse.urlsplit(raw.decode().strip())
        if u.scheme!='http' or u.hostname!='127.0.0.1' or not u.port or u.username or u.password or u.query or u.fragment or u.path not in ('','/'): raise ValueError()
        opener=urllib.request.build_opener(urllib.request.ProxyHandler({}),NoRedirect())
        result={}
        for route,word in (('healthz','live'),('readyz','ready')):
            try:
                with opener.open('http://127.0.0.1:'+str(u.port)+'/'+route,timeout=.75) as response:
                    body=response.read(257)
                    result[route]=word if response.status==200 and len(body)<=256 and body.decode().strip()==word else 'unknown'
            except Exception: result[route]='unavailable'
        print(json.dumps(result));return 0
    except Exception:
        print('{}');return 1

class MioMetadata:
    def __init__(self,runner=subprocess.run,clock=None,monotonic=time.monotonic):
        self.runner=runner;self.clock=clock or (lambda:int(time.time()*1000));self.monotonic=monotonic
        self.lock=threading.Lock();self.cached=None;self.cached_at=None
    def empty(self):
        return {'id':'mio.gateway','name':'Mio','checked_at_ms':None,'stale_after_ms':10000,
          'liveness':'unknown','readiness':'unknown','evidence':'local_client_health',
          'external_roundtrip':'not_checked','tool_publication':'not_checked','tool_count':None,
          'provider_readiness':'not_checked','error_code':None}
    def module(self):
        if not self.lock.acquire(blocking=False): return dict(self.cached or self.empty())
        try:
            now=self.monotonic()
            if self.cached_at is not None and now-self.cached_at<5: return dict(self.cached)
            result=self.empty();result['checked_at_ms']=self.clock()
            try:
                p=self.runner([sys.executable,'-I','-B',str(Path(__file__).resolve()),'--probe-worker'],
                    stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=2,
                    env={'PATH':'/usr/bin:/bin:/usr/sbin:/sbin'})
                if p.returncode or len(p.stdout)>4096: raise ValueError()
                data=json.loads(p.stdout)
                if type(data) is not dict: raise ValueError()
                result['liveness']=data.get('healthz') if data.get('healthz') in {'live','unavailable','unknown'} else 'unknown'
                result['readiness']=data.get('readyz') if data.get('readyz') in {'ready','unavailable','unknown'} else 'unknown'
            except subprocess.TimeoutExpired: result['error_code']='probe_deadline_exceeded'
            except Exception: result['error_code']='probe_unavailable'
            self.cached=result;self.cached_at=self.monotonic();return dict(result)
        finally:self.lock.release()
    def snapshot(self):
        return {'schema_version':1,'checked_at_ms':self.clock(),'modules':[self.module()]}

if __name__=='__main__':
    if sys.argv[1:]==['--probe-worker']:raise SystemExit(probe_worker())
    raise SystemExit(2)
