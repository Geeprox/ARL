"""macOS process registration with kernel peer identity; host-only, no RPC enrollment.

This is a concrete optional verifier for a trusted supervisor launching fixed
clients. It is not a general code-signing authenticator or protection against
the account owner editing its own runtime. Registration is volatile by design.
"""
from __future__ import annotations

import ctypes
import hashlib
import os
import struct
import sys
import threading
import uuid
from pathlib import Path

from .contracts import Fault


class BSDInfo(ctypes.Structure):
    _fields_ = [(name, ctypes.c_uint32) for name in (
        "flags", "status", "xstatus", "pid", "ppid", "uid", "gid", "ruid", "rgid", "svuid", "svgid", "reserved")]
    _fields_ += [("comm", ctypes.c_char*16), ("name", ctypes.c_char*32)]
    _fields_ += [(name, ctypes.c_uint32) for name in ("nfiles", "pgid", "jobc", "tdev", "tpgid")]
    _fields_ += [("nice", ctypes.c_int32), ("start_sec", ctypes.c_uint64), ("start_usec", ctypes.c_uint64)]


def process_identity(pid):
    if sys.platform != "darwin":
        raise Fault("identity_platform_unsupported")
    library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    library.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
    library.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    info = BSDInfo()
    if library.proc_pidinfo(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info)) != ctypes.sizeof(info):
        raise Fault("peer_identity_unavailable")
    path = ctypes.create_string_buffer(4096)
    if library.proc_pidpath(pid, path, len(path)) <= 0:
        raise Fault("peer_identity_unavailable")
    return {"uid": info.uid, "birth": (info.start_sec, info.start_usec),
            "executable": str(Path(os.fsdecode(path.value)).resolve())}


class RegisteredPeerVerifier:
    def __init__(self, app_ids):
        self.app_ids = frozenset(app_ids)
        self.registry = {}
        self.lock = threading.Lock()
        self.generation = 0
        self._subject_epoch = uuid.uuid4().hex

    def registration_subject(self, app):
        """Bounded current generation with the existing kernel identity check.

        A descriptor or heartbeat cannot create a subject. Validation happens
        outside the registry lock, then the same entry must still be current.
        """
        with self.lock:
            if len(self.registry)>100:
                raise Fault('priority_identity_binding_unavailable')
            matches=[(pid,entry) for pid,entry in self.registry.items() if entry[0]==app]
            if len(matches)!=1:
                raise Fault('priority_identity_binding_unavailable')
            pid,entry=matches[0]
        if not self.is_registered(app,pid):
            raise Fault('priority_identity_binding_unavailable')
        with self.lock:
            if self.registry.get(pid) is not entry:
                raise Fault('priority_identity_binding_unavailable')
            generation=entry[2]
            return hashlib.sha256((self._subject_epoch+':'+app+':'+str(generation)).encode()).hexdigest()

    def register(self, app, pid, expected_executable):
        if app not in self.app_ids or type(pid) is not int or pid <= 0:
            raise Fault("unknown_app")
        current = process_identity(pid)
        expected = str(Path(expected_executable).resolve(strict=True))
        if current["uid"] != os.geteuid() or current["executable"] != expected:
            raise Fault("registration_identity_mismatch")
        with self.lock:
            self.generation += 1
            self.registry[pid] = (app, current, self.generation)
            return self.generation

    def registration_generation(self, app, pid):
        with self.lock:
            entry=self.registry.get(pid)
            return entry[2] if entry is not None and entry[0]==app else -1

    def revoke(self, pid, *, expected_generation=None):
        with self.lock:
            entry=self.registry.get(pid)
            if entry is None or (expected_generation is not None and entry[2]!=expected_generation):
                return False
            self.registry.pop(pid, None)
            return True

    def is_registered(self, app, pid):
        """Trusted host metadata guard; never enrolls or accepts caller claims."""
        with self.lock:
            registered = self.registry.get(pid)
        if registered is None or registered[0] != app:
            return False
        return self._is_current_record(pid, registered)

    def _is_current_record(self, pid, registered):
        try:
            current = process_identity(pid)
        except (OSError, Fault):
            return False
        with self.lock:
            return self.registry.get(pid) is registered and current == registered[1]

    def capture_registration(self, app, pid):
        """Host-only capture of this exact registration, not an app-ID grant.

        The lease never enrolls. Re-registering the same PID invalidates it even
        if the app/executable/birth metadata is unchanged. It remains subject to
        the owning host's separate code/profile/operation-policy checks.
        """
        with self.lock:
            record = self.registry.get(pid)
        if record is None or record[0] != app or not self._is_current_record(pid, record):
            raise Fault('app_identity_unverified')
        return RegistrationLease(self, pid, record)

    def session_binding(self, connection, app):
        if self(connection, app) != app:
            raise Fault('app_identity_unverified')
        pid = struct.unpack('i', connection.getsockopt(0, 2, 4))[0]
        lease = self.capture_registration(app, pid)
        key = hashlib.sha256((self._subject_epoch+':'+app+':'+str(lease.epoch)).encode()).hexdigest()
        return key, lease.is_current

    def __call__(self, connection, claimed_app):
        # SOL_LOCAL=0, LOCAL_PEERPID=2 from this Mac's SDK sys/un.h.
        try:
            pid = struct.unpack("i", connection.getsockopt(0, 2, 4))[0]
            with self.lock:
                registered = self.registry.get(pid)
            if registered is None or registered[0] != claimed_app:
                return None
            current = process_identity(pid)
            with self.lock:
                # Linearize validation with revoke/re-register. An older validation
                # cannot authorize after revoke or remove a newer registration.
                if self.registry.get(pid) is not registered:
                    return None
                if current != registered[1]:
                    self.registry.pop(pid, None)
                    return None
                return registered[0]
        except (OSError, Fault):
            return None  # Fail closed if kernel/process introspection is unavailable.


class RegistrationLease:
    """In-process host resource; no decoder, socket or registration capability."""
    __slots__ = ('_verifier', '_pid', '_record')

    def __init__(self, verifier, pid, record):
        self._verifier, self._pid, self._record = verifier, pid, record

    @property
    def subject(self):
        return self._record[0]

    @property
    def epoch(self):
        return self._record[2]

    def is_current(self):
        return self._verifier._is_current_record(self._pid, self._record)
