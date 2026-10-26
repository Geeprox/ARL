"""Actual factory/manager/broker/native provider assembly with only the SMB boundary synthetic."""
import asyncio
import base64
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / "integrations/nas/runtime"), str(ROOT)]
import nas_host as host
from arl_nas_credential import CredentialFault, Failure

class Wire:
    kernel_check = False
    nonce = None
    def __init__(self):
        self.stages = []
        self.reject = None
        self.lease_count = 0
    async def authorize(self, stage, scope, caller, *, lease=False):
        self.stages.append(stage)
        if stage == self.reject:
            raise CredentialFault(Failure.REVOKED)
        result = {"remaining_seconds": 30}
        if lease:
            self.lease_count += 1
            result["credential"] = base64.b64encode(json.dumps({"schema": 1,
                "endpoint_fingerprint": "a"*64, "username": "fixture", "password": "fixture-only"}).encode()).decode()
        return result

class SMB:
    opened = 0
    closed = 0
    after_list = None
    def __init__(self, config, credentials):
        assert credentials.payload() == {"username":"fixture", "password":"fixture-only"}
        assert config.require_encryption and config.root == "approved"
        type(self).opened += 1
    def health(self):
        return {"reachable":True,"authenticated":True,"readable":True}
    def list_page(self, path, cursor, limit):
        assert path == "" and cursor is None and limit <= 128
        if type(self).after_list:
            type(self).after_list()
        return {"entries":[{"path":"only.txt","kind":"file","revision":"b"*64,"size":4,"modified_ns":0}],
                "cursor":None,"complete":True}
    def close(self):
        type(self).closed += 1

def bootstrap():
    return {"kind":"connect","id":1,"nonce":"c"*32,
        "caller":{"subject":"local.arl.control","uid":os.getuid(),"pid":os.getpid(),"executable_sha256":"1"*64,
                  "designated_requirement_sha256":"2"*64,"profile_sha256":"3"*64,"registration_epoch":1},
        "config":{"source_ref":"fixture","transport":"smb","host":"synthetic.invalid","share":"fixture",
                  "root":"approved","credential_ref":"fixture-ref","enabled":True,
                  "connect_timeout_seconds":2,"operation_timeout_seconds":2,"health_interval_seconds":300},
        "credential_generation":"4"*32,"config_generation":1}

class AssemblyTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.previous = Path.cwd()
        self.directory = tempfile.TemporaryDirectory(prefix="arl-nas-fixture-",dir="/private/tmp")
        os.chmod(self.directory.name,0o700)
        os.chdir(self.directory.name)
        SMB.opened=SMB.closed=0
        SMB.after_list=None
        self.patch = patch.object(host,"SMBReader",SMB)
        self.patch.start()
        self.wire=Wire()
        self.runtime=host.NativeRuntimeHost(self.wire)

    async def asyncTearDown(self):
        await self.runtime.stop()
        self.patch.stop()
        os.chdir(self.previous)
        self.directory.cleanup()

    async def test_real_assembly_returns_opaque_bounded_metadata(self):
        state=await self.runtime.connect(bootstrap())
        self.assertTrue(state["connected"])
        result=await self.runtime.command({"kind":"list","id":2,"nonce":self.wire.nonce})
        self.assertEqual(len(result["entries"]),1)
        self.assertEqual(result["entries"][0]["size"],4)
        self.assertNotIn("path",result["entries"][0])
        self.assertFalse(result["snapshot_consistent"])
        self.assertEqual(self.wire.lease_count,1)
        self.assertTrue({"reserve","connect_effect","request_reply","inventory_metadata"}<=set(self.wire.stages))
        await self.runtime.stop()
        self.assertFalse(self.runtime.snapshot()["connected"])
        self.assertEqual(SMB.opened,SMB.closed)

    async def test_native_connect_budget_includes_all_seven_authorizations(self):
        original_authorize = self.wire.authorize
        async def slow_authorize(*args, **kwargs):
            await asyncio.sleep(.012) # 1.2s at the 1/100 coordinator scale.
            return await original_authorize(*args, **kwargs)
        self.wire.authorize = slow_authorize
        original_timeout = asyncio.timeout
        budgets = []
        def scaled_timeout(seconds):
            budgets.append(seconds)
            return original_timeout(seconds * .01)
        request = bootstrap()
        request["config"]["connect_timeout_seconds"] = 8
        with patch.object(host.asyncio, "timeout", side_effect=scaled_timeout):
            state = await self.runtime.connect(request)
        self.assertTrue(state["connected"])
        self.assertEqual(self.wire.stages, ["reserve", "lease", "lease", "connect", "connect_effect", "reply", "provider_reply"])
        self.assertIn(80, budgets)
        self.assertEqual(self.runtime.connection.manager.config.connect_timeout_seconds, 8)
        self.assertEqual(self.runtime.connection.manager.config.operation_timeout_seconds, 2)
        self.assertEqual(self.wire.lease_count, 1)
        self.assertEqual(SMB.opened, 1)

    async def test_trusted_connect_budget_rejects_unbounded_or_ambiguous_values(self):
        for value in [True, 0, -1, 91, float("inf"), float("nan")]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                host.make_scoped_nas_manager(Path(self.directory.name)/"invalid", scope=None, caller=None,
                    connect_coordinator_seconds=value)

    async def test_native_connect_coordinator_cannot_extend_original_authority(self):
        original_authorize = self.wire.authorize
        async def slow_authorize(*args, **kwargs):
            await asyncio.sleep(.012)
            return await original_authorize(*args, **kwargs)
        self.wire.authorize = slow_authorize
        original_authority = host.NativePipeAuthority
        def short_authority(wire, caller, scope, deadline):
            return original_authority(wire, caller, scope, min(deadline, host.time.monotonic() + .025))
        with patch.object(host, "NativePipeAuthority", side_effect=short_authority):
            with self.assertRaises(TimeoutError):
                await self.runtime.connect(bootstrap())
        self.assertEqual(SMB.opened, 0)
        self.assertLessEqual(self.wire.lease_count, 1)
        self.assertTrue(self.runtime.authority.revoked)

    async def test_ordinary_manager_keeps_its_original_connect_timeout(self):
        from homeplane.nas_connection import NASConnectionManager, NASConnectionConfig, NASCredentials
        opened = []
        async def slow_resolver(_):
            await asyncio.sleep(.12)
            return NASCredentials("fixture", "fixture-only")
        class Transport:
            async def connect(self, config, credentials):
                opened.append(True)
                return {"reachable":True,"authenticated":True,"readable":True}
            async def close(self): pass
        manager = NASConnectionManager(Path(self.directory.name)/"ordinary.json",
            credential_resolver=slow_resolver, transport_factory=Transport)
        config = NASConnectionConfig.model_validate(bootstrap()["config"])
        config = config.model_copy(update={"connect_timeout_seconds":8})
        original_timeout = asyncio.timeout
        try:
            with patch.object(host.asyncio, "timeout", side_effect=lambda seconds:original_timeout(seconds * .01)):
                await manager.configure(config, expected_generation=0)
                for _ in range(100):
                    if manager.status().failure: break
                    await asyncio.sleep(.003)
                self.assertEqual(manager.status().failure, "nas_timeout")
            self.assertEqual(opened, [])
        finally:
            await manager.close()

    async def test_native_denial_before_secret_and_network(self):
        self.wire.reject="reserve"
        with self.assertRaises(CredentialFault) as caught:
            await self.runtime.connect(bootstrap())
        self.assertEqual(caught.exception.code,Failure.CALLER_UNVERIFIED)
        self.assertEqual(SMB.opened,0)
        self.assertEqual(self.wire.lease_count,0)

    async def test_revoke_on_late_reply_does_not_publish(self):
        await self.runtime.connect(bootstrap())
        SMB.after_list=lambda: setattr(self.wire,"reject","request_reply")
        with self.assertRaises(Exception):
            await self.runtime.command({"kind":"list","id":2,"nonce":self.wire.nonce})

    async def test_expiry_stops_real_manager_without_retry(self):
        await self.runtime.connect(bootstrap())
        self.runtime.authority.deadline=0
        await asyncio.wait_for(self.runtime.monitor,1)
        self.assertFalse(self.runtime.snapshot()["connected"])
        self.assertEqual(self.runtime.failure,"expired")
        self.assertEqual(SMB.opened,1)

    async def test_status_rechecks_remote_health_then_closes_on_failure(self):
        await self.runtime.connect(bootstrap())
        self.runtime.last_health = 0
        with patch.object(SMB,"health",side_effect=OSError("synthetic_disconnect")):
            result = await self.runtime.command({"kind":"status","id":2,"nonce":self.wire.nonce})
        self.assertFalse(result["connected"])
        self.assertEqual(result["failure"],"nas_transport_failed")
        self.assertEqual(SMB.opened,1)

    async def test_session_command_nonce_cannot_be_switched(self):
        await self.runtime.connect(bootstrap())
        with self.assertRaises(CredentialFault):
            await self.runtime.command({"kind":"list","id":2,"nonce":"d"*32})

if __name__=="__main__":
    unittest.main()
