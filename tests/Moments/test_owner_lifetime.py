"""A real child process must drain after its ARL-shaped parent disappears."""
import json,os,subprocess,sys,tempfile,time,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
class OwnerLifetime(unittest.TestCase):
 def test_parent_exit_stops_child_without_risk_or_grant_mutation(self):
  with tempfile.TemporaryDirectory() as d:
   root=Path(d);output=root/'data';output.mkdir();(output/'moments.json').write_text('{"posts":[]}')
   # Entry imports only packaged worker code; no account inputs or image grant.
   parent_code='''import sys,os,json,subprocess
from pathlib import Path
import time
root=Path(sys.argv[1]);cfg={'output':str(root/'data'),'sns_db':str(root/'no-source'),'keys_file':str(root/'unused'),'images_enabled':False,'viewer_port':0,'poll_seconds':.1,'owner_pid':os.getpid()}
p=root/'config.json';p.write_text(json.dumps(cfg))
child=subprocess.Popen([sys.executable,'-I','-B',sys.argv[2],'--config',str(p)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
for _ in range(50):
 if (root/"data/local-service-status.json").exists():break
 time.sleep(.1)
print(child.pid,flush=True)
'''
   parent=subprocess.run([sys.executable,'-I','-B','-c',parent_code,str(root),str(ROOT/'integrations/moments/entry.py')],capture_output=True,text=True,timeout=5)
   self.assertEqual(parent.returncode,0)
   pid=int(parent.stdout.strip());deadline=time.monotonic()+8
   while time.monotonic()<deadline:
    try:status=json.loads((output/'local-service-status.json').read_text())
    except (FileNotFoundError,json.JSONDecodeError):status={}
    if status.get('phase')=='stopped':break
    time.sleep(.1)
   self.assertEqual(status.get('phase'),'stopped')
   self.assertFalse((output/'.video-batch.stop').exists())
   self.assertFalse((output/'private/image-resume.json').exists())
   for _ in range(30):
    try:os.kill(pid,0)
    except ProcessLookupError:break
    time.sleep(.1)
   else:self.fail('child still running after parent death')
if __name__=='__main__':unittest.main()
