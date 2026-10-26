from contextlib import ExitStack
from copy import deepcopy
import io
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

from arl.contracts import encode
from arl.control import AppRegistry
from arl.service_deployment import EvidenceSource, project_status
from arl.service_deployment.__main__ import main, plan_catalog
from support import NOW, evidence, fixture, single


class NoEffectsTests(unittest.TestCase):
    def test_planner_and_status_no_file_network_process_registry_or_thread_effect(self):
        data = fixture()
        m, c = single()
        binding, obs, rows, registry = evidence(m, c)
        before = deepcopy(registry.entries)
        prohibited = ["builtins.open", "os.open", "os.mkdir", "os.makedirs", "os.remove", "os.unlink", "os.rename",
                      "os.system", "subprocess.run", "subprocess.Popen", "socket.socket", "urllib.request.urlopen",
                      "threading.Thread.start", "pathlib.Path.open", "pathlib.Path.exists", "pathlib.Path.mkdir",
                      "pathlib.Path.write_bytes", "pathlib.Path.write_text", "pathlib.Path.stat"]
        with ExitStack() as stack:
            for name in prohibited:
                stack.enter_context(patch(name, side_effect=AssertionError("prohibited effect: " + name)))
            for method in ("register", "revoke", "observe_verified", "observe_capability", "snapshot"):
                stack.enter_context(patch.object(AppRegistry, method, side_effect=AssertionError("registry effect")))
            plan = plan_catalog(data)
            state = project_status(m, c, registry_rows=rows, registry_source=EvidenceSource.HOST,
                                   registration_binding=binding, observation=obs, now_ms=NOW)
            self.assertEqual(plan.wire()["effects_performed"], [])
            self.assertEqual(state.readiness, "ready")
        self.assertEqual(before, registry.entries)

    def test_inputs_are_not_mutated_and_repeated_plans_identical(self):
        data = fixture("nas-catalog.json")
        original = deepcopy(data)
        first = encode(plan_catalog(data).wire())
        self.assertEqual(first, encode(plan_catalog(data).wire()))
        self.assertEqual(data, original)

    def test_cli_read_only_stdin_and_rejects_apply(self):
        class Stream:
            def __init__(self, data=b""):
                self.buffer = io.BytesIO(data)
        out, inp = Stream(), Stream(encode(fixture()))
        with patch.object(sys, "stdout", out), patch.object(sys, "stdin", inp):
            self.assertEqual(main(["--input", "-"]), 0)
        result = json.loads(out.buffer.getvalue())
        self.assertEqual(result["execution"], "not_performed")
        self.assertEqual(result["registration"], "not_performed")
        with patch.object(sys, "stderr", io.StringIO()), self.assertRaises(SystemExit) as caught:
            main(["--input", "-", "--apply"])
        self.assertEqual(caught.exception.code, 2)

    def test_cli_invalid_secret_not_echoed_and_blocked_exit_distinct(self):
        class Stream:
            def __init__(self, data=b""):
                self.buffer = io.BytesIO(data)
        data = fixture(); data["configurations"][0]["secret"] = "secret-marker-must-not-echo"
        out = Stream()
        with patch.object(sys, "stdout", out), patch.object(sys, "stdin", Stream(encode(data))):
            self.assertEqual(main(["--input", "-"]), 2)
        self.assertNotIn(b"secret-marker", out.buffer.getvalue())
        data = fixture(); data["configurations"][0]["port_bindings"] = []
        out = Stream()
        with patch.object(sys, "stdout", out), patch.object(sys, "stdin", Stream(encode(data))):
            self.assertEqual(main(["--input", "-"]), 3)
        self.assertEqual(json.loads(out.buffer.getvalue())["state"], "blocked")
