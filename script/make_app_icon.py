"""Deterministically extract the approved ARL pixels and package a macOS icon.

No image generation or third-party Python packages. Run on macOS with sips/iconutil.
The optional dual-preview input stays private; the checked-in source crop contains
only ARL. Interior RGB values are copied exactly; alpha removes the outer canvas.
"""
import argparse
import binascii
import hashlib
import json
from pathlib import Path
import shutil
import struct
import subprocess
import zlib

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT/'macOS/ARLControl/Resources/AppIcon'
CANVAS_SHA256 = '06ae180632127b5c3897521a0cb07c2b87806d64f3237ac32b0e2895cba14b63'
CROP = (79, 105, 650, 650)
COLOR_CHUNKS = {b'sRGB', b'gAMA', b'cHRM', b'iCCP'}

def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def read_png(path):
    data = Path(path).read_bytes()
    if data[:8] != b'\x89PNG\r\n\x1a\n':
        raise ValueError('expected_png')
    offset, compressed, metadata = 8, bytearray(), []
    while offset < len(data):
        length, kind = struct.unpack('>I4s', data[offset:offset+8])
        payload = data[offset+8:offset+8+length]
        crc = struct.unpack('>I', data[offset+8+length:offset+12+length])[0]
        if binascii.crc32(kind+payload) & 0xffffffff != crc:
            raise ValueError('png_crc_changed')
        offset += length+12
        if kind == b'IHDR':
            w, h, depth, color, compression, filtering, interlace = struct.unpack('>IIBBBBB', payload)
            if depth != 8 or color not in (2, 6) or compression or filtering or interlace or w*h > 16_000_000:
                raise ValueError('unsupported_png_encoding')
        elif kind == b'IDAT':
            compressed.extend(payload)
        elif kind in COLOR_CHUNKS:
            metadata.append((kind, payload))
        elif kind == b'IEND':
            break
    channels = 3 if color == 2 else 4
    stride = w*channels
    decoded = zlib.decompress(compressed)
    if len(decoded) != (stride+1)*h:
        raise ValueError('png_size_changed')
    rows, previous, offset = [], bytearray(stride), 0
    for _ in range(h):
        method = decoded[offset]
        row = bytearray(decoded[offset+1:offset+1+stride]); offset += stride+1
        if method not in range(5):
            raise ValueError('invalid_png_filter')
        for i in range(stride):
            a = row[i-channels] if i >= channels else 0
            b = previous[i]
            c = previous[i-channels] if i >= channels else 0
            if method == 1:
                predicted = a
            elif method == 2:
                predicted = b
            elif method == 3:
                predicted = (a+b)//2
            elif method == 4:
                p = a+b-c
                pa, pb, pc = abs(p-a), abs(p-b), abs(p-c)
                predicted = a if pa <= pb and pa <= pc else b if pb <= pc else c
            else:
                predicted = 0
            row[i] = (row[i]+predicted) & 255
        rows.append(bytes(row)); previous = row
    return w, h, channels, rows, metadata

def write_png(path, width, height, channels, rows, metadata=()):
    def chunk(kind, payload):
        return struct.pack('>I', len(payload))+kind+payload+struct.pack('>I', binascii.crc32(kind+payload) & 0xffffffff)
    header = struct.pack('>IIBBBBB', width, height, 8, 2 if channels == 3 else 6, 0, 0, 0)
    raw = b''.join(b'\0'+bytes(row) for row in rows)
    data = b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR', header)
    data += b''.join(chunk(kind, payload) for kind, payload in metadata)
    data += chunk(b'IDAT', zlib.compress(raw, 9))+chunk(b'IEND', b'')
    Path(path).write_bytes(data)

def approved_crop(preview, destination):
    if sha(preview) != CANVAS_SHA256:
        raise ValueError('unapproved_preview')
    w, h, channels, rows, metadata = read_png(preview)
    if (w, h, channels) != (1669, 942, 3):
        raise ValueError('approved_preview_shape_changed')
    x, y, width, height = CROP
    cropped = [row[x*3:(x+width)*3] for row in rows[y:y+height]]
    write_png(destination, width, height, 3, cropped, metadata)

def extract(source, destination):
    width, height, channels, rows, metadata = read_png(source)
    if (width, height, channels) != (650, 650, 3):
        raise ValueError('approved_crop_shape_changed')
    output, contours, unchanged = [], [], 0
    for y, row in enumerate(rows):
        # The selected tile has a continuous peach outline. Neutral grey shadow
        # has no such chroma. Trace the original outline row by row, then retain
        # everything between both edges, including the light tile and inner art.
        hits = [x for x in range(width) if row[x*3]-row[x*3+2] >= 13 and row[x*3]-row[x*3+1] >= 4]
        rgba = bytearray(width*4)
        if hits:
            left, right = hits[0], hits[-1]
            if not 8 <= left <= 150 or not 495 <= right <= 641:
                raise ValueError('outline_not_the_approved_tile')
            contours.append((y, left, right))
            for x in range(left, right+1):
                rgba[x*4:x*4+4] = row[x*3:x*3+3]+b'\xff'; unchanged += 1
        output.append(bytes(rgba))
    if contours[0][0] != 11 or contours[-1][0] != 638 or len(contours) != 628:
        raise ValueError('approved_outline_changed')
    write_png(destination, width, height, 4, output, metadata)
    return {'opaque_pixels_copied_exactly':unchanged, 'source_size':[width, height],
            'alpha_boundary':'original_peach_outline', 'canvas_label_and_external_shadow_removed':True,
            'rgb_modified_inside_mask':0, 'outline_rows':len(contours)}

def run(*argv):
    subprocess.run(list(map(str, argv)), check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=30)

def package(cutout, output):
    resized = output/'tile-860.png'
    run('/usr/bin/sips', '-z', '860', '860', cutout, '--out', resized)
    w, h, channels, rows, metadata = read_png(resized)
    if (w, h, channels) != (860, 860, 4):
        raise ValueError('resampler_lost_alpha')
    canvas = [bytearray(1024*4) for _ in range(1024)]
    for y, row in enumerate(rows):
        canvas[y+82][82*4:(82+860)*4] = row
    master = output/'AppIcon-1024.png'
    write_png(master, 1024, 1024, 4, canvas, metadata)
    iconset = output/'ARL.iconset';iconset.mkdir(exist_ok=False)
    sizes = {'icon_16x16.png':16,'icon_16x16@2x.png':32,'icon_32x32.png':32,
             'icon_32x32@2x.png':64,'icon_128x128.png':128,'icon_128x128@2x.png':256,
             'icon_256x256.png':256,'icon_256x256@2x.png':512,
             'icon_512x512.png':512,'icon_512x512@2x.png':1024}
    for name, size in sizes.items():
        run('/usr/bin/sips','-z',size,size,master,'--out',iconset/name)
    icns = output/'ARL.icns';run('/usr/bin/iconutil','-c','icns',iconset,'-o',icns)
    container=icns.read_bytes()
    if container[:4] != b'icns':
        raise ValueError('invalid_icns')
    # Keep encoded image chunks, omit build metadata, and fix chunk order.
    # No image payload or color data is changed here.
    cursor=8;chunks=[]
    while cursor<len(container):
        kind=container[cursor:cursor+4];length=struct.unpack('>I',container[cursor+4:cursor+8])[0]
        if length<8 or cursor+length>len(container):raise ValueError('invalid_icns_chunk')
        if kind!=b'info':chunks.append((kind,container[cursor:cursor+length]))
        cursor+=length
    payload=b''.join(part for _,part in sorted(chunks))
    icns.write_bytes(b'icns'+struct.pack('>I',len(payload)+8)+payload)
    return master, icns

def qa_preview(master, destination):
    # Presentation for edge inspection only; production icon keeps true alpha.
    w,h,channels,rows,metadata = read_png(master)
    result=[]
    for y,row in enumerate(rows):
        light=bytearray();dark=bytearray()
        for x in range(w):
            r,g,b,a=row[x*4:x*4+4]
            checker=245 if (x//32+y//32)%2 else 215
            for output,background in [(light,checker),(dark,32)]:
                output.extend((round((v*a+background*(255-a))/255) for v in (r,g,b)))
        result.append(light+dark)
    write_png(destination,w*2,h,3,result,metadata)

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--preview',type=Path)
    parser.add_argument('--source',type=Path,default=ASSETS/'approved-arl-crop.png')
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--publish',action='store_true')
    args=parser.parse_args();output=args.output.absolute()
    if not output.is_relative_to(ROOT/'build') or not any(p.name.endswith('.noindex') for p in output.parents):
        raise ValueError('output_requires_repo_build_noindex')
    output.mkdir(parents=True,exist_ok=False)
    source=output/'approved-arl-crop.png'
    if args.preview:
        approved_crop(args.preview,source)
    else:
        record=json.loads((ASSETS/'provenance.json').read_text())
        if sha(args.source)!=record['approved_crop_sha256']:
            raise ValueError('approved_crop_hash_changed')
        shutil.copyfile(args.source,source)
    cutout=output/'cutout-native.png';verification=extract(source,cutout)
    master,icns=package(cutout,output);qa_preview(master,output/'edge-inspection.png')
    record={'schema':1,'asset':'ARL soft orange','origin':'user-approved existing image; deterministic extraction',
            'original_preview_sha256':CANVAS_SHA256,'crop_xywh':list(CROP),
            'approved_crop_sha256':sha(source),'master_sha256':sha(master),'icns_sha256':sha(icns),
            'master_size':[1024,1024],'master_alpha':True,'native_tile_resample':860,'canvas_offset':[82,82],
            'verification':verification,'generator':'script/make_app_icon.py'}
    (output/'provenance.json').write_text(json.dumps(record,indent=2)+'\n')
    if args.publish:
        ASSETS.mkdir(parents=True,exist_ok=True)
        for path in [source,master,icns,output/'provenance.json']:
            shutil.copyfile(path,ASSETS/path.name)
    print(json.dumps({'status':'PASS','output':str(output.relative_to(ROOT)),'published':args.publish,'verification':verification}))
if __name__=='__main__':main()
