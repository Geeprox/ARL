#!/usr/bin/env python3
"""Read only three fixed journal entries; never list records or print contents."""
import argparse
import json
import os
import re
import stat


def inspect(home):
    if not os.path.isabs(home) or os.path.normpath(home) != home:
        raise ValueError("canonical_absolute_home_required")
    directory = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for component in home.split("/")[1:]:
            child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
            os.close(directory)
            directory = child
        result = {"read_only": True, "records_read": 0, "entries": {}}
        stats = {}
        for name in ("product-v1", "product-v1/tasks", "product-v1.anchor"):
            try:
                if name == "product-v1/tasks":
                    root = stats.get("product-v1")
                    if root is None or not stat.S_ISDIR(root.st_mode) or root.st_uid != os.getuid() or stat.S_IMODE(root.st_mode) != 0o700:
                        result["entries"][name] = {"checked": False, "reason": "unsafe_or_absent_parent"}
                        continue
                    child = os.open("product-v1", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
                    try:
                        entry = os.stat("tasks", dir_fd=child, follow_symlinks=False)
                    finally:
                        os.close(child)
                else:
                    entry = os.stat(name, dir_fd=directory, follow_symlinks=False)
            except FileNotFoundError:
                result["entries"][name] = {"exists": False}
                continue
            stats[name] = entry
            result["entries"][name] = {"exists": True, "device": entry.st_dev, "inode": entry.st_ino,
                "uid": entry.st_uid, "mode": oct(stat.S_IMODE(entry.st_mode)), "links": entry.st_nlink,
                "directory": stat.S_ISDIR(entry.st_mode), "regular_file": stat.S_ISREG(entry.st_mode)}
        if "product-v1.anchor" not in stats:
            result["binding"] = "absent" if "product-v1" not in stats else "missing_anchor"
            return result
        marker = stats["product-v1.anchor"]
        if not stat.S_ISREG(marker.st_mode) or marker.st_uid != os.getuid() or stat.S_IMODE(marker.st_mode) != 0o600 or marker.st_nlink != 1 or marker.st_size > 256:
            result["binding"] = "unsafe_anchor"
            return result
        fd = os.open("product-v1.anchor", os.O_RDONLY | os.O_NOFOLLOW, dir_fd=directory)
        try:
            current = os.fstat(fd)
            if (current.st_dev, current.st_ino) != (marker.st_dev, marker.st_ino):
                result["binding"] = "anchor_changed"
                return result
            raw = os.read(fd, 257)
        finally:
            os.close(fd)
        legacy = re.fullmatch(rb"v1\n[0-9]+\n[0-9]+\n[0-9]+\n[0-9]+\n", raw)
        stable = re.fullmatch(rb"v2\n[a-fA-F0-9-]{36}\n[0-9]+\n[a-fA-F0-9-]{36}\n[0-9]+\n", raw)
        if not legacy and not stable:
            result["binding"] = "invalid_anchor_format"
            return result
        if not all(key in stats for key in ("product-v1", "product-v1/tasks")):
            result["binding"] = "missing_directory"
            return result
        root, tasks = stats["product-v1"], stats["product-v1/tasks"]
        if stable:
            fields = raw.decode("ascii").splitlines()
            matches = int(fields[2]) == root.st_ino and int(fields[4]) == tasks.st_ino
            result["binding"] = "v2_requires_native_volume_verification" if matches else "identity_mismatch"
            result["anchor_version"] = 2
            return result
        expected = ("v1\n%d\n%d\n%d\n%d\n" % (root.st_dev, root.st_ino, tasks.st_dev, tasks.st_ino)).encode()
        result["binding"] = "matches" if raw == expected else "identity_mismatch"
        return result
    finally:
        os.close(directory)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--home", required=True)
    args = parser.parse_args()
    try:
        result = inspect(args.home)
    except (OSError, ValueError) as error:
        result = {"read_only": True, "records_read": 0, "error": type(error).__name__, "errno": getattr(error, "errno", None)}
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
