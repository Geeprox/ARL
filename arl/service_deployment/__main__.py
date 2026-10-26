"""Bounded fixture/catalog reader. Prints a dry-run, never writes a deployment."""
import argparse
import os
import stat
import sys

from ..contracts import Fault, encode
from .planning import build_plan
from .validation import (MAX_INPUT_BYTES, MAX_SERVICES, ValidationFault, arr, integer,
                         obj, parse_configuration, parse_inventory, parse_manifest,
                         service_id, strict_json)


def plan_catalog(value):
    obj(value, {"schema_version", "root_service_id", "manifests", "configurations", "inventory"}, "catalog")
    integer(value["schema_version"], "schema_version", 1, 1)
    root = service_id(value["root_service_id"], "root_service_id")
    manifests = tuple(parse_manifest(m) for m in arr(value["manifests"], "manifests", MAX_SERVICES))
    by_id = {m.service_id: m for m in manifests}
    configurations = []
    for c in arr(value["configurations"], "configurations", MAX_SERVICES):
        if type(c) is not dict or c.get("service_id") not in by_id:
            raise Fault("unknown_configuration_service")
        configurations.append(parse_configuration(c, by_id[c["service_id"]]))
    inventory = parse_inventory(value["inventory"]) if value["inventory"] is not None else None
    return build_plan(root, manifests, tuple(configurations), inventory=inventory)


def _read_regular_file(path):
    """Use one bounded read-only fd; reject terminal symlinks and special files."""
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise OSError("input_not_regular")
        raw = bytearray()
        while len(raw) < MAX_INPUT_BYTES + 1:
            chunk = os.read(fd, MAX_INPUT_BYTES + 1 - len(raw))
            if not chunk:
                break
            raw.extend(chunk)
        return bytes(raw)
    finally:
        os.close(fd)


def main(argv=None):
    parser = argparse.ArgumentParser(description="Validate a bounded service catalog and print an unperformed deployment plan.")
    parser.add_argument("--input", required=True, help="Explicit JSON catalog file, or - for stdin (at most 64 KiB).")
    args = parser.parse_args(argv)
    try:
        if args.input == "-":
            raw = sys.stdin.buffer.read(MAX_INPUT_BYTES + 1)
        else:
            raw = _read_regular_file(args.input)
        plan = plan_catalog(strict_json(raw))
        sys.stdout.buffer.write(encode(plan.wire()) + b"\n")
        return 3 if plan.state == "blocked" else 0
    except Fault as fault:
        record = {"schema_version": 1, "kind": "service_deployment_validation", "state": "invalid",
                  "code": fault.code, "execution": "not_performed", "effects_performed": []}
        if isinstance(fault, ValidationFault):
            record["field"] = fault.field
        sys.stdout.buffer.write(encode(record) + b"\n")
        return 2
    except OSError:
        sys.stdout.buffer.write(encode({"schema_version": 1, "kind": "service_deployment_validation", "state": "invalid",
                                       "code": "input_unavailable", "execution": "not_performed", "effects_performed": []}) + b"\n")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
