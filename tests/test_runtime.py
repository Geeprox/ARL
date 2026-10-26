from __future__ import annotations

import concurrent.futures
import hashlib
import json
import os
import socket
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from contextlib import contextmanager

from arl import PROTOCOL
from arl.capabilities import AppleAdapter
from arl.client import Client, RuntimeLauncher
from arl.contracts import AppPolicy, Fault, Tool, object_schema
from arl.service import Runtime, default_policies
from arl.storage import Store
from arl.travel import TravelAdapter


@contextmanager
def running(home, **kwargs):
    runtime = Runtime(home, **kwargs)
    errors = []
    def run():
        try:
            runtime.run()
        except Exception as exc:
            errors.append(exc)
    thread = threading.Thread(target=run)
    thread.start()
    client = Client(home, "tisra")
    try:
        client.connect(timeout=5)
        yield runtime, client
    finally:
        runtime.shutdown()
        thread.join(40)
        if thread.is_alive():
            raise AssertionError("Runtime did not shut down")
        if errors:
            raise errors[0]


class RuntimeCase(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="arl-test-")
        self.home = Path(self.temp.name)
    def tearDown(self):
        self.temp.cleanup()

    def assert_fault(self, code, callback):
        with self.assertRaises(Fault) as result:
            callback()
        self.assertEqual(result.exception.code, code)


class RuntimeTests(RuntimeCase):
    def test_real_tools_dedupe_and_conflict(self):
        with running(self.home) as (runtime, client):
            job = client.submit("text.sha256", {"text": "test"}, "same")
            with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
                duplicate = list(pool.map(lambda _: client.submit("text.sha256", {"text": "test"}, "same"), range(16)))
            self.assertEqual({j["id"] for j in duplicate}, {job["id"]})
            self.assertEqual(client.wait(job["id"])["result"], {"sha256": hashlib.sha256(b"test").hexdigest()})
            self.assert_fault("idempotency_conflict", lambda: client.submit("text.sha256", {"text": "changed"}, "same"))
            friday = Client(self.home, "friday")
            self.assert_fault("job_not_found", lambda: friday.rpc("get", {"id": job["id"]}))
            self.assert_fault("job_not_found", lambda: friday.rpc("cancel", {"id": job["id"]}))

    def test_protocol_unknown_and_forged_authority(self):
        with running(self.home) as (runtime, client):
            self.assert_fault("unknown_method", lambda: client.rpc("shell", {"path": "/bin/sh"}))
            self.assert_fault("unknown_tool", lambda: client.submit("shell.exec", {}, "bad"))
            self.assert_fault("unknown_app", lambda: Client(self.home, "attacker").rpc("health"))
            self.assert_fault("tool_not_authorized", lambda: Client(self.home, "friday").submit("apple.calendar.list", {"start": "x", "end": "y"}, "apple"))
            # Declaring a known app ID is not authentication: private tools fail closed.
            self.assert_fault("app_identity_unverified", lambda: client.submit("apple.calendar.list", {"start": "x", "end": "y"}, "spoof"))
            self.assert_fault("app_identity_unverified", lambda: Client(self.home, "mio").submit("mio_maps_geo", {"address": "杭州"}, "spoof-mio"))
            request = {"protocol": PROTOCOL, "app": "friday", "method": "get", "params": {"id": "x"}, "owner": "tisra"}
            self.assert_fault("invalid_request", lambda: runtime.dispatch(request))
            request.pop("owner")
            request["protocol"] = "arl/2"
            self.assert_fault("unsupported_protocol", lambda: runtime.dispatch(request))
            self.assert_fault("invalid_arguments", lambda: client.rpc("wake", {"target": "friday", "command": "whoami"}))
            self.assert_fault("unknown_app", lambda: client.wake("/Applications/Other.app"))
            self.assert_fault("invalid_arguments", lambda: client.submit("runtime.ping", {"path": "/tmp"}, "extra"))

    def test_ready_is_separate_from_live(self):
        process = subprocess.Popen([sys.executable, "-m", "arl", "serve", "--home", str(self.home), "--start-delay", "0.6"],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        client = Client(self.home, "tisra")
        try:
            deadline = time.monotonic()+5
            while not (self.home/"runtime.sock").exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            health = client.rpc("health")
            self.assertTrue(health["live"])
            self.assertFalse(health["ready"])
            self.assert_fault("not_ready", lambda: client.rpc("ready"))
            self.assert_fault("not_ready", lambda: client.rpc("capabilities"))
            self.assertTrue(client.connect()["ready"])
        finally:
            process.terminate()
            process.wait(timeout=10)

    def test_concurrent_bootstrap_has_single_instance(self):
        launchers = [RuntimeLauncher(self.home) for _ in range(8)]
        clients = [Client(self.home, "tisra", launcher) for launcher in launchers]
        try:
            with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
                results = list(pool.map(lambda c: (c.connect(), c.rpc("health")), clients))
            self.assertEqual(len({r[1]["pid"] for r in results}), 1)
            clients[0].rpc("stop")
        finally:
            for launcher in launchers:
                for child in launcher.children:
                    if child.poll() is None:
                        child.terminate()
                    child.wait(timeout=10)

    def test_user_stop_wins_during_startup(self):
        process = subprocess.Popen([sys.executable, "-m", "arl", "serve", "--home", str(self.home), "--start-delay", "10"],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        client = Client(self.home, "tisra")
        try:
            deadline = time.monotonic()+5
            while not (self.home/"runtime.sock").exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertFalse(client.rpc("health")["ready"])
            self.assertTrue(client.rpc("stop")["disabled"])
            process.wait(timeout=2)
            self.assert_fault("user_disabled", lambda: client.connect())
        finally:
            if process.poll() is None:
                process.kill(); process.wait()

    def test_stop_is_persisted_and_requires_explicit_enable(self):
        launcher = RuntimeLauncher(self.home)
        client = Client(self.home, "tisra", launcher)
        try:
            client.connect()
            self.assertTrue(client.rpc("stop")["disabled"])
            for child in launcher.children:
                child.wait(timeout=10)
            self.assert_fault("user_disabled", lambda: client.connect())
            self.assertEqual(len(launcher.children), 1)
            result = subprocess.run([sys.executable, "-m", "arl", "enable", "--home", str(self.home)], capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            client.connect()
            client.rpc("stop")
        finally:
            for child in launcher.children:
                if child.poll() is None:
                    child.terminate()
                child.wait(timeout=10)

    def test_registered_bidirectional_wake(self):
        callback = threading.Event()
        with running(self.home, wake_callbacks={"friday": callback.set}) as (runtime, tisra):
            friday = Client(self.home, "friday")
            delivery = tisra.wake("friday")
            self.assertEqual(delivery["delivery"], "host_callback")
            self.assertTrue(callback.wait(1))
            received = []
            friday.poll_wakes(received.append)
            self.assertEqual(received[0]["source"], "tisra")
            self.assertEqual(friday.poll_wakes(), [])
            friday.wake("tisra")
            self.assertEqual(tisra.poll_wakes()[0]["source"], "friday")

    def test_cancel_and_backoff(self):
        entered = threading.Event()
        tries = []
        def slow(args, context):
            entered.set()
            while True:
                context.check_cancelled()
                time.sleep(0.01)
        def transient(args, context):
            tries.append(time.monotonic())
            if len(tries) < 3:
                raise Fault("transient")
            return {"ok": True}
        extra = [Tool("test.slow", object_schema(), slow), Tool("test.retry", object_schema(), transient)]
        policies = {"tisra": AppPolicy(frozenset(t.name for t in extra))}
        with running(self.home, extra_tools=extra, policies=policies) as (runtime, client):
            job = client.submit("test.slow", {}, "cancel")
            self.assertTrue(entered.wait(2))
            self.assertEqual(client.rpc("cancel", {"id": job["id"]})["state"], "running")
            self.assertEqual(client.wait(job["id"])["state"], "cancelled")
            retry = client.submit("test.retry", {}, "retry")
            self.assertEqual(client.wait(retry["id"])["attempts"], 3)
            self.assertGreaterEqual(tries[1]-tries[0], 0.19)
            self.assertGreaterEqual(tries[2]-tries[1], 0.39)

    def test_needs_unlock_does_not_pause_other_work(self):
        unlocked = threading.Event()
        def locked(args, context):
            if not unlocked.is_set():
                raise Fault("needs_unlock")
            return {"test_double": True}
        extra = [Tool("test.ui", object_schema(), locked)]
        policies = default_policies()
        policies["tisra"] = AppPolicy(policies["tisra"].tools | {"test.ui"})
        with running(self.home, extra_tools=extra, policies=policies) as (_, client):
            job = client.submit("test.ui", {}, "locked")
            self.assertEqual(client.wait(job["id"])["state"], "needs_unlock")
            headless = client.submit("runtime.ping", {}, "headless")
            self.assertEqual(client.wait(headless["id"])["state"], "succeeded")
            unlocked.set()
            client.rpc("resume", {"id": job["id"]})
            self.assertEqual(client.wait(job["id"])["state"], "succeeded")

    def test_pending_queue_budget_and_nonidempotent_unlock_are_safe(self):
        def locked(args, context):
            raise Fault("needs_unlock")
        read = Tool("test.locked_read", object_schema(), locked)
        write = Tool("test.locked_write", object_schema(), locked, idempotent=False)
        policy = AppPolicy(frozenset({read.name, write.name}), max_pending=1)
        with running(self.home, extra_tools=[read, write], policies={"tisra": policy}) as (_, client):
            pending = client.submit(read.name, {}, "read")
            self.assertEqual(client.wait(pending["id"])["state"], "needs_unlock")
            self.assert_fault("queue_budget_exceeded", lambda: client.submit(write.name, {}, "blocked"))
            client.rpc("cancel", {"id": pending["id"]})
            uncertain = client.submit(write.name, {}, "uncertain")
            self.assertEqual(client.wait(uncertain["id"])["state"], "needs_review")
            self.assert_fault("not_resumable", lambda: client.rpc("resume", {"id": uncertain["id"]}))

    def test_restored_task_rechecks_capability_policy(self):
        store = Store(self.home/"state.sqlite")
        tool = Tool("removed.capability", object_schema(), lambda a, c: {"bad": True})
        job = store.submit("tisra", "restore", tool, {}, AppPolicy(frozenset({tool.name})))
        store.claim(); store.close()
        with running(self.home, identity_verifier=lambda connection, app: app) as (_, client):
            result = client.wait(job["id"])
            self.assertEqual(result["state"], "needs_review")
            self.assertEqual(result["error"], "tool_contract_changed")

    def test_future_store_version_rejected_without_replacing_data(self):
        connection = sqlite3.connect(str(self.home/"future.sqlite"))
        connection.execute("CREATE TABLE preserved(value TEXT)")
        connection.execute("INSERT INTO preserved VALUES('synthetic')")
        connection.execute("PRAGMA user_version=5")
        connection.commit(); connection.close()
        self.assert_fault("unsupported_store_version", lambda: Store(self.home/"future.sqlite"))
        connection = sqlite3.connect(str(self.home/"future.sqlite"))
        self.assertEqual(connection.execute("SELECT value FROM preserved").fetchone()[0], "synthetic")
        self.assertEqual(connection.execute("PRAGMA user_version").fetchone()[0], 5)
        connection.close()

    def test_crash_recovery_does_not_replay_uncertain_write(self):
        def start():
            return subprocess.Popen([sys.executable, "-m", "tests.worker_fixture", str(self.home)],
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        process = start()
        client = Client(self.home, "tisra")
        try:
            client.connect()
            write = client.submit("test.write", {}, "write")
            slow = client.submit("test.slow", {}, "slow")
            deadline = time.monotonic()+5
            while not (self.home/"fake-effect").exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertEqual((self.home/"fake-effect").read_text(), "1")
            process.kill()
            process.wait(timeout=5)
            self.assert_fault("disconnected", lambda: client.rpc("health"))
            process = start()
            client.connect()
            self.assertEqual(client.wait(write["id"])["state"], "needs_review")
            self.assertEqual(client.wait(slow["id"])["state"], "succeeded")
            self.assertEqual((self.home/"fake-effect").read_text(), "1")
            self.assertEqual(client.submit("test.write", {}, "write")["id"], write["id"])
            # Now kill an in-flight idempotent read: one safe bounded retry on restart.
            again = client.submit("test.slow", {}, "read-running")
            deadline = time.monotonic()+3
            while client.rpc("get", {"id": again["id"]})["state"] != "running" and time.monotonic() < deadline:
                time.sleep(0.01)
            process.kill(); process.wait(timeout=5)
            process = start(); client.connect()
            restored = client.wait(again["id"])
            self.assertEqual(restored["state"], "succeeded")
            self.assertEqual(restored["attempts"], 2)
        finally:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=5)

    def test_disconnect_before_response_is_recoverable(self):
        with running(self.home) as (_, client):
            request = {"protocol": PROTOCOL, "app": "tisra", "method": "submit",
                       "params": {"tool": "text.sha256", "args": {"text": "disconnect"}, "key": "lost"}}
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
                connection.connect(str(self.home/"runtime.sock"))
                connection.sendall(json.dumps(request).encode()+b"\n")
            time.sleep(0.05)
            retry = client.submit("text.sha256", {"text": "disconnect"}, "lost")
            self.assertEqual(client.wait(retry["id"])["state"], "succeeded")

    def test_persistent_call_budget_and_metadata_only_audit(self):
        secret = "synthetic-private-prompt"
        policy = AppPolicy(frozenset({"text.sha256"}), max_calls=1)
        with running(self.home, policies={"tisra": policy}) as (runtime, client):
            job = client.submit("text.sha256", {"text": secret}, "budget")
            client.wait(job["id"])
            rows = runtime.store.db.execute("SELECT * FROM audit").fetchall()
            self.assertNotIn(secret, str([tuple(r) for r in rows]))
        with running(self.home, policies={"tisra": policy}) as (_, client):
            self.assertEqual(client.submit("text.sha256", {"text": secret}, "budget")["id"], job["id"])
            self.assert_fault("call_budget_exceeded", lambda: client.submit("text.sha256", {"text": "new"}, "new"))

    def test_malformed_frame_is_rejected_without_stopping_service(self):
        with running(self.home) as (_, client):
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
                connection.connect(str(self.home/"runtime.sock"))
                connection.sendall(b"x"*16385+b"\n")
                reply = json.loads(connection.makefile("rb").readline())
                self.assertEqual(reply["error"]["code"], "invalid_frame")
            self.assertTrue(client.rpc("health")["live"])

    def test_unsafe_home_and_symlink_rejected(self):
        os.chmod(self.home, 0o755)
        self.assert_fault("unsafe_home", lambda: Client(self.home, "tisra"))
        os.chmod(self.home, 0o700)
        (self.home/"state.sqlite").symlink_to("/tmp/not-arl")
        self.assert_fault("unsafe_home", lambda: Client(self.home, "tisra"))


if __name__ == "__main__":
    unittest.main()
