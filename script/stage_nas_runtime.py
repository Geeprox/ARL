"""Offline NAS runtime staging. No download, pip install, Keychain lookup or application launch."""
from pathlib import Path
import hashlib
import json
import os
import plistlib
import shutil
import stat
import subprocess

ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / "vendor/nas"
MAGICS = {b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"}
ENV = {"PATH":"/usr/bin:/bin", "TMPDIR":"/tmp", "LANG":"C", "LC_ALL":"C"}

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def inventory(root, *, links=False):
    result = {}
    for path in sorted(root.rglob("*")):
        name = str(path.relative_to(root))
        if path.is_symlink():
            target = path.resolve(strict=True)
            if not target.is_relative_to(root.resolve()):
                raise ValueError("external runtime link")
            if links:
                result[name] = {"link":os.readlink(path)}
                continue
            raise ValueError("staged runtime symlink")
        if path.is_file():
            result[name] = {"sha256":sha(path), "bytes":path.stat().st_size,
                            "mode":stat.S_IMODE(path.stat().st_mode)}
        elif not path.is_dir():
            raise ValueError("runtime special file")
    return result

def source_inputs():
    names = ["script/stage_nas_runtime.py", "vendor/nas/DEPENDENCIES.lock.json",
             "vendor/nas/CACHE.json", "vendor/nas/python-source.json"]
    for folder in ["integrations/nas/runtime", "arl_nas_credential", "arl_nas_upload_new"]:
        for path in sorted((ROOT/folder).rglob("*")):
            if path.is_file() and "__pycache__" not in path.parts and path.name not in {"FRIDAY-NAS-PROVENANCE.json", "friday_bridge.py"}:
                names.append(str(path.relative_to(ROOT)))
    names += ["integrations/nas/document_text.py", "integrations/nas/attachment_bridge.py",
              "integrations/nas/native/NASPDFTextExtractor.swift"]
    return names

def document_compile_step(output, swiftc, sdk, target):
    return {"name":"NASPDFTextExtractor", "phase":"prestage", "seconds":60,
            "argv":[swiftc,"-sdk",sdk,"-j","1","-swift-version","6","-target",target,
                    "-parse-as-library","-module-cache-path",str(ROOT/"build/cache/ModuleCache"),
                    str(ROOT/"integrations/nas/native/NASPDFTextExtractor.swift"),
                    "-o",str(Path(output)/"work/NASPDFTextExtractor")]}

def import_probe_command(app):
    """Import the actual staged entry with its isolated bundled interpreter.
    Definitions only: no pipe host, network, Keychain or business operation.
    """
    root = Path(app)/"Contents/Resources/NASRuntime"
    code = ("import runpy,sys; from pathlib import Path; "
            "root=Path(sys.argv[1]); sys.path.insert(0,str(root)); "
            "runpy.run_path(str(root/'nas_host.py'),run_name='arl_packaged_import_check'); import nas_document_host; from integrations.nas import document_text; "
            "print('NAS packaged imports: PASS; network=0 credentials=0')")
    return {"name":"verify_NAS_packaged_imports", "seconds":15,
            "argv":[str(root/"python/bin/python3.12"),"-I","-B","-c",code,str(root/"Runtime")]}

def preflight(cache_pin):
    cache_path = CACHE / "CACHE.json"
    if sha(cache_path) != cache_pin:
        raise ValueError("NAS cache pin mismatch")
    manifest = json.loads(cache_path.read_text())
    if manifest["python"] != inventory(CACHE/"python",links=True):
        raise ValueError("NAS interpreter/dependency cache changed")
    if manifest["licenses"] != inventory(CACHE/"license-source/python/licenses"):
        raise ValueError("NAS license cache changed")
    return manifest

def normalize_permissions(root):
    """Only freshly staged resources; never the vendor cache/installed app."""
    if root.is_symlink() or not root.is_dir(): raise ValueError("unsafe NAS stage")
    for path in [root,*root.rglob("*")]:
        if path.is_symlink(): raise ValueError("staged runtime symlink")
        mode=stat.S_IMODE(path.stat().st_mode)
        if mode & 0o7000: raise ValueError("staged runtime special mode")
        relative = path.relative_to(root)
        import_tree = bool(relative.parts) and relative.parts[0] in {'python', 'Runtime', 'Tools'}
        # CPython ignores cache-write permission failures and still imports.
        # Code/import trees are immutable in the signed bundle, including when
        # an external diagnostic accidentally omits -B. Runtime state is outside.
        path.chmod(mode & ~(0o222 if import_tree else 0o022))

def refresh_staged_permissions(app):
    """Verified incremental reuse: change modes/metadata, retain signed code.
    The caller has already validated the complete base package inventory.
    """
    root=app/"Contents/Resources/NASRuntime";info_path=app/"Contents/Info.plist"
    info=plistlib.loads(info_path.read_bytes());inv_path=root/"inventory.json"
    if sha(inv_path)!=info["ARLNASRuntimeInventorySHA256"]:raise ValueError("NAS seal changed")
    old=json.loads(inv_path.read_text());actual=inventory(root);actual.pop("inventory.json",None)
    if actual!=old:raise ValueError("NAS staged inventory changed")
    normalize_permissions(root)
    provenance=root/"provenance.json";data=json.loads(provenance.read_text())
    data["source_inputs"]["script/stage_nas_runtime.py"]=sha(Path(__file__))
    mode=stat.S_IMODE(provenance.stat().st_mode);provenance.chmod(mode|0o200)
    provenance.write_text(json.dumps(data,sort_keys=True,indent=2)+"\n");provenance.chmod(mode)
    rows=inventory(root);rows.pop("inventory.json",None)
    mode=stat.S_IMODE(inv_path.stat().st_mode);inv_path.chmod(mode|0o200)
    inv_path.write_text(json.dumps(rows,sort_keys=True,indent=2)+"\n");inv_path.chmod(mode)
    info["ARLNASRuntimeInventorySHA256"]=sha(inv_path)
    mode=stat.S_IMODE(info_path.stat().st_mode);info_path.chmod(mode|0o200)
    info_path.write_bytes(plistlib.dumps(info));info_path.chmod(mode)
    return {"inventory_sha256":sha(inv_path),"files":len(rows),"bytes":sum(r["bytes"] for r in rows.values()),"permissions_normalized":True,"nested_code_bytes_reused":True}

def stage(app, *, cache_pin, build_only, signing_identity, document_worker=None):
    manifest = preflight(cache_pin)
    output = app / "Contents/Resources/NASRuntime"
    if output.exists():
        raise ValueError("NAS stage already exists")
    output.mkdir()
    def ignore(directory, names):
        # Omit installers, caches and development-only data. Keep all runtime licenses.
        dropped = {"__pycache__", "pip", "ensurepip", "idlelib"}
        return [n for n in names if n in dropped or n.startswith("pip-") and n.endswith(".dist-info")]
    shutil.copytree(CACHE/"python",output/"python",symlinks=False,ignore=ignore)
    # Bin contains no generic installer entrypoint in the distributed runtime.
    for path in (output/"python/bin").iterdir():
        if path.name not in {"python3.12"} and path.is_file():
            path.unlink()
    runtime = output/"Runtime"
    shutil.copytree(ROOT/"integrations/nas/runtime",runtime,ignore=shutil.ignore_patterns("__pycache__", "FRIDAY-NAS-PROVENANCE.json", "friday_bridge.py"))
    for package in ["arl_nas_credential","arl_nas_upload_new"]:
        shutil.copytree(ROOT/package,runtime/package,ignore=shutil.ignore_patterns("__pycache__", "FRIDAY-NAS-PROVENANCE.json", "friday_bridge.py"))
    components = runtime/"integrations/nas"
    components.mkdir(parents=True)
    for name in ["attachment_bridge.py", "document_text.py"]:
        shutil.copyfile(ROOT/"integrations/nas"/name,components/name)
    if document_worker is None or Path(document_worker).is_symlink() or not Path(document_worker).is_file():
        raise ValueError("NAS document worker missing")
    tools=output/"Tools";tools.mkdir()
    shutil.copyfile(document_worker,tools/"NASPDFTextExtractor")
    (tools/"NASPDFTextExtractor").chmod(0o755)
    shutil.copytree(CACHE/"license-source/python/licenses",output/"Licenses/Python")
    shutil.copy2(CACHE/"DEPENDENCIES.lock.json",output/"Licenses/DEPENDENCIES.lock.json")
    # Pin all first-party consumed code independently of runtime packaging.
    source = {name:sha(ROOT/name) for name in source_inputs()}
    (output/"provenance.json").write_text(json.dumps({"schema":1,"source_inputs":source,
        "python_archive":json.loads((CACHE/"python-source.json").read_text())["sha256"],
        "no_system_python":True,"user_installs_required":False},sort_keys=True,indent=2)+"\n")
    signed = []
    if not build_only:
        env = {**ENV,"HOME":str(Path.home())}
        paths = []
        for path in output.rglob("*"):
            if path.is_file():
                with path.open("rb") as handle:
                    if handle.read(4) in MAGICS:
                        paths.append(path)
        paths.sort(key=lambda p:(p==output/"python/bin/python3.12",str(p)))
        for path in paths:
            result = subprocess.run(["/usr/bin/codesign","--force","--options","runtime",
                "--timestamp=none","--sign",signing_identity,str(path)],env=env,
                stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=30)
            if result.returncode:
                raise ValueError("NAS nested signing failed: "+str(path.relative_to(output)))
            signed.append(str(path.relative_to(output)))
    normalize_permissions(output)
    files = inventory(output)
    (output/"inventory.json").write_text(json.dumps(files,sort_keys=True,indent=2)+"\n")
    pin = sha(output/"inventory.json")
    info_path = app/"Contents/Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    info["ARLNASRuntimeInventorySHA256"] = pin
    info_path.write_bytes(plistlib.dumps(info))
    preflight(cache_pin)
    return {"inventory_sha256":pin,"files":len(files),"native_files_signed":signed,
            "bytes":sum(row["bytes"] for row in files.values()),"build_only":build_only}
