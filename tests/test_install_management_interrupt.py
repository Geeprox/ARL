"""One real outer-only SIGINT; owned manager/worker/command/lock must end."""
import json,os,signal,subprocess,sys,tempfile,time,unittest,uuid
from pathlib import Path
from arl.install_platform import MacPlatform
from arl.install_transaction import Layout,atomic,encode
from arl.identity import process_identity
ROOT=Path(__file__).resolve().parents[1]
@unittest.skipUnless(sys.platform=='darwin','native kernel identity requires macOS')
class ManagementInterruptTests(unittest.TestCase):
    def test_outer_sigint_drains_owned_worker_before_cleanup(self):
        area=ROOT/'build/audit';area.mkdir(parents=True,exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='interrupt-',dir=area) as directory:
            temp=Path(directory).resolve();layout=Layout(temp/'account');layout.root.mkdir(parents=True,mode=0o700);layout.state.chmod(0o700)
            identifier=str(uuid.uuid4());folder=layout.folder(identifier);folder.mkdir(mode=0o700);atomic(folder/'journal.json',encode({'phase':'fixture'}))
            worker=temp/'worker.py';worker.write_text('''import os,signal,sys
from pathlib import Path
sys.path[:0]=[os.environ['ARL_TEST_ROOT'],os.environ['ARL_TEST_ROOT']+'/script']
from bundled_runtime_entry import watch_parent
from arl.install_transaction import Layout,Transaction,InstallFault
from arl.install_platform import MacPlatform
layout=Layout(Path(os.environ['ARL_TEST_ACCOUNT']));folder=Path(os.environ['ARL_TEST_FOLDER']);p=MacPlatform(layout,sys.executable,management_parent=os.getppid())
def stopped(_s,_f):raise InstallFault('install_parent_exited')
signal.signal(signal.SIGTERM,stopped);watch_parent(os.getppid())
try:
 with Transaction(layout,p).lock():
  p.record_worker(folder)
  body='import os,time;from pathlib import Path;Path('+repr(str(folder/'helper-pid'))+').write_text(str(os.getpid()));time.sleep(30)'
  p.command([sys.executable,'-B','-c',body],seconds=40)
except InstallFault as e:(folder/'worker-outcome').write_text(e.code)
''')
            host=temp/'host';source=temp/'host.c';source.write_text('''#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>
#include <stdlib.h>
extern char **environ;
int main(){pid_t pid;char *python=getenv("ARL_TEST_PYTHON");char *args[]={python,"-B",getenv("ARL_TEST_WORKER"),NULL};if(posix_spawn(&pid,python,NULL,NULL,args,environ))return 2;int result=0;waitpid(pid,&result,0);return WIFEXITED(result)?WEXITSTATUS(result):2;}
''')
            built=subprocess.run(['/usr/bin/xcrun','clang',str(source),'-o',str(host)],capture_output=True,timeout=30);self.assertEqual(built.returncode,0,'fixture compile failed')
            controller=temp/'controller.py';controller.write_text('''import sys,os
from pathlib import Path
sys.path.insert(0,os.environ['ARL_TEST_ROOT'])
from arl.install_platform import MacPlatform
from arl.install_transaction import Layout,InstallFault
p=MacPlatform(Layout(Path(os.environ['ARL_TEST_ACCOUNT'])),Path(os.environ['ARL_TEST_HOST']))
try:p.management(os.environ['ARL_TEST_ID'],'apply','0'*64)
except InstallFault as e:Path(os.environ['ARL_TEST_RESULT']).write_text(e.code)
''')
            result=temp/'result';env={'PATH':'/usr/bin:/bin','LANG':'C','ARL_TEST_ROOT':str(ROOT),'ARL_TEST_ACCOUNT':str(layout.account),'ARL_TEST_FOLDER':str(folder),'ARL_TEST_HOST':str(host),'ARL_TEST_WORKER':str(worker),'ARL_TEST_PYTHON':sys.executable,'ARL_TEST_ID':identifier,'ARL_TEST_RESULT':str(result)}
            outer=subprocess.Popen([sys.executable,'-B',str(controller)],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            try:
                deadline=time.monotonic()+8
                while not (folder/'helper-pid').exists() and time.monotonic()<deadline:time.sleep(.02)
                self.assertTrue((folder/'helper-pid').exists(),'fixture worker did not start')
                receipt=json.loads((folder/'worker.json').read_text());helper_pid=int((folder/'helper-pid').read_text());identity=process_identity(helper_pid);helper={'pid':helper_pid,**identity};helper['birth']=list(helper['birth'])
                os.kill(outer.pid,signal.SIGINT);outer.wait(timeout=20)
                self.assertEqual(result.read_text(),'install_management_interrupted_drained')
                p=MacPlatform(layout,host);self.assertFalse(p.current(receipt['owner']));self.assertFalse(p.current(receipt['worker']));self.assertFalse(p.current(helper));self.assertEqual((folder/'worker-outcome').read_text(),'install_parent_exited')
            finally:
                if outer.poll() is None:outer.terminate();outer.wait(timeout=5)
