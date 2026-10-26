"""Fixed nested Mio build from a verified offline resource template.
Never accesses keys, opens an account, creates a tunnel or installs an app.
"""
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import stat

ROOT=Path(__file__).resolve().parents[1]
RELATIVE="Contents/Library/LoginItems/ARLMioAppleBridge.app"

def inputs():
    recipe=json.loads((ROOT/"script/mio_native_recipe.json").read_text())
    for row in recipe["sources"]:
        if hashlib.sha256((ROOT/row["path"]).read_bytes()).hexdigest()!=row["sha256"]: raise ValueError("mio_source_pin_changed")
    return [row["path"] for row in recipe["sources"]]+["script/stage_mio_runtime.py", "script/mio_native_recipe.json"]

def preflight(config,inventory):
    source=ROOT/config["template"]
    if source.is_symlink() or not source.is_dir():raise ValueError("mio_template_missing")
    files=inventory(source)
    pin=hashlib.sha256(json.dumps(files,sort_keys=True,separators=(",",":")).encode()).hexdigest()
    if pin!=config["inventory_sha256"]:raise ValueError("mio_template_changed")
    info=plistlib.loads((source/"Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier")!="local.arl.mioapplebridge" or info.get("CFBundleExecutable")!="ARLMioAppleBridge":raise ValueError("mio_template_identity")
    if not isinstance(info.get("ARLApprovedPolicySHA256"),str) or len(info["ARLApprovedPolicySHA256"])!=64:raise ValueError("mio_template_unsealed")
    return source

RUNTIME_MANIFEST_SHA256="74ab77c977187fd42e2fe30c83ed2407a31d60ea86405a98d8317d8e9475a2db"
RUNTIME_MODES={"tunnel-client":0o755,"cloudflared":0o755,"cloudflared-manifest.json":0o644,
               "LICENSE":0o644,"NOTICE":0o644,"sbom.spdx.json":0o644}

def verify_runtime(root, repair_modes=False):
    """Restore only modes from the exact immutable runtime seal before signing."""
    root=Path(root);manifest_path=root/"manifest.json"
    if root.is_symlink() or manifest_path.is_symlink():raise ValueError("mio_runtime_symlink")
    raw=manifest_path.read_bytes()
    if hashlib.sha256(raw).hexdigest()!=RUNTIME_MANIFEST_SHA256:raise ValueError("mio_runtime_seal_changed")
    rows=json.loads(raw)["files"]
    if set(rows)!=set(RUNTIME_MODES) or {p.name for p in root.iterdir()}!=set(rows)|{"manifest.json"}:raise ValueError("mio_runtime_inventory_changed")
    # Validate all contents first. Never grant execution to an unsealed file.
    for name,mode in RUNTIME_MODES.items():
        path=root/name;row=rows[name]
        if path.is_symlink() or not path.is_file() or row["mode"]!=mode or path.stat().st_size!=row["bytes"] or hashlib.sha256(path.read_bytes()).hexdigest()!=row["sha256"]:
            raise ValueError("mio_runtime_resource_changed")
    for name,mode in {**RUNTIME_MODES,"manifest.json":0o644}.items():
        path=root/name
        if repair_modes:path.chmod(mode)
        if stat.S_IMODE(path.stat().st_mode)!=mode:raise ValueError("mio_runtime_mode_changed")
    return {"sealed_resources":len(rows),"manifest_sha256":RUNTIME_MANIFEST_SHA256,"sealed_modes_verified":True}

def stage(app,template,build,policy_sha256=None,verified_template=False):
    target=Path(app)/RELATIVE
    if target.exists():raise ValueError("mio_stage_exists")
    shutil.copytree(template,target)
    if verified_template:
        # Only a complete, signature/inventory-verified baseline may supply this
        # resource shell. Remove code/seal in the NEW staging copy, then compile
        # all helper inputs against the same frozen SDK source as the parent.
        target.chmod(0o700);(target/'Contents').chmod(0o700)
        for directory in [target/'Contents/MacOS',target/'Contents/_CodeSignature']:
            if directory.exists():
                for p in [directory,*directory.rglob('*')]:p.chmod(0o700 if p.is_dir() else 0o600)
                shutil.rmtree(directory)
    runtime=verify_runtime(target/"Contents/Resources/MioRuntime",repair_modes=True)
    (target/"Contents/MacOS").mkdir()
    info_path=target/"Contents/Info.plist"
    info_path.chmod(0o600)
    info=plistlib.loads(info_path.read_bytes());info["CFBundleVersion"]=str(build)
    if policy_sha256:
        if len(policy_sha256)!=64 or any(c not in "abcdef0123456789" for c in policy_sha256):raise ValueError("invalid_mio_policy_seal")
        info["ARLApprovedPolicySHA256"]=policy_sha256
    info_path.write_bytes(plistlib.dumps(info))
    return {"relative_bundle":RELATIVE,"existing_authority_preserved":True,"existing_tunnel_runtime_preserved":True,"runtime":runtime,"installed":False}

def compile_step(output,swiftc,sdk):
    app=Path(output)/"package/ARL.app"/RELATIVE
    sources=[row["path"] for row in json.loads((ROOT/"script/mio_native_recipe.json").read_text())["sources"]]
    return {"name":"Mio_nested_host","seconds":180,"argv":[swiftc,"-swift-version","6","-j","1","-sdk",sdk,"-target","arm64-apple-macos14.0","-module-cache-path",str(ROOT/"build/cache/ModuleCache"),
        *[str(ROOT/p) for p in sources],"-framework","Security","-framework","EventKit","-framework","AppKit","-framework","CoreGraphics","-o",str(app/"Contents/MacOS/ARLMioAppleBridge")]}
