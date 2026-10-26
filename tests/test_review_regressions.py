import json
import os
import socket
import sqlite3
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest.mock import patch

from arl import PROTOCOL
from arl.client import Client
from arl.contracts import AppPolicy, Fault, Tool, object_schema
from arl.identity import RegisteredPeerVerifier
from arl.lifecycle import InstanceLock
from arl.providers import local_json
from arl.service import Runtime
from arl.storage import Store
from tests.test_runtime import RuntimeCase, running


class ReviewRegressions(RuntimeCase):
    def test_private_result_survives_descriptor_removal_and_security_downgrade(self):
        private = Tool("test.private", object_schema(), lambda a, c: {"synthetic_private": True}, permissions=("private_data",))
        policy = {"tisra": AppPolicy(frozenset({private.name}))}
        with running(self.home, extra_tools=[private], policies=policy,
                     identity_verifier=lambda connection, app: app) as (runtime, client):
            job = client.submit(private.name, {}, "private")
            self.assertEqual(client.wait(job["id"])["state"], "succeeded")
            runtime.identity_verifier = None
            for variant in (None, Tool(private.name, object_schema(), lambda a, c: None)):
                if variant:
                    runtime.tools[private.name] = variant
                else:
                    runtime.tools.pop(private.name, None)
                for method in ("get", "cancel", "resume"):
                    self.assert_fault("app_identity_unverified", lambda: client.rpc(method, {"id": job["id"]}))
                if variant:
                    # A same-key submit must not expose the old private result either.
                    self.assert_fault("app_identity_unverified", lambda: client.submit(private.name, {}, "private"))
        with running(self.home, extra_tools=[Tool(private.name, object_schema(), lambda a, c: None)], policies=policy) as (_, client):
            self.assert_fault("app_identity_unverified", lambda: client.rpc("get", {"id": job["id"]}))

    def test_legacy_migration_treats_unclassified_results_as_private(self):
        path = self.home/"state.sqlite"
        connection = sqlite3.connect(str(path))
        connection.executescript('''CREATE TABLE jobs(id TEXT PRIMARY KEY, owner TEXT NOT NULL, key TEXT NOT NULL,
            digest TEXT NOT NULL, tool TEXT NOT NULL, args TEXT NOT NULL, idempotent INTEGER NOT NULL,
            state TEXT NOT NULL, attempts INTEGER DEFAULT 0, cancel INTEGER DEFAULT 0, next_at REAL DEFAULT 0,
            result TEXT, error TEXT, created REAL NOT NULL, updated REAL NOT NULL, UNIQUE(owner,key));
            PRAGMA user_version=1;''')
        connection.execute("INSERT INTO jobs VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", (
            "legacy", "tisra", "old", "digest", "runtime.ping", "{}", 1, "succeeded", 1, 0, 0,
            '{"synthetic_private":true}', None, time.time(), time.time()))
        connection.commit(); connection.close(); os.chmod(path, 0o600)
        with running(self.home) as (runtime, client):
            self.assertEqual(runtime.store.db.execute("PRAGMA user_version").fetchone()[0], 4)
            self.assert_fault("app_identity_unverified", lambda: client.rpc("get", {"id": "legacy"}))

    def test_verifier_revoke_and_reenroll_are_linearized(self):
        entered, proceed = threading.Event(), threading.Event()
        current = {"uid": os.geteuid(), "birth": (1, 2), "executable": "/fixed"}
        registry = RegisteredPeerVerifier({"tisra"})
        original = ("tisra", current, 1)
        registry.registry[7] = original
        class Connection:
            def getsockopt(self, *args):
                import struct
                return struct.pack("i", 7)
        answer = []
        def slow_identity(pid):
            entered.set(); proceed.wait(2)
            return current
        with patch("arl.identity.process_identity", slow_identity):
            check = threading.Thread(target=lambda: answer.append(registry(Connection(), "tisra")))
            check.start(); self.assertTrue(entered.wait(1))
            registry.revoke(7)
            # Identical details, new registration generation: old check still cannot authorize.
            replacement = ("tisra", current, 2)
            with registry.lock:
                registry.registry[7] = replacement
            proceed.set(); check.join(2)
        self.assertEqual(answer, [None])
        self.assertIs(registry.registry[7], replacement)

    def test_effect_then_any_fault_is_needs_review(self):
        effects = []
        def oversized(args, context):
            effects.append("oversized")
            return {"text": "x"*70000}
        def failure(args, context):
            effects.append("fault")
            raise Fault("transient")
        tools = [Tool("test.oversize_write", object_schema(), oversized, idempotent=False),
                 Tool("test.fault_write", object_schema(), failure, idempotent=False)]
        with running(self.home, extra_tools=tools, policies={"tisra": AppPolicy(frozenset(t.name for t in tools))}) as (_, client):
            for tool in tools:
                job = client.submit(tool.name, {}, tool.name)
                final = client.wait(job["id"])
                self.assertEqual(final["state"], "needs_review")
                self.assertEqual(final["attempts"], 1)
                self.assertEqual(client.submit(tool.name, {}, tool.name)["id"], job["id"])
            self.assertEqual(effects, ["oversized", "fault"])

    def test_upgrade_contract_and_idempotency_changes_do_not_execute(self):
        for variant in ("idempotency", "version", "permissions"):
            home = self.home/variant
            home.mkdir(mode=0o700)
            previous = Tool("test.change", object_schema(), lambda a, c: {})
            store = Store(home/"state.sqlite")
            job = store.submit("tisra", "same", previous, {}, AppPolicy(frozenset({previous.name})))
            store.claim(); store.close()
            effects = []
            current = Tool(previous.name, object_schema(), lambda a, c: effects.append("BAD"),
                           idempotent=variant != "idempotency", version=2 if variant == "version" else 1,
                           permissions=("new_private",) if variant == "permissions" else ())
            with running(home, extra_tools=[current], policies={"tisra": AppPolicy(frozenset({current.name}))},
                         identity_verifier=lambda connection, app: app) as (_, client):
                final = client.wait(job["id"])
                self.assertEqual(final["state"], "needs_review")
                self.assertEqual(final["error"], "tool_contract_changed")
                self.assertEqual(effects, [])

    def test_shutdown_keeps_resources_until_worker_exits(self):
        entered, release = threading.Event(), threading.Event()
        def noncooperative(args, context):
            entered.set(); release.wait(3)
            return {"finished": True}
        tool = Tool("test.blocking", object_schema(), noncooperative, idempotent=False)
        runtime = Runtime(self.home, extra_tools=[tool], policies={"tisra": AppPolicy(frozenset({tool.name}))}, shutdown_grace=.02)
        thread = threading.Thread(target=runtime.run); thread.start()
        client = Client(self.home, "tisra")
        try:
            client.connect(); job = client.submit(tool.name, {}, "blocking")
            self.assertTrue(entered.wait(1))
            runtime.shutdown(); time.sleep(.06)
            self.assertTrue(thread.is_alive()); self.assertFalse(runtime.closed.is_set())
            self.assert_fault("already_running", lambda: InstanceLock(self.home))
            self.assertEqual(runtime.store.get("tisra", job["id"])["state"], "running")
            release.set(); thread.join(3)
            self.assertFalse(thread.is_alive()); self.assertTrue(runtime.closed.is_set())
            lock = InstanceLock(self.home); lock.close()
        finally:
            release.set(); runtime.shutdown(); thread.join(3)


class SlowHTTPTests(unittest.TestCase):
    def test_http_slow_drip_has_absolute_deadline(self):
        class Slow(BaseHTTPRequestHandler):
            def log_message(self, *args): pass
            def do_GET(self):
                self.send_response(200); self.end_headers()
                try:
                    for byte in b'{"slow":true}':
                        self.wfile.write(bytes([byte])); self.wfile.flush(); time.sleep(.04)
                except (BrokenPipeError, ConnectionResetError):
                    pass
        server = ThreadingHTTPServer(("127.0.0.1", 0), Slow)
        thread = threading.Thread(target=server.serve_forever); thread.start()
        started = time.monotonic()
        try:
            with self.assertRaises(Fault) as error:
                local_json("http://127.0.0.1:"+str(server.server_port), timeout=.2)
            self.assertEqual(error.exception.code, "provider_deadline_exceeded")
            self.assertLess(time.monotonic()-started, .4)
        finally:
            server.shutdown(); thread.join(); server.server_close()
