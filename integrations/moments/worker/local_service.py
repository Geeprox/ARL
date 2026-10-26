#!/usr/bin/env python3
"""Local SNS/WAL watcher, image queue and loopback viewer; no LLM or account API.

Never obtains keys, launches WeChat, clears stop markers, renews grants or retries
failed media. A pre-existing image-only grant is required for CDN downloads.
"""
import argparse
import contextlib
import datetime as dt
import errno
import fcntl
import hashlib
import json
import logging
from logging.handlers import RotatingFileHandler
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time

from async_media import Queue
from remote_bridge import Bridge
from image_integrity import audit, worker_running
from moments_backup import atomic_json, load_json, now

ROOT=Path(__file__).resolve().parent
TRANSIENT_CODES={'stable_source_pair_unavailable','source_changed_before_publish',
                 'contact_source_changed_before_publish'}


def source_fingerprint(config):
    """Only stat explicit DB/WAL inputs; never inspect processes or credentials."""
    if config.get('native_capture_manifest'):
        value=load_json(Path(config['native_capture_manifest']),{})
        if value.get('schema')!=1:raise FileNotFoundError('native_capture_not_ready')
        return value['fingerprint']
    result=[]
    for name in ('sns_db','contact_db'):
        if not config.get(name):continue
        base=Path(config[name])
        for path in (base,Path(str(base)+'-wal')):
            try:
                s=path.stat();result.append([s.st_dev,s.st_ino,s.st_size,s.st_mtime_ns,s.st_ctime_ns])
            except FileNotFoundError:
                if path==base:raise
                result.append(None)
    return hashlib.sha256(json.dumps(result).encode()).hexdigest()


def run_refresh(config):
    if config.get('native_capture_manifest'):
        # Native owner publishes immutable generations. Its exclusive lease
        # prevents pruning until this shared reader has finished exporting.
        with Path(config['native_capture_lock']).open('a') as lock:
            fcntl.flock(lock,fcntl.LOCK_SH)
            capture=load_json(Path(config['native_capture_manifest']),{})
            if capture.get('schema')!=1:raise RuntimeError('native_capture_not_ready')
            staged={k:v for k,v in config.items() if not k.startswith('native_capture_')}
            staged.update(sns_db=capture['sns_db'],contact_db=capture.get('contact_db'))
            return run_refresh(staged)
    args=[sys.executable,str(ROOT/'refresh_local.py'),'--sns-db',config['sns_db'],
          '--keys-file',config['keys_file'],'--output',config['output']]
    if config.get('contact_db'):args+=['--contact-db',config['contact_db']]
    # Output is a bounded public summary; never include raw stderr in logs.
    result=subprocess.run(args,capture_output=True,text=True,timeout=180)
    try:report=json.loads(result.stdout.strip().splitlines()[-1])
    except (ValueError,IndexError):
        if 'PermissionError' in result.stderr or 'Operation not permitted' in result.stderr:
            raise RuntimeError('source_access_denied_by_macos') from None
        if 'ModuleNotFoundError' in result.stderr:
            raise RuntimeError('refresh_dependency_unavailable') from None
        raise RuntimeError('refresh_process_failed') from None
    if result.returncode or report.get('status')!='ok':
        code=report.get('error_code','refresh_process_failed')
        raise RuntimeError(code if isinstance(code,str) and code.replace('_','').isalnum() else 'refresh_process_failed')
    return report


class Service:
    def __init__(self,config,*,refresh_runner=run_refresh,clock=time.monotonic):
        self.config=config;self.output=Path(config['output']).resolve()
        self.output.mkdir(parents=True,exist_ok=True)
        self.queue=Queue(self.output);self.refresh_runner=refresh_runner;self.clock=clock
        self.status=load_json(self.output/'local-service-status.json',{})
        self.status.update(pid=os.getpid(),started_at=now(),phase='starting',uses_llm=False,
            uses_wx_cli=False,account_network_requests=0,video_downloads_permitted=False,
            poll_seconds=config.get('poll_seconds',5),refresh_min_seconds=config.get('refresh_min_seconds',30),
            scope='current_mac_local_cache_only')
        self.last_source=None;self.pending_source=None;self.changed_at=None
        self.started_wall=time.time()
        self.last_refresh=-float('inf');self.server=None;self.stopping=threading.Event()
        self.local_pause=False;self.last_audit=None;self.manual_refresh=False
        self.bridge=Bridge(config["bridge_home"],self) if config.get("bridge_home") else None
        private=self.output/'private';private.mkdir(mode=0o700,exist_ok=True)
        self.logger=logging.getLogger('moments.local.'+str(id(self)));self.logger.setLevel(logging.INFO)
        h=RotatingFileHandler(private/'local-service.log',maxBytes=1024*1024,backupCount=2)
        os.chmod(private/'local-service.log',0o600);self.logger.addHandler(h)

    def event(self,name,**fields):
        self.logger.info(json.dumps({'at':now(),'event':name,**fields},ensure_ascii=False))

    def checkpoint(self,phase,**fields):
        self.status.update(phase=phase,checked_at=now(),**fields)
        atomic_json(self.output/'local-service-status.json',self.status)

    def collection_blocked(self):
        return "local_stop_requested" if (self.output/".local-service.stop").exists() else None

    def blocked(self):
        q=self.queue._edit()
        if q.get('halted'):return q.get('error_code') or 'image_queue_halted'
        if (self.output/'.local-service.stop').exists():return 'local_stop_requested'
        if self.queue._global_stop():return 'image_authorization_or_global_stop'
        return None

    def enqueue(self):
        doc=load_json(self.output/'moments.json',{'posts':[]});ids=[]
        for p in sorted(doc['posts'],key=lambda p:p.get('created_at_unix') or 0,reverse=True):
            ids.extend(m['asset_id'] for m in p.get('media',[]) if str(m.get('type'))=='2'
                       and m.get('backup_status') in ('missing','locator_only_not_downloaded'))
            for c in p.get('comments',{}).get('items') or []:
                ids.extend(m['asset_id'] for m in c.get('media',[]) if m.get('type')=='comment_emoji'
                           and m.get('backup_status')=='missing')
        accepted=0
        for start in range(0,len(ids),10000):
            result=self.queue.submit(ids[start:start+10000]);accepted+=len(result['accepted'])
        return accepted

    def refresh(self,fingerprint):
        # Match downloader/auditor lock order: media then backup (in exporter).
        # Avoid starving an active download; defer to a later local tick.
        with (self.output/'.media.lock').open('a') as lock:
            try:fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
            except BlockingIOError:return False
            if self.collection_blocked():return False
            self.last_refresh=self.clock()
            try:report=self.refresh_runner(self.config)
            except Exception as error:
                code=str(error) if isinstance(error,RuntimeError) else type(error).__name__
                if code not in TRANSIENT_CODES:self.local_pause=True
                if self.bridge:self.bridge.complete(error=code)
                self.manual_refresh=False
                self.event('refresh_failed',error_code=code)
                self.checkpoint('waiting_for_stable_source' if code in TRANSIENT_CODES else 'paused',error_code=code)
                return False
        self.last_source=fingerprint;self.pending_source=None;self.manual_refresh=False
        if self.bridge:self.bridge.complete(report=report)
        accepted=self.enqueue()
        self.status.update(last_success_at=report['at'],last_refresh=report,
                           latest_post_at=report['latest_post_at'],posts=report['posts_after'],
                           new_posts=report['new_posts'],last_images_enqueued=accepted,error_code=None)
        self.event('refreshed',posts=report['posts_after'],new_posts=report['new_posts'],images_enqueued=accepted)
        return True

    def request_refresh(self):
        if self.collection_blocked():return {"error_code":"local_stop_requested"}
        if self.config.get("bridge_home"):
            import uuid
            identity=str(uuid.uuid4())
            atomic_json(Path(self.config["bridge_home"])/"manual-refresh.json",{"id":identity,"created_at":now(),"kind":"refresh"})
        else:self.manual_refresh=True
        return {"accepted":True,"scope":"mac_local_cache"}

    def viewer(self):
        if self.server is not None:return
        from http.server import ThreadingHTTPServer
        import viewer_server
        viewer_server.ROOT=self.output.parent
        from viewer_server import Handler
        try:self.server=ThreadingHTTPServer(('127.0.0.1',self.config.get('viewer_port',8791)),Handler)
        except OSError as error:
            if error.errno==errno.EADDRINUSE:self.status['viewer']='existing_listener';return
            self.status['viewer']='unavailable';return
        self.server.media_queue=self.queue
        self.server.refresh_callback=self.request_refresh
        # Avoid unbounded per-image request logs in launchd's stderr file.
        self.server.RequestHandlerClass=type('QuietHandler',(Handler,),{'log_message':lambda *args:None})
        threading.Thread(target=self.server.serve_forever,daemon=True).start()
        self.status['viewer']='running'

    def terminal_audit(self):
        q=self.queue._edit()
        pending=any(x.get('status') in ('queued','attempted','downloading') for x in q['assets'].values())
        if pending and not q.get('halted'):return
        raw=(self.output/'moments.json').read_bytes()
        signature=(hashlib.sha256(raw).hexdigest(),q.get('error_code'),q.get('halted'))
        if signature==self.last_audit:return
        report=audit(self.output,final=True);self.last_audit=signature
        self.status.update(image_audit_phase=report['phase'],image_audit_at=report['checked_at'],
                           image_audit_ready=report['verified_ready_references'],image_audit_issues=report['issues_count'])
        self.event('image_audit',phase=report['phase'],ready=report['verified_ready_references'],issues=report['issues_count'])

    def tick(self,*,execute_images=True):
        # The existing archive remains viewable even when a source permission
        # or risk stop prevents collection. Serving local files is offline.
        self.viewer()
        q=self.queue._edit();counts={}
        for a in q['assets'].values():counts[a['status']]=counts.get(a['status'],0)+1
        self.status['image_counts']=counts
        if self.bridge:self.bridge.poll()
        reason=self.collection_blocked()
        if reason:
            self.checkpoint("paused",error_code=reason)
            if self.bridge:self.bridge.publish()
            return
        if self.config.get('native_capture_manifest'):self.local_pause=False
        if not self.local_pause:
            try:
                if self.last_source is None and self.config.get('native_capture_manifest'):
                    capture=load_json(Path(self.config['native_capture_manifest']),{})
                    stamp=dt.datetime.fromisoformat(capture.get('captured_at','1970-01-01T00:00:00Z').replace('Z','+00:00')).timestamp()
                    if stamp<self.started_wall-5:raise FileNotFoundError('waiting_for_native_capture')
                fingerprint=source_fingerprint(self.config)
            except OSError as error:
                self.local_pause=True;self.checkpoint('source_paused',error_code='source_'+type(error).__name__)
            else:
                t=self.clock()
                if (self.last_source is None or self.manual_refresh) and t-self.last_refresh>=self.config.get('refresh_min_seconds',30):
                    self.refresh(fingerprint)
                elif self.last_source is not None and fingerprint!=self.last_source:
                    if fingerprint!=self.pending_source:self.pending_source=fingerprint;self.changed_at=t
                    quiet=t-self.changed_at>=self.config.get('quiet_seconds',5)
                    overdue=t-self.last_refresh>=self.config.get('max_defer_seconds',120)
                    if t-self.last_refresh>=self.config.get('refresh_min_seconds',30) and (quiet or overdue):self.refresh(fingerprint)
        if self.stopping.is_set():return
        if self.blocked():
            self.checkpoint('watching_downloads_paused',error_code=self.blocked())
            if self.bridge:self.bridge.publish()
            return
        if execute_images and self.config.get('images_enabled') and not worker_running(self.output):
            self.queue.start(execute=True)
        # Full NAS hash/decode audit is an explicit offline job. Never hold
        # the media lease for a full library scan in the interactive collector.
        q=self.queue._edit();counts={}
        for a in q['assets'].values():counts[a['status']]=counts.get(a['status'],0)+1
        phase=('source_paused' if self.local_pause else
               'waiting_for_stable_source' if self.status.get('error_code') in TRANSIENT_CODES else 'watching')
        self.checkpoint(phase,image_counts=counts,image_worker_running=worker_running(self.output),
                        source_fingerprint=self.last_source)
        if self.bridge:self.bridge.publish()

    def watch_owner(self):
        owner=self.config.get('owner_pid')
        if type(owner) is not int or owner<=1:return
        while not self.stopping.wait(.5):
            if os.getppid()!=owner:
                # Reparenting cannot be confused with PID reuse. Stop future
                # network exchanges immediately, then drain the active one.
                self.queue.request_stop();self.stopping.set();return

    def close(self):
        self.stopping.set();self.queue.close()
        if self.server:self.server.shutdown();self.server.server_close()
        self.checkpoint('stopped')
        for handler in self.logger.handlers[:]:handler.close();self.logger.removeHandler(handler)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config',type=Path,required=True)
    parser.add_argument('--once',action='store_true',help='One local-only refresh; never starts an image download')
    args=parser.parse_args();config=json.loads(args.config.read_text())
    output=Path(config['output']);output.mkdir(parents=True,exist_ok=True)
    with (output/'.local-service.lock').open('a') as lease:
        owner=config.get('owner_pid')
        deadline=time.monotonic()+200 if type(owner) is int and owner>1 else 0
        while True:
            if type(owner) is int and os.getppid()!=owner:return
            try:
                fcntl.flock(lease,fcntl.LOCK_EX|fcntl.LOCK_NB);break
            except BlockingIOError:
                if time.monotonic()>=deadline:raise SystemExit('local_service_already_running')
                time.sleep(.25)
        service=Service(config)
        def stop(*_):service.stopping.set()
        signal.signal(signal.SIGINT,stop);signal.signal(signal.SIGTERM,stop)
        threading.Thread(target=service.watch_owner,daemon=True).start()
        try:
            while not service.stopping.is_set():
                try:service.tick(execute_images=not args.once)
                except Exception as error:
                    service.local_pause=True;service.checkpoint('paused',error_code='local_'+type(error).__name__)
                    service.event('local_error',error_type=type(error).__name__)
                if args.once:break
                service.stopping.wait(config.get('poll_seconds',5))
        finally:service.close()


if __name__=='__main__':main()
