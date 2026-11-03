"""User-scoped reproducible build areas. Never stores installed or recovery state."""
import datetime,fcntl,hashlib,json,os,re,uuid
from contextlib import contextmanager
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]

@contextmanager
def build_area(task,*,toolchain='python3-macos-arm64',configuration='verification',reproduce=()):
    for value in (task,toolchain,configuration):
        if type(value) is not str or re.fullmatch(r'[A-Za-z0-9_.-]{1,100}',value) is None:raise ValueError('invalid_build_area_label')
    source=ROOT.resolve();project=source.name+'-'+hashlib.sha256(os.fsencode(str(source))).hexdigest()[:12]
    path=Path.home()/'Library/Caches/CodexBuilds.noindex'/project/toolchain/configuration/(task+'-'+uuid.uuid4().hex[:8])
    if any(p.is_symlink() for p in (path,*path.parents)):raise ValueError('build_area_symlink')
    path.mkdir(parents=True,mode=0o700)
    lock=os.open(path/'active.lock',os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW,0o600)
    fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    def stamp():return datetime.datetime.now(datetime.timezone.utc).isoformat()
    record={'schema':1,'project':str(source),'toolchain':toolchain,'configuration':configuration,
        'purpose':task,'created_at':stamp(),'ended_at':None,'status':'running','pid':os.getpid(),
        'reproduce':list(reproduce),'cache_retention_days':7,'diagnostic_retention_days':14}
    manifest=path/'manifest.json'
    def save():manifest.write_text(json.dumps(record,indent=2)+'\n');manifest.chmod(0o600)
    save()
    try:
        yield path
        record['status']='completed'
    except BaseException:
        record['status']='failed';raise
    finally:
        record['ended_at']=stamp();save();fcntl.flock(lock,fcntl.LOCK_UN);os.close(lock)
