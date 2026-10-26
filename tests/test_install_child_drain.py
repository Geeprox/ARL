"""Exact owned child drain; no launchd, account data or new authorization."""
import subprocess,sys,threading,time,unittest
from pathlib import Path
from unittest.mock import patch
from arl.install_platform import MacPlatform
from arl.install_transaction import Layout,InstallFault
from arl.identity import process_identity

class ChildDrainTests(unittest.TestCase):
 def setUp(self):self.platform=MacPlatform(Layout(Path('/tmp/arl-child-drain-fixture').resolve()),'/tmp/arl-child-drain-fixture/host')
 def test_parent_end_does_not_imply_child_exit(self):
  records=[{'pid':1,'birth':[1,2],'executable':'fixed-core'},{'pid':2,'birth':[3,4],'executable':'fixed-mio'}]
  calls=[];live={1:2,2:2}
  def current(record):
   calls.append(record);remaining=live[record['pid']];live[record['pid']]=max(0,remaining-1);return remaining>0
  with patch.object(self.platform,'current',side_effect=current),patch('arl.install_platform.time.sleep'),patch.object(self.platform,'command') as command:
   self.platform.wait_owned_children(records)
  self.assertEqual(set(r['pid'] for r in calls),{1,2});self.assertGreater(len(calls),2);command.assert_not_called()
 def test_live_child_deadline_remains_blocked(self):
  record={'pid':1,'birth':[1,2],'executable':'fixed-core'}
  with patch.object(self.platform,'current',return_value=True),patch('arl.install_platform.time.monotonic',side_effect=[0,1,16]),patch('arl.install_platform.time.sleep'),patch.object(self.platform,'command') as command,self.assertRaisesRegex(InstallFault,'install_child_cleanup_unproven'):
   self.platform.wait_owned_children([record])
  command.assert_not_called()
 @unittest.skipUnless(sys.platform=='darwin','actual kernel identity is macOS only')
 def test_real_owned_child_is_observed_until_exit(self):
  child=subprocess.Popen(['/usr/bin/python3','-I','-B','-c','import time;time.sleep(0.4)'],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
  try:
   record={'pid':child.pid,**process_identity(child.pid)};record['birth']=list(record['birth']);self.assertTrue(self.platform.current(record))
   reaper=threading.Thread(target=child.wait,daemon=True);reaper.start()
   self.platform.wait_owned_children([record],seconds=3);reaper.join(timeout=1)
   self.assertFalse(self.platform.current(record));self.assertEqual(child.returncode,0)
  finally:
   if child.poll() is None:child.terminate();child.wait(timeout=3)
if __name__=='__main__':unittest.main()
