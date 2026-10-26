#!/usr/bin/env python3
"""Read-only, cache-based Moments backup. Python 3.10+, standard library only.

This polls an explicitly supplied decrypted SQLite source, not the phone or a
WeChat API. SQLite's backup API includes committed WAL data. No source writes,
process access, network requests, or credential extraction are performed.
"""
from __future__ import annotations

import argparse
import contextlib
import copy
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import tempfile
import time
import xml.etree.ElementTree as ET

from independent.moments_protocol.finder import project_finder_feed
from independent.moments_protocol.share_link import project_share_link

SCHEMA_VERSION = 1
MAX_XML_BYTES = 16 * 1024 * 1024


class BackupError(Exception):
    pass


def now():
    return dt.datetime.now(dt.timezone.utc).isoformat().replace('+00:00', 'Z')


def timestamp(value):
    return dt.datetime.fromtimestamp(value, dt.timezone.utc).isoformat().replace('+00:00', 'Z')


def file_sha256(path):
    checksum = hashlib.sha256()
    with open(path, 'rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            checksum.update(chunk)
    return checksum.hexdigest()


def encoded(value):
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + '\n').encode('utf-8')


def digest(value):
    return hashlib.sha256(encoded(value)).hexdigest()


def atomic_json(path, value):
    """Same-filesystem atomic replacement, private permissions from creation."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temp = tempfile.mkstemp(prefix='.' + path.name + '-', dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, 'wb') as stream:
            stream.write(encoded(value))
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp, path)
        directory_fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def string_id(value, *, unsigned_64=False):
    if value is None or str(value).strip() == '':
        return None
    try:
        number = int(str(value).strip())
    except ValueError as exc:
        raise BackupError('Invalid numeric identifier') from exc
    if unsigned_64:
        if number < -(1 << 63) or number > (1 << 64) - 1:
            raise BackupError('Identifier outside uint64/signed SQLite range')
        number &= (1 << 64) - 1
    return str(number)


def optional_int(node, name):
    value = node.findtext(name) if node is not None else None
    if value is None or value.strip() == '':
        return None
    try:
        return int(value)
    except ValueError as exc:
        raise BackupError('Invalid integer in selected XML') from exc


def interaction(root, tag, post_id=None, locators=None):
    container = root.find('LocalExtraInfo/' + tag)
    if container is None:
        return {'availability': 'not_observed', 'items': None,
                'completeness': 'unknown'}
    items = []
    text_fields = ('username', 'nickname', 'content', 'ref_username')
    int_fields = ('source', 'type', 'create_time', 'is_local_added',
                  'is_rich_text', 'b_deleted', 'comment_flag', 'comment_content_type',
                  'comment_emojiinfo_count')
    id_fields = ('comment_id', 'comment_64id', 'ref_comment_id', 'ref_comment_64id')
    occurrences = {}
    for item in container.findall('user_comment'):
        record = {name: item.findtext(name) for name in text_fields}
        record.update({name: optional_int(item, name) for name in int_fields})
        record.update({name: string_id(item.findtext(name), unsigned_64=True) for name in id_fields})
        if tag == 'comment_user_list' and post_id is not None:
            from comment_media import project_comment_media
            identity = tuple(item.findtext(k) for k in ('username', 'comment_id', 'comment_64id'))
            occurrence = occurrences.get(identity, 0)
            occurrences[identity] = occurrence + 1
            media, private = project_comment_media(item, post_id, occurrence)
            if media:record['media'] = media
            if locators is not None:locators.update(private)
        # Keep ordering stable when the cache changes incidental list order.
        items.append(record)
    items.sort(key=lambda x: encoded(x))
    return {'availability': 'observed_in_cache', 'items': items,
            'completeness': 'unknown'}


def parse_post(tid, db_author, xml, self_username):
    if not isinstance(xml, (str, bytes)) or len(xml) > MAX_XML_BYTES:
        raise BackupError('Selected XML missing or oversized')
    raw = xml.encode() if isinstance(xml, str) else xml
    if b'<!DOCTYPE' in raw.upper() or b'<!ENTITY' in raw.upper():
        raise BackupError('DTD/entity declarations are unsupported')
    try:
        root = ET.fromstring(raw)
    except ET.ParseError as exc:
        raise BackupError('Malformed XML for selected author; backup preserved') from exc
    timeline = root.find('TimelineObject')
    if timeline is None:
        raise BackupError('Selected XML has no TimelineObject')
    if db_author != self_username or timeline.findtext('username') != self_username:
        raise BackupError('Selected database/XML author mismatch')
    post_id = string_id(timeline.findtext('id') or tid, unsigned_64=True)
    if post_id is None:
        raise BackupError('Selected post has no identifier')
    created = optional_int(timeline, 'createTime')
    locators = {}
    media = []
    for index, item in enumerate(timeline.findall('ContentObject/mediaList/media')):
        media_id = string_id(item.findtext('id'), unsigned_64=True)
        asset_id = post_id + ':' + (media_id or 'index-' + str(index))
        size = item.find('size')
        safe_size = {}
        if size is not None:
            for key in ('width', 'height', 'totalSize'):
                if key in size.attrib:
                    safe_size[key] = size.attrib[key]
        media.append({'asset_id': asset_id, 'media_id': media_id,
                      'type': optional_int(item, 'type'),
                      'sub_type': optional_int(item, 'sub_type'), 'size': safe_size,
                      'video_duration': item.findtext('videoDuration'),
                      'local_path': None, 'backup_status': 'locator_only_not_downloaded'})
        # Signing attributes belong only in this private downloader input.
        locators[asset_id] = {
            'moment_id': post_id, 'media_id': media_id,
            'kind': item.findtext('type'), 'url': item.findtext('url'),
            'thumb': item.findtext('thumb'), 'enc': item.findtext('enc'),
            'enc_attrs': dict(item.find('enc').attrib) if item.find('enc') is not None else {},
            'attrs': {name: dict(item.find(name).attrib) if item.find(name) is not None else {}
                      for name in ('url', 'thumb')}}
    content = timeline.find('ContentObject')
    post = {'id': post_id, 'author_username': self_username,
            'author_nickname': root.findtext('LocalExtraInfo/nickname'),
            'created_at_unix': created, 'text': timeline.findtext('contentDesc'),
            'content_type': optional_int(content, 'type'),
            'media': media, 'likes': interaction(root, 'like_user_list'),
            'comments': interaction(root, 'comment_user_list', post_id, locators)}
    finder, finder_private = project_finder_feed(content, post_id + ':finder')
    if finder is not None:
        post['finder'] = finder
        # Finder cards have their own media list; do not invent a downloaded
        # ordinary Moments video when only a forwarded Channels card was seen.
        for reference, record in finder_private.items():
            locators[reference] = dict(record, moment_id=post_id)
    link, link_private = project_share_link(content, post_id + ':link',
                                           [item['asset_id'] for item in media])
    if link is not None:
        post['link'] = link
    for reference, record in link_private.items():
        locators[reference] = dict(record, moment_id=post_id)
    return post, locators


@contextlib.contextmanager
def snapshot_database(source):
    source = Path(source).expanduser().resolve()
    if not source.is_file():
        raise BackupError('Source database does not exist')
    source_stat = source.stat()
    wal = Path(str(source) + '-wal')
    wal_bytes = wal.stat().st_size if wal.exists() else 0
    wal_mtime = wal.stat().st_mtime if wal_bytes else None
    with tempfile.TemporaryDirectory(prefix='moments-snapshot-') as directory:
        target = Path(directory) / 'snapshot.sqlite'
        started = time.monotonic()

        def progress(status, remaining, total):
            if time.monotonic() - started > 15:
                raise BackupError('SQLite snapshot timeout; backup preserved')

        try:
            with contextlib.closing(sqlite3.connect(source.as_uri() + '?mode=ro', uri=True, timeout=3)) as src:
                with contextlib.closing(sqlite3.connect(target)) as dst:
                    src.backup(dst, pages=256, progress=progress, sleep=0.05)
            with contextlib.closing(sqlite3.connect(target)) as db:
                if db.execute('PRAGMA quick_check').fetchone() != ('ok',):
                    raise BackupError('SQLite integrity check failed')
                db.execute('PRAGMA query_only=ON')
                provenance = {
                    'file_name': source.name,
                    'source_last_modified': timestamp(source_stat.st_mtime),
                    'wal_last_modified': timestamp(wal_mtime) if wal_mtime is not None else None,
                    'wal_bytes': wal_bytes,
                    'snapshot_sha256': file_sha256(target),
                    'source_mtime_changed_during_snapshot': source.stat().st_mtime_ns != source_stat.st_mtime_ns,
                    'freshness_verified_against_phone_or_server': False,
                    'mtime_meaning': 'supplied file metadata; a copied snapshot may have a copy time; not phone/server freshness'}
                yield db, provenance
        except sqlite3.Error as exc:
            raise BackupError('SQLite read/snapshot failed; backup preserved') from exc


def load_json(path, default):
    if not path.exists():
        return default
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError) as exc:
        raise BackupError('Existing backup cannot be read; refusing replacement') from exc


def parse_since(value):
    if value is None:
        return None
    try:
        return int(value)
    except ValueError:
        try:
            stamp = dt.datetime.fromisoformat(value.replace('Z', '+00:00'))
            if stamp.tzinfo is None:
                stamp = stamp.replace(tzinfo=dt.timezone.utc)
            return int(stamp.timestamp())
        except ValueError as exc:
            raise BackupError('--since must be Unix seconds or an ISO date/time (UTC by default)') from exc


def _post_assets(post):
    # Finder references remain separate from ordinary media in public records
    # and coverage counts, while sharing local-file verification and retention.
    return (post['media'] + post.get('finder', {}).get('media', [])
            + [media for comment in (post.get('comments', {}).get('items') or [])
               for media in comment.get('media', [])])


def merge_media_state(posts, output, existing=None):
    from archive_storage import media_file,receipt,retained_reference
    archive_receipt=receipt(output)
    state = load_json(output / 'media-state.json', {'schema_version': 1, 'assets': {}})
    if state.get('schema_version') != 1 or not isinstance(state.get('assets'), dict):
        raise BackupError('Unsupported media-state schema')
    previous_assets = {media['asset_id']: media for post in (existing or {}).values() for media in _post_assets(post)}
    checked_files = {}
    for post in posts.values():
        for media in _post_assets(post):
            item = state['assets'].get(media['asset_id'])
            if item is None:
                previous = previous_assets.get(media['asset_id'])
                if previous is None or previous['backup_status'] in ('locator_only_not_downloaded', 'missing_bytes', 'missing'):
                    continue
                item = dict(previous, status=previous['backup_status'])
            status = item.get('status')
            if status not in ('downloaded', 'thumbnail_only', 'failed', 'unsupported'):
                raise BackupError('Invalid media-state status')
            local_path = item.get('local_path')
            retained=False;resolved=None
            if local_path is not None:
                path = Path(local_path)
                if path.is_absolute() or '..' in path.parts or not path.parts:
                    raise BackupError('Unsafe media-state local path')
                retained=retained_reference(output,str(path),item.get("sha256"),item.get("bytes"),binding=archive_receipt)
                resolved = None if retained else media_file(output, str(path))
                if not retained and resolved is None:
                    raise BackupError('Media-state file is missing or outside output')
            if status in ('downloaded', 'thumbnail_only') and local_path is None:
                raise BackupError('Media-state success has no local file')
            if status in ('downloaded', 'thumbnail_only'):
                expected_hash = item.get('sha256')
                expected_bytes = item.get('bytes')
                if not isinstance(expected_hash, str) or len(expected_hash) != 64 or any(c not in '0123456789abcdef' for c in expected_hash):
                    raise BackupError('Media-state success has invalid SHA-256')
                if not isinstance(expected_bytes, int) or isinstance(expected_bytes, bool) or expected_bytes < 0:
                    raise BackupError('Media-state success has invalid byte count')
                if not retained and resolved.stat().st_size != expected_bytes:
                    raise BackupError('Media-state file size mismatch; backup preserved')
                if not retained and resolved not in checked_files:
                    checked_files[resolved] = file_sha256(resolved)
                if not retained and checked_files[resolved] != expected_hash:
                    raise BackupError('Media-state file SHA-256 mismatch; backup preserved')
            if media in post.get('finder', {}).get('media', []) and item.get('poster_path') is not None:
                poster = Path(item['poster_path'])
                if poster.is_absolute() or '..' in poster.parts or not poster.parts:
                    raise BackupError('Unsafe Finder poster local path')
                poster_hash=item.get("poster_sha256") or (item.get("sha256") if str(poster)==local_path else None)
                poster_bytes=item.get("poster_bytes",item.get("bytes") if str(poster)==local_path else None)
                poster_retained=type(poster_bytes) is int and retained_reference(output,str(poster),poster_hash,poster_bytes,binding=archive_receipt)
                poster_file = None if poster_retained else media_file(output, str(poster))
                if not poster_retained and poster_file is None:
                    raise BackupError('Finder poster file is missing or outside output')
                # A cover saved as thumbnail_only can share the verified local
                # asset. A distinct poster needs its own hash and byte count.
                if not poster_retained and (status not in ('downloaded', 'thumbnail_only') or poster_file != resolved):
                    poster_hash, poster_bytes = item.get('poster_sha256'), item.get('poster_bytes')
                    if (not isinstance(poster_hash, str) or len(poster_hash) != 64
                            or any(c not in '0123456789abcdef' for c in poster_hash)
                            or type(poster_bytes) is not int or poster_bytes < 0):
                        raise BackupError('Finder poster has invalid SHA-256 or byte count')
                    if poster_file.stat().st_size != poster_bytes:
                        raise BackupError('Finder poster file size mismatch; backup preserved')
                    if poster_file not in checked_files:
                        checked_files[poster_file] = file_sha256(poster_file)
                    if checked_files[poster_file] != poster_hash:
                        raise BackupError('Finder poster SHA-256 mismatch; backup preserved')
            media['backup_status'] = status
            media['local_path'] = local_path
            for key in ('sha256', 'bytes', 'format', 'source_variant'):
                media[key] = item.get(key)
            for key in ('duration', 'width', 'height', 'codec', 'verification', 'poster_path',
                        'poster_sha256', 'poster_bytes', 'poster_width', 'poster_height'):
                if key in item:
                    media[key] = item[key]


def export_backup(source, self_username, output, since=None):
    if not self_username or self_username != self_username.strip():
        raise BackupError('An exact nonempty self username is required')
    output = Path(output).expanduser().resolve()
    output.mkdir(parents=True, exist_ok=True, mode=0o700)
    lock_path = output / '.backup.lock'
    with open(lock_path, 'a') as lock:
        os.chmod(lock_path, 0o600)
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise BackupError('Another export is running') from exc
        return _export_locked(source, self_username, output, since)


def _export_locked(source, self_username, output, since):
    started = now()
    previous = load_json(output / 'moments.json', {'schema_version': SCHEMA_VERSION,
                         'self_username': self_username, 'posts': [], 'changes': []})
    if previous.get('self_username') != self_username or previous.get('schema_version') != SCHEMA_VERSION:
        raise BackupError('Output belongs to another account/schema')
    existing = {post['id']: post for post in previous['posts']}
    private_path = output / 'private' / 'locators.json'
    private = load_json(private_path, {'schema_version': SCHEMA_VERSION,
                                      'self_username': self_username, 'assets': {}})
    if private.get('self_username') != self_username:
        raise BackupError('Private locators belong to another account')
    assets = dict(private['assets'])
    fresh = {}
    total_rows = 0
    newest_post = None
    try:
        with snapshot_database(source) as (db, provenance):
            total_rows = db.execute('SELECT count(*) FROM SnsTimeLine').fetchone()[0]
            # COLLATE BINARY is intentional: display names and LIKE matches do
            # not identify the user's account; only the exact username does.
            rows = db.execute('SELECT tid,user_name,content FROM SnsTimeLine WHERE user_name = ? COLLATE BINARY',
                              (self_username,))
            for tid, author, xml in rows:
                post, locators = parse_post(tid, author, xml, self_username)
                if post['created_at_unix'] is not None:
                    newest_post = max(newest_post or post['created_at_unix'], post['created_at_unix'])
                if since is not None and post['created_at_unix'] is None:
                    raise BackupError('Selected post lacks createTime required by --since')
                # Existing older posts are always revisited for late likes or
                # comments. --since limits first-time historical acquisition.
                if since is not None and post['created_at_unix'] < since and post['id'] not in existing:
                    continue
                if post['id'] in fresh and fresh[post['id']] != post:
                    raise BackupError('Conflicting duplicate post IDs in source')
                fresh[post['id']] = post
                assets.update(locators)
    except BackupError:
        raise
    # A media download can finish after a post has disappeared from the source
    # cache. Reconcile retained posts too, without inventing a new source sighting.
    metadata_fields = {'content_sha256', 'revision', 'first_seen_at', 'last_seen_at'}
    candidates = {post_id: copy.deepcopy({key: value for key, value in post.items()
                                         if key not in metadata_fields})
                  for post_id, post in existing.items() if post_id not in fresh}
    candidates.update(fresh)
    merge_media_state(candidates, output, existing)
    provenance['newest_post_cached_at'] = timestamp(newest_post) if newest_post is not None else None
    provenance['newest_post_cached_unix'] = newest_post
    contact_mapping = load_json(output / 'private/contact-names.json', None)
    if contact_mapping is not None:
        if contact_mapping.get('self_username') != self_username:
            raise BackupError('Contact mapping belongs to another account')
        from contact_names import enrich_document
    changes = list(previous['changes'])
    updated_count = 0
    for post_id, post in candidates.items():
        old = existing.get(post_id)
        if old:
            for field in ('likes', 'comments'):
                if post[field]['items'] is None and old[field]['items'] is not None:
                    post[field] = dict(old[field], availability='not_observed_in_latest_snapshot')
        if contact_mapping is not None:
            # Names are a current local contact observation; old change snapshots
            # remain immutable and retain their original semantic hashes.
            post = enrich_document({'posts': [post]}, contact_mapping)['posts'][0]
        semantic_hash = digest(post)
        if old is None or semantic_hash != old['content_sha256']:
            version = 1 if old is None else old['revision'] + 1
            changes.append({'event_id': post_id + ':' + str(version), 'post_id': post_id,
                            'revision': version, 'kind': 'created' if old is None else 'updated',
                            'observed_at': started, 'content_sha256': semantic_hash,
                            'snapshot': post})
            updated_count += 1
        else:
            version = old['revision']
        existing[post_id] = dict(post, content_sha256=semantic_hash, revision=version,
                                 first_seen_at=old['first_seen_at'] if old else started,
                                 last_seen_at=started if post_id in fresh else old['last_seen_at'])
    all_media = [media for post in existing.values() for media in post['media']]
    downloaded_media = sum(media['backup_status'] == 'downloaded' for media in all_media)
    thumbnails = sum(media['backup_status'] == 'thumbnail_only' for media in all_media)
    coverage = {'scope': 'local_cache_only', 'completeness': 'partial_or_unknown',
                'source_rows': total_rows, 'self_posts_observed_this_run': len(fresh),
                'historical_posts_retained': len(existing), 'since_unix': since,
                'missing_source_posts_are_not_deletions': True,
                'interactions_are_cached_observations_not_server_totals': True,
                'media_bytes_backed_up': bool(all_media) and downloaded_media == len(all_media),
                'media_assets': len(all_media), 'media_downloaded': downloaded_media,
                'media_thumbnail_only': thumbnails, 'listening_mode': 'sqlite_polling'}
    result = {'schema_version': SCHEMA_VERSION, 'self_username': self_username,
              'last_success_at': started, 'source': provenance, 'coverage': coverage,
              'posts': sorted(existing.values(), key=lambda p: (p['created_at_unix'] or 0, int(p['id']))),
              'changes': changes}
    profile_saved = load_json(output / 'private/profile-assets.json', None)
    if profile_saved is not None:
        if profile_saved.get('self_username') != self_username:
            raise BackupError('Profile assets belong to another account')
        import re
        profile = {}
        for key in ('avatar_path', 'cover_path'):
            relative = profile_saved.get('profile', {}).get(key)
            if relative is None:profile[key] = None;continue
            match = re.fullmatch(r'media/([a-f0-9]{64})\.(jpg|jpeg|png|gif|webp)', str(relative))
            from archive_storage import media_file,retained_reference
            if match and retained_reference(output,str(relative),match.group(1)):
                profile[key]=relative;continue
            target = media_file(output, str(relative))
            if (target is not None and match and not (output / 'media').is_symlink() and target.is_file()
                    and not target.is_symlink() and file_sha256(target) == match.group(1)):
                profile[key] = relative
        if profile:result['profile'] = profile
    if contact_mapping is not None:
        people = [person for post in result['posts'] for kind in ('likes', 'comments')
                  for person in (post.get(kind, {}).get('items') or [])]
        result['contact_names'] = {'source': 'exact_username_local_contact_cache',
            'source_sha256': contact_mapping.get('source', {}).get('sha256'),
            'updated_at': contact_mapping.get('updated_at'),
            'interaction_records': len(people),
            'remark_display_records': sum(person.get('display_name_source') == 'contact_remark' for person in people),
            'original_nicknames_preserved': True}
    # Locators are written before the authoritative backup. They may be ahead
    # after a crash, but successful public records never point to absent locators.
    atomic_json(private_path, {'schema_version': SCHEMA_VERSION, 'self_username': self_username,
                               'assets': assets})
    atomic_json(output / 'moments.json', result)
    atomic_json(output / 'manifest.json', {'schema_version': SCHEMA_VERSION,
                'last_success_at': started, 'moments_sha256': hashlib.sha256(encoded(result)).hexdigest(),
                'posts': len(existing), 'changes_this_run': updated_count, 'source': provenance, 'coverage': coverage,
                'freshness_meaning': 'last successful read of supplied SQLite; not phone/server freshness'})
    with contextlib.suppress(FileNotFoundError):
        (output / 'last_error.json').unlink()
    return {'posts': len(existing), 'changes_this_run': updated_count,
            'observed_this_run': len(fresh), 'last_success_at': started}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    for command in ('export', 'watch'):
        child = commands.add_parser(command)
        child.add_argument('--sns-db', required=True, type=Path)
        child.add_argument('--self-username', required=True)
        child.add_argument('--output', required=True, type=Path)
        child.add_argument('--since', help='Unix seconds or ISO date/time; naive dates mean UTC')
        if command == 'watch':
            child.add_argument('--interval', type=float, default=60)
            child.add_argument('--max-cycles', type=int, help='omit to run until interrupted')
    args = parser.parse_args(argv)
    if args.command == 'watch' and (args.interval <= 0 or (args.max_cycles is not None and args.max_cycles < 1)):
        parser.error('interval and max-cycles must be positive')
    try:
        since = parse_since(args.since)
    except BackupError as exc:
        parser.error(str(exc))
    cycle = 0
    latest_failed = False
    try:
        while True:
            try:
                report = export_backup(args.sns_db, args.self_username, args.output, since)
                print(json.dumps({'status': 'ok', **report}), flush=True)
                latest_failed = False
            except (BackupError, OSError, ValueError, KeyError, TypeError) as exc:
                # No raw SQL, XML, source values, signing URLs, or process data
                # enter logs. Existing successful backup is left untouched.
                report = {'status': 'error', 'at': now(), 'error_type': type(exc).__name__,
                          'message': str(exc) if isinstance(exc, BackupError) else 'Backup I/O or data validation failed'}
                with contextlib.suppress(OSError):
                    atomic_json(args.output / 'last_error.json', report)
                print(json.dumps(report), flush=True)
                latest_failed = True
            cycle += 1
            if args.command == 'export' or (args.max_cycles is not None and cycle >= args.max_cycles):
                return 1 if latest_failed else 0
            time.sleep(args.interval)
    except KeyboardInterrupt:
        return 130


if __name__ == '__main__':
    raise SystemExit(main())
