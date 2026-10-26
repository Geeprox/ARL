#!/usr/bin/env python3
"""Refresh an existing archive from explicit local SNS files, without wx-cli.

Requires an already saved SNS key mapping; does not obtain process keys, log in,
request account data, or schedule itself. Freshness is limited to local cache.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import sys


def main():
    if importlib.util.find_spec('cryptography') is None:
        raise SystemExit('existing_cryptography_runtime_required')
    from local_sns_snapshot import snapshot, SnapshotError
    from contact_names import ContactNamesError
    from moments_backup import export_backup, atomic_json, now
    import datetime as dt
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sns-db',required=True,type=Path)
    parser.add_argument('--keys-file',required=True,type=Path)
    parser.add_argument('--contact-db',type=Path,help='Optional explicit encrypted contact.db; same saved keys file')
    parser.add_argument('--output',type=Path,default=Path(__file__).resolve().parent/'data')
    args=parser.parse_args()
    output=args.output.resolve()
    old=json.loads((output/'moments.json').read_text())
    old_ids={post['id'] for post in old['posts']}
    destination=output/'private/current-sns.sqlite3'
    try:
        verified=snapshot(args.sns_db,args.keys_file,destination)
        if args.contact_db:
            from contact_names import snapshot_contact_database
            contacts=snapshot_contact_database(args.contact_db,args.keys_file,output/'private/current-contact.sqlite3')
            contacts.update(self_username=old['self_username'],updated_at=now())
            atomic_json(output/'private/contact-names.json',contacts)
        result=export_backup(destination,old['self_username'],output)
    except (SnapshotError, ContactNamesError) as error:
        print(json.dumps({'status':'failed','error_code':str(error),'previous_export_preserved':True}))
        return 1
    document=json.loads((output/'moments.json').read_text())
    newest=max((post.get('created_at_unix') or 0 for post in document['posts']),default=0)
    report={'status':'ok','at':now(),'method':'independent_read_only_sqlcipher4_sns_snapshot',
            'uses_wx_cli':False,'account_network_requests':0,'posts_before':len(old_ids),
            'posts_after':len(document['posts']),
            'new_posts':sum(post['id'] not in old_ids for post in document['posts']),
            'latest_post_at':dt.datetime.fromtimestamp(newest,dt.timezone.utc).isoformat(),
            'hmac_pages_authenticated':verified['main_pages_authenticated'],
            'wal_frames_committed':verified['wal']['committed_frames'],
            'sqlite_integrity_check':verified['sqlite_integrity_check'],
            'coverage':'current_local_cache_only_server_phone_completeness_unknown',
            'export_result':result,'contact_names':document.get('contact_names')}
    atomic_json(output/'local-refresh.json',report)
    template=Path(__file__).resolve().parent/'viewer.template.html'
    if template.is_file():
        embedded=dict(document);embedded.pop('changes',None)
        data=json.dumps(embedded,ensure_ascii=False,separators=(',',':')).replace('<',r'\u003c').replace('>',r'\u003e').replace('&',r'\u0026')
        html=template.read_text().replace('__INITIAL_DATA__',data)
        from local_sns_snapshot import _private_write
        _private_write(output.parent/'moments.html',html.encode())
    print(json.dumps(report,ensure_ascii=False))
    return 0


if __name__=='__main__':raise SystemExit(main())
