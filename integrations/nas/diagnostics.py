"""Read the four fixed, sanitized NAS diagnostic records without connecting.

This developer command never opens configuration, credentials, task bodies or
provider logs. Records are evidence of their timestamped failure, not a probe
of current server availability.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import pwd
import re
import stat
import time

STAGES = {
    "login-diagnostic.json": {"server_login", "share_list", "directory_list"},
    "file-diagnostic.json": {"file_connect", "file_health", "file_list", "file_stat", "file_read"},
}
NETWORK_RECORD = "network-diagnostic.json"
TIMING_RECORD = "authorization-timings.json"
TIMING_STAGES = {"reserve","lease","connect","connect_effect","reply","provider_reply",
                 "request","request_reply","inventory_metadata"}
TIMING_OUTCOMES = {"ok","reply_timeout","cancelled","wire_error"}


def _int(value, low=0, high=2**53-1):
    return type(value) is int and low <= value <= high


def _name(value, pattern):
    return type(value) is str and re.fullmatch(pattern, value) is not None


def _validate(value, name):
    if name == TIMING_RECORD:
        if (type(value) is not dict or set(value) != {"schema_version","operation","at","measurement","context","truncated","stages"}
                or type(value["schema_version"]) is not int or value["schema_version"] != 1
                or value["operation"] != "nas_native_authorization_timings" or not _int(value["at"])
                or value["measurement"] != "authorize_entry_to_validated_reply" or value["context"] != "read_only_connect_list"
                or type(value["truncated"]) is not bool or type(value["stages"]) is not list
                or not 1 <= len(value["stages"]) <= len(TIMING_STAGES)):
            raise ValueError("invalid_diagnostic")
        seen=set();count=0
        for row in value["stages"]:
            if (type(row) is not dict or set(row) != {"stage","count","total_microseconds","min_microseconds","max_microseconds","recent_microseconds","outcomes"}
                    or row["stage"] not in TIMING_STAGES or row["stage"] in seen
                    or not _int(row["count"],low=1,high=4096)
                    or not _int(row["total_microseconds"],high=4096*120_000_000)
                    or not _int(row["min_microseconds"],high=120_000_000)
                    or not _int(row["max_microseconds"],high=120_000_000)
                    or row["min_microseconds"] > row["max_microseconds"]
                    or not row["min_microseconds"]*row["count"] <= row["total_microseconds"] <= row["max_microseconds"]*row["count"]
                    or type(row["recent_microseconds"]) is not list
                    or len(row["recent_microseconds"]) != min(16,row["count"])
                    or any(not _int(item,low=row["min_microseconds"],high=row["max_microseconds"]) for item in row["recent_microseconds"])
                    or type(row["outcomes"]) is not dict or set(row["outcomes"]) != TIMING_OUTCOMES
                    or any(not _int(item,high=4096) for item in row["outcomes"].values())
                    or sum(row["outcomes"].values()) != row["count"]):
                raise ValueError("invalid_diagnostic")
            seen.add(row["stage"]);count+=row["count"]
        if count > 4096:raise ValueError("invalid_diagnostic")
        return value
    if name == NETWORK_RECORD:
        required = {"schema_version", "operation", "context", "credentials_read", "smb_payload_sent",
                    "at", "outcome", "elapsed_milliseconds"}
        optional = {"unsatisfied_reason", "error_domain", "error_code"}
        if (type(value) is not dict or not required <= set(value) or set(value) - required - optional
                or type(value["schema_version"]) is not int or value["schema_version"] != 1
                or value["operation"] != "nas_network_diagnostic" or value["context"] != "gui_after_transport_failure"
                or value["credentials_read"] is not False or value["smb_payload_sent"] is not False
                or not _int(value["at"]) or not _int(value["elapsed_milliseconds"], high=60000)
                or value["outcome"] not in {"ready", "failed", "deadline", "cancelled", "not_attempted"}
                or ("unsatisfied_reason" in value and value["unsatisfied_reason"] not in {
                    "not_available", "cellular_denied", "wifi_denied", "local_network_denied", "unknown"})
                or ("error_domain" in value) != ("error_code" in value)):
            raise ValueError("invalid_diagnostic")
        if "error_domain" in value:
            if (value["error_domain"] not in {"posix", "dns", "tls"}
                    or not _int(value["error_code"], low=0 if value["error_domain"] == "posix" else -2**31, high=2**31-1)):
                raise ValueError("invalid_diagnostic")
        return value
    if (type(value) is not dict or set(value) != {"schema", "at", "stage", "exception_chain"}
            or value["schema"] != 1 or type(value["schema"]) is not int
            or not _int(value["at"]) or value["stage"] not in STAGES[name]
            or type(value["exception_chain"]) is not list or not 1 <= len(value["exception_chain"]) <= 8):
        raise ValueError("invalid_diagnostic")
    for row in value["exception_chain"]:
        if (type(row) is not dict or not {"type", "frames"} <= set(row)
                or set(row) - {"type", "frames", "smb_status", "errno", "errno_name", "frames_truncated", "socket_family"}
                or not _name(row["type"], r"[A-Za-z_]{1,80}")
                or type(row["frames"]) is not list or len(row["frames"]) > 12):
            raise ValueError("invalid_diagnostic")
        if "smb_status" in row and not _int(row["smb_status"], high=0xffffffff):
            raise ValueError("invalid_diagnostic")
        if "errno" in row and not _int(row["errno"], high=0x7fffffff):
            raise ValueError("invalid_diagnostic")
        if "errno_name" in row and ("errno" not in row or not _name(row["errno_name"], r"[A-Z0-9_]{1,64}")):
            raise ValueError("invalid_diagnostic")
        if "frames_truncated" in row and row["frames_truncated"] is not True:
            raise ValueError("invalid_diagnostic")
        for frame in row["frames"]:
            if (type(frame) is not dict or set(frame) != {"module", "function", "line"}
                    or not _name(frame["module"], r"[A-Za-z_][A-Za-z0-9_.]{0,159}")
                    or not _name(frame["function"], r"[A-Za-z_][A-Za-z0-9_]{0,79}")
                    or not _int(frame["line"], 1, 2**31-1)):
                raise ValueError("invalid_diagnostic")
        if "socket_family" in row and (
                "errno" not in row or type(row["socket_family"]) is not str
                or row["socket_family"] not in {"ipv4", "ipv6"}
                or not any(frame["module"] == "socket" and frame["function"] == "create_connection"
                           for frame in row["frames"])):
            raise ValueError("invalid_diagnostic")
    return value


def _record(root_fd, name, now):
    try:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=root_fd)
        try:
            info = os.fstat(fd)
            limit = 4096 if name == NETWORK_RECORD else 16384 if name == TIMING_RECORD else 65536
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                    or info.st_nlink != 1 or info.st_mode & 0o077 or info.st_size > limit
                    or name in {NETWORK_RECORD,TIMING_RECORD} and stat.S_IMODE(info.st_mode) != 0o600):
                return {"state": "untrusted"}
            raw = os.read(fd, limit + 1)
            if len(raw) != info.st_size:
                return {"state": "changed"}
            def pairs(rows):
                value = {}
                for key, item in rows:
                    if key in value: raise ValueError("duplicate_key")
                    value[key] = item
                return value
            value = _validate(json.loads(raw, object_pairs_hook=pairs), name)
            age = now - value["at"]
            return dict(state="available", age_seconds=max(0, int(age)), fresh=0 <= age <= 300, record=value)
        finally:
            os.close(fd)
    except FileNotFoundError:
        return {"state": "missing"}
    except (OSError, ValueError, TypeError, RecursionError):
        # Never echo malformed input or an exception message into diagnostics.
        return {"state": "invalid"}


def snapshot(*, root=None, now=None):
    """root is only an injected test seam; the CLI exposes no path selector."""
    now = time.time() if now is None else now
    root = Path(pwd.getpwuid(os.getuid()).pw_dir) / "Library/Application Support/ARL/nas" if root is None else Path(root)
    result = dict(schema_version=1, operation="nas_local_diagnostics", connection_attempted=False,
                  credentials_read=False, current_server_health="not_probed", records={})
    try:
        fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            if os.fstat(fd).st_uid != os.getuid():
                raise OSError("untrusted")
            result["records"] = {name: _record(fd, name, now) for name in (*STAGES, NETWORK_RECORD, TIMING_RECORD)}
        finally:
            os.close(fd)
    except OSError:
        result["records"] = {name: {"state": "directory_unavailable"} for name in (*STAGES, NETWORK_RECORD, TIMING_RECORD)}
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.parse_args()
    print(json.dumps(snapshot(), ensure_ascii=False, sort_keys=True))


if __name__ == "__main__":
    main()
