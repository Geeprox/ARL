"""Limited policy/CLI regression tests; only synthetic temporary paths, no service/native work."""
from contextlib import contextmanager
from dataclasses import replace
import io
import json
import os
from pathlib import Path
import signal
import stat
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from arl import PROTOCOL
from arl.contracts import AppPolicy, Fault, encode
from arl.host import make_runtime, metadata_policies
from arl.service import Runtime
from arl.service_deployment.__main__ import main
from arl.service_deployment.portal import CATALOG_METHOD, REVIEW_METHOD, ServicePortal
from arl.service_deployment.validation import MAX_INPUT_BYTES

ROOT = Path(__file__).resolve().parents[2]
DATA = (ROOT / "tests/service_deployment/fixtures/docker-catalog.json").read_bytes()


class DeadlineExceeded(Exception):
    pass


@contextmanager
def deadline():
    previous = signal.getsignal(signal.SIGALRM)
    def timed_out(*_):
        raise DeadlineExceeded()
    signal.signal(signal.SIGALRM, timed_out)
    signal.setitimer(signal.ITIMER_REAL, 0.25)
    try:
        yield
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous)


def cli(path):
    output = io.BytesIO()
    with patch("sys.stdout", SimpleNamespace(buffer=output)), deadline():
        code = main(["--input", str(path)])
    return code, json.loads(output.getvalue()), output.getvalue()


def deny(*args, **kwargs):
    raise AssertionError("unexpected effect")


class ReviewFixes(unittest.TestCase):
    def test_runtime_without_settings_retains_legacy_policy_behavior(self):
        policy = AppPolicy(frozenset(), frozenset(), 0, 0, 0, methods=frozenset({"health"}))
        policies = {"tisra": policy}
        with tempfile.TemporaryDirectory(prefix="policy-fix-", dir="/private/tmp") as folder:
            for name, constructor in (("fixed", Runtime),):
                with patch("socket.socket", side_effect=deny), patch("subprocess.Popen", side_effect=deny), patch("threading.Thread.start", side_effect=deny):
                    runtime = constructor(Path(folder) / name, policies=policies, execute_jobs=False)
                    self.assertEqual(runtime.policies, policies)
                    self.assertIs(runtime.policies["tisra"], policy)
                    self.assertNotIn("settings", runtime.policies)
                    self.assertFalse(runtime.execute_jobs)
                    self.assertIsNone(runtime.server)
                    self.assertIsNone(runtime.store)
                    self.assertIsNone(runtime.worker)
                    self.assertFalse(runtime.ready.is_set())
                    self.assertEqual(runtime.dispatch({"protocol": PROTOCOL, "app": "tisra", "method": "health", "params": {}})["ready"], False)
                    for method in (CATALOG_METHOD, REVIEW_METHOD):
                        with self.assertRaises(Fault):
                            runtime.dispatch({"protocol": PROTOCOL, "app": "tisra", "method": method, "params": {}})
                    with self.assertRaises(Fault):
                        runtime.dispatch({"protocol": PROTOCOL, "app": "settings", "method": CATALOG_METHOD, "params": {}})
                    runtime.control.close()
                    if hasattr(runtime, "service_portal"):
                        runtime.service_portal.close()
        self.assertEqual(policies, {"tisra": policy})

    def test_disabled_empty_portal_preserves_no_settings_policy_map(self):
        policy = AppPolicy(frozenset(), frozenset(), 0, 0, 0, methods=frozenset())
        for count in (1, 101):
            existing = {f"legacy{index}": policy for index in range(count)}
            result = ServicePortal().policies(existing)
            self.assertEqual(result, existing)
            self.assertIsNot(result, existing)
            self.assertNotIn("settings", result)
            self.assertTrue(all(p.methods == frozenset() for p in result.values()))

    def test_enabled_catalog_still_requires_settings_limits_and_zero_grants(self):
        portal = ServicePortal(DATA)
        policies = {"tisra": AppPolicy(frozenset(), frozenset(), 0, 0, 0, methods=frozenset())}
        with self.assertRaises(Fault) as error:
            portal.policies(policies)
        self.assertEqual(error.exception.code, "invalid_service_portal_composition")
        base = metadata_policies()
        extended = portal.policies(base)
        self.assertEqual(extended["settings"].methods - base["settings"].methods, {CATALOG_METHOD, REVIEW_METHOD})
        for identity in ("service.hub", "service.indexer"):
            self.assertEqual(extended[identity].tools | extended[identity].providers | extended[identity].methods, frozenset())
        collision = dict(base); collision["service.hub"] = base["mio"]
        with self.assertRaises(Fault):
            portal.policies(collision)
        overflow = dict(base)
        overflow.update({f"legacy{index}": base["mio"] for index in range(100)})
        with self.assertRaises(Fault):
            portal.policies(overflow)

    def test_default_host_retains_empty_read_only_portal(self):
        with tempfile.TemporaryDirectory(prefix="host-fix-", dir="/private/tmp") as folder:
            with patch("socket.socket", side_effect=deny), patch("subprocess.Popen", side_effect=deny), patch("threading.Thread.start", side_effect=deny):
                runtime = make_runtime(Path(folder) / "home")
                self.assertEqual(runtime.service_portal._manifests, ())
                self.assertEqual(runtime.service_portal.dispatch(CATALOG_METHOD, {})["entries"], [])
                self.assertTrue({CATALOG_METHOD, REVIEW_METHOD} <= runtime.policies["settings"].methods)
                self.assertFalse(runtime.execute_jobs)
                self.assertFalse(runtime.local_enabled)
                self.assertEqual(runtime.policies["settings"].tools, frozenset())
                runtime.control.close()
                runtime.service_portal.close()

    def test_regular_file_and_explicit_stdin_remain_unperformed_and_redacted(self):
        value = json.loads(DATA)
        value["manifests"][0]["credential_requirements"] = [{"key": "API_TOKEN", "purpose": "synthetic", "required": True}]
        value["configurations"][0]["credential_refs"] = {"API_TOKEN": "opaque-secret-sentinel"}
        raw = encode(value)
        with tempfile.TemporaryDirectory(prefix="cli-fix-", dir="/private/tmp") as folder:
            path = Path(folder) / "catalog.json"
            path.write_bytes(raw)
            code, result, output = cli(path)
            self.assertEqual(code, 0)
            self.assertEqual(result["effects_performed"], [])
            self.assertEqual(result["execution"], "not_performed")
            self.assertFalse(result["apply_available"])
            self.assertNotIn(b"opaque-secret-sentinel", output)
            with patch("sys.stdin", SimpleNamespace(buffer=io.BytesIO(raw))), patch("os.open", side_effect=deny):
                stdin_code, stdin_result, _ = cli("-")
            self.assertEqual((stdin_code, stdin_result), (code, result))

    def test_symlink_fifo_directory_and_mocked_device_fail_without_blocking(self):
        with tempfile.TemporaryDirectory(prefix="cli-types-", dir="/private/tmp") as folder:
            root = Path(folder); regular = root / "catalog.json"; regular.write_bytes(DATA)
            symlink = root / "secret-path-sentinel"; symlink.symlink_to(regular)
            fifo = root / "fifo-secret-path-sentinel"; os.mkfifo(fifo)
            for path in (symlink, fifo, root):
                code, result, output = cli(path)
                self.assertEqual(code, 2)
                self.assertEqual(result, {"schema_version": 1, "kind": "service_deployment_validation", "state": "invalid",
                                         "code": "input_unavailable", "execution": "not_performed", "effects_performed": []})
                self.assertNotIn(b"secret-path-sentinel", output)
            with patch("os.fstat", return_value=SimpleNamespace(st_mode=stat.S_IFCHR)), patch("os.read", side_effect=deny):
                code, result, _ = cli(regular)
            self.assertEqual(code, 2)
            self.assertEqual(result["code"], "input_unavailable")
            # NOFOLLOW applies to the final path component, not ancestor directories.
            actual_directory = root / "actual"; actual_directory.mkdir()
            (actual_directory / "catalog.json").write_bytes(DATA)
            alias = root / "ancestor"; alias.symlink_to(actual_directory, target_is_directory=True)
            self.assertEqual(cli(alias / "catalog.json")[0], 0)

    def test_oversize_regular_file_is_bounded_and_short_reads_are_assembled(self):
        with tempfile.TemporaryDirectory(prefix="cli-size-", dir="/private/tmp") as folder:
            large = Path(folder) / "large"; large.write_bytes(b"x" * (MAX_INPUT_BYTES + 1))
            actual_read = os.read; requested = []
            def record_read(fd, count):
                requested.append(count)
                return actual_read(fd, count)
            with patch("os.read", side_effect=record_read):
                code, result, _ = cli(large)
            self.assertEqual((code, result["code"]), (2, "input_too_large"))
            self.assertTrue(requested and max(requested) <= MAX_INPUT_BYTES + 1)
            regular = Path(folder) / "regular"; regular.write_bytes(DATA)
            reads = []
            def short_first(fd, count):
                reads.append(count)
                return actual_read(fd, min(count, 8) if len(reads) == 1 else count)
            with patch("os.read", side_effect=short_first):
                self.assertEqual(cli(regular)[0], 0)
            self.assertGreater(len(reads), 1)

    def test_one_read_only_fd_is_closed_on_success_stat_and_read_errors(self):
        actual_open, actual_stat, actual_read, actual_close = os.open, os.fstat, os.read, os.close
        with tempfile.TemporaryDirectory(prefix="cli-fds-", dir="/private/tmp") as folder:
            regular = Path(folder) / "regular"; regular.write_bytes(DATA)
            for failure in (None, "stat", "read"):
                opened, checked, closed, reads = [], [], [], []
                def open_fd(path, flags):
                    self.assertEqual(flags & (os.O_WRONLY | os.O_RDWR), 0)
                    self.assertEqual(flags & (os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC), os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
                    fd = actual_open(path, flags); opened.append(fd); return fd
                def check_fd(fd):
                    checked.append(fd)
                    if failure == "stat":
                        raise OSError("secret-error-sentinel")
                    return actual_stat(fd)
                def read_fd(fd, count):
                    reads.append(fd)
                    if failure == "read":
                        raise OSError("secret-error-sentinel")
                    return actual_read(fd, count)
                def close_fd(fd):
                    closed.append(fd); return actual_close(fd)
                with patch("os.open", side_effect=open_fd), patch("os.fstat", side_effect=check_fd), patch("os.read", side_effect=read_fd), patch("os.close", side_effect=close_fd):
                    code, result, output = cli(regular)
                self.assertEqual(code, 0 if failure is None else 2)
                self.assertEqual(opened, checked)
                self.assertEqual(opened, closed)
                self.assertTrue(all(fd == opened[0] for fd in reads))
                self.assertNotIn(b"secret-error-sentinel", output)
                for fd in opened:
                    with self.assertRaises(OSError):
                        actual_stat(fd)


if __name__ == "__main__":
    unittest.main()
