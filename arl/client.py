from __future__ import annotations

import json
import os
import random
import socket
import subprocess
import sys
import secrets
import time
from pathlib import Path

from . import PROTOCOL
from .contracts import Fault, encode
from .priority import validate_request, validate_acceptance, validate_profile
from .lifecycle import private_home


class RuntimeLauncher:
    """Trusted SDK composition: executable/module/home fixed at construction.

    RPC never accepts a launch path, shell string, environment or command.
    Launches only ARL, with no OS auto-start registration.
    """
    def __init__(self, home):
        self.home = private_home(home)
        self.children = []

    def __call__(self):
        if (self.home/"disabled").exists():
            raise Fault("user_disabled")
        root = Path(__file__).resolve().parents[1]
        process = subprocess.Popen([sys.executable, "-B", "-m", "arl", "serve", "--home", str(self.home)],
                                   cwd=root, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL, start_new_session=True)
        self.children.append(process)
        return process


class Client:
    def __init__(self, home, app, launcher=None):
        self.home = private_home(home)
        self.app = app
        self.launcher = launcher
        self.app_session = None

    def describe_runtime(self):
        from .runtime_description import validate_description
        return validate_description(self.rpc("runtime.describe"))

    def open_app_session(self, name, capabilities=(), icon_ref="sf:app", version=None):
        nonce = secrets.token_hex(32)
        reply = self.rpc("connection.open", {"client_nonce":nonce,"name":name,"icon_ref":icon_ref,"version":version,"capabilities":list(capabilities)})
        if (type(reply) is not dict or reply.get("protocol") != PROTOCOL or reply.get("schema_version") != 1
                or reply.get("client_nonce") != nonce or not isinstance(reply.get("session_id"), str)
                or not isinstance(reply.get("challenge"), str) or not isinstance(reply.get("accepted_capabilities"), list)
                or not set(reply["accepted_capabilities"]).issubset(capabilities)):
            raise Fault("invalid_response")
        accepted = self.rpc("connection.confirm", {"session_id":reply["session_id"],"challenge":reply["challenge"]})
        if accepted.get("connected") is not True or accepted.get("session_id") != reply["session_id"]:
            raise Fault("invalid_response")
        self.app_session = reply["session_id"]
        return reply["accepted_capabilities"]

    def ping_app_session(self):
        if self.app_session is None: raise Fault("app_session_changed")
        return self.rpc("connection.ping", {"session_id":self.app_session})

    def close_app_session(self):
        if self.app_session is None: return
        self.rpc("connection.close", {"session_id":self.app_session})
        self.app_session = None

    def rpc(self, method, params=None):
        request = {"protocol": PROTOCOL, "app": self.app, "method": method, "params": params or {}}
        payload = encode(request)+b"\n"
        if len(payload) > 16384:
            raise Fault("invalid_frame")
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
                connection.settimeout(5)
                connection.connect(str(self.home/"runtime.sock"))
                connection.sendall(payload)
                with connection.makefile("rb") as stream:
                    raw = stream.readline(131073)
                    if not raw or len(raw) > 131072 or not raw.endswith(b"\n"):
                        raise Fault("disconnected")
                    response = json.loads(raw)
        except OSError:
            raise Fault("disconnected") from None
        except ValueError:
            raise Fault("invalid_response") from None
        if response.get("protocol") != PROTOCOL:
            raise Fault("unsupported_protocol")
        if not response.get("ok"):
            raise Fault(response["error"]["code"])
        return response["result"]

    def connect(self, timeout=10):
        deadline, launched, delay = time.monotonic()+timeout, False, 0.02
        while time.monotonic() < deadline:
            if (self.home/"disabled").exists():
                raise Fault("user_disabled")
            try:
                return self.rpc("ready")
            except Fault as exc:
                if exc.code not in {"disconnected", "not_ready"}:
                    raise
                if exc.code == "disconnected" and not launched and self.launcher:
                    self.launcher()
                    launched = True
            time.sleep(delay+random.uniform(0, delay/4))
            delay = min(delay*1.6, 0.3)
        raise Fault("ready_timeout")

    def submit(self, tool, args, key):
        self.connect()
        try:
            return self.rpc("submit", {"tool": tool, "args": args, "key": key})
        except Fault as exc:
            if exc.code != "disconnected":
                raise
            # Resend exactly the same owner+key+body after reconnect; no new logical job.
            self.connect()
            return self.rpc("submit", {"tool": tool, "args": args, "key": key})

    def negotiate_priority(self, requested_classes=('background',)):
        self.connect()
        result=self.rpc('priority.negotiate.v1',{'requested_profile':{'classes':list(requested_classes)}})
        validate_profile(result)
        return result

    def negotiate_priority_v2(self, requested_classes=('background',)):
        from .priority import validate_profile_v2
        self.connect()
        result=self.rpc('priority.negotiate.v2',{'requested_profile':{'classes':list(requested_classes)}})
        validate_profile_v2(result)
        return result

    @staticmethod
    def priority_request_v2(profile, *, submit_method, tool, task_kind, requested_class,
                            deadline_at_ms, estimate_ms, provider=None, model=None,
                            model_fingerprint=None, allow_interrupt=False,
                            allow_fallback=False, minimum_class=None):
        from .priority import select_binding_v2, CLASSES
        row=select_binding_v2(profile,submit_method=submit_method,tool=tool,task_kind=task_kind,
            provider=provider,model=model,model_fingerprint=model_fingerprint)
        choices=[c for c in row['allowed_classes'] if CLASSES[c]<=CLASSES.get(requested_class,-1)
                 and CLASSES[c]>=CLASSES.get(minimum_class or 'background',99)]
        if not choices or requested_class not in choices and not allow_fallback:
            raise Fault('priority_class_not_authorized')
        request={'profile_id':profile['profile_id'],'policy_epoch':profile['policy_epoch'],
            'task_kind':task_kind,'requested_class':requested_class,'deadline_at_ms':deadline_at_ms,
            'resource_kind':row['resource_kind'],'estimate_ms':estimate_ms,
            'allow_interrupt':allow_interrupt,'allow_fallback':allow_fallback}
        if minimum_class is not None:request['minimum_class']=minimum_class
        validate_request(request)
        return request

    @staticmethod
    def priority_request(profile, *, task_kind, requested_class, deadline_at_ms, resource_kind,
                         estimate_ms, allow_interrupt=False, allow_fallback=False, minimum_class=None):
        validate_profile(profile)
        request={'profile_id':profile['profile_id'],'policy_epoch':profile['policy_epoch'],
            'task_kind':task_kind,'requested_class':requested_class,'deadline_at_ms':deadline_at_ms,
            'resource_kind':resource_kind,'estimate_ms':estimate_ms,'allow_interrupt':allow_interrupt,
            'allow_fallback':allow_fallback}
        if minimum_class is not None:request['minimum_class']=minimum_class
        validate_request(request)
        return request

    def submit_priority(self,tool,args,key,scheduling):
        # A possibly accepted model/effect submission is sent once. A lost reply
        # requires the caller's explicit status/reconciliation path, never replay.
        validate_request(scheduling)
        self.connect()
        result=self.rpc('priority.submit.v1',{'tool':tool,'args':args,'key':key,'scheduling':scheduling})
        validate_acceptance(scheduling,result.get('scheduling'))
        return result

    def wait(self, job, timeout=10):
        deadline = time.monotonic()+timeout
        while time.monotonic() < deadline:
            try:
                result = self.rpc("get", {"id": job})
            except Fault as exc:
                if exc.code != "disconnected":
                    raise
                self.connect(timeout=max(0.1, deadline-time.monotonic()))
                continue
            if result["state"] in {"succeeded", "failed", "cancelled", "needs_review", "needs_unlock"}:
                return result
            time.sleep(0.02)
        raise Fault("job_timeout")

    def wake(self, target):
        self.connect()
        return self.rpc("wake", {"target": target})

    def poll_wakes(self, callback=None):
        self.connect()
        events = self.rpc("poll_wakes")
        if callback:
            for event in events:
                callback(event)
        return events
