"""Retain a verified release ZIP and remove only its disposable App staging tree.
Run after candidate QA/installation. Check mode is read-only and idempotent.
"""
import argparse,hashlib,json,os
from pathlib import Path
import shutil,stat,subprocess,zipfile,uuid,fcntl,ctypes
from contextlib import contextmanager
ROOT=Path(__file__).resolve().parents[1]
LS='/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
def require(ok,code):
    if not ok:raise ValueError(code)
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def no_links(p):
    require(all(not q.is_symlink() for q in (p,*p.parents)),'archive_symlink')
def scoped_output(output):
    output=Path(output).absolute()
    require('..' not in output.parts,'archive_output_scope');no_links(output)
    output=output.resolve();build=(ROOT/'build').resolve()
    require(output.is_relative_to(build) and output!=build and any(p.name.endswith('.noindex') for p in (output,*output.parents) if p.is_relative_to(build)),'archive_output_scope')
    return output
def registered_paths(identifier='local.arl.control'):
    """Read only this bundle ID, without enumerating unrelated applications."""
    cf=ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
    ls=ctypes.CDLL('/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/LaunchServices')
    cf.CFStringCreateWithCString.argtypes=[ctypes.c_void_p,ctypes.c_char_p,ctypes.c_uint32];cf.CFStringCreateWithCString.restype=ctypes.c_void_p
    cf.CFRelease.argtypes=[ctypes.c_void_p]
    cf.CFErrorGetCode.argtypes=[ctypes.c_void_p];cf.CFErrorGetCode.restype=ctypes.c_long
    cf.CFArrayGetCount.argtypes=[ctypes.c_void_p];cf.CFArrayGetCount.restype=ctypes.c_long
    cf.CFArrayGetValueAtIndex.argtypes=[ctypes.c_void_p,ctypes.c_long];cf.CFArrayGetValueAtIndex.restype=ctypes.c_void_p
    cf.CFURLCopyFileSystemPath.argtypes=[ctypes.c_void_p,ctypes.c_int];cf.CFURLCopyFileSystemPath.restype=ctypes.c_void_p
    cf.CFStringGetCString.argtypes=[ctypes.c_void_p,ctypes.c_void_p,ctypes.c_long,ctypes.c_uint32];cf.CFStringGetCString.restype=ctypes.c_bool
    ls.LSCopyApplicationURLsForBundleIdentifier.argtypes=[ctypes.c_void_p,ctypes.POINTER(ctypes.c_void_p)];ls.LSCopyApplicationURLsForBundleIdentifier.restype=ctypes.c_void_p
    key=cf.CFStringCreateWithCString(None,identifier.encode(),0x08000100);error=ctypes.c_void_p()
    array=ls.LSCopyApplicationURLsForBundleIdentifier(key,ctypes.byref(error));cf.CFRelease(key);paths=[]
    try:
        if not array:
            require(error.value and cf.CFErrorGetCode(error)==-10814,'registered_apps_unavailable');return []
        count=cf.CFArrayGetCount(array);require(0<=count<=4096,'registered_apps_limit')
        for i in range(count):
            value=cf.CFURLCopyFileSystemPath(cf.CFArrayGetValueAtIndex(array,i),0);require(bool(value),'registered_path_unreadable')
            try:
                buffer=ctypes.create_string_buffer(4096);require(cf.CFStringGetCString(value,buffer,len(buffer),0x08000100),'registered_path_unreadable')
                paths.append(buffer.value.decode())
            finally:cf.CFRelease(value)
        return paths
    finally:
        if array:cf.CFRelease(array)
        if error.value:cf.CFRelease(error)
def unregister_staging(app):
    if str(app) not in registered_paths():return False
    result=subprocess.run([LS,'-u',str(app)],capture_output=True,timeout=20)
    require(result.returncode==0 and str(app) not in registered_paths(),'staging_entry_unregister_failed')
    return True
def _finalize(output,check=False):
    output=scoped_output(output)
    artifact=json.loads((output/'artifact.json').read_text());manifest_path=output/artifact['manifest'];archive=output/artifact['archive']
    for p in (manifest_path,archive):
        require('..' not in p.parts and p.is_relative_to(output),'archive_path_scope');no_links(p)
    require(artifact['status']=='PASS' and sha(manifest_path)==artifact['manifest_sha256'] and sha(archive)==artifact['archive_sha256'],'archive_receipt_changed')
    manifest=json.loads(manifest_path.read_text());app=output/'package/ARL.app';expected=manifest['bundle_files']
    # Recoverability is proved from ZIP contents, not just the presence of a ZIP.
    with zipfile.ZipFile(archive) as z:
        prefix='package/ARL.app/'
        names={n for n in z.namelist() if n.startswith(prefix) and not n.endswith('/')}
        require(names=={prefix+k for k in expected},'archive_inventory_changed')
        for rel,row in expected.items():
            entry=z.getinfo(prefix+rel)
            require(not stat.S_ISLNK(entry.external_attr>>16),'archive_symlink')
            require(hashlib.sha256(z.read(entry)).hexdigest()==row['sha256'] and (entry.external_attr>>16)&0o777==row['mode'],'archive_content_changed')
    unregistered=False
    if app.exists():
        no_links(app);actual={}
        for p in app.rglob('*'):
            no_links(p);s=p.stat();require(s.st_uid==os.geteuid() and (p.is_dir() or p.is_file()),'staged_owner_changed')
            if p.is_file():actual[str(p.relative_to(app))]={'sha256':sha(p),'mode':stat.S_IMODE(s.st_mode)}
        require(actual==expected,'staged_app_changed')
        if not check:
            unregistered=unregister_staging(app)
            for p in [app,*[p for p in app.rglob('*') if p.is_dir()]]:p.chmod(stat.S_IMODE(p.stat().st_mode)|0o700)
            shutil.rmtree(app)
    if not check and not app.exists():require(str(app) not in registered_paths(),'staging_entry_still_registered')
    result={'status':'CHECK' if check else 'PASS','archive_preserved':True,'app_staging_present':app.exists(),'entry_unregistered':unregistered,'entry_absent_confirmed':not check,'installed_app_modified':False}
    if not check:
        receipt=output/'finalization.json';receipt.write_text(json.dumps(result,indent=2)+'\n');receipt.chmod(0o600)
    return result
@contextmanager
def staging_lock(output):
    output=scoped_output(output)
    path=output/'staging.lock';no_links(path)
    fd=os.open(path,os.O_RDWR|os.O_CREAT|os.O_NOFOLLOW,0o600)
    try:
        require(os.fstat(fd).st_uid==os.geteuid() and os.fstat(fd).st_nlink==1,'unsafe_staging_lock')
        try:fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError:raise ValueError('release_staging_busy')
        yield
    finally:os.close(fd)
def finalize(output,check=False):
    if check:return _finalize(output,True)
    with staging_lock(output):return _finalize(output)
def materialize(output):
    output=scoped_output(output);_finalize(output,True)
    app=output/'package/ARL.app'
    if app.exists():return app
    artifact=json.loads((output/'artifact.json').read_text());archive=output/artifact['archive']
    with zipfile.ZipFile(archive) as z:
        require(len(z.infolist())<=50000 and sum(i.file_size for i in z.infolist())<=3*1024**3,'archive_size_limit')
        require(len(z.namelist())==len(set(z.namelist())),'archive_duplicate_entry')
        for i in z.infolist():
            rel=Path(i.filename)
            require(not rel.is_absolute() and '..' not in rel.parts and rel.parts and rel.parts[0] in {'package','__MACOSX'} and not stat.S_ISLNK(i.external_attr>>16),'archive_entry_scope')
    scratch=output/('.materialize-'+uuid.uuid4().hex);scratch.mkdir(mode=0o700)
    try:
        result=subprocess.run(['/usr/bin/ditto','-x','-k',str(archive),str(scratch)],capture_output=True,timeout=60)
        require(result.returncode==0,'archive_extract_failed')
        staged=scratch/'package/ARL.app';no_links(staged);require(staged.is_dir(),'archive_app_missing')
        expected=json.loads((output/'package/manifest.json').read_text())['bundle_files']
        actual={str(p.relative_to(staged)):{'sha256':sha(p),'mode':stat.S_IMODE(p.stat().st_mode)} for p in staged.rglob('*') if p.is_file()}
        require(actual==expected,'archive_extract_changed');require(not app.exists(),'staging_app_appeared')
        os.rename(staged,app)
    finally:
        for p in [scratch,*[p for p in scratch.rglob('*') if p.is_dir() and not p.is_symlink()]]:p.chmod(stat.S_IMODE(p.stat().st_mode)|0o700)
        shutil.rmtree(scratch)
    return app
@contextmanager
def staged_release(output):
    """One scoped candidate, automatically retired after use, including failure."""
    with staging_lock(output):
        app=materialize(output)
        preserve=False
        try:yield app
        except BaseException as error:
            preserve=getattr(error,'code',None) in {'install_management_stop_unproven','install_worker_cleanup_unproven','install_worker_generation_unproven'}
            if preserve:
                receipt=Path(output)/'finalization.json';receipt.write_text(json.dumps({'status':'PENDING','code':'owned_worker_cleanup_unproven','archive_preserved':True,'app_staging_present':True})+'\n');receipt.chmod(0o600)
            raise
        finally:
            if not preserve:_finalize(output)
if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--output',required=True,type=Path);parser.add_argument('--check',action='store_true');args=parser.parse_args()
    try:print(json.dumps(finalize(args.output,args.check)))
    except Exception as error:print(json.dumps({'status':'FAILED','code':str(error) if isinstance(error,ValueError) else 'finalization_failed'}));raise SystemExit(1)
