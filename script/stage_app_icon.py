"""Validated, source-pinned main App icon. No signing identity or runtime changes."""
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import stat
import struct

ROOT=Path(__file__).resolve().parents[1]
ASSET='macOS/ARLControl/Resources/AppIcon/'
FILES=[ASSET+name for name in ('approved-arl-crop.png','AppIcon-1024.png','ARL.icns','provenance.json')]

def source_inputs():
    return ['script/stage_app_icon.py','script/make_app_icon.py',*FILES]

def regular(path):
    path=Path(path)
    if any(p.is_symlink() for p in (path,*path.parents)) or not path.is_file():
        raise ValueError('app_icon_regular_file_required')
    return path.read_bytes()

def preflight():
    record=json.loads(regular(ROOT/(ASSET+'provenance.json')))
    expected={'approved-arl-crop.png':'approved_crop_sha256','AppIcon-1024.png':'master_sha256','ARL.icns':'icns_sha256'}
    for name,key in expected.items():
        if hashlib.sha256(regular(ROOT/(ASSET+name))).hexdigest()!=record[key]:
            raise ValueError('app_icon_source_changed')
    png=regular(ROOT/(ASSET+'AppIcon-1024.png'))
    if png[:8]!=b'\x89PNG\r\n\x1a\n' or struct.unpack('>II',png[16:24])!=(1024,1024) or png[24:29]!=bytes([8,6,0,0,0]):
        raise ValueError('app_icon_rgba_master_required')
    icns=regular(ROOT/(ASSET+'ARL.icns'))
    if icns[:4]!=b'icns' or struct.unpack('>I',icns[4:8])[0]!=len(icns):
        raise ValueError('app_icon_invalid_container')
    offset=8;types=set()
    while offset<len(icns):
        kind=icns[offset:offset+4];length=struct.unpack('>I',icns[offset+4:offset+8])[0]
        if length<8 or offset+length>len(icns):raise ValueError('app_icon_invalid_chunk')
        types.add(kind);offset+=length
    if not {b'ic07',b'ic08',b'ic09',b'ic10'}<=types or offset!=len(icns):
        raise ValueError('app_icon_resolution_missing')
    if record.get('origin')!='user-approved existing image; deterministic extraction' or record['verification']['rgb_modified_inside_mask']!=0:
        raise ValueError('app_icon_approved_pixel_provenance_required')
    return {'file':'ARL.icns','sha256':record['icns_sha256'],'master_sha256':record['master_sha256'],'rgba_master':True}

def stage(app):
    checked=preflight();app=Path(app);destination=app/'Contents/Resources'/checked['file']
    if destination.exists():raise ValueError('app_icon_staging_collision')
    shutil.copyfile(ROOT/(ASSET+checked['file']),destination);destination.chmod(0o644)
    info_path=app/'Contents/Info.plist';mode=stat.S_IMODE(info_path.stat().st_mode);info=plistlib.loads(regular(info_path))
    info['CFBundleIconFile']=checked['file']
    info_path.chmod(mode|0o200);info_path.write_bytes(plistlib.dumps(info));info_path.chmod(mode)
    if hashlib.sha256(destination.read_bytes()).hexdigest()!=checked['sha256']:
        raise ValueError('app_icon_stage_changed')
    return checked
