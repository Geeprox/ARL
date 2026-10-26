"""Prepare exact path-only Mio migration candidates in private build storage.
Never modifies deployment, creates an account/tunnel or reads Keychain.
"""
import hashlib
import json
import os
import plistlib
from pathlib import Path
import stat

ROOT=Path(__file__).resolve().parents[1]

def sha(raw):return hashlib.sha256(raw).hexdigest()

def owned_file(path):
    for p in (path,*path.parents):
        if p.is_symlink():raise ValueError("migration_symlink")
    info=path.stat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid!=os.geteuid() or info.st_mode&0o077:raise ValueError("migration_file_not_private")
    return path.read_bytes()

def candidates(activation_raw,profile_raw,old_executable,new_executable):
    activation=json.loads(activation_raw)
    if type(activation.get("schema_version")) is not int or activation.get("schema_version") not in {2,3} or type(activation.get("enabled")) is not int or activation.get("enabled")!=1 or activation.get("profile_sha256")!=sha(profile_raw):raise ValueError("mio_activation_changed")
    if activation["schema_version"] == 3 and activation.get("calendar_execution_policy") != "os_tcc_only":raise ValueError("mio_calendar_policy_changed")
    count=profile_raw.count(old_executable.encode())
    if count!=1:raise ValueError("mio_gateway_path_not_unique")
    updated=profile_raw.replace(old_executable.encode(),new_executable.encode())
    following=dict(activation);following["profile_sha256"]=sha(updated)
    raw=(json.dumps(following,indent=2,sort_keys=True)+"\n").encode()
    if {k for k in activation if activation[k]!=following[k]}!={"profile_sha256"}:raise ValueError("mio_scope_changed")
    return raw,updated

def prepare():
    state=Path.home()/"Library/Application Support/ARL/mio-apple"
    activation_raw=owned_file(state/"activation.json")
    installed=Path.home()/"Applications/ARLMioAppleBridge.app/Contents/Info.plist"
    if plistlib.loads(installed.read_bytes()).get("ARLApprovedPolicySHA256")!=sha(activation_raw):raise ValueError("mio_existing_approval_changed")
    activation=json.loads(activation_raw);profile=Path(activation["profile"])
    profile_raw=owned_file(profile)
    old=Path.home()/"Applications/ARLMioAppleBridge.app/Contents/MacOS/ARLMioAppleBridge"
    new=Path.home()/"Applications/ARL.app/Contents/Library/LoginItems/ARLMioAppleBridge.app/Contents/MacOS/ARLMioAppleBridge"
    following,updated=candidates(activation_raw,profile_raw,str(old),str(new))
    output=ROOT/"build/local-config/MioMigration"
    if output.exists():
        receipt=json.loads(owned_file(output/"receipt.json"))
        if receipt["before_activation_sha256"]!=sha(activation_raw) or receipt["before_profile_sha256"]!=sha(profile_raw):raise ValueError("mio_migration_preimage_changed")
    else:output.mkdir(mode=0o700)
    receipt={"schema":1,"before_activation_sha256":sha(activation_raw),"before_profile_sha256":sha(profile_raw),
        "after_activation_sha256":sha(following),"after_profile_sha256":sha(updated),"scope_fields_preserved":True,
        "only_gateway_path_changed":True,"installed":False,"live_configuration_changed":False}
    for name,raw in [("activation.json",following),("profile.yaml",updated),("receipt.json",(json.dumps(receipt,indent=2)+"\n").encode())]:
        path=output/name
        if path.exists() and owned_file(path)!=raw:raise ValueError("migration_candidate_changed")
        if not path.exists():
            fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
            with os.fdopen(fd,"wb") as f:f.write(raw)
    local=ROOT/"build/local-config/release_recipe.json"
    recipe=json.loads(owned_file(local))
    recipe["mio_runtime"]["policy_sha256"]=sha(following)
    local.write_text(json.dumps(recipe,indent=2)+"\n")
    return receipt

if __name__=="__main__":
    try:print(json.dumps(prepare()))
    except Exception:print(json.dumps({"error":"mio_migration_prepare_failed","live_configuration_changed":False}));raise SystemExit(1)
