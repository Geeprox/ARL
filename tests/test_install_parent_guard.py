"""Real owned process/lock test; no launchd, installed App, credentials or network."""
import fcntl,json,os,subprocess,sys,tempfile,time,unittest,uuid
from pathlib import Path
from arl.install_platform import MacPlatform
from arl.install_transaction import Layout
from arl.identity import process_identity
ROOT=Path(__file__).resolve().parents[1]
@unittest.skipUnless(sys.platform=='darwin','kernel process birth verification requires macOS')
class ParentGuardTests(unittest.TestCase):
    def test_parent_exit_reaps_command_before_unlock_and_recovery(self):
        with tempfile.TemporaryDirectory() as directory:
            layout=Layout(Path(directory).resolve());layout.root.mkdir(parents=True,mode=0o700);layout.state.chmod(0o700)
            folder=layout.folder(str(uuid.uuid4()));folder.mkdir(mode=0o700)
            helper_file=folder/'helper-pid';outcome=folder/'outcome'
            worker="""import sys,os,signal
from pathlib import Path
sys.path[:0]=[sys.argv[1],sys.argv[1]+'/script']
from bundled_runtime_entry import watch_parent
from arl.install_transaction import Layout,Transaction,InstallFault
from arl.install_platform import MacPlatform
layout=Layout(Path(sys.argv[2]));folder=Path(sys.argv[3]);platform=MacPlatform(layout,sys.executable,management_parent=os.getppid())
def parent_exit(_s,_f):raise InstallFault('install_parent_exited')
signal.signal(signal.SIGTERM,parent_exit);watch_parent(os.getppid())
try:
 with Transaction(layout,platform).lock():
  platform.record_worker(folder)
  code='import os,time;from pathlib import Path;Path('+repr(str(folder/'helper-pid'))+').write_text(str(os.getpid()));time.sleep(30)'
  platform.command([sys.executable,'-B','-c',code],seconds=40)
except InstallFault as error:(folder/'outcome').write_text(error.code)
"""
            driver="import subprocess,sys,time;subprocess.Popen([sys.executable,'-B','-c',sys.argv[1],*sys.argv[2:]]);time.sleep(30)"
            parent=subprocess.Popen([sys.executable,'-B','-c',driver,worker,str(ROOT),str(layout.account),str(folder)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            try:
                identity=process_identity(parent.pid);owner={'pid':parent.pid,**identity};owner['birth']=list(owner['birth'])
                deadline=time.monotonic()+5
                while not helper_file.exists() and time.monotonic()<deadline:time.sleep(.02)
                self.assertTrue(helper_file.exists(),'fixture worker never entered command')
                helper_pid=int(helper_file.read_text());helper_identity=process_identity(helper_pid);helper={'pid':helper_pid,**helper_identity};helper['birth']=list(helper['birth'])
                # The Xcode Python launcher execs the framework interpreter.
                # Bind the stable fixture parent only after its child is ready.
                stable=process_identity(parent.pid);self.assertEqual(stable['birth'],identity['birth'])
                owner={'pid':parent.pid,**stable};owner['birth']=list(owner['birth'])
                receipt=json.loads((folder/'worker.json').read_text());worker_process=receipt['worker']
                parent.terminate();parent.wait(timeout=3)
                platform=MacPlatform(layout,sys.executable);platform.management_quiet(folder,owner,seconds=5)
                self.assertFalse(platform.current(worker_process));self.assertFalse(platform.current(helper))
                self.assertEqual(outcome.read_text(),'install_parent_exited')
                fd=os.open(layout.lock_path,os.O_RDWR)
                try:fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
                finally:os.close(fd)
            finally:
                if parent.poll() is None:parent.terminate();parent.wait(timeout=3)
