"""Local-only, signed/session-bound relay to the native Messages receive owner.

The owning packaged host supplies the native parent's identity and transport.
Request JSON never supplies a process, credential, peer binding or scope grant.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import secrets
import socket
import stat
import struct
import time
import uuid
import hashlib
import plistlib
import re
import subprocess

from .contracts import Fault, encode
from .identity import process_identity
from .supervisor import SignedPeerVerifier
from .wire import strict_json

CAPABILITY = "messages.receive"
METHODS = frozenset({"messages.receive.status", "messages.receive.pull", "messages.receive.ack"})
REQUEST_LIMIT = 16384
RESPONSE_LIMIT = 512 * 1024


class NativeReceiveTransport:
    """Authenticated native-parent socket, configured only by the trusted host."""
    def __init__(self, home, *, parent_pid, parent_requirement, peer_helper):
        self.home = Path(home).absolute()
        self.path = self.home / "messages-receive.sock"
        if (type(parent_pid) is not int or parent_pid <= 1 or parent_pid != os.getppid() or
                type(parent_requirement) is not str or not parent_requirement or
                not isinstance(peer_helper, Path)):
            raise Fault("messages_receive_parent_unverified")
        self.parent_pid = parent_pid
        self.parent_identity = process_identity(parent_pid)
        self.signed = SignedPeerVerifier(peer_helper, {"native-messages-owner": parent_requirement})
        self.package_current = None

    def _private_endpoint(self):
        try:
            for directory in (self.home, *self.home.parents):
                if directory.is_symlink():
                    raise Fault("messages_receive_transport_unavailable")
            info = self.home.stat()
            endpoint = self.path.lstat()
        except OSError as error:
            raise Fault("messages_receive_transport_unavailable") from error
        if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077 or
                not stat.S_ISSOCK(endpoint.st_mode) or endpoint.st_uid != os.geteuid() or
                stat.S_IMODE(endpoint.st_mode) != 0o600):
            raise Fault("messages_receive_transport_unavailable")

    def call(self, method, params, consumer, recheck):
        if method not in METHODS:
            raise Fault("unknown_method")
        self._check_package()
        self._private_endpoint()
        request_id = str(uuid.uuid4())
        request = {"schema_version": 1, "request_id": request_id, "method": method,
                   "consumer_app_id": consumer["app_id"], "consumer_session_id": consumer["session_id"],
                   "consumer_generation": consumer["registration_generation"],
                   "parameters_json": json.dumps(params, ensure_ascii=False, sort_keys=True, separators=(",", ":"))}
        raw = encode(request)
        if len(raw) > REQUEST_LIMIT:
            raise Fault("messages_receive_invalid_arguments")
        deadline = time.monotonic() + 8
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
                connection.settimeout(2)
                connection.connect(str(self.path))
                peer_pid = struct.unpack("i", connection.getsockopt(0, 2, 4))[0]
                if peer_pid != self.parent_pid or process_identity(peer_pid) != self.parent_identity:
                    raise Fault("messages_receive_parent_unverified")
                binding = self.signed.session_binding(connection, "native-messages-owner")
                if binding[1]() is not True:
                    raise Fault("messages_receive_parent_unverified")
                recheck()
                connection.sendall(raw + b"\n")
                result = bytearray()
                while b"\n" not in result:
                    left = deadline - time.monotonic()
                    if left <= 0:
                        raise Fault("messages_receive_deadline")
                    connection.settimeout(left)
                    chunk = connection.recv(min(65536, RESPONSE_LIMIT + 1 - len(result)))
                    if not chunk:
                        raise Fault("messages_receive_transport_unavailable")
                    result.extend(chunk)
                    if len(result) > RESPONSE_LIMIT:
                        raise Fault("messages_receive_result_limit")
                frame, tail = bytes(result).split(b"\n", 1)
                if tail:
                    raise Fault("messages_receive_invalid_response")
                if (binding[1]() is not True or process_identity(peer_pid) != self.parent_identity or
                        os.getppid() != self.parent_pid):
                    raise Fault("messages_receive_parent_unverified")
                recheck()
                reply = strict_json(frame)
                if (type(reply) is not dict or set(reply) != {"schema_version", "request_id", "ok", "result_json", "error_code"} or
                        reply["schema_version"] != 1 or type(reply["schema_version"]) is not int or
                        reply["request_id"] != request_id or type(reply["ok"]) is not bool):
                    raise Fault("messages_receive_invalid_response")
                if not reply["ok"]:
                    if type(reply["error_code"]) is not str or len(reply["error_code"]) > 128 or reply["result_json"] is not None:
                        raise Fault("messages_receive_invalid_response")
                    raise Fault(reply["error_code"])
                if reply["error_code"] is not None or type(reply["result_json"]) is not str:
                    raise Fault("messages_receive_invalid_response")
                value = strict_json(reply["result_json"].encode("utf-8"))
                recheck()
                self._check_package()
                connection.sendall(b"!")
                return value
        except (OSError, ValueError, KeyError) as error:
            raise Fault("messages_receive_transport_unavailable") from error

    def _check_package(self):
        try:
            if self.package_current is not None and self.package_current() is not True:
                raise Fault("messages_receive_package_unverified")
        except (OSError, ValueError, TypeError, KeyError) as error:
            raise Fault("messages_receive_package_unverified") from error


class MessagesReceive:
    def __init__(self, registry, policies, transport):
        if not callable(getattr(transport, "call", None)):
            raise Fault("messages_receive_invalid_composition")
        self.registry, self.policies, self.transport = registry, policies, transport

    def dispatch(self, app, method, params, binding, policy):
        if method not in METHODS or type(params) is not dict:
            raise Fault("messages_receive_invalid_arguments")
        expected = {"session_id"}
        if method != "messages.receive.status": expected.add("scope_id")
        if method == "messages.receive.ack": expected.update({"batch_id", "batch_digest"})
        if set(params) != expected or any(type(value) is not str for value in params.values()):
            raise Fault("messages_receive_invalid_arguments")
        if any(len(value) > 128 for value in params.values()):
            raise Fault("messages_receive_invalid_arguments")
        if binding is None or len(binding) != 2 or not callable(binding[1]):
            raise Fault("app_identity_unverified")
        session_id = params["session_id"]
        if len(session_id) != 64 or any(c not in "0123456789abcdef" for c in session_id):
            raise Fault("app_session_changed")

        def current():
            # Never hold the registry lock during native IO. Revalidate the same
            # immutable entry/session and current policy before and after it.
            if binding[1]() is not True:
                raise Fault("app_identity_unverified")
            with self.registry.lock:
                entry = self.registry.entries.get(app)
                if entry is None or entry.get("registration") != "registered":
                    raise Fault("app_identity_unverified")
                guard = entry.get("active_guard")
                if guard is not None and guard() is not True:
                    raise Fault("app_identity_unverified")
                session = self.registry.live_session(entry)
                current_policy = self.policies.get(app)
                if (session is None or session.get("binding") != binding[0] or
                        not secrets.compare_digest(session_id, session["id"]) or
                        current_policy is not policy or method not in policy.methods or
                        CAPABILITY not in policy.tools or CAPABILITY not in session["tools"]):
                    raise Fault("messages_receive_not_authorized")
                return entry, session

        entry, session = current()

        def recheck():
            latest_entry, latest_session = current()
            if latest_entry is not entry or latest_session is not session:
                raise Fault("app_session_changed")

        consumer = {"app_id": app, "session_id": session_id, "registration_generation": binding[0]}
        native_params = {key: value for key, value in params.items() if key != "session_id"}
        recheck()
        result = self.transport.call(method, native_params, consumer, recheck)
        recheck()
        return result


def _package_file(path, limit, *, private=False):
    path = Path(path).absolute()
    if any(part.is_symlink() for part in (path, *path.parents)):
        raise Fault("messages_receive_package_unverified")
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        info = os.fstat(descriptor)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_nlink != 1 or
                info.st_mode & (0o077 if private else 0o022) or not 0 < info.st_size <= limit):
            raise Fault("messages_receive_package_unverified")
        raw = os.read(descriptor, limit + 1)
        if len(raw) != info.st_size:
            raise Fault("messages_receive_package_unverified")
        return raw
    finally:
        os.close(descriptor)


def build_native_receive_transport(home):
    """Use existing signed bundle/authority; never add an app policy or grant.

    Returns (transport-or-None, fixed diagnostic). A source checkout, public
    zero-grant package or absent authority remains unconfigured.
    """
    try:
        code = Path(__file__).absolute().parents[1]
        app = code.parents[3]
        if app.suffix != ".app" or code != app / "Contents/Resources/CoreRuntime/code":
            return None, "not_packaged"
        info = plistlib.loads(_package_file(app / "Contents/Info.plist", 1024 * 1024))
        if info.get("CFBundleIdentifier") != "local.arl.control":
            raise Fault("messages_receive_parent_unverified")
        manifest_path = code.parent / "manifest.json"
        manifest_raw = _package_file(manifest_path, 1024 * 1024)
        manifest_pin = hashlib.sha256(manifest_raw).hexdigest()
        if manifest_pin != info.get("ARLCoreRuntimeManifestSHA256"):
            raise Fault("messages_receive_package_unverified")
        manifest = strict_json(manifest_raw)
        if (type(manifest) is not dict or manifest.get("schema") != 1 or
                manifest.get("protocol") != "arl/1" or manifest.get("profile") != "local-compatibility" or
                type(manifest.get("files")) is not dict):
            raise Fault("messages_receive_package_unverified")
        helper = code / "build/PeerSignatureHelper"
        helper_pin = manifest["files"].get("code/build/PeerSignatureHelper")
        module_pin = manifest["files"].get("code/arl/messages_receive.py")
        if (not isinstance(helper_pin, str) or not isinstance(module_pin, str) or
                hashlib.sha256(_package_file(helper, 16 * 1024 * 1024)).hexdigest() != helper_pin or
                hashlib.sha256(_package_file(Path(__file__), 1024 * 1024)).hexdigest() != module_pin):
            raise Fault("messages_receive_package_unverified")
        authority_path = app.with_suffix(".authority.json")
        authority_raw = _package_file(authority_path, 32768, private=True)
        authority = strict_json(authority_raw)
        if (type(authority) is not dict or authority.get("schema") not in (1, 2, 3) or
                authority.get("identifier") != "local.arl.control" or authority.get("bundlePath") != str(app) or authority.get("executionAllowed") is not True or
                type(authority.get("designatedRequirement")) is not str or not authority["designatedRequirement"] or
                type(authority.get("executableSHA256")) is not str):
            raise Fault("messages_receive_parent_unverified")
        name = info.get("CFBundleExecutable")
        if type(name) is not str or re.fullmatch(r"[A-Za-z0-9_.-]{1,100}", name) is None:
            raise Fault("messages_receive_parent_unverified")
        executable = app / "Contents/MacOS" / name
        if hashlib.sha256(_package_file(executable, 256 * 1024 * 1024)).hexdigest() != authority["executableSHA256"]:
            raise Fault("messages_receive_parent_unverified")
        parent_pid = os.getppid()
        parent = process_identity(parent_pid)
        if parent["uid"] != os.geteuid() or parent["executable"] != str(executable):
            raise Fault("messages_receive_parent_unverified")
        result = subprocess.run(["/usr/bin/codesign", "--verify", "--strict", "--deep", str(app)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5,
            env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"})
        if result.returncode:
            raise Fault("messages_receive_parent_unverified")
        transport = NativeReceiveTransport(home, parent_pid=parent_pid,
            parent_requirement=authority["designatedRequirement"], peer_helper=helper)
        # Pins are checked on every call as well as at construction. A new
        # bundle or authority must be adopted by a new managed core generation.
        transport.package_current = lambda: (
            _package_file(authority_path, 32768, private=True) == authority_raw and
            hashlib.sha256(_package_file(manifest_path, 1024 * 1024)).hexdigest() == manifest_pin and
            hashlib.sha256(_package_file(helper, 16 * 1024 * 1024)).hexdigest() == helper_pin and
            hashlib.sha256(_package_file(executable, 256 * 1024 * 1024)).hexdigest() == authority["executableSHA256"])
        return transport, "configured"
    except Fault as error:
        return None, error.code
    except (OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError):
        return None, "messages_receive_package_unavailable"
