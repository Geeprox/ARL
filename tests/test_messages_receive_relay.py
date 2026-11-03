from pathlib import Path
import os
import shutil
import signal
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
from arl.identity import process_identity

ROOT=Path(__file__).resolve().parents[1]


@unittest.skipUnless(sys.platform=="darwin" and shutil.which("xcrun"),"native macOS identity required")
class MessagesReceiveRelayTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary=tempfile.TemporaryDirectory(prefix="arl-mr-",dir="/private/tmp")
        cls.root=Path(cls.temporary.name)
        common=["xcrun","swiftc","-swift-version","6","-target","arm64-apple-macos14.0","-module-cache-path",str(cls.root/"cache"),"-parse-as-library"]
        cls.executable=cls.root/"native"
        args=common+["-D","ARL_MESSAGES_RECEIVE_FIXTURE",str(ROOT/"macOS/ARLControl/Services/MessagesReceiveCore.swift"),str(ROOT/"macOS/ARLControl/Services/MessagesReceiveRelayServer.swift"),str(ROOT/"tests/MessagesReceiveRelayTests.swift"),"-lsqlite3","-o",str(cls.executable)]
        built=subprocess.run(args,capture_output=True,text=True,timeout=120)
        if built.returncode:raise AssertionError(built.stdout+built.stderr)
        cls.helper=cls.root/"PeerSignatureHelper"
        built=subprocess.run([part for part in common if part != "-parse-as-library"]+[str(ROOT/"apple/PeerSignatureHelper.swift"),"-o",str(cls.helper)],capture_output=True,text=True,timeout=120)
        if built.returncode:raise AssertionError(built.stdout+built.stderr)

    @classmethod
    def tearDownClass(cls):cls.temporary.cleanup()

    def home(self,name):
        path=self.root/name;path.mkdir(mode=0o700);return path

    def run_mode(self,mode,home):
        result=subprocess.run([str(self.executable),mode,str(home)],capture_output=True,text=True,timeout=15)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        return result

    def test_killed_owner_stale_socket_recovers_without_replacing_live_owner(self):
        home=self.home("stale")
        child=subprocess.Popen([str(self.executable),"--hold",str(home)],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        try:
            deadline=time.monotonic()+10
            while not (home/"ready").exists() and time.monotonic()<deadline:
                if child.poll() is not None:break
                time.sleep(.02)
            self.assertTrue((home/"ready").exists())
            old=(home/"messages-receive.sock").lstat().st_ino
            self.run_mode("--expect-busy",home)
            self.assertEqual((home/"messages-receive.sock").lstat().st_ino,old)
            child.send_signal(signal.SIGKILL);child.wait(timeout=5)
            self.run_mode("--recover",home)
            self.assertFalse((home/"messages-receive.sock").exists())
        finally:
            if child.poll() is None:child.kill();child.wait()
            child.stdout.close();child.stderr.close()

    def test_live_listener_without_our_lock_is_preserved(self):
        home=self.home("foreign")
        listener=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM)
        listener.bind(str(home/"messages-receive.sock"));os.chmod(home/"messages-receive.sock",0o600);listener.listen(1)
        try:
            original=(home/"messages-receive.sock").lstat().st_ino
            self.run_mode("--expect-held",home)
            self.assertEqual((home/"messages-receive.sock").lstat().st_ino,original)
        finally:listener.close()

    def test_real_signed_native_core_and_application_delivery(self):
        home=self.home("delivery")
        connection=sqlite3.connect(home/"chat.db")
        connection.executescript("CREATE TABLE chat(guid TEXT,account_login TEXT,display_name TEXT,service_name TEXT);CREATE TABLE handle(id TEXT,service TEXT);CREATE TABLE chat_handle_join(chat_id INTEGER,handle_id INTEGER);CREATE TABLE chat_message_join(chat_id INTEGER,message_id INTEGER);CREATE TABLE message(guid TEXT,text TEXT,attributedBody BLOB,handle_id INTEGER,is_from_me INTEGER,date INTEGER,service TEXT,associated_message_type INTEGER,item_type INTEGER);INSERT INTO chat VALUES('synthetic-chat','synthetic-account@example.test','Synthetic peer','iMessage');INSERT INTO handle VALUES('synthetic-peer@example.test','iMessage');INSERT INTO chat_handle_join VALUES(1,1);INSERT INTO message VALUES('old','OLD HISTORY MUST NOT APPEAR',NULL,1,0,1,'iMessage',0,0);INSERT INTO chat_message_join VALUES(1,1);")
        connection.commit();connection.close();os.chmod(home/"chat.db",0o600)
        python=process_identity(os.getpid())["executable"]
        result=subprocess.run([str(self.executable),"--delivery",str(home),python,str(ROOT/"tests/fixtures/MessagesReceiveRelayClient.py"),str(self.helper)],capture_output=True,text=True,timeout=60)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertIn("registered/signed app",result.stdout)
        self.assertFalse((home/"messages-receive.sock").exists())


if __name__=="__main__":unittest.main()
