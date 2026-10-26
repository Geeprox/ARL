"""Decode only the bounded structural error packet from an existing readback JSON."""
import json
import math
import re
import sys
import zlib


def unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('duplicate_context_key')
        result[key] = value
    return result


def decode(rows):
    selected = [r for r in rows if r.get('code') in [-97200, -97201]
                or isinstance(r.get('code'), int) and -97395 <= r['code'] <= -97300]
    if not selected:
        return None
    value = lambda r: r.get('subCode', r.get('sub_code'))
    assert len(selected) >= 2 and selected[0]['code'] == -97200 and selected[1]['code'] == -97201
    header, length = value(selected[0]), value(selected[1])
    assert type(header) is int and 110000 <= header <= 145000
    assert type(length) is int and 0 <= length <= 223
    if length == 0:
        assert len(selected) == 2
        return {'header': header, 'packet_complete': False, 'reason': 'diagnostic_budget'}
    assert len(selected) == 2 + math.ceil(length * 8 / 19)
    accumulator = bits = 0
    data = bytearray()
    for index, row in enumerate(selected[2:]):
        n = value(row)
        assert row['code'] == -97300 - index and type(n) is int and 0 <= n < 2**19
        accumulator = accumulator * 2**19 + n
        bits += 19
        while bits >= 8:
            bits -= 8
            digit, accumulator = divmod(accumulator, 2**bits)
            data.append(digit)
    decoder = zlib.decompressobj(-15)
    raw = decoder.decompress(bytes(data[:length]), 32769)
    assert len(raw) <= 32768 and decoder.eof and not decoder.unused_data and not decoder.unconsumed_tail
    shape = json.loads(raw, object_pairs_hook=unique)
    assert set(shape) == {'v', 's', 'r', 't', 'q', 'n', 'a', 'h', 'o'} and shape['v'] == 1
    assert type(shape['s']) is int and 1 <= shape['s'] <= 4
    assert type(shape['r']) is int and (shape['r'] == 0 or -97050 <= shape['r'] <= -97001)
    assert shape['t'] in 'XZAOSNB' and len(shape['t']) == 1
    assert len(shape['q']) == 3 and all(type(n) is int and 0 <= n <= 15 for n in shape['q'])
    assert 0 <= shape['q'][1] <= shape['q'][0] <= 4
    assert type(shape['h']) is int and 0 <= shape['h'] <= 512
    assert type(shape['o']) is int and 0 <= shape['o'] <= 15
    forbidden = re.compile(r'token|credential|secret|auth|cookie|password|account|user|profile|login|device|phone|email|address', re.I)

    def path_ok(path):
        assert isinstance(path, str) and len(path) <= 170
        assert re.fullmatch(r'\$(?:\.[A-Za-z_][A-Za-z0-9_]{0,31}){0,4}', path)
        assert not forbidden.search(path)

    def fields_ok(fields):
        assert isinstance(fields, list) and len(fields) <= 16
        for field in fields:
            assert isinstance(field, str) and re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]{0,31}:[ZAOSNBX]', field)
            assert not forbidden.search(field.split(':')[0])

    assert isinstance(shape['n'], list) and len(shape['n']) <= 12
    for path, fields in shape['n']:
        path_ok(path)
        fields_ok(fields)
    assert isinstance(shape['a'], list) and len(shape['a']) <= 8
    for path, length, kind, fields in shape['a']:
        path_ok(path)
        assert type(length) is int and 0 <= length <= 524288 and kind in 'XZAOSNB' and len(kind) == 1
        fields_ok(fields)
    expected = 100000 + shape['s'] * 10000 + shape['q'][0] * 1000 + shape['q'][1] * 100 + 'XZAOSNB'.index(shape['t']) * 10 + (shape['o'] == 0)
    assert header == expected
    return {'header': header, 'packet_complete': True, 'shape_complete': shape['o'] == 0, 'shape': shape}


if __name__ == '__main__':
    with open(sys.argv[1], 'rb') as stream:
        raw = stream.read(1048577)
    assert len(raw) <= 1048576
    value = json.loads(raw, object_pairs_hook=unique)
    groups = {}
    for event in value['events']:
        row = event['diagnostic']
        call_id = row['callID']
        assert re.fullmatch(r'[A-Fa-f0-9-]{36}', call_id)
        groups.setdefault(call_id, []).append(row)
    result = {call_id: decoded for call_id, rows in groups.items() if (decoded := decode(rows)) is not None}
    print(json.dumps(result, ensure_ascii=False, indent=2))
