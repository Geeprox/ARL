"""Refresh code hashes for the same verified installed helper; never grant access."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import stat
import subprocess

ROOT = Path(__file__).resolve().parents[1]
APP = Path.home()/'Applications/ARL.app'
HOME_STATE = Path.home()/'Library/Application Support/ARL/reminders-v3'
HELPER = APP/'Contents/Library/LoginItems/ARLRemindersBridge.app'
KEYS = {'schema_version','helper_bundle_path','host_home','control_requirement','helper_requirement',
        'helper_executable_sha256','helper_designated_requirement_sha256','closure_sha256','policy_sha256'}


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def unique(pairs):
    result = {}
    for key, value in pairs:
        assert key not in result, 'DUPLICATE_METADATA_FIELD'
        result[key] = value
    return result


def decode(raw):
    assert len(raw) <= 65536
    return json.loads(raw, object_pairs_hook=unique)


def candidates(control, closure, actual, identity):
    assert set(control) == KEYS and type(control['schema_version']) is int and control['schema_version'] == 1
    assert identity['helper_bundle_id'] == 'local.arl.remindersbridge'
    assert identity['designated_requirement_sha256'] == control['helper_designated_requirement_sha256'], 'STABLE_IDENTITY_CHANGED'
    assert control['helper_bundle_path'] == str(HELPER) and control['host_home'] == str(HOME_STATE)
    assert set(closure) == set(actual) == {'Contents/Info.plist','Contents/MacOS/ARLRemindersBridge','Contents/_CodeSignature/CodeResources'}
    changed = {path for path in closure if closure[path] != actual[path]}
    assert changed <= {'Contents/MacOS/ARLRemindersBridge'}, 'HELPER_RESOURCES_OR_POLICY_CHANGED'
    assert actual['Contents/MacOS/ARLRemindersBridge'] == identity['executable_sha256']
    closure_bytes = (json.dumps(actual, indent=2, sort_keys=True)+'\n').encode()
    updated = dict(control)
    updated['helper_executable_sha256'] = identity['executable_sha256']
    updated['closure_sha256'] = sha(closure_bytes)
    assert {key for key in control if control[key] != updated[key]} <= {'helper_executable_sha256','closure_sha256'}
    return closure_bytes, (json.dumps(updated, indent=2, sort_keys=True)+'\n').encode()


def safe(path):
    for part in (path, *path.parents):
        assert not part.is_symlink(), 'SYMLINK_REJECTED'
    row = path.stat()
    assert row.st_uid == os.getuid() and row.st_nlink == 1 and stat.S_ISREG(row.st_mode)
    assert row.st_mode & 0o077 == 0


def replace(path, raw, before):
    safe(path)
    assert path.read_bytes() == before, 'PUBLIC_METADATA_CHANGED'
    temporary = path.with_name('.'+path.name+'.code-rebind')
    fd = os.open(temporary, os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'wb') as stream:
        stream.write(raw);stream.flush();os.fsync(stream.fileno())
    assert path.read_bytes() == before
    os.replace(temporary, path)
    directory = os.open(path.parent, os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
    try: os.fsync(directory)
    finally: os.close(directory)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    assert os.getuid() == 501
    control_path, closure_path = HOME_STATE/'control.json', HOME_STATE/'closure.json'
    safe(control_path);safe(closure_path)
    control_raw, closure_raw = control_path.read_bytes(), closure_path.read_bytes()
    control, closure = decode(control_raw), decode(closure_raw)
    assert sha(closure_raw) == control['closure_sha256']
    specification = importlib.util.spec_from_file_location('reminders_identity', ROOT/'integrations/reminders_v3/build_static.py')
    module = importlib.util.module_from_spec(specification);specification.loader.exec_module(module)
    assert control['helper_requirement'] == module.HELPER_REQUIREMENT
    subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict','-R','='+module.HELPER_REQUIREMENT,str(HELPER)],check=True,capture_output=True)
    info = plistlib.loads((HELPER/'Contents/Info.plist').read_bytes())
    assert info['ARLFirstRemindersPolicySHA256'] == control['policy_sha256'] == sha((HOME_STATE/'activation.json').read_bytes())
    result = subprocess.run([str(HELPER/'Contents/MacOS/ARLRemindersBridge'),'--permissions-status'],capture_output=True,check=True,timeout=10)
    status = decode(result.stdout)
    assert all(row['prompts_requested'] is False and row['data_read'] is False for row in status['records'])
    actual = {path:sha((HELPER/path).read_bytes()) for path in closure}
    new_closure, new_control = candidates(control, closure, actual, status['identity'])
    backup = ROOT/'build/audit/native-product-20261013/reminders-rebind'
    if args.apply:
        assert not backup.exists(), 'RETAINED_REPAIR_EXISTS'
        backup.mkdir(mode=0o700)
        for name, data in [('control.before.json',control_raw),('closure.before.json',closure_raw)]:
            file = backup/name;file.write_bytes(data);file.chmod(0o600)
        # A reader between replacements fails closed on the hash, never gains scope.
        replace(closure_path, new_closure, closure_raw)
        try: replace(control_path, new_control, control_raw)
        except BaseException:
            if closure_path.read_bytes() == new_closure: replace(closure_path, closure_raw, new_closure)
            raise
    print(json.dumps({'status':'CODE_BINDING_REFRESHED' if args.apply else 'CODE_BINDING_READY',
        'stable_requirement_unchanged':True,'changed_control_fields':['helper_executable_sha256','closure_sha256'],
        'permission_states':sorted({row['permission_state'] for row in status['records']}),
        'permissions_requested':False,'source_history_or_scope_modified':False,'GUI_or_daemon_started':False}))

if __name__ == '__main__': main()
