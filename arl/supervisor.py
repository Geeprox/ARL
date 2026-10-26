from __future__ import annotations

import hashlib
import json
import os
import re
import selectors
import subprocess
import stat
import threading
import time
from dataclasses import dataclass
from pathlib import Path

from .contracts import Fault, encode
from .identity import RegisteredPeerVerifier, process_identity
from .extension_contracts import managed_app_ids


class SignedPeerVerifier:
    """Host-pinned native requirements; no caller registration, executable or certificate.

    Uses this Mac's LOCAL_PEERTOKEN=6 and Security dynamic guest validation.
    Requirements must pin a reviewed cdhash (ad-hoc development) or production
    identifier + signing anchor/team, or native owner certificate + sealed Info
    resource binding. An identifier alone is insufficient policy.
    """
    def __init__(self, helper, requirements):
        self.helper = Path(helper).resolve(strict=True)
        development = r'cdhash H"[0-9a-fA-F]{40,64}"'
        production = r'identifier "[A-Za-z0-9.-]+" and anchor apple generic and certificate leaf\[subject\.OU\] = "[A-Z0-9]{10}"'
        # Same certificate + signed resource seal emitted by OwnerReadAuthority.
        native_owner = (r'identifier "[A-Za-z0-9.-]+" and certificate leaf = H"[0-9a-fA-F]{40}"'
                        r' and info\[ARLCredentialReadOwnerAuthoritySHA256\] = "[0-9a-fA-F]{64}"')
        if any(not (re.fullmatch(development, value) or re.fullmatch(production, value)
                    or re.fullmatch(native_owner, value))
               for value in requirements.values()):
            raise Fault("signature_policy_unpinned")
        self.requirements = dict(requirements)

    def __call__(self, connection, claimed_app):
        requirement = self.requirements.get(claimed_app)
        if requirement is None:
            return None
        try:
            token = connection.getsockopt(0, 6, 32)
            if len(token) != 32:
                return None
            result = subprocess.run([str(self.helper)],
                input=encode({"audit_token": token.hex(), "requirement": requirement}),
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=1,
                env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C", "TMPDIR": "/tmp"})
            return claimed_app if result.returncode == 0 and json.loads(result.stdout) == {"valid": True} else None
        except (OSError, ValueError, subprocess.TimeoutExpired):
            return None

    def session_binding(self, connection, app):
        import struct
        if self(connection, app) != app:
            raise Fault('app_identity_unverified')
        pid = struct.unpack('i', connection.getsockopt(0, 2, 4))[0]
        identity = process_identity(pid)
        audit_token = connection.getsockopt(0, 6, 32)
        requirement = self.requirements[app]
        key = hashlib.sha256(encode([audit_token.hex(),requirement,identity])).hexdigest()
        def current():
            try:
                if self.requirements.get(app) != requirement or process_identity(pid) != identity:
                    return False
                result = subprocess.run([str(self.helper)], input=encode({'audit_token':audit_token.hex(),'requirement':requirement}),
                    stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=1,
                    env={'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','LANG':'C','LC_ALL':'C','TMPDIR':'/tmp'})
                return result.returncode == 0 and json.loads(result.stdout) == {'valid':True}
            except (OSError,ValueError,Fault,subprocess.TimeoutExpired):
                return False
        return key, current


@dataclass(frozen=True)
class LaunchSpec:
    app: str
    executable: Path
    arguments: tuple
    working_directory: Path
    pinned_sources: tuple  # (absolute Path, sha256) pairs, fixed by trusted host review
    python_paths: tuple = ()
    # Optional full actor closure, set only by the reviewed trusted host. The
    # single top-level state directory is mutable but never an import path.
    closure_root: Path | None = None
    closure_mutable_directory: str | None = None

    def validate_closure(self):
        if self.closure_root is None:
            return
        root = Path(self.closure_root)
        if not root.is_absolute() or self.closure_mutable_directory not in {None, 'state'}:
            raise Fault('untrusted_launch_spec')
        expected_files, expected_dirs = set(), {'.'}
        for path, _ in self.pinned_sources:
            try:
                relative = Path(path).relative_to(root)
            except ValueError:
                raise Fault('untrusted_launch_spec') from None
            if '..' in relative.parts or relative.parts[0] == self.closure_mutable_directory:
                raise Fault('untrusted_launch_spec')
            expected_files.add(str(relative))
            expected_dirs.update(str(parent) for parent in relative.parents)
        actual_files, actual_dirs = set(), set()
        # followlinks=False is not sufficient by itself: reject link entries,
        # nonregular immutable nodes and unsafe owner/modes at every walk.
        for current, dirs, files in os.walk(root, followlinks=False):
            current = Path(current)
            for path in [current, *(current/name for name in dirs), *(current/name for name in files)]:
                relative = path.relative_to(root)
                info = path.lstat()
                mutable = bool(relative.parts) and relative.parts[0] == self.closure_mutable_directory
                if (stat.S_ISLNK(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o022 or
                    not (stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode) or (mutable and stat.S_ISSOCK(info.st_mode)))):
                    raise Fault('unsafe_launch_closure')
                if mutable:
                    if len(relative.parts) == 1 and (not stat.S_ISDIR(info.st_mode) or info.st_mode & 0o077):
                        raise Fault('unsafe_launch_closure')
                    continue
                if stat.S_ISDIR(info.st_mode): actual_dirs.add(str(relative))
                else: actual_files.add(str(relative))
        if actual_files != expected_files or actual_dirs != expected_dirs:
            raise Fault('launch_closure_changed')

    def validate(self):
        if self.app not in managed_app_ids() or not self.pinned_sources:
            raise Fault("untrusted_launch_spec")
        self.validate_closure()
        for path, digest in self.pinned_sources:
            if hashlib.sha256(Path(path).read_bytes()).hexdigest() != digest:
                raise Fault("launch_source_changed")
        if not self.executable.is_file() or not self.working_directory.is_dir():
            raise Fault("launch_installation_missing")


class ControlledSupervisor:
    """Foreground only. Owns fixed child PIDs and reviewed entry/module hashes.

    Python identity is a controlled launch + pinned source set + kernel PID/birth,
    never merely a shared interpreter path. No RPC accepts or mutates LaunchSpec.
    The child blocks on a host gate before using RPC, preventing enrollment races.
    """
    def __init__(self, specs, verifier, *, control=None, descriptors=()):
        self.specs = {spec.app: spec for spec in specs}
        if len(self.specs) != len(specs):
            raise Fault("duplicate_launch_app")
        self.verifier = verifier
        self.control = control
        self.descriptors = {d.id:d for d in descriptors}
        if control is not None:
            if set(self.descriptors) != set(self.specs):
                raise Fault('missing_app_descriptor')
            for descriptor in descriptors:
                descriptor.validate()
        self.children = {}
        # The generation belongs to this exact launched child. A later query by
        # PID must never become authority for an older callback.
        self.owned = {}
        self.lock = threading.RLock()

    def _owned_generation(self, app, spec, process):
        current=self.owned.get(app)
        if (current is None or current[0] is not spec or current[1] is not process or
                self.children.get(app) is not process):
            return None
        return current[2]

    def _revoke_owned(self, app, spec, process, generation):
        """Caller holds the supervisor lock; cleanup only this registration."""
        if self._owned_generation(app,spec,process)!=generation:return False
        if not self.verifier.revoke(process.pid,expected_generation=generation):return False
        # A replacement may arrive while an old callback is being validated.
        # Do not apply its app/PID cleanup to that newer registration.
        if (self._owned_generation(app,spec,process)!=generation or
                self.verifier.registration_generation(app,process.pid)!=-1):
            return True
        if self.control:
            self.control.apps.revoke(app)
            self.control.resources.unregister(process.pid)
        return True

    def metadata_active(self, app, spec, process, generation=None):
        # Called by AppRegistry while it holds its own lock. Do not take the
        # supervisor lock or mutate AppRegistry here; its snapshot revokes the
        # exact entry whose guard returned False. ResourceSampler also rejects
        # a changed PID/birth on its next read.
        owned=self._owned_generation(app,spec,process)
        if generation is None:generation=owned
        if (owned is None or owned!=generation or
                self.verifier.registration_generation(app,process.pid)!=generation):
            return False
        if process.poll() is not None or not self.verifier.is_registered(app,process.pid):
            self.verifier.revoke(process.pid,expected_generation=generation)
            return False
        try:
            spec.validate()
            return (self._owned_generation(app,spec,process)==generation and
                    self.verifier.registration_generation(app,process.pid)==generation)
        except (OSError, Fault):
            self.verifier.revoke(process.pid,expected_generation=generation)
            return False

    def launch(self, app, *, on_registered=None):
        with self.lock:
            spec = self.specs.get(app)
            if spec is None:
                raise Fault("unknown_app")
            spec.validate()
            old = self.children.get(app)
            if old and old.poll() is None:
                return old
            if old:
                owned=self.owned.get(app)
                if owned is not None and owned[1] is old:
                    self._revoke_owned(app,owned[0],old,owned[2])
                    self.owned.pop(app,None)
            env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "PYTHONDONTWRITEBYTECODE": "1"}
            if spec.python_paths:
                env["PYTHONPATH"] = os.pathsep.join(str(p) for p in spec.python_paths)
            process = subprocess.Popen([str(spec.executable), *spec.arguments], cwd=spec.working_directory,
                env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                text=True, bufsize=1)
            generation=None
            try:
                selector = selectors.DefaultSelector()
                try:
                    selector.register(process.stdout, selectors.EVENT_READ)
                    deadline, line = time.monotonic()+3, bytearray()
                    while b"\n" not in line and len(line) <= 32:
                        remaining = deadline-time.monotonic()
                        if remaining <= 0 or not selector.select(timeout=remaining):
                            raise Fault("launch_handshake_failed")
                        chunk = os.read(process.stdout.fileno(), 1)
                        if not chunk:
                            raise Fault("launch_handshake_failed")
                        line.extend(chunk)
                    if line != b"prepared\n":
                        raise Fault("launch_handshake_failed")
                finally:
                    selector.close()
                spec.validate()
                self.verifier.register(app, process.pid, spec.executable)
                generation=self.verifier.registration_generation(app,process.pid)
                if generation<1:raise Fault('registration_identity_mismatch')
                self.children[app]=process
                self.owned[app]=(spec,process,generation)
                if self.control:
                    self.control.apps.register(self.descriptors[app],
                        active_guard=lambda a=app,s=spec,p=process,g=generation:self.metadata_active(a,s,p,g))
                    self.control.resources.register(app,process.pid,[app])
                # Trusted host-only attachment while the existing child gate is
                # still closed. No RPC may supply this callback or enrollment.
                if on_registered is not None:
                    on_registered(process)
                process.stdin.write("go\n"); process.stdin.flush()
                return process
            except BaseException:
                if generation is not None:
                    self._revoke_owned(app,spec,process,generation)
                if generation is not None and self._owned_generation(app,spec,process)==generation:
                    self.owned.pop(app,None)
                if self.children.get(app) is process:self.children.pop(app,None)
                process.kill(); process.wait()
                for pipe in (process.stdin, process.stdout, process.stderr):
                    if pipe is not None: pipe.close()
                raise

    def peer_verifier(self, connection, app):
        with self.lock:
            spec, process = self.specs.get(app), self.children.get(app)
            if spec is None or process is None:return None
            generation=self._owned_generation(app,spec,process)
            if generation is None:return None
            if self.verifier.registration_generation(app,process.pid)!=generation:
                return None
            if process.poll() is not None:
                self._revoke_owned(app,spec,process,generation)
                return None
            try:
                spec.validate()
            except (OSError, Fault):
                self._revoke_owned(app,spec,process,generation)
                return None
            if self.verifier.registration_generation(app,process.pid)!=generation:
                return None
            result=self.verifier(connection, app)
            return result if self.verifier.registration_generation(app,process.pid)==generation else None

    def close(self):
        with self.lock:
            for app, process in self.children.items():
                owned=self.owned.get(app)
                if owned is not None and owned[1] is process:
                    self._revoke_owned(app,owned[0],process,owned[2])
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        process.kill(); process.wait()
            self.owned.clear()


def pin_sources(paths):
    return tuple((Path(p).resolve(strict=True), hashlib.sha256(Path(p).read_bytes()).hexdigest()) for p in paths)
