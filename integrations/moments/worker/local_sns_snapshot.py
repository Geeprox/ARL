#!/usr/bin/env python3
"""Independent read-only SQLCipher4 SNS snapshot, including validated WAL commits.

Only explicit --source (sns.db), --keys-file and --output are consumed. No
WeChat/wx-cli code, process access, account requests or network. The saved key is
used as a raw 32-byte AES key; no guessed passphrase derivation. The supported
4096/80 SHA512 profile is accepted only after page authentication succeeds.
Every main page and current-epoch WAL frame is authenticated before decryption.
WAL's rolling checksums and epoch salt define its contiguous logical prefix;
old-epoch preallocated tail is reported, not applied. Only the final complete
commit is overlaid. SQLite integrity_check validates the resulting private DB.
"""
from __future__ import annotations

import argparse
import hashlib
import hmac
import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import stat
import struct
import sys
import tempfile
import time


PAGE_SIZE = 4096
RESERVE = 80
DATA_END = PAGE_SIZE - RESERVE
MAX_SOURCE_BYTES = 2 * 1024 * 1024 * 1024
SQLITE_HEADER = b"SQLite format 3\x00"


class SnapshotError(ValueError):
    """Stable public error codes contain neither paths nor secret material."""


def _runtime():
    if importlib.util.find_spec("cryptography") is not None:return
    raise SnapshotError("existing_cryptography_runtime_required")


def _stat_identity(value):
    return (value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns, value.st_ctime_ns)


def _path_identity(path):
    try:return _stat_identity(path.stat())
    except FileNotFoundError:return None


def _read_file(path):
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_size > MAX_SOURCE_BYTES:
            raise SnapshotError("source_not_regular_or_too_large")
        chunks, count = [], 0
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:break
            count += len(chunk)
            if count > MAX_SOURCE_BYTES:raise SnapshotError("source_too_large")
            chunks.append(chunk)
        after = os.fstat(descriptor)
        if _stat_identity(before) != _stat_identity(after) or count != before.st_size:
            raise SnapshotError("source_changed_during_read")
        return b"".join(chunks), _stat_identity(before)
    finally:
        os.close(descriptor)


def capture(source, *, attempts=3):
    """Read stable DB+WAL generations without opening SQLite on original files."""
    wal_path = Path(str(source) + "-wal")
    for attempt in range(attempts):
        before = (_path_identity(source), _path_identity(wal_path))
        if before[0] is None:raise SnapshotError("source_missing")
        try:
            database, db_identity = _read_file(source)
            if before[1] is None:
                wal, wal_identity = b"", None
            else:
                wal, wal_identity = _read_file(wal_path)
            after = (_path_identity(source), _path_identity(wal_path))
            if before != after or after != (db_identity, wal_identity):
                raise SnapshotError("source_pair_changed_during_capture")
            return database, wal, {"attempts": attempt + 1,
                "database_stat": list(db_identity), "wal_stat": list(wal_identity) if wal_identity else None}
        except (FileNotFoundError, SnapshotError) as error:
            if isinstance(error, SnapshotError) and not str(error).startswith("source_"):
                raise
            if attempt + 1 == attempts:raise SnapshotError("stable_source_pair_unavailable") from None
            time.sleep(0.05)
    raise SnapshotError("stable_source_pair_unavailable")


def load_sns_key(keys_file):
    # Parse the explicit saved mapping, select SNS only, and never print values.
    try:
        with keys_file.open("r", encoding="utf-8") as source:
            mapping = json.load(source)
        if not isinstance(mapping, dict):raise SnapshotError("saved_key_mapping_invalid")
        selected = [record for name, record in mapping.items()
                    if isinstance(name, str) and Path(name).name.lower() == "sns.db"]
        if len(selected) != 1:raise SnapshotError("saved_sns_key_not_unique")
        record = selected[0]
        encoded = record.get("enc_key") if isinstance(record, dict) else None
        if not isinstance(encoded, str) or len(encoded) != 64:
            raise SnapshotError("saved_sns_key_not_32_bytes")
        key = bytes.fromhex(encoded)
        if len(key) != 32:raise SnapshotError("saved_sns_key_not_32_bytes")
        return key
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as error:
        if isinstance(error, SnapshotError):raise
        raise SnapshotError("saved_sns_key_unreadable_or_invalid") from None


class SQLCipher4:
    def __init__(self, key, salt):
        if not isinstance(key, bytes) or len(key) != 32 or len(salt) != 16:
            raise SnapshotError("unsupported_key_or_salt_length")
        self.key, self.salt = key, salt
        self.hmac_key = hashlib.pbkdf2_hmac("sha512", key,
                                           bytes(value ^ 0x3a for value in salt), 2, 32)

    def decrypt(self, page, number):
        from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
        if len(page) != PAGE_SIZE or not 1 <= number <= 0x7ffffffe:
            raise SnapshotError("invalid_encrypted_page")
        offset = 16 if number == 1 else 0
        if number == 1 and page[:16] != self.salt:
            raise SnapshotError("page1_salt_mismatch")
        # SQLCipher4 authenticates ciphertext+IV+LE32(page number), excluding
        # page1's unencrypted salt and the trailing 64-byte SHA512 HMAC itself.
        calculated = hmac.new(self.hmac_key, page[offset:DATA_END + 16]
                              + struct.pack("<I", number), hashlib.sha512).digest()
        if not hmac.compare_digest(calculated, page[DATA_END + 16:PAGE_SIZE]):
            raise SnapshotError("page_hmac_failed")
        decryptor = Cipher(algorithms.AES(self.key), modes.CBC(page[DATA_END:DATA_END + 16])).decryptor()
        plaintext = decryptor.update(page[offset:DATA_END]) + decryptor.finalize()
        # SQLite retains the 80-byte reserved area in its page geometry; zero it
        # in the private plaintext copy instead of exposing obsolete IV/HMAC.
        return (SQLITE_HEADER if number == 1 else b"") + plaintext + bytes(RESERVE)


def wal_checksum(data, previous=(0, 0), byte_order="<"):
    if len(data) % 8:raise SnapshotError("wal_checksum_input_misaligned")
    first, second = previous
    for left, right in struct.iter_unpack(byte_order + "II", data):
        first = (first + left + second) & 0xffffffff
        second = (second + right + first) & 0xffffffff
    return first, second


def decrypt_wal(wal, codec):
    report = {"present": bool(wal), "bytes": len(wal), "sha256": hashlib.sha256(wal).hexdigest(),
              "header_checksum_valid": None, "valid_current_epoch_frames": 0,
              "authenticated_frames": 0, "commit_markers": 0, "committed_frames": 0,
              "uncommitted_frames_not_applied": 0, "tail_bytes_not_applied": 0,
              "logical_end": "absent_or_empty", "final_database_pages": None}
    if not wal:return {}, report
    if len(wal) < 32:raise SnapshotError("wal_header_truncated")
    magic, version, page_size, _checkpoint, salt1, salt2, check1, check2 = struct.unpack(">8I", wal[:32])
    if magic not in (0x377f0682, 0x377f0683) or version != 3007000 or page_size != PAGE_SIZE:
        raise SnapshotError("unsupported_wal_profile")
    order = ">" if magic & 1 else "<"
    rolling = wal_checksum(wal[:24], byte_order=order)
    if rolling != (check1, check2):raise SnapshotError("wal_header_checksum_failed")
    report.update({"header_checksum_valid": True, "magic": hex(magic),
                   "version": version, "page_size": page_size})
    frames, last_commit, final_pages = [], 0, None
    frame_size, position = 24 + PAGE_SIZE, 32
    while position < len(wal):
        remaining = wal[position:]
        if len(remaining) < 24:
            if any(remaining):raise SnapshotError("wal_partial_frame_header")
            report["logical_end"] = "zero_preallocated_tail"
            break
        page_number, database_pages, fs1, fs2, fc1, fc2 = struct.unpack(">6I", wal[position:position + 24])
        if (fs1, fs2) != (salt1, salt2):
            # SQLite WAL readers stop at the first different salt. Old-epoch
            # bytes may survive WAL reset/preallocation and cannot be appended
            # to the new epoch; no later frame is searched or cherry-picked.
            report["logical_end"] = "stale_epoch_at_first_frame" if not frames else "stale_epoch_tail"
            break
        if len(remaining) < frame_size:raise SnapshotError("wal_current_epoch_frame_truncated")
        if not 1 <= page_number <= 0x7ffffffe or database_pages > 0x7ffffffe:
            raise SnapshotError("wal_invalid_frame_page_number")
        page = wal[position + 24:position + frame_size]
        calculated = wal_checksum(wal[position:position + 8] + page, rolling, order)
        if calculated != (fc1, fc2):raise SnapshotError("wal_frame_checksum_failed")
        decrypted = codec.decrypt(page, page_number)
        rolling = calculated
        frames.append((page_number, decrypted))
        if database_pages:
            if database_pages < page_number:raise SnapshotError("wal_commit_size_invalid")
            last_commit, final_pages = len(frames), database_pages
            report["commit_markers"] += 1
        position += frame_size
    else:
        report["logical_end"] = "physical_end"
    committed = {}
    for number, page in frames[:last_commit]:
        if number <= final_pages:committed[number] = page
    report.update({"valid_current_epoch_frames": len(frames), "authenticated_frames": len(frames),
                   "committed_frames": last_commit, "unique_pages_overlaid": len(committed),
                   "uncommitted_frames_not_applied": len(frames) - last_commit,
                   "tail_bytes_not_applied": len(wal) - position,
                   "final_database_pages": final_pages})
    return committed, report


def reconstruct(database, wal, key):
    if len(database) < PAGE_SIZE or len(database) % PAGE_SIZE:
        raise SnapshotError("encrypted_database_page_alignment_invalid")
    if database.startswith(SQLITE_HEADER):raise SnapshotError("source_is_already_plaintext")
    codec = SQLCipher4(key, database[:16])
    count = len(database) // PAGE_SIZE
    plaintext = bytearray(len(database))
    for index in range(count):
        start = index * PAGE_SIZE
        plaintext[start:start + PAGE_SIZE] = codec.decrypt(database[start:start + PAGE_SIZE], index + 1)
    header = plaintext[:100]
    if (int.from_bytes(header[16:18], "big") != PAGE_SIZE or header[20] != RESERVE
            or header[18] not in (1, 2) or header[19] not in (1, 2)
            or header[21:24] != bytes([64, 32, 32])):
        raise SnapshotError("decrypted_sqlite_header_profile_invalid")
    overlays, wal_report = decrypt_wal(wal, codec)
    final_pages = wal_report["final_database_pages"] or count
    if final_pages > MAX_SOURCE_BYTES // PAGE_SIZE:raise SnapshotError("snapshot_size_limit")
    if final_pages > count:
        for number in range(count + 1, final_pages + 1):
            if number not in overlays:raise SnapshotError("wal_snapshot_has_missing_new_page")
        plaintext.extend(bytes((final_pages - count) * PAGE_SIZE))
    for number, page in overlays.items():
        start = (number - 1) * PAGE_SIZE
        plaintext[start:start + PAGE_SIZE] = page
    del plaintext[final_pages * PAGE_SIZE:]
    return bytes(plaintext), {"page_size": PAGE_SIZE, "reserved_bytes": RESERVE,
        "profile": "SQLCipher4_AES256CBC_HMACSHA512_raw32",
        "main_pages_authenticated": count, "final_pages": final_pages, "wal": wal_report}


def validate_snapshot(path):
    connection = sqlite3.connect(path.resolve().as_uri() + "?mode=ro&immutable=1", uri=True)
    try:
        # Do not expose rows or corruption diagnostics containing user content.
        checked = list(connection.execute("PRAGMA integrity_check"))
        if checked != [("ok",)]:raise SnapshotError("sqlite_integrity_check_failed")
        tables = {row[0] for row in connection.execute("SELECT name FROM sqlite_schema WHERE type='table'")}
        if "SnsTimeLine" not in tables:
            raise SnapshotError("snapshot_missing_sns_timeline")
        result = {"sqlite_integrity_check": "ok", "table_count": len(tables),
                  "sqlite_page_count": connection.execute("PRAGMA page_count").fetchone()[0]}
        result["sns_timeline_rows"] = connection.execute('SELECT count(*) FROM "SnsTimeLine"').fetchone()[0]
        return result
    except sqlite3.Error:
        raise SnapshotError("sqlite_snapshot_validation_failed") from None
    finally:
        connection.close()


def _private_write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor, temporary = tempfile.mkstemp(prefix="." + path.name + "-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(data);output.flush();os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):os.unlink(temporary)


def snapshot(source, keys_file, output, manifest=None):
    source, keys_file, output = Path(source).resolve(), Path(keys_file).resolve(), Path(output).resolve()
    manifest = Path(manifest).resolve() if manifest else Path(str(output) + ".manifest.json")
    if source.name.lower() != "sns.db":raise SnapshotError("explicit_sns_database_required")
    protected = {source, Path(str(source) + "-wal"), Path(str(source) + "-shm"), keys_file}
    if output in protected or manifest in protected or output == manifest:
        raise SnapshotError("output_must_not_replace_input")
    key = load_sns_key(keys_file)
    database, wal, stable = capture(source)
    plaintext, crypto_report = reconstruct(database, wal, key)
    # No saved key, derived key, IV or salt is written to either deliverable.
    output.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor, temporary = tempfile.mkstemp(prefix=".verified-sns-", dir=output.parent)
    candidate = Path(temporary)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(plaintext);handle.flush();os.fsync(handle.fileno())
        verified = validate_snapshot(candidate)
        # A final path/stat check avoids publishing if a checkpoint happened
        # while authentication/integrity validation ran.
        if (_path_identity(source) != tuple(stable["database_stat"])
                or _path_identity(Path(str(source) + "-wal")) !=
                (tuple(stable["wal_stat"]) if stable["wal_stat"] else None)):
            raise SnapshotError("source_changed_before_snapshot_publish")
        os.replace(candidate, output)
    finally:
        if candidate.exists():candidate.unlink()
    report = {"format": "independent-sns-private-snapshot-v1", "source": str(source),
              "source_bytes": len(database), "source_sha256": hashlib.sha256(database).hexdigest(),
              "source_stability": stable, "output": str(output),
              "output_bytes": len(plaintext), "output_sha256": hashlib.sha256(plaintext).hexdigest(),
              "source_write_performed": False, "network_used": False,
              "key_scope": "one_explicit_saved_sns_raw_key_not_exported",
              **crypto_report, **verified}
    _private_write(manifest, (json.dumps(report, ensure_ascii=False, indent=2) + "\n").encode())
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--keys-file", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--manifest", type=Path)
    args = parser.parse_args(argv)
    try:
        _runtime()
        report = snapshot(args.source, args.keys_file, args.output, args.manifest)
        # Paths containing account directory names stay in the private manifest.
        public = {name: report[name] for name in ("source_bytes", "output_bytes", "page_size",
            "main_pages_authenticated", "final_pages", "sqlite_integrity_check", "table_count")}
        if "sns_timeline_rows" in report:public["sns_timeline_rows"] = report["sns_timeline_rows"]
        public.update({"status": "ok", "wal_bytes": report["wal"]["bytes"],
                       "wal_current_frames_authenticated": report["wal"]["authenticated_frames"],
                       "wal_frames_committed": report["wal"]["committed_frames"],
                       "wal_logical_end": report["wal"]["logical_end"],
                       "source_write_performed": False, "network_used": False})
        print(json.dumps(public, sort_keys=True))
        return 0
    except (SnapshotError, OSError, ValueError) as error:
        code = str(error) if isinstance(error, SnapshotError) else "local_snapshot_io_or_format_error"
        print(json.dumps({"status": "failed", "error_code": code,
                          "source_write_performed": False, "network_used": False}))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
