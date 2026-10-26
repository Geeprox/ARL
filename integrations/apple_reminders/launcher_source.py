"""Generate a sealed stdlib-only -I launcher; no cwd/PYTHONPATH imports."""
import json

def render(files,state):
 return '''import sys,os,stat,hashlib,json,importlib.abc,importlib.util
from pathlib import Path
EXPECTED = '''+repr(files)+'''
BASE = Path('''+repr(str(state))+''')
def fail():
 print(json.dumps({'status':'sealed_source_changed'}));raise SystemExit(1)
if not sys.flags.isolated or Path(__file__) != BASE/'launch_reminders.py':fail()
sys.dont_write_bytecode=True
code=BASE/'code';loaded={};actual=set()
for component in [BASE,code,code/'arl']:
 try:
  info=component.lstat()
  if not stat.S_ISDIR(info.st_mode) or component.is_symlink() or info.st_uid!=os.geteuid() or info.st_mode&0o022:fail()
 except OSError:fail()
for path in code.rglob('*'):
 info=path.lstat()
 if path.is_symlink() or info.st_uid!=os.geteuid() or info.st_mode&0o022:fail()
 if not path.is_file():
  if not path.is_dir():fail()
  continue
 rel=str(path.relative_to(code));actual.add(rel)
 if rel not in EXPECTED:fail()
 fd=os.open(str(path),os.O_RDONLY|os.O_NOFOLLOW)
 try:
  info=os.fstat(fd)
  if not stat.S_ISREG(info.st_mode) or info.st_size>1048576:fail()
  raw=b''
  while True:
   chunk=os.read(fd,65536)
   if not chunk:break
   raw+=chunk
   if len(raw)>1048576:fail()
 finally:os.close(fd)
 if hashlib.sha256(raw).hexdigest()!=EXPECTED[rel]:fail()
 name='arl' if rel=='arl/__init__.py' else 'arl.'+Path(rel).stem
 loaded[name]=(raw,rel)
if actual!=set(EXPECTED):fail()
if sys.argv[1:]==['--verify-only']:
 print(json.dumps({'status':'sealed_source_verified','imports_from_cwd':False}));raise SystemExit(0)
# Compile the bytes already hashed, avoiding a second source-file open by import.
class FrozenLoader(importlib.abc.MetaPathFinder,importlib.abc.Loader):
 def find_spec(self,fullname,path=None,target=None):
  if fullname in loaded:return importlib.util.spec_from_loader(fullname,self,is_package=fullname=='arl')
 def create_module(self,spec):return None
 def exec_module(self,module):
  raw,rel=loaded[module.__name__];module.__file__=str(code/rel)
  if module.__name__=='arl':module.__path__=[]
  exec(compile(raw,'sealed/'+rel,'exec'),module.__dict__)
sys.meta_path.insert(0,FrozenLoader())
from arl.reminders_review import main
from arl.contracts import Fault
try:raise SystemExit(main())
except Fault as exc:
 print(json.dumps({'broker_receipt':{'state':'failed','error':exc.code}}),flush=True);raise SystemExit(1)
'''
