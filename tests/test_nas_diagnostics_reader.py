"""Failure classification never requires credentials or a NAS connection."""
import errno
import json
import os
from pathlib import Path
import tempfile
import types
import unittest
from unittest.mock import patch

from integrations.nas import diagnostics
from tests.test_nas_diagnostic import diag, synthetic_socket_failure


class DiagnosticReaderTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name)
        self.root = self.home / "Library/Application Support/ARL/nas"
        self.root.mkdir(parents=True)

    def tearDown(self):
        self.temp.cleanup()

    def write(self, raw=None):
        value = dict(schema=1, at=1000, stage="file_connect", exception_chain=[dict(
            type="ConnectionRefusedError", errno=errno.ECONNREFUSED, errno_name="ECONNREFUSED", frames=[])])
        path = self.root / "file-diagnostic.json"
        path.write_text(json.dumps(value) if raw is None else raw)
        path.chmod(0o600)
        return path

    def record(self, now=1001):
        return diagnostics.snapshot(root=self.root, now=now)["records"]["file-diagnostic.json"]

    def network(self, **changes):
        value=dict(schema_version=1,operation="nas_network_diagnostic",context="gui_after_transport_failure",
            credentials_read=False,smb_payload_sent=False,at=1000,outcome="failed",
            unsatisfied_reason="local_network_denied",error_domain="posix",error_code=65,elapsed_milliseconds=20)
        value.update(changes)
        path=self.root/"network-diagnostic.json";path.write_text(json.dumps(value));path.chmod(0o600)
        return path

    def test_actual_record_roundtrip_and_staleness(self):
        with patch.object(diag.pwd, "getpwuid", return_value=types.SimpleNamespace(pw_dir=str(self.home))):
            diag.failure_record(OSError(errno.ETIMEDOUT, "SECRET_ENDPOINT_PASSWORD"), "file_read")
        value = json.loads((self.root / "file-diagnostic.json").read_bytes())
        fresh = self.record(value["at"] + 1)
        self.assertTrue(fresh["fresh"])
        self.assertEqual(fresh["record"]["exception_chain"][0]["errno"], errno.ETIMEDOUT)
        self.assertNotIn("SECRET", json.dumps(fresh))
        self.assertFalse(self.record(value["at"] + 301)["fresh"])
        self.assertFalse(self.record(value["at"] - 1)["fresh"])

    def test_actual_socket_family_record_roundtrip_and_legacy_compatibility(self):
        import socket
        for family, label in ((socket.AF_INET, "ipv4"), (socket.AF_INET6, "ipv6")):
            error, _ = synthetic_socket_failure([family], [OSError(errno.EHOSTUNREACH, "SECRET_HOST")])
            with patch.object(diag.pwd, "getpwuid", return_value=types.SimpleNamespace(pw_dir=str(self.home))):
                diag.failure_record(error, "file_connect")
            value = self.record()
            self.assertEqual(value["state"], "available")
            self.assertEqual(value["record"]["exception_chain"][1]["socket_family"], label)
            self.assertNotIn("SECRET", json.dumps(value))
        self.write()
        self.assertEqual(self.record()["state"], "available")

    def test_socket_family_requires_closed_enum_errno_and_matching_frame(self):
        self.write()
        original = json.loads((self.root / "file-diagnostic.json").read_bytes())
        original["exception_chain"][0]["frames"] = [dict(module="socket", function="create_connection", line=850)]
        for family in (None, True, 2, "AF_INET", "ipv5", "SECRET_ENDPOINT", [], {}):
            value = json.loads(json.dumps(original))
            value["exception_chain"][0]["socket_family"] = family
            self.write(json.dumps(value))
            self.assertEqual(self.record(), {"state": "invalid"})
            self.assertNotIn("SECRET", json.dumps(self.record()))
        for omit in ("errno", "socket_frame"):
            value = json.loads(json.dumps(original))
            row = value["exception_chain"][0]
            row["socket_family"] = "ipv4"
            if omit == "errno":
                row.pop("errno"); row.pop("errno_name")
            else:
                row["frames"] = []
            self.write(json.dumps(value))
            self.assertEqual(self.record(), {"state": "invalid"})
        for forbidden in ("address", "locals", "attempt_order"):
            value = json.loads(json.dumps(original))
            value["exception_chain"][0].update(socket_family="ipv4", **{forbidden: "SECRET_ENDPOINT"})
            self.write(json.dumps(value))
            self.assertEqual(self.record(), {"state": "invalid"})
            self.assertNotIn("SECRET", json.dumps(self.record()))

    def test_unknown_data_never_echoed_and_duplicate_keys_rejected(self):
        for raw in ('{"schema":1,"schema":1}', '{"error":"SECRET"}', "SECRET"):
            self.write(raw)
            self.assertEqual(self.record(), {"state": "invalid"})

    def test_symlink_hardlink_and_nonprivate_file_refused(self):
        target = self.home / "unrelated"
        target.write_text("SECRET")
        path = self.root / "file-diagnostic.json"
        path.symlink_to(target)
        self.assertEqual(self.record(), {"state": "invalid"})
        path.unlink()
        path = self.write()
        os.link(path, self.home / "hardlink")
        self.assertEqual(self.record(), {"state": "untrusted"})
        (self.home / "hardlink").unlink()
        path.chmod(0o644)
        self.assertEqual(self.record(), {"state": "untrusted"})

    def test_unavailable_and_current_health_are_honest(self):
        result = diagnostics.snapshot(root=self.root, now=1001)
        self.assertFalse(result["connection_attempted"])
        self.assertFalse(result["credentials_read"])
        self.assertEqual(result["current_server_health"], "not_probed")
        self.assertEqual(self.record(), {"state": "missing"})

    def test_fixed_gui_network_record_roundtrip_is_timestamped_not_live_health(self):
        self.network()
        value=diagnostics.snapshot(root=self.root,now=1001)
        record=value['records']['network-diagnostic.json']
        self.assertEqual(record['record']['unsatisfied_reason'],'local_network_denied')
        self.assertTrue(record['fresh']);self.assertEqual(record['age_seconds'],1)
        self.assertEqual(value['current_server_health'],'not_probed')
        self.network(outcome='ready')
        self.assertEqual(diagnostics.snapshot(root=self.root,now=1301)['current_server_health'],'not_probed')
        self.assertFalse(diagnostics.snapshot(root=self.root,now=1301)['records']['network-diagnostic.json']['fresh'])

    def test_network_schema_refuses_endpoint_text_unknown_fields_and_nonfinite_codes(self):
        for changes in ({'host':'SECRET_ENDPOINT'},{'outcome':'SECRET_BODY'}, {'credentials_read':True},
                        {'error_code':True},{'error_domain':'unknown'},{'unsatisfied_reason':'SECRET_BODY'},
                        {'elapsed_milliseconds':60001},{'smb_payload_sent':True}):
            with self.subTest(changes=changes):
                self.network(**changes)
                value=diagnostics.snapshot(root=self.root,now=1001)['records']['network-diagnostic.json']
                self.assertEqual(value,{'state':'invalid'})
                self.assertNotIn('SECRET',json.dumps(value))

    def test_network_requires_exact_0600_and_single_regular_file(self):
        path=self.network();path.chmod(0o400)
        self.assertEqual(diagnostics.snapshot(root=self.root,now=1001)['records']['network-diagnostic.json'],{'state':'untrusted'})
        path.chmod(0o600);os.link(path,self.home/'network-alias')
        self.assertEqual(diagnostics.snapshot(root=self.root,now=1001)['records']['network-diagnostic.json'],{'state':'untrusted'})


if __name__ == "__main__":
    unittest.main()
