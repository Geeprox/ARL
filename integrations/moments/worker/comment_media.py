"""Lossless private comment-sticker locators and safe offline media projection.

No network, guessing of URLs, encryption or authentication. Source comment text
is deliberately untouched. Missing image replies remain explicit records.
"""
import hashlib
import json
from pathlib import Path
import re

_MD5 = re.compile(r'[a-fA-F0-9]{32}')
_LOCAL = re.compile(r'media/[a-f0-9]{64}\.(?:gif|png|jpg|jpeg|webp)')


def _number(value):
    try:
        result = int(value)
        return result if 0 <= result <= 1 << 31 else None
    except (TypeError, ValueError):
        return None


def _tree(node):
    return {'tag': node.tag, 'text': node.text, 'attributes': dict(node.attrib),
            'children': [_tree(child) for child in node]}


def project_comment_media(node, post_id, occurrence=0):
    """Return (public media, private assets); stable identity scoped to own post.

    Identical/absent comment IDs cannot overwrite another comment's locators:
    the caller supplies an occurrence within equal (username, ID) identities.
    """
    identity = [node.findtext(k) for k in ('username', 'comment_id', 'comment_64id')]
    key = hashlib.sha256(json.dumps(identity, ensure_ascii=False,
                         separators=(',', ':')).encode()).hexdigest()
    result, private = [], {}
    for index, emoji in enumerate(node.findall('emojilist/emojiinfo')):
        asset = f'{post_id}:comment:{key}:{occurrence}:emoji:{index}'
        md5 = emoji.findtext('md5')
        md5 = md5.lower() if isinstance(md5, str) and _MD5.fullmatch(md5) else None
        public = {'asset_id': asset, 'type': 'comment_emoji', 'md5': md5,
                  'width': _number(emoji.findtext('width')),
                  'height': _number(emoji.findtext('height')),
                  'bytes_reported': _number(emoji.findtext('size')),
                  'description': emoji.findtext('desc'),
                  'local_path': None, 'backup_status': 'missing'}
        result.append(public)
        private[asset] = {'kind': 'comment_emoji', 'moment_id': str(post_id),
                          'md5': md5, 'tree': _tree(emoji)}
    return result, private


def public_comment_media(media):
    """Nested allowlist: a top-level media key never opens private child fields."""
    result = []
    for item in media if isinstance(media, list) else []:
        if not isinstance(item, dict):continue
        fields = ('asset_id', 'type', 'md5', 'width', 'height', 'bytes_reported',
                  'description', 'backup_status', 'format', 'bytes', 'sha256')
        safe = {k: item[k] for k in fields if k in item}
        local = item.get('local_path')
        safe['local_path'] = local if isinstance(local, str) and _LOCAL.fullmatch(local) else None
        result.append(safe)
    return result


def recover_cached_media(media, output, cache_root):
    """Explicit offline recovery: exact MD5 filename AND bytes, then decode.

    Only Emoticon cache trees are indexed. No account paths auto-discovered,
    no raw cache path is exposed publicly. Returns state entries to merge; the
    caller owns locking/publishing. A missing or encrypted file stays missing.
    """
    wanted = {m['md5'] for m in media if isinstance(m.get('md5'), str)
              and _MD5.fullmatch(m['md5'])}
    candidates = {key: [] for key in wanted}
    root, output = Path(cache_root), Path(output)
    for folder in root.glob('*/Emoticon'):
        for path in folder.rglob('*'):
            if not path.is_file() or path.is_symlink():continue
            name = path.stem.lower()
            if name in candidates:candidates[name].append(path)
    recovered = {}
    for item in media:
        for path in candidates.get(item.get('md5'), []):
            if not 0 < path.stat().st_size <= 40 * 1024 * 1024:continue
            raw = path.read_bytes()
            if hashlib.md5(raw).hexdigest() != item['md5']:continue
            try:
                from PIL import Image
                import io
                with Image.open(io.BytesIO(raw)) as image:
                    if image.width * image.height > 40_000_000:continue
                    image.load()
                    fmt = {'JPEG':'jpg', 'PNG':'png', 'GIF':'gif', 'WEBP':'webp'}.get(image.format)
                    width, height = image.size
                if fmt is None:continue
            except (OSError, ValueError):continue
            sha = hashlib.sha256(raw).hexdigest()
            local = f'media/{sha}.{fmt}'
            (output/'media').mkdir(parents=True, exist_ok=True)
            if (output/'media').is_symlink():raise ValueError('unsafe_media_directory')
            destination = output/local
            if destination.is_symlink():raise ValueError('unsafe_media_destination')
            if not destination.exists():destination.write_bytes(raw);destination.chmod(0o600)
            if hashlib.sha256(destination.read_bytes()).hexdigest() != sha:
                raise ValueError('cache_copy_hash_mismatch')
            recovered[item['asset_id']] = {'status':'downloaded','local_path':local,
                'sha256':sha,'bytes':len(raw),'format':fmt,'width':width,'height':height,
                'source_variant':'exact_md5_local_emoticon_cache'}
            break
    return recovered


def comment_locator(record):
    """Use the exact plain-image URL; never transfer keys between variants."""
    from urllib.parse import urlsplit, urlunsplit
    if record.get('kind')!='comment_emoji':raise ValueError('not_comment_image')
    md5=record.get('md5')
    if not isinstance(md5,str) or _MD5.fullmatch(md5) is None:
        raise ValueError('comment_image_missing_md5')
    groups=[n for n in record['tree']['children'] if n['tag']=='sns_emoji_data']
    if len(groups)!=1:raise ValueError('ambiguous_comment_image_data')
    urls=[n.get('text') for n in groups[0]['children'] if n['tag']=='url']
    if len(urls)!=1 or not isinstance(urls[0],str):raise ValueError('missing_comment_image_url')
    value=urls[0]
    if len(value)>32768 or any(c in value for c in '\r\n\x00'):raise ValueError('invalid_comment_image_url')
    parsed=urlsplit(value)
    if parsed.scheme not in ('http','https') or parsed.username or parsed.password or parsed.port not in (None,80,443):
        raise ValueError('invalid_comment_image_url')
    permitted={('vweixinf.tc.qq.com','/110/20401/stodownload'),
               ('wxapp.tc.qq.com','/262/20304/stodownload'),
               ('wxapp.tc.qq.com','/275/20304/stodownload')}
    if (parsed.hostname,parsed.path) not in permitted and not (
            parsed.hostname=='mmbiz.qpic.cn' and parsed.path.startswith('/mmemoticon/')):
        raise ValueError('unsupported_comment_image_destination')
    # Legacy vweixinf locators explicitly use HTTP; its HTTPS endpoint presents
    # a certificate for another hostname. Preserve that supplied scheme rather
    # than disabling TLS checks or retrying a different scheme automatically.
    scheme=parsed.scheme if parsed.hostname=='vweixinf.tc.qq.com' else 'https'
    return {'url':urlunsplit((scheme,parsed.hostname,parsed.path,parsed.query,'')),
            'expected_md5':md5.lower(),'kind':'comment_emoji'}


def fetch_comment_once(locator):
    """One plain-variant exchange; exact MD5 and image decode are mandatory.

    Encrypted/extern URLs and AES parameters are not used or guessed. Failure
    never triggers another variant, redirect or retry.
    """
    import io
    import urllib.request
    from PIL import Image
    from async_media import NoRedirect
    from media_backup import MAX_BYTES,image_format
    request=urllib.request.Request(locator['url'],headers={
        'User-Agent':'Mozilla/5.0','Accept-Encoding':'identity'})
    opener=urllib.request.build_opener(NoRedirect())
    with opener.open(request,timeout=15) as response:
        if response.status!=200:raise ValueError('unexpected_http_status')
        if response.headers.get('Content-Encoding','identity')!='identity':raise ValueError('unexpected_content_encoding')
        expected=response.headers.get('Content-Length')
        if expected is not None and (not expected.isdigit() or int(expected)>MAX_BYTES):raise ValueError('too_large')
        raw=response.read(MAX_BYTES+1)
        if len(raw)>MAX_BYTES:raise ValueError('too_large')
        if expected is not None and int(expected)!=len(raw):raise ValueError('incomplete_download')
    if hashlib.md5(raw).hexdigest()!=locator['expected_md5']:
        raise ValueError('comment_image_md5_mismatch')
    fmt=image_format(raw)
    if not fmt:raise ValueError('not_supported_image_bytes')
    with Image.open(io.BytesIO(raw)) as image:
        if image.width*image.height>40_000_000:raise ValueError('comment_image_dimensions_exceed_budget')
        image.load();width,height=image.size
    return raw,fmt,{'verified_md5':locator['expected_md5'],'width':width,'height':height,
                   'verification':'source_md5_and_image_decode'}
