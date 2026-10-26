"""Populate an uninstalled helper candidate before signing; no live service calls."""
import hashlib
import json
from pathlib import Path
import plistlib
import shutil

INPUTS = ('arl/__init__.py', 'arl/contracts.py', 'arl/travel.py', 'arl/netease_music.py',
          'arl/service_connections.py', 'arl/mio_music.py', 'docs/mio-tools.json',
          'docs/service-connections.json', 'integrations/mio_music/server.py')

def populate(source, app):
    source, app = Path(source).resolve(), Path(app).resolve()
    if app == (Path.home()/'Applications/ARL.app/Contents/Library/LoginItems/ARLMioAppleBridge.app').resolve():
        raise ValueError('installed_bundle_not_a_packaging_target')
    info_path = app / 'Contents/Info.plist'
    info = plistlib.loads(info_path.read_bytes())
    if info.get('CFBundleIdentifier') != 'local.arl.mioapplebridge':
        raise ValueError('wrong_helper_bundle')
    target = app / 'Contents/Resources/MioMusicBridge'
    if target.exists():
        raise ValueError('existing_resource_stage')
    pins = {}
    for relative in INPUTS:
        path = source / relative
        if path.is_symlink() or not path.is_file() or path.stat().st_size > 262144:
            raise ValueError('source_input_boundary')
        raw = path.read_bytes()
        pins[relative] = hashlib.sha256(raw).hexdigest()
        dest = target / relative
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(raw)
        dest.chmod(0o644)
    raw = (json.dumps(pins,sort_keys=True,indent=2)+'\n').encode()
    (target/'manifest.json').write_bytes(raw)
    info['ARLMioMusicBridgeManifestSHA256'] = hashlib.sha256(raw).hexdigest()
    info_path.write_bytes(plistlib.dumps(info))
    return {'resources':pins,'manifest_sha256':info['ARLMioMusicBridgeManifestSHA256'],
            'original14_legacy_server_modified':False,'credential_files_read':False}
