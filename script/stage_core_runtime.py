"""Embed a hash-bound core in the app; no install or state access."""
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import ast

ROOT = Path(__file__).resolve().parents[1]


def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()

def inputs(private=False):
    if not private:
        import importlib.util
        spec = importlib.util.spec_from_file_location("public_core", ROOT/"script/export_public_core.py")
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        sources = {str(p) for p in module.closure()}
    else:
        manifest = json.loads((ROOT/"script/core_runtime_sources.json").read_text())
        listed = manifest.get("modules")
        if manifest.get("schema") != 1 or type(listed) is not list or listed != sorted(set(listed)):
            raise ValueError("invalid_core_source_manifest")
        if any(type(p) is not str or not p.startswith("arl/") or not p.endswith(".py") or ".." in Path(p).parts or (ROOT/p).is_symlink() for p in listed):
            raise ValueError("invalid_core_source_manifest")
        actual = {str(p.relative_to(ROOT)) for p in (ROOT/"arl").rglob("*.py") if "__pycache__" not in p.parts}
        if set(listed) != actual: raise ValueError("core_source_set_changed")
        sources = set(listed) | {"script/core_runtime_sources.json"}
    sources |= {"arl/install_transaction.py", "arl/install_platform.py", "arl/install_cli.py"}
    sources |= {"docs/mio-tools.json", "docs/service-connections.json", "script/bundled_runtime_entry.py", "script/stage_core_runtime.py"}
    if private:
        sources |= {"build/PeerSignatureHelper", "integrations/nas/attachment_bridge.py",
                    "integrations/nas/file_params_importer.py"}
    return sorted(sources)

def stage(app, private=False):
    sources = inputs(private)
    before = {name: sha(ROOT/name) for name in sources}
    target = Path(app)/"Contents/Resources/CoreRuntime"
    if target.exists(): raise ValueError("core_runtime_exists")
    target.mkdir(parents=True)
    for name in sources:
        if name.startswith("script/") and name != "script/bundled_runtime_entry.py": continue
        source = ROOT/name
        if source.is_symlink() or not source.is_file(): raise ValueError("invalid_core_source")
        relative = Path("entry.py") if name == "script/bundled_runtime_entry.py" else Path("code")/name
        destination = target/relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination)
        destination.chmod(0o555 if name == "build/PeerSignatureHelper" else 0o444)
    digest = hashlib.sha256()
    root = target/"code/arl"
    for path in sorted(root.rglob("*.py")):
        name = str(path.relative_to(root)).encode(); raw = path.read_bytes()
        digest.update(len(name).to_bytes(4,"big")+name); digest.update(len(raw).to_bytes(8,"big")+raw)
    version = next(ast.literal_eval(n.value) for n in ast.parse((ROOT/"arl/__init__.py").read_text()).body if isinstance(n,ast.Assign) and any(isinstance(t,ast.Name) and t.id=="VERSION" for t in n.targets))
    manifest = {"version":version, "schema":1,"protocol":"arl/1","store_version":4,
        "profile":"local-compatibility" if private else "public-core-zero-grants",
        "source_sha256":digest.hexdigest(), "files":{str(p.relative_to(target)):sha(p) for p in target.rglob("*") if p.is_file()}}
    (target/"manifest.json").write_text(json.dumps(manifest, sort_keys=True, indent=2)+"\n")
    (target/"manifest.json").chmod(0o444)
    # Files were already read-only; directories must also reject creation of
    # __pycache__. All database/log/temp writes use the separate state home.
    for directory in [target, *[p for p in target.rglob("*") if p.is_dir()]]:
        directory.chmod(0o555)
    info_path = Path(app)/"Contents/Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    info["ARLCoreRuntimeManifestSHA256"] = sha(target/"manifest.json")
    info["ARLCoreRuntimeSourceSHA256"] = digest.hexdigest()
    mode = info_path.stat().st_mode & 0o777; info_path.chmod(mode|0o200)
    info_path.write_bytes(plistlib.dumps(info)); info_path.chmod(mode)
    if before != {name:sha(ROOT/name) for name in sources}: raise ValueError("core_source_changed")
    return {"profile":manifest["profile"], "manifest_sha256":info["ARLCoreRuntimeManifestSHA256"],
        "source_sha256":digest.hexdigest(), "files":len(manifest["files"]), "activation_required":True,
        "installed":False, "grants_changed":False}
