"""Owner-only five-package registry shared with ARL's native preferences."""
import contextlib, fcntl, hashlib, json, os, stat, uuid
from pathlib import Path
from .contracts import Fault
from .codex_execution_options import selection
IDS=('low','medium','high','very_high','highest')
TITLES=('低','中','高','很高','最高')
def canonical(value):
    return json.dumps(value,ensure_ascii=False,sort_keys=True,separators=(',',':'),allow_nan=False).encode()
def digest(value):return hashlib.sha256(canonical(value)).hexdigest()
def read_private(path,limit=65536):
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW)
    with os.fdopen(fd,'rb') as stream:
        info=os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid!=os.getuid() or info.st_mode&0o077 or info.st_size>limit:raise Fault('unsafe_package_configuration')
        return json.load(stream)
def atomic(path,value):
    temporary=path.with_name('.'+path.name+'.'+uuid.uuid4().hex)
    fd=os.open(temporary,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'wb') as stream:stream.write(canonical(value));stream.flush();os.fsync(stream.fileno())
    os.replace(temporary,path)
def validate_packages(packages,catalog):
    if type(packages)!=dict or set(packages)!=set(IDS):raise Fault('invalid_package_configuration')
    for row in packages.values():
        if type(row)!=dict or set(row)!={'display_name','model','reasoning_effort'} or type(row['display_name'])!=str or not 1<=len(row['display_name'])<=40:raise Fault('invalid_package_configuration')
        selection(catalog,row['model'],row['reasoning_effort'],'default')
class PackageRegistry:
    def __init__(self,home):
        self.home=Path(home)
        if self.home.is_symlink():raise Fault('unsafe_package_configuration')
        self.home.mkdir(mode=0o700,parents=True,exist_ok=True)
        info=self.home.stat()
        if info.st_uid!=os.getuid() or info.st_mode&0o077:raise Fault('unsafe_package_configuration')
    @contextlib.contextmanager
    def locked(self):
        fd=os.open(self.home/'packages.lock',os.O_RDWR|os.O_CREAT|os.O_NOFOLLOW,0o600)
        try:
            info=os.fstat(fd)
            if info.st_uid!=os.getuid() or info.st_mode&0o077:raise Fault('unsafe_package_configuration')
            fcntl.flock(fd,fcntl.LOCK_EX);yield
        finally:os.close(fd)
    def load(self):
        row=read_private(self.home/'packages-v2.json')
        if type(row)!=dict or set(row)!={'schema_version','revision','catalog_version','packages'} or row['schema_version']!=2 or type(row['revision'])!=int or row['revision']<1:raise Fault('invalid_package_configuration')
        return row
    def version(self,catalog,config=None):
        config=self.load() if config is None else config
        return digest({'models':catalog,'package_revision':config['revision'],'packages':config['packages'],'execution_policy':{'service_tiers':['default'],'max_input_bytes':8192,'max_output_bytes':32768,'max_wall_ms':180000,'priority':['explicit']}})
    def publish(self,catalog,current):
        version=digest(catalog)
        with self.locked():
            if not (self.home/'packages-v2.json').exists():
                model=next(m for m in catalog if m['model']==current['model']);efforts={e['id'] for e in model['efforts']}
                packages={key:{'display_name':title,'model':model['model'],'reasoning_effort':effort if effort in efforts else model['default_effort']} for key,title,effort in zip(IDS,TITLES,('low','medium','high','xhigh','max'))}
                atomic(self.home/'packages-v2.json',{'schema_version':2,'revision':1,'catalog_version':version,'packages':packages})
            version=self.version(catalog)
            atomic(self.home/'catalog-v2.json',{'schema_version':2,'catalog_version':version,'models':catalog,'current':current})
        return version
    def save(self,value,catalog):
        with self.locked():
            old=self.load()
            if set(value)!={'schema_version','base_revision','catalog_version','packages'} or value['schema_version']!=2:raise Fault('invalid_package_configuration')
            if value['base_revision']!=old['revision']:raise Fault('package_revision_conflict')
            if value['catalog_version']!=self.version(catalog,old):raise Fault('catalog_changed')
            validate_packages(value['packages'],catalog)
            row={'schema_version':2,'revision':old['revision']+1,'catalog_version':value['catalog_version'],'packages':value['packages']}
            atomic(self.home/'packages-v2.json',row);return row
