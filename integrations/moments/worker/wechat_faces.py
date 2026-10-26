#!/usr/bin/env python3
"""Extract exact face resources from the observed shipped WeChat Qt resource.

No execution, process access or network. Unknown binary identities fail closed;
new versions require a new verified resource layout. Raw post text is untouched.
"""
from pathlib import Path
import argparse
import hashlib
import json
import re
import struct
import xml.etree.ElementTree as ET
import zlib

SOURCE_SHA256 = '6e82322680d7747020c305f67e932b235fe68b22578c24d9c524dabb31a4694a'
LAYOUT = {'tree': 0x11ad0d50, 'names': 0x11ad1a8c, 'data': 0x11ad2fd6,
          'entries': 154, 'entry_bytes': 22, 'architecture': 'arm64'}


def png_size(raw):
    if not raw.startswith(b'\x89PNG\r\n\x1a\n'):
        raise ValueError('Not a PNG resource')
    pos = 8
    dimensions = None
    while pos + 12 <= len(raw):
        size = struct.unpack_from('>I', raw, pos)[0]
        if size > 8 * 1024 * 1024 or pos + 12 + size > len(raw):
            raise ValueError('Truncated PNG resource')
        kind, chunk = raw[pos + 4:pos + 8], raw[pos + 8:pos + 8 + size]
        crc = struct.unpack_from('>I', raw, pos + 8 + size)[0]
        if zlib.crc32(kind + chunk) & 0xffffffff != crc:
            raise ValueError('PNG resource CRC mismatch')
        if kind == b'IHDR':
            if pos != 8 or size != 13:
                raise ValueError('Invalid PNG dimensions')
            dimensions = struct.unpack_from('>II', chunk)
        pos += size + 12
        if kind == b'IEND':
            if size or pos != len(raw) or not dimensions or not all(0 < n <= 4096 for n in dimensions):
                raise ValueError('Invalid PNG end')
            return dimensions
    raise ValueError('PNG resource end missing')


def resources(binary, layout=LAYOUT):
    """Parse bounded Qt v3 tree entries, BE UTF-16 names and resource payloads."""
    result = {}
    for index in range(layout['entries']):
        pos = layout['tree'] + index * layout['entry_bytes']
        name_offset, flags = struct.unpack_from('>IH', binary, pos)
        if flags & 2:
            continue
        if flags not in (0, 1):
            raise ValueError('Unsupported Qt compression flag')
        npos = layout['names'] + name_offset
        length = struct.unpack_from('>H', binary, npos)[0]
        if not 1 <= length <= 128:
            raise ValueError('Invalid Qt resource name')
        name = binary[npos + 6:npos + 6 + length * 2].decode('utf-16be')
        if not re.fullmatch(r'[A-Za-z0-9_ !.\-]+', name) or '/' in name or '..' in name:
            raise ValueError('Unsafe Qt resource name')
        data_offset = struct.unpack_from('>I', binary, pos + 10)[0]
        dpos = layout['data'] + data_offset
        size = struct.unpack_from('>I', binary, dpos)[0]
        if size > 8 * 1024 * 1024 or dpos + 4 + size > len(binary):
            raise ValueError('Invalid Qt resource size')
        raw = binary[dpos + 4:dpos + 4 + size]
        if flags == 1:
            expected = struct.unpack_from('>I', raw)[0]
            if expected > 8 * 1024 * 1024:
                raise ValueError('Oversized compressed Qt resource')
            decoder = zlib.decompressobj()
            raw = decoder.decompress(raw[4:], expected + 1)
            if len(raw) != expected or not decoder.eof or decoder.unused_data:
                raise ValueError('Invalid Qt compression stream')
        if name in result:
            raise ValueError('Duplicate resource name')
        result[name] = {'raw': raw, 'container_offset': dpos + 4, 'stored_bytes': size,
                        'compression': 'qcompress' if flags else 'none'}
    return result


def face_aliases(xml):
    if b'<!DOCTYPE' in xml.upper() or b'<!ENTITY' in xml.upper():
        raise ValueError('Unsupported face config entity')
    root = ET.fromstring(xml)
    result = {}
    for item in root.findall('emoji'):
        name = item.findtext('fileName')
        for key in ('key', 'cn-value', 'qq-value', 'en-value', 'tw-value', 'th-value'):
            token = item.findtext(key)
            if token and token.startswith('[') and token.endswith(']'):
                if token in result and result[token] != name:
                    raise ValueError('Ambiguous native face alias')
                result[token] = name
    return result


def extract(source, output):
    source, output = Path(source), Path(output)
    binary = source.read_bytes()
    if hashlib.sha256(binary).hexdigest() != SOURCE_SHA256:
        raise ValueError('Unverified WeChat artifact identity')
    records = resources(binary)
    aliases = face_aliases(records['newemoji-config.xml']['raw'])
    exported = {}
    evidence = []
    media = output / 'data' / 'media'
    media.mkdir(parents=True, exist_ok=True)
    for name, item in records.items():
        if not name.endswith('.png'):
            continue
        raw = item['raw']
        width, height = png_size(raw)
        sha = hashlib.sha256(raw).hexdigest()
        relative = 'media/' + sha + '.png'
        target = output / 'data' / relative
        if target.is_symlink():
            raise ValueError('Unsafe media destination')
        target.write_bytes(raw)
        exported[name] = relative
        evidence.append({k: v for k, v in item.items() if k != 'raw'} | {
            'name': name, 'sha256': sha, 'bytes': len(raw), 'width': width, 'height': height})
    mapping = {token: exported[name] for token, name in aliases.items() if name in exported}
    (output / 'wechat-face-map.json').write_text(json.dumps(mapping, ensure_ascii=False, indent=2) + '\n')
    report = {'source_sha256': SOURCE_SHA256, 'layout': LAYOUT,
              'schema': 'Qt v3 resource tree; BE UTF-16 names; exact native newemoji config aliases',
              'native_faces_mapped': len(set(aliases.values())), 'aliases': len(mapping),
              'png_files_extracted': len(evidence), 'resources': evidence,
              'raw_comment_content_unchanged': True, 'network_requests': 0,
              'limitations': ['Legacy expression_N order is not guessed; only explicit native XML aliases are mapped.']}
    (output / 'wechat-face-evidence.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', default='/Applications/WeChat.app/Contents/Resources/wechat.dylib')
    parser.add_argument('--output', type=Path, default=Path(__file__).parent)
    args = parser.parse_args()
    report = extract(args.source, args.output)
    print(json.dumps({k: report[k] for k in ('native_faces_mapped', 'aliases', 'png_files_extracted', 'network_requests')}))
