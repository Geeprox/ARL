"""Explicitly enabled, serial image queue. No login, scheduler or automatic retry.

Queue(output).submit(ids) is offline. Only start(execute=True) permits requests.
Signed locators are resolved from the private file at execution and never queued.
"""
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import socket
import ssl
import tempfile
import threading
import time
import urllib.error
import urllib.request

from media_backup import MAX_BYTES, existing_valid, image_format, locator_url
from moments_backup import atomic_json, encoded, load_json, now


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def fetch_once(locator):
    """Exactly one HTTP exchange: no redirects, alternate variant or retry."""
    url = locator_url(locator, 'url')
    request = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0',
                                                 'Accept-Encoding': 'identity'})
    opener = urllib.request.build_opener(NoRedirect())
    with opener.open(request, timeout=15) as response:
        if response.status != 200:raise ValueError('unexpected_http_status')
        data = response.read(MAX_BYTES + 1)
        if len(data) > MAX_BYTES:raise ValueError('too_large')
        expected = response.headers.get('Content-Length')
        if expected is not None and (not expected.isdigit() or int(expected) != len(data)):
            raise ValueError('incomplete_download')
        fmt = image_format(data)
        key = locator.get('attrs', {}).get('url', {}).get('key')
        if not fmt and key is not None and str(key).isdigit() and int(key) != 0:
            from sns_crypto import decrypt_image
            data = decrypt_image(data, key)
            fmt = image_format(data)
        if not fmt:raise ValueError('not_supported_image_bytes')
        return data, fmt


def request_locator(locator):
    """Pick one permitted image variant before any request, never retry it.

    Some old share-card media.url values are web pages. Their explicit thumb
    is the image source; it remains thumbnail_only in the public archive.
    """
    try:
        locator_url(locator,'url')
        return locator,'url'
    except (ValueError,KeyError):
        candidate={**locator,'url':locator.get('thumb'),'attrs':{'url':locator.get('attrs',{}).get('thumb',{})}}
        locator_url(candidate,'url')
        return candidate,'thumb'


def _safe_path(value):
    if not isinstance(value, str):return None
    path = Path(value)
    return value if path.parts and path.parts[0]=='media' and path.suffix.lower() in ('.jpg','.jpeg','.png','.gif','.webp') and not path.is_absolute() and '..' not in path.parts else None


def _valid_existing(output, record):
    relative = _safe_path(record.get('local_path'))
    if relative is None or not (output / relative).resolve().is_relative_to(output):
        return False
    return existing_valid(output, record)


def _referenced(output):
    document = load_json(output / 'moments.json', {'posts': []})
    result = set()
    for post in document.get('posts', []):
        for item in post.get('media', []) + post.get('finder', {}).get('media', []):
            if str(item.get('type')) == '2' and isinstance(item.get('asset_id'), str):
                result.add(item['asset_id'])
        for comment in post.get('comments',{}).get('items') or []:
            for item in comment.get('media',[]):
                if item.get('type')=='comment_emoji' and isinstance(item.get('asset_id'),str):
                    result.add(item['asset_id'])
    return result


def _write_image(output, data, fmt):
    if fmt not in ('jpg', 'png', 'gif', 'webp') or image_format(data) != fmt:
        raise ValueError('not_supported_image_bytes')
    sha = hashlib.sha256(data).hexdigest()
    directory = output / 'media'
    if directory.is_symlink():raise ValueError('unsafe_media_directory')
    directory.mkdir(mode=0o700, exist_ok=True)
    relative = 'media/' + sha + '.' + fmt
    target = output / relative
    if target.is_symlink():raise ValueError('unsafe_media_file')
    if not target.exists() or hashlib.sha256(target.read_bytes()).hexdigest() != sha:
        fd, temporary = tempfile.mkstemp(prefix='.image-', dir=directory)
        try:
            os.fchmod(fd, 0o600)
            with os.fdopen(fd, 'wb') as stream:
                stream.write(data);stream.flush();os.fsync(stream.fileno())
            os.replace(temporary, target)
        finally:
            if os.path.exists(temporary):os.unlink(temporary)
    return {'status': 'downloaded', 'local_path': relative, 'sha256': sha,
            'bytes': len(data), 'format': fmt, 'source_variant': 'url',
            'last_attempt_at': now(), 'error_code': None}


def _publish_asset(output, asset_id, item):
    """Caller holds media lock. Merge just this asset into the latest export."""
    with (output / '.backup.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        document = load_json(output / 'moments.json', None)
        if document is None:raise ValueError('missing_moments_export')
        allowed = ('local_path', 'sha256', 'bytes', 'format', 'source_variant', 'error_code','width','height','verification')
        for post in document.get('posts', []):
            comments=[m for c in (post.get('comments',{}).get('items') or []) for m in c.get('media',[])]
            for media in post.get('media', []) + comments:
                if media.get('asset_id') == asset_id and str(media.get('type')) in ('2','comment_emoji'):
                    media.update({key: item[key] for key in allowed if key in item})
                    media['backup_status'] = item['status']
        # Existing coverage counts concern ordinary post media, matching export.
        all_media = [m for p in document.get('posts', []) for m in p.get('media', [])]
        counts = {}
        for media in all_media:
            status = media.get('backup_status', 'unknown')
            counts[status] = counts.get(status, 0) + 1
        coverage = document.setdefault('coverage', {})
        coverage.update(media_assets=len(all_media), media_downloaded=counts.get('downloaded', 0),
                        media_thumbnail_only=counts.get('thumbnail_only', 0))
        coverage['media_bytes_backed_up'] = bool(all_media) and counts.get('downloaded', 0) == len(all_media)
        document['media_updated_at'] = now()
        atomic_json(output / 'moments.json', document)
        manifest = load_json(output / 'manifest.json', {})
        manifest.update(media_backup_counts=counts,
                        moments_sha256=hashlib.sha256(encoded(document)).hexdigest(),
                        media_updated_at=now())
        atomic_json(output / 'manifest.json', manifest)


class Queue:
    def __init__(self, output):
        self.output = Path(output).resolve()
        self.output.mkdir(parents=True, exist_ok=True)
        self.path = self.output / 'image-queue.json'
        self._mutex = threading.RLock()
        self._stop = threading.Event()
        self._wake = threading.Event()
        self._thread = None
        self._enabled = False
        self._stage = 'idle'

    def _edit(self, change=None):
        with self._mutex, (self.output / '.image-queue.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            data = load_json(self.path, {'schema_version': 1, 'assets': {}, 'halted': False,
                                         'error_code': None, 'network_attempts': 0,
                                         'next_request_at': 0})
            if data.get('schema_version') != 1 or not isinstance(data.get('assets'), dict):
                raise ValueError('invalid_image_queue')
            if change is not None:
                change(data);data['updated_at'] = now();atomic_json(self.path, data)
            return data

    def _halt(self, code, risk=False):
        (self.output / 'private/image-resume.json').unlink(missing_ok=True)
        def change(data):
            data.update(halted=True, error_code=code, risk_control_suspected=bool(risk))
        self._edit(change);self._stage = 'halted'
        # Shared stop sentinel prevents another media batch starting after a
        # queue failure. It contains no diagnostic or private locator bytes.
        descriptor = os.open(self.output / '.video-batch.stop', os.O_CREAT | os.O_WRONLY, 0o600)
        os.close(descriptor)

    def _global_stop(self):
        if (self.output / '.video-batch.stop').exists() and not self._image_resume_grant():
            return 'global_stop_requested'
        if load_json(self.output / 'video-batch.json', {}).get('halted'):
            return 'video_batch_halted'
        return None

    def _stop_fingerprint(self):
        path=self.output / '.video-batch.stop'
        if path.is_symlink():return None
        try:
            stat=path.stat()
            return {'device':stat.st_dev,'inode':stat.st_ino,'mtime_ns':stat.st_mtime_ns,'bytes':stat.st_size}
        except FileNotFoundError:return None

    def _image_resume_grant(self):
        grant=load_json(self.output / 'private/image-resume.json', {})
        risk=load_json(self.output.parent / 'risk-stop.json', {})
        if (grant.get('scope') in (['ordinary_images'],['ordinary_images','comment_emoji']) and risk.get('image_downloads_permitted') is True
                and grant.get('stop_fingerprint')==self._stop_fingerprint()
                and grant.get('stop_fingerprint') is not None):
            return grant
        return None

    def authorize_comment_images(self, *, user_authorized=False):
        if user_authorized is not True:raise ValueError('explicit_comment_image_authorization_required')
        grant=self._image_resume_grant()
        if not grant or self._edit().get('halted'):raise ValueError('current_image_authorization_required')
        grant.update(scope=['ordinary_images','comment_emoji'],comment_images_authorized_at=now())
        atomic_json(self.output / 'private/image-resume.json',grant)
        risk=load_json(self.output.parent / 'risk-stop.json',{})
        risk.update(network_download_scope=grant['scope'],comment_images_authorized_at=grant['comment_images_authorized_at'])
        atomic_json(self.output.parent / 'risk-stop.json',risk)
        return grant

    def authorize_image_resume(self, *, user_authorized=False, reviewed_asset_failure=None,
                               skip_resource_errors=False, reviewed_asset_failures=None):
        """Explicit image-only grant; video/account global stop remains in place."""
        if user_authorized is not True:raise ValueError('explicit_image_resume_authorization_required')
        data=self._edit()
        reviewed = None
        if reviewed_asset_failures is not None:
            failed={key for key,item in data['assets'].items() if item.get('status')=='failed'}
            if (not data.get('halted') or not skip_resource_errors or data.get('risk_control_suspected')
                or data.get('error_code')!='repeated_resource_http_errors'
                or not isinstance(reviewed_asset_failures,list) or not 3<=len(reviewed_asset_failures)<=100
                or set(reviewed_asset_failures)!=failed
                or any(data['assets'][key].get('error_code') not in ('http_400','http_404','http_410') for key in failed)):
                raise ValueError('reviewed_resource_failures_do_not_match_current_stop')
            reviewed={'asset_ids':sorted(failed),'error_code':'repeated_resource_http_errors',
                      'reviewed_at':now(),'action':'retain_failures_without_retry',
                      'cause_confirmed':False,'explicit_resume_authorized':True}
        elif reviewed_asset_failure is not None:
            item=data['assets'].get(reviewed_asset_failure,{})
            if (not data.get('halted') or not skip_resource_errors or data.get('risk_control_suspected')
                    or data.get('error_code')!='http_400' or item.get('status')!='failed'
                    or item.get('error_code')!='http_400'):
                raise ValueError('reviewed_resource_failure_does_not_match_current_stop')
            reviewed={'asset_id':reviewed_asset_failure,'error_code':'http_400',
                      'reviewed_at':now(),'action':'retain_failure_without_retry'}
        elif data.get('error_code') not in ('user_reported_account_logout_risk_suspected','global_stop_requested'):
            raise ValueError('image_resume_requires_review_of_current_stop')
        if any(item.get('status')=='attempted' for item in data['assets'].values()):
            raise ValueError('interrupted_attempt_requires_separate_review')
        fingerprint=self._stop_fingerprint()
        if fingerprint is None:raise ValueError('expected_global_stop_missing')
        grant={'scope':['ordinary_images'],'authorized_at':now(),'stop_fingerprint':fingerprint,
               'min_interval_seconds':30,'cooldown_every':10,'cooldown_seconds':120,
               'failed_asset_retries_permitted':False,'account_operations_permitted':False}
        if skip_resource_errors:
            grant.update(skip_resource_http_codes=[400,404,410],resource_failure_streak_limit=3)
        if reviewed:grant['reviewed_resource_failure']=reviewed
        risk=load_json(self.output.parent / 'risk-stop.json', {})
        risk.update(status='images_only_authorized',image_downloads_permitted=True,
                    video_downloads_permitted=False,account_operations_permitted=False,
                    network_downloads_permitted=True,network_download_scope=['ordinary_images'],
                    image_queue_halted=False,
                    image_resume_authorized_at=grant['authorized_at'],global_stop_present=True)
        atomic_json(self.output.parent / 'risk-stop.json',risk)
        atomic_json(self.output / 'private/image-resume.json',grant)
        def resume(queue):
            if reviewed:queue.setdefault('reviewed_stops',[]).append(reviewed)
            queue.update(halted=False,error_code=None,risk_control_suspected=False,
                         consecutive_resource_failures=0,resumed_at=grant['authorized_at'],
                         next_request_at=max(queue.get('next_request_at',0),time.time()+30))
        self._edit(resume)
        return grant

    def _request_finished(self, queue, *, resource_failure=False):
        grant=self._image_resume_grant()
        interval,cooldown=(30,120) if grant else (15,60)
        queue['next_request_at']=time.time()+(cooldown if queue['network_attempts']%10==0 else interval)
        queue['consecutive_resource_failures']=(queue.get('consecutive_resource_failures',0)+1
                                                if resource_failure else 0)

    def submit(self, asset_ids, *, priority=False):
        if not isinstance(asset_ids, list) or len(asset_ids) > 10000:
            raise ValueError('asset_ids_array_limit_10000')
        if type(priority) is not bool:raise ValueError('priority_must_be_boolean')
        # IDs are identifiers, never client-supplied locators or paths.
        if any(not isinstance(x, str) or re.fullmatch(r'[A-Za-z0-9:_-]{1,200}', x) is None
               for x in asset_ids):
            raise ValueError('invalid_asset_id')
        referenced = _referenced(self.output)
        locators = load_json(self.output / 'private/locators.json', {}).get('assets', {})
        state = load_json(self.output / 'media-state.json', {'assets': {}})['assets']
        # Hash existing files outside the queue mutex. The worker independently
        # revalidates after acquiring the shared media lock before any request.
        valid_ids = {asset for asset in dict.fromkeys(asset_ids)
                     if _valid_existing(self.output, state.get(asset, {}))}
        result = {'accepted': [], 'already': [], 'rejected': []}
        def update(data):
            order = data.setdefault('order', list(data['assets']))
            for asset in dict.fromkeys(asset_ids):
                code = None
                previous = state.get(asset, {})
                entry = data['assets'].get(asset)
                if data['halted']:code = 'queue_halted'
                elif asset not in referenced:code = 'not_referenced_image'
                elif entry and entry.get('status') in ('failed', 'unsupported'):
                    code = 'previous_attempt_not_retryable'
                elif entry:
                    result['already'].append(asset);continue
                elif previous.get('status') in ('failed', 'unsupported'):
                    code = 'previous_attempt_not_retryable'
                elif asset in valid_ids:
                    data['assets'][asset] = {'status': 'skipped', 'updated_at': now()}
                    result['already'].append(asset);continue
                else:
                    locator = locators.get(asset, {})
                    if locator.get('kind')=='comment_emoji':
                        grant=self._image_resume_grant()
                        if not grant or 'comment_emoji' not in grant['scope']:code='comment_images_not_authorized'
                        else:
                            from comment_media import comment_locator
                            try:comment_locator(locator)
                            except ValueError:code='unsupported_comment_image_locator'
                    elif str(locator.get('kind')) != '2':code = 'not_image_locator'
                    else:
                        try:request_locator(locator)
                        except Exception:code = 'unsupported_image_locator'
                if code:
                    result['rejected'].append({'asset_id': asset, 'error_code': code});continue
                data['assets'][asset] = {'status': 'queued', 'submitted_at': now(), 'updated_at': now()}
                order.append(asset)
                result['accepted'].append(asset)
            if priority:
                promoted = [asset for asset in dict.fromkeys(asset_ids)
                            if data['assets'].get(asset, {}).get('status') == 'queued']
                selected = set(promoted)
                data['order'] = promoted + [asset for asset in order if asset not in selected]
        self._edit(update);self._wake.set()
        return result

    def start(self, *, execute=False):
        if execute is not True:return self.snapshot()
        with self._mutex:
            if self._stop.is_set():raise ValueError('queue_closed')
            if not (self._thread and self._thread.is_alive()):
                self._enabled = True
                self._thread = threading.Thread(target=self._worker, name='moments-image-queue', daemon=True)
                self._thread.start()
        return self.snapshot()

    def snapshot(self):
        data = self._edit()
        states = load_json(self.output / 'media-state.json', {'assets': {}}).get('assets', {})
        assets = {};counts = {key: 0 for key in ('queued', 'downloaded', 'failed', 'unsupported', 'skipped')}
        for asset, record in data['assets'].items():
            status = record.get('status', 'queued')
            if status == 'attempted':status = 'downloading'
            counts['queued' if status == 'downloading' else status] = counts.get('queued' if status == 'downloading' else status, 0) + 1
            safe = {'status': status}
            path = _safe_path(states.get(asset, {}).get('local_path'))
            if (path and (self.output / path).resolve().is_relative_to(self.output)
                    and status in ('downloaded', 'skipped')):
                safe['local_path'] = path
                safe['backup_status'] = states.get(asset,{}).get('status',status)
            if record.get('error_code'):safe['error_code'] = record['error_code']
            assets[asset] = safe
        return {'enabled': self._enabled and not self._stop.is_set(), 'halted': bool(data['halted']),
                'error_code': data.get('error_code'), 'stage': 'halted' if data['halted'] else self._stage,
                'counts': counts, 'assets': assets, 'network_attempts': data.get('network_attempts', 0),
                'risk_control_suspected': bool(data.get('risk_control_suspected'))}

    def request_stop(self):
        self._stop.set();self._wake.set()

    def close(self, timeout=20):
        self.request_stop()
        if self._thread and self._thread is not threading.current_thread():self._thread.join(timeout)
        self._enabled = False

    def _worker(self):
        try:
            # A process-wide worker lease prevents restart instances racing the
            # persistent queue. Media lock remains shared with video/exporters.
            with (self.output / '.image-worker.lock').open('a') as lease:
                try:fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    self._stage = 'waiting_for_lock';return
                interrupted = self._edit()
                if any(item.get('status') == 'attempted' for item in interrupted['assets'].values()):
                    def failed(queue):
                        for item in queue['assets'].values():
                            if item.get('status') == 'attempted':
                                item.update(status='failed', error_code='interrupted_image_attempt', updated_at=now())
                    self._edit(failed);self._halt('interrupted_image_attempt');return
                while not self._stop.is_set():
                    data = self._edit()
                    if data['halted']:return
                    code = self._global_stop()
                    if code:self._halt(code);return
                    if (self.output / '.video-pipeline.active').exists():
                        self._stage = 'waiting_for_videos';self._stop.wait(0.5);continue
                    if not any(v['status'] in ('queued', 'downloading') for v in data['assets'].values()):
                        self._stage = 'idle';self._wake.wait(0.5);self._wake.clear();continue
                    video_end=load_json(self.output/'video-batch.json',{}).get('finished_at')
                    try:video_ready=dt.datetime.fromisoformat(video_end.replace('Z','+00:00')).timestamp()+15 if video_end else 0
                    except (TypeError,ValueError,AttributeError):video_ready=0
                    ready_at=max(data.get('next_request_at',0),video_ready)
                    if time.time()<ready_at:
                        self._stage='cooldown';self._stop.wait(min(0.5,ready_at-time.time()));continue
                    with (self.output / '.media.lock').open('a') as lock:
                        try:fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        except BlockingIOError:
                            self._stage = 'waiting_for_lock';self._stop.wait(0.5);continue
                        if self._stop.is_set():break
                        code = self._global_stop()
                        if code:self._halt(code);return
                        if (self.output / '.video-pipeline.active').exists():continue
                        self._process_locked()
        except Exception:
            # Errors may carry signed locators: persist a fixed local code only.
            self._halt('local_queue_error')
        finally:
            self._enabled = False
            if self._stage != 'halted':self._stage = 'idle'

    def _process_locked(self):
        data = self._edit()
        if data['halted']:return
        order = data.get('order', list(data['assets']))
        asset = next((key for key in order if data['assets'].get(key, {}).get('status')
                      in ('queued', 'downloading')), None)
        if asset is None:return
        state = load_json(self.output / 'media-state.json', {'schema_version': 1, 'assets': {}})
        previous = state['assets'].get(asset, {})
        def mark(status, error=None):
            def change(queue):
                queue['assets'][asset].update(status=status, updated_at=now())
                if error:queue['assets'][asset]['error_code'] = error
            self._edit(change)
        if _valid_existing(self.output, previous):mark('skipped');return
        if previous.get('status') in ('failed', 'unsupported'):
            mark('unsupported', 'previous_attempt_not_retryable');return
        try:
            if asset not in _referenced(self.output):raise ValueError('not_referenced_image')
            locator = load_json(self.output / 'private/locators.json', {})['assets'][asset]
            comment_image=locator.get('kind')=='comment_emoji'
            if comment_image:
                grant=self._image_resume_grant()
                if not grant or 'comment_emoji' not in grant['scope']:raise ValueError('comment_images_not_authorized')
                from comment_media import comment_locator,fetch_comment_once
                selected,variant=comment_locator(locator),'comment_url'
                existing=next((record for record in state['assets'].values()
                    if record.get('verified_md5')==selected['expected_md5'] and _valid_existing(self.output,record)),None)
                if existing:
                    state['assets'][asset]=dict(existing);atomic_json(self.output/'media-state.json',state)
                    _publish_asset(self.output,asset,existing);mark('downloaded');return
            else:
                if str(locator.get('kind')) != '2':raise ValueError('not_image_locator')
                selected,variant=request_locator(locator)
            # Recheck immediately before committing a network attempt; submit,
            # filesystem reads, or validation may have overlapped a stop.
            if self._stop.is_set():return
            stop_code = self._global_stop()
            if stop_code:self._halt(stop_code);return
            if (self.output / '.video-pipeline.active').exists():return
            self._stage = 'downloading';mark('downloading')
            def attempting(queue):
                queue['network_attempts'] += 1
                # Interrupted requests are not retried after restarting Queue.
                queue['assets'][asset]['status'] = 'attempted'
            self._edit(attempting)
            if comment_image:raw,fmt,metadata=fetch_comment_once(selected)
            else:raw,fmt=fetch_once(selected);metadata={}
            item = _write_image(self.output, raw, fmt)
            item.update(status='thumbnail_only' if variant=='thumb' else 'downloaded',source_variant=variant,**metadata)
            item['locator_sha256'] = hashlib.sha256(json.dumps(locator, sort_keys=True).encode()).hexdigest()
            state['assets'][asset] = item;state['updated_at'] = now()
            atomic_json(self.output / 'media-state.json', state)
            _publish_asset(self.output, asset, item)
            def completed(queue):
                queue['assets'][asset].update(status='downloaded', updated_at=now())
                self._request_finished(queue)
            self._edit(completed)
        except Exception as error:
            code = ('http_' + str(error.code)) if isinstance(error, urllib.error.HTTPError) else (
                str(error) if isinstance(error, ValueError) and str(error) in {
                    'not_referenced_image', 'not_image_locator', 'too_large', 'incomplete_download',
                    'not_supported_image_bytes', 'unsafe_media_directory', 'unsafe_media_file',
                    'unexpected_http_status', 'missing_moments_export','comment_image_md5_mismatch',
                    'comment_image_dimensions_exceed_budget','comment_images_not_authorized'} else 'image_request_or_validation_failed')
            if isinstance(error,urllib.error.URLError) and not isinstance(error,urllib.error.HTTPError):
                reason=error.reason
                code=('tls_certificate_rejected_'+str(reason.verify_code) if isinstance(reason,ssl.SSLCertVerificationError)
                      else 'dns_unavailable_'+str(reason.errno) if isinstance(reason,socket.gaierror)
                      else 'network_error_'+type(reason).__name__)
            retry_after=bool(isinstance(error,urllib.error.HTTPError) and error.headers
                             and error.headers.get('Retry-After'))
            if isinstance(error, urllib.error.HTTPError):error.close()
            # Preserve any already-successful file/state if publishing failed.
            if not _valid_existing(self.output, state['assets'].get(asset, {})):
                state['assets'][asset] = {**previous, 'status': 'failed', 'error_code': code,
                                           'last_attempt_at': now()}
                atomic_json(self.output / 'media-state.json', state)
            mark('failed', code)
            risk=code in ('http_403','http_429','http_451','http_514') or retry_after
            grant=self._image_resume_grant()
            if (not risk and isinstance(error,urllib.error.HTTPError) and grant
                    and error.code in grant.get('skip_resource_http_codes',[])):
                queue=self._edit(lambda queue:self._request_finished(queue,resource_failure=True))
                if queue['consecutive_resource_failures']>=grant.get('resource_failure_streak_limit',3):
                    self._halt('repeated_resource_http_errors')
                return
            self._halt(code,risk)
