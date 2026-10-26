from __future__ import annotations

import ctypes
import fcntl
import os
import socket
import stat
import sys
from pathlib import Path

from .contracts import Fault


def private_home(home):
    home = Path(home).absolute()
    if home.is_symlink():
        raise Fault("unsafe_home")
    home.mkdir(parents=True, exist_ok=True, mode=0o700)
    info = home.stat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
        raise Fault("unsafe_home", "Runtime home must be an owner-only directory")
    for name in ("runtime.sock", "instance.lock", "state.sqlite", "state.sqlite-wal",
                 "state.sqlite-shm", "disabled"):
        path = home/name
        if path.is_symlink():
            raise Fault("unsafe_home")
        if path.exists():
            item = path.stat()
            if item.st_uid != os.geteuid() or item.st_mode & 0o077:
                raise Fault("unsafe_home")
    if len(os.fsencode(str(home / "runtime.sock"))) >= 104:
        raise Fault("socket_path_too_long")
    return home


class InstanceLock:
    def __init__(self, home):
        self.fd = os.open(str(home/"instance.lock"), os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            os.close(self.fd)
            raise Fault("already_running") from None

    def close(self):
        fcntl.flock(self.fd, fcntl.LOCK_UN)
        os.close(self.fd)


def peer_uid(connection):
    if sys.platform == "darwin":
        uid, gid = ctypes.c_uint(), ctypes.c_uint()
        libc = ctypes.CDLL(None, use_errno=True)
        if libc.getpeereid(connection.fileno(), ctypes.byref(uid), ctypes.byref(gid)) != 0:
            raise Fault("peer_identity_unavailable")
        return uid.value
    if hasattr(socket, "SO_PEERCRED"):
        import struct
        return struct.unpack("3i", connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))[1]
    raise Fault("peer_identity_unavailable")
