"""Deterministic NAS acceptance data and an owner-injected read/cleanup runner.

No account, credential, network connection or NAS path is resolved here. The
coordinator supplies the already authorized Mio caller and exact metadata. The
CLI only prepares local synthetic files; it cannot upload or delete anything.
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import stat
import time
import uuid

from integrations.nas.attachment_bridge import collect_download_file, digest, BridgeFault

PREFIX = "ARL-Test-20261030-"
CHINESE_PREFIX = "ARL-验收-20261030"
LARGE_BYTES = 3 * 1024 * 1024 + 17


class AcceptanceFault(ValueError):
    def __init__(self, code):
        self.code = code
        super().__init__(code)


def fail(code):
    raise AcceptanceFault(code)


def samples():
    # These are the existing public, synthetic format fixtures, never user data.
    from tests.fixtures import nas_documents
    result = {PREFIX + "document." + name.rsplit(".", 1)[1]: raw
              for name, raw in nas_documents.fixtures().items()}
    marker = (CHINESE_PREFIX + " synthetic transfer; safe to remove after exact verification.\n").encode()
    result[PREFIX + "large.bin"] = marker + (bytes(range(256)) * ((LARGE_BYTES + 255) // 256))[:LARGE_BYTES-len(marker)]
    result[PREFIX + "write.txt"] = (CHINESE_PREFIX + "\nSynthetic new-file and exact cleanup check.\n").encode()
    return result


def manifest():
    expected = {"pdf": ["ARL PDF fixture"], "docx": ["ARL DOCX fixture", "你好"],
                "xlsx": ["ARL XLSX fixture", "你好"], "pptx": ["ARL PPTX fixture", "第二张"]}
    files = []
    for name, raw in sorted(samples().items()):
        kind = name.rsplit(".", 1)[1]
        row = dict(name=name, size=len(raw), sha256=digest(raw),
                   purpose="document_read" if kind in expected else "large_download" if kind == "bin" else "new_file_write",
                   document_format=kind if kind in expected else None,
                   expected_text=expected.get(kind, []))
        files.append(row)
    return dict(schema_version=1, label=CHINESE_PREFIX, filename_prefix=PREFIX,
                synthetic=True, files=files, overwrite_allowed=False,
                scope_change_allowed=False, cleanup="only_confirmed_created_and_exact_identity_revision_sha")


def prepare(directory):
    """Create a new private local pack; never merge into an existing directory."""
    directory = Path(directory)
    directory.mkdir(parents=True, mode=0o700, exist_ok=False)
    for name, raw in samples().items():
        fd = os.open(directory / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "wb") as out:
            out.write(raw); out.flush(); os.fsync(out.fileno())
    value = manifest()
    fd = os.open(directory / "MANIFEST.json", os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as out:
        json.dump(value, out, ensure_ascii=False, sort_keys=True, indent=2)
        out.flush(); os.fsync(out.fileno())
    return value


def business(reply):
    """Validate the actual two Mio business representations, including failures."""
    if type(reply) is not dict or not {"content", "structuredContent", "isError"} <= set(reply):
        fail("invalid_mio_reply")
    content, value = reply["content"], reply["structuredContent"]
    if (type(content) is not list or len(content) != 1 or type(content[0]) is not dict
            or content[0].get("type") != "text" or type(content[0].get("text")) is not str
            or len(content[0]["text"].encode()) > 196608 or type(value) is not dict
            or type(reply["isError"]) is not bool):
        fail("invalid_mio_reply")
    try:
        decoded = json.loads(content[0]["text"])
        if json.dumps(decoded, sort_keys=True, allow_nan=False) != json.dumps(value, sort_keys=True, allow_nan=False):
            fail("mio_representations_differ")
    except (ValueError, TypeError, RecursionError):
        fail("invalid_mio_reply")
    if reply["isError"] or value.get("state") == "failed":
        code = value.get("error", {}).get("code") if type(value.get("error")) is dict else None
        fail(code if type(code) is str and code.isascii() and code.replace("_", "").isalnum() and len(code) <= 96 else "mio_operation_failed")
    return decoded


def _fence(value):
    source, generation, epoch = (value.get(k) for k in ("source_ref", "config_generation", "connection_epoch"))
    import re
    if (type(source) is not str or re.fullmatch(r"[A-Za-z0-9_-]{1,96}", source) is None
            or type(generation) is not int or not 1 <= generation <= 2**63-1
            or type(epoch) is not str or re.fullmatch(r"[0-9a-f]{32}", epoch) is None):
        fail("invalid_scope_fence")
    return dict(source_ref=source, config_generation=generation, connection_epoch=epoch)


def read_acceptance(*, call, listing, verify, run_id=None, clock=time.monotonic):
    """Run exact document reads and streamed downloads in the supplied live scope.

    The callback must be the existing trusted caller, not an endpoint/path from
    a tool request. No reconnect, scope restoration, write or automatic retry.
    All sample files must already exist in the selected scope. Failures stop.
    """
    if not callable(call) or not callable(verify): fail("owner_required")
    verify()
    listed = business(listing)
    fence = _fence(listed)
    if type(listed.get("entries")) is not list: fail("invalid_listing")
    indexed = {}
    for entry in listed["entries"]:
        if type(entry) is not dict or entry.get("kind") != "file": continue
        name = PurePosixPath(entry.get("path", "")).name
        if not name.startswith(PREFIX): continue
        if name in indexed: fail("ambiguous_sample_name")
        indexed[name] = entry
    run_id = uuid.UUID(run_id) if run_id is not None else uuid.uuid4()
    results = []
    for item in manifest()["files"]:
        entry = indexed.get(item["name"])
        if entry is None: fail("sample_missing")
        if type(entry.get("size")) is not int or entry["size"] != item["size"]: fail("sample_size_mismatch")
        common = dict(fence, **{k:entry[k] for k in ("object_ref", "revision", "size")}, name=item["name"])
        verify()
        if item["document_format"] is not None:
            result = business(call("mio_nas_read_document", dict(common)))
            if (result.get("source_sha256") != item["sha256"] or result.get("source_size") != item["size"]
                    or result.get("format") != item["document_format"] or result.get("complete") is not True
                    or result.get("object_ref") != common["object_ref"] or result.get("revision") != common["revision"]
                    or _fence(result) != fence or type(result.get("text")) is not str
                    or not all(text in result["text"] for text in item["expected_text"])):
                fail("document_acceptance_mismatch")
        operation_id = str(uuid.uuid5(run_id, item["name"]))
        expected = dict(common, operation_id=operation_id)
        downloaded = call("mio_nas_download", dict(expected))
        with collect_download_file(downloaded, expected=expected, call=call, verify=verify, clock=clock) as got:
            if got.size != item["size"] or got.sha256 != item["sha256"]:
                fail("sample_digest_mismatch")
        verify()
        results.append(dict(name=item["name"], size=item["size"], sha256=item["sha256"],
                            document_verified=item["document_format"] is not None,
                            download_verified=True, operation_id=operation_id))
    return dict(schema_version=1, state="read_checks_passed", transport_attestation="supplied_by_owner",
                scope_changed=False, write_performed=False, files=results)


IDENTITY = {"path", "object_ref", "revision", "size", "sha256"}


def _created_identity(identity):
    import re
    if type(identity) is not dict or set(identity) != IDENTITY or type(identity["path"]) is not str:
        fail("creation_identity_mismatch")
    path = PurePosixPath(identity["path"])
    item = next((row for row in manifest()["files"] if path.name == row["name"]), None)
    if (item is None or path.is_absolute() or ".." in path.parts or str(path) != identity["path"]
            or "\\" in identity["path"] or any(ord(c) < 32 for c in identity["path"])
            or type(identity["size"]) is not int or identity["size"] != item["size"]
            or identity["sha256"] != item["sha256"]
            or any(type(identity[k]) is not str or re.fullmatch(r"[0-9a-f]{64}", identity[k]) is None for k in ("object_ref", "revision"))):
        fail("creation_identity_mismatch")
    return item


class CleanupRun:
    """One durable cleanup attempt per confirmed, verified created sample.

    delete_exact must be the trusted backend's conditional deletion primitive:
    it must bind the opened object/revision/digest through the actual deletion.
    A path-only delete API cannot implement that callback. Unknown effects are
    retained for review and never automatically attempted again.
    """
    def __init__(self, directory):
        self.directory = Path(directory)
        self.directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        info = self.directory.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            fail("private_journal_required")

    @contextmanager
    def _state(self):
        fd = os.open(self.directory / "cleanup.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1 or info.st_mode & 0o077:
                fail("private_journal_required")
            fcntl.flock(fd, fcntl.LOCK_EX)
            path = self.directory / "cleanup.json"
            if path.exists() or path.is_symlink():
                state_fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
                try:
                    info = os.fstat(state_fd)
                    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1 or info.st_mode & 0o077 or info.st_size > 65536:
                        fail("private_journal_required")
                    value = json.loads(os.read(state_fd, 65537))
                finally: os.close(state_fd)
            else: value = dict(schema_version=1, samples={})
            if type(value) is not dict or set(value) != {"schema_version", "samples"} or type(value["schema_version"]) is not int or value["schema_version"] != 1 or type(value["samples"]) is not dict:
                fail("invalid_cleanup_journal")
            paths = set()
            for key, row in value["samples"].items():
                try:
                    valid_id = type(key) is str and str(uuid.UUID(key)) == key
                except (ValueError, AttributeError): valid_id = False
                if (not valid_id or type(row) is not dict or set(row) != {"state", "identity"}
                        or row["state"] not in {"verified_created", "delete_attempted", "deleted", "unknown"}):
                    fail("invalid_cleanup_journal")
                _created_identity(row["identity"])
                if row["identity"]["path"] in paths: fail("invalid_cleanup_journal")
                paths.add(row["identity"]["path"])
            yield value
        finally:
            os.close(fd)

    def _save(self, value):
        raw = json.dumps(value, sort_keys=True, ensure_ascii=False).encode()
        temporary = self.directory / ("cleanup-" + uuid.uuid4().hex + ".tmp")
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        try:
            with os.fdopen(fd, "wb") as out:
                out.write(raw); out.flush(); os.fsync(out.fileno())
            os.replace(temporary, self.directory / "cleanup.json")
            directory_fd = os.open(self.directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            try: os.fsync(directory_fd)
            finally: os.close(directory_fd)
        finally:
            try: temporary.unlink()
            except FileNotFoundError: pass

    def register_created(self, *, operation_id, baseline_absent, identity, verified_sha256):
        try:
            if str(uuid.UUID(operation_id)) != operation_id: fail("invalid_creation_receipt")
        except (ValueError, AttributeError): fail("invalid_creation_receipt")
        if type(identity) is not dict or set(identity) != IDENTITY or baseline_absent is not True:
            fail("confirmed_new_file_required")
        item = _created_identity(identity)
        if verified_sha256 != item["sha256"]:
            fail("creation_identity_mismatch")
        with self._state() as state:
            old = state["samples"].get(operation_id)
            value = dict(state="verified_created", identity=dict(identity))
            if old is not None and old != value: fail("cleanup_already_consumed")
            if any(row["identity"]["path"] == identity["path"] and key != operation_id for key,row in state["samples"].items()):
                fail("target_already_registered")
            state["samples"][operation_id] = value
            self._save(state)

    def cleanup(self, *, operation_id, stat_exact, hash_exact, delete_exact, verify):
        if not all(callable(f) for f in (stat_exact, hash_exact, delete_exact, verify)): fail("conditional_delete_backend_required")
        with self._state() as state:
            row = state["samples"].get(operation_id)
            if row is None or row.get("state") != "verified_created": fail("cleanup_already_consumed")
            identity = dict(row["identity"])
            verify()
            if stat_exact(identity) != identity or hash_exact(identity) != identity["sha256"]:
                fail("cleanup_target_changed")
            verify()
            row["state"] = "delete_attempted"
            self._save(state)  # Durable consume precedes any possible effect.
            try:
                outcome = delete_exact(dict(identity))
                verify()
                if outcome != {"state":"deleted", "identity":identity} or stat_exact(identity) is not None:
                    fail("cleanup_unconfirmed")
                row["state"] = "deleted"
                self._save(state)
                return dict(state="deleted", operation_id=operation_id, identity=identity, automatic_replay=False)
            except BaseException:
                row["state"] = "unknown"
                self._save(state)
                raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prepare", type=Path, required=True, help="New local output directory; no NAS access")
    args = parser.parse_args()
    value = prepare(args.prepare)
    print(json.dumps(dict(state="local_pack_prepared", directory=str(args.prepare.resolve()),
                         files=value["files"], nas_write_performed=False), ensure_ascii=False))


if __name__ == "__main__":
    main()
