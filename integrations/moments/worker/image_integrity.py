#!/usr/bin/env python3
"""Offline image-reference audit and completion watcher. No network or account API."""
import argparse
from collections import Counter,defaultdict
import datetime as dt
import fcntl
import hashlib
import json
from pathlib import Path
import time
import warnings
from zoneinfo import ZoneInfo
from moments_backup import atomic_json,load_json,now
from archive_storage import media_file


LABELS={'pending_download':'等待下载','download_failed':'下载失败','unsupported':'暂不支持',
        'not_enqueued':'未进入下载队列','missing_local_file':'本地文件缺失',
        'thumbnail_only':'仅有缩略图，原图未备份','unsafe_local_path':'本地路径不安全',
        'sha256_missing':'缺少文件校验值','sha256_mismatch':'SHA256不一致',
        'source_md5_mismatch':'源MD5不一致','byte_count_mismatch':'文件大小不一致',
        'decode_failed':'图像解码失败','decode_budget_exceeded':'图像解码超出核对上限',
        'inconsistent_backup_status':'文件存在但备份状态不一致'}


def references(document):
    for post in document.get('posts',[]):
        try:date=dt.datetime.fromtimestamp(post['created_at_unix'],ZoneInfo('Asia/Shanghai')).strftime('%Y-%m-%d %H:%M')
        except (KeyError,ValueError,TypeError,OSError):date='未记录'
        base={'post_id':post['id'],'post_date':date,'post_text_preview':(post.get('text') or '')[:120]}
        for index,media in enumerate(post.get('media',[])):
            if media.get('type')!=2:continue
            role='link_cover' if media.get('asset_id')==(post.get('link') or {}).get('thumbnail_ref') else 'post_image'
            yield {**base,'role':role,'media_index':index,'asset_id':media['asset_id']},media
        for comment in post.get('comments',{}).get('items') or []:
            for index,media in enumerate(comment.get('media',[])):
                if media.get('type')!='comment_emoji':continue
                yield {**base,'role':'comment_emoji','media_index':index,'asset_id':media['asset_id'],
                    'comment_id':comment.get('comment_id'),'comment_64id':comment.get('comment_64id'),
                    'comment_author':comment.get('remark') or comment.get('display_name') or comment.get('nickname'),
                    'comment_text_preview':(comment.get('content') or '')[:120]},media


def inspect_file(output,relative,cache):
    if not isinstance(relative,str):return {'error':'missing_local_file'}
    path=Path(relative)
    if path.is_absolute() or not path.parts or path.parts[0]!='media' or '..' in path.parts:
        return {'error':'unsafe_local_path'}
    target=output/path
    if (output/'media').is_symlink() or target.is_symlink() or not target.resolve().is_relative_to((output/'media').resolve()):
        return {'error':'unsafe_local_path'}
    target=media_file(output,relative)
    if target is None:return {'error':'missing_local_file'}
    if relative in cache:return cache[relative]
    result={'local_path':relative,'bytes':target.stat().st_size}
    sha,md5=hashlib.sha256(),hashlib.md5()
    with target.open('rb') as source:
        for block in iter(lambda:source.read(1024*1024),b''):sha.update(block);md5.update(block)
    result.update(sha256=sha.hexdigest(),md5=md5.hexdigest())
    try:
        from PIL import Image,ImageSequence
        with warnings.catch_warnings():
            warnings.simplefilter('error',Image.DecompressionBombWarning)
            with Image.open(target) as image:
                result['dimensions']=[image.width,image.height]
                pixels=0;frames=0
                for frame in ImageSequence.Iterator(image):
                    pixels+=frame.width*frame.height;frames+=1
                    if frames>2000 or pixels>500_000_000:
                        result['error']='decode_budget_exceeded';break
                    frame.load()
                result['frames_decoded']=frames
    except Exception as error:result.update(error='decode_failed',decode_error_type=type(error).__name__)
    cache[relative]=result
    return result


def inspect_reference(output,media,queue,cache):
    problems=[];status=media.get('backup_status')
    if status=='failed' or queue.get('status')=='failed':problems.append('download_failed')
    elif status=='unsupported' or queue.get('status')=='unsupported':problems.append('unsupported')
    if not media.get('local_path'):
        if queue.get('status') in ('queued','attempted','downloading'):problems.append('pending_download')
        elif not problems:problems.append('not_enqueued' if not queue else 'missing_local_file')
        return {'problems':problems,'backup_status':status,'queue_status':queue.get('status'),
                'error_code':queue.get('error_code') or media.get('error_code')}
    checked=inspect_file(output,media['local_path'],cache)
    if checked.get('error'):problems.append(checked['error'])
    if checked.get('sha256'):
        if not media.get('sha256'):problems.append('sha256_missing')
        elif checked['sha256']!=media['sha256']:problems.append('sha256_mismatch')
        if type(media.get('bytes')) is int and media['bytes']!=checked['bytes']:problems.append('byte_count_mismatch')
        if media.get('type')=='comment_emoji' and checked['md5']!=media.get('md5'):problems.append('source_md5_mismatch')
    if status not in ('downloaded','thumbnail_only') and not problems:problems.append('inconsistent_backup_status')
    return {'problems':problems,'backup_status':status,'queue_status':queue.get('status'),
            'local_path':media['local_path'],'file_check':checked,
            'error_code':queue.get('error_code') or media.get('error_code')}


def worker_running(output):
    with (output/'.image-worker.lock').open('a') as lock:
        try:fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB);return False
        except BlockingIOError:return True


def audit(output, *, final=False):
    output=Path(output).resolve();parent=output.parent;files={};entries=[];issues=[];groups=defaultdict(Counter)
    # Same lock order as the downloader; no reads of keys, cookies or source DBs.
    with (output/'.media.lock').open('a') as media_lock:
        fcntl.flock(media_lock,fcntl.LOCK_EX)
        with (output/'.backup.lock').open('a') as export_lock:
            fcntl.flock(export_lock,fcntl.LOCK_EX)
            raw=(output/'moments.json').read_bytes();document=json.loads(raw)
            queue=load_json(output/'image-queue.json',{'assets':{}})
            states=load_json(output/'media-state.json',{'assets':{}})['assets']
            for context,media in references(document):
                state=states.get(media['asset_id'],{})
                queued=queue['assets'].get(media['asset_id'],{})
                if not queued and state.get('status') in ('failed','unsupported'):
                    queued={'status':state['status'],'error_code':state.get('error_code')}
                checked=inspect_reference(output,media,queued,files)
                if media.get('backup_status')=='thumbnail_only' and context['role']!='link_cover':
                    checked['problems'].append('thumbnail_only')
                checked['error_code']=checked.get('error_code') or state.get('error_code')
                row={**context,**checked};entries.append(row)
                groups[context['role']]['expected']+=1
                groups[context['role']]['verified_ready' if not row['problems'] else 'with_gaps']+=1
                if row['problems']:issues.append(row)
            supplements=[]
            for name,path in document.get('profile',{}).items():
                if name not in ('avatar_path','cover_path') or not path:continue
                checked=inspect_file(output,path,files)
                if checked.get('sha256') and checked['sha256']!=Path(path).stem:checked={**checked,'error':'sha256_mismatch'}
                supplements.append({'role':name,**checked})
            for path in sorted(set(load_json(parent/'wechat-face-map.json',{}).values())):
                checked=inspect_file(output,path,files)
                if checked.get('sha256') and checked['sha256']!=Path(path).stem:checked={**checked,'error':'sha256_mismatch'}
                supplements.append({'role':'wechat_face',**checked})
    pending=sum(v.get('status') in ('queued','attempted','downloading') for v in queue['assets'].values())
    active=worker_running(output)
    phase='halted' if queue.get('halted') else 'in_progress' if pending and active else 'stalled' if pending else 'completed'
    if phase=='completed' and (issues or any(x.get('error') for x in supplements)):phase='completed_with_gaps'
    report={'schema_version':1,'checked_at':now(),'phase':phase,'terminal':phase in ('halted','completed','completed_with_gaps'),
            'scope':'image references in the current exported JSON; server history completeness remains unknown',
            'source_moments_sha256':hashlib.sha256(raw).hexdigest(),'posts':len(document['posts']),
            'expected_image_references':len(entries),'verified_ready_references':len(entries)-len(issues),
            'roles':dict(groups),'unique_local_files_checked':len(files),'issues_count':len(issues),
            'issue_counts':dict(Counter(p for row in issues for p in row['problems'])),
            'supplemental_images':supplements,'supplemental_errors':sum(bool(x.get('error')) for x in supplements),
            'finder_media_excluded_paused':sum(len(p.get('finder',{}).get('media',[])) for p in document['posts']),
            'queue':{'pending':pending,'worker_running':active,'halted':bool(queue.get('halted')),
                     'risk_control_suspected':bool(queue.get('risk_control_suspected')),'error_code':queue.get('error_code'),
                     'counts':dict(Counter(v.get('status') for v in queue['assets'].values()))},
            'issues':issues,'references':entries,'network_requests':0}
    stem='image-integrity-final' if final and report['terminal'] else 'image-integrity-current'
    atomic_json(parent/(stem+'.json'),report)
    brief={k:v for k,v in report.items() if k not in ('references','supplemental_images')}
    atomic_json(parent/('image-missing-final.json' if stem.endswith('final') else 'image-missing-current.json'),brief)
    (parent/(stem+'.md')).write_text(markdown(report),encoding='utf8')
    return report


def markdown(report):
    def cell(value):return str(value or '').replace('|','\\|').replace('\n',' ')[:140]
    lines=['# 图片完整性核对','',f"状态：{report['phase']}；核对时间：{report['checked_at']}。",
           f"导出 {report['posts']} 条朋友圈，图片引用 {report['expected_image_references']} 项，核对通过 {report['verified_ready_references']} 项，仍有问题 {report['issues_count']} 项。",
           f"视频号媒体 {report['finder_media_excluded_paused']} 项继续暂停，不计入此次图片缺失。",
           '核对范围限于已导出 JSON，不证明服务端历史总量完整。','',
           '| 时间 | 类别 | 帖子 ID | 序号/评论 ID | 问题 | 摘要 |','|---|---|---|---|---|---|']
    for row in report['issues']:
        label={'post_image':'配图','link_cover':'链接封面','comment_emoji':'评论表情图'}[row['role']]
        reason='、'.join(LABELS.get(p,p) for p in row['problems'])
        if row.get('error_code'):reason+='（'+row['error_code']+'）'
        lines.append('| '+' | '.join(cell(x) for x in [row['post_date'],label,row['post_id'],row.get('comment_id') or row['media_index'],reason,row['post_text_preview']])+' |')
    if not report['issues']:lines.append('| — | — | — | — | 无缺失或失败条目 | — |')
    for extra in report['supplemental_images']:
        if extra.get('error'):lines.append('\n附加图片问题：'+cell(extra['role'])+' '+cell(extra.get('local_path'))+' '+cell(extra['error']))
    return '\n'.join(lines)+'\n'


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,required=True);parser.add_argument('--watch',action='store_true')
    args=parser.parse_args();output=args.output.resolve()
    report=audit(output,final=True);print(json.dumps({k:report[k] for k in ['phase','expected_image_references','verified_ready_references','issues_count']}),flush=True)
    if not args.watch:return
    while not report['terminal']:
        time.sleep(15)
        queue=load_json(output/'image-queue.json',{})
        pending=any(v.get('status') in ('queued','attempted','downloading') for v in queue.get('assets',{}).values())
        if queue.get('halted') or not pending:
            report=audit(output,final=True)
            print(json.dumps({k:report[k] for k in ['phase','issues_count','queue']}),flush=True)
            if report['terminal']:return
        # Health checkpoint only, without repeatedly decoding all image files.
        atomic_json(output.parent/'image-audit-watch.json',{'checked_at':now(),'waiting_for_queue':True,
                    'pending':sum(v.get('status') in ('queued','attempted','downloading') for v in queue.get('assets',{}).values()),
                    'worker_running':worker_running(output),'network_requests':0})


if __name__=='__main__':
    try:main()
    except KeyboardInterrupt:pass
