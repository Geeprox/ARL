from __future__ import annotations

import hashlib
import json
import shutil
import subprocess
import sys
import time
from pathlib import Path
import urllib.error
import urllib.request

from .contracts import Context, Fault, encode


def _blocking_local_json(url, body=None, timeout=1):
    # Fixed loopback URLs only, no environment proxies or credentials.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    request = urllib.request.Request(url, data=encode(body) if body is not None else None,
                                     headers={"Content-Type": "application/json"})
    try:
        with opener.open(request, timeout=timeout) as response:
            raw = response.read(65537)
            if len(raw) > 65536:
                raise Fault("provider_response_too_large")
            return json.loads(raw)
    except Fault:
        raise
    except (OSError, ValueError, urllib.error.URLError):
        raise Fault("provider_unavailable") from None


def local_json(url, body=None, timeout=1):
    """Wall-clock deadline via a killable, short-lived HTTP worker.

    A socket inactivity timeout alone does not bound slow-drip headers/bodies.
    The worker only talks to fixed loopback HTTP, never loads models itself.
    """
    if timeout <= 0:
        raise Fault("provider_deadline_exceeded")
    deadline = time.monotonic()+timeout
    process = subprocess.Popen([sys.executable, "-B", "-m", "arl.http_worker"],
        cwd=Path(__file__).resolve().parents[1], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL)
    try:
        stdout, _ = process.communicate(encode({"url": url, "body": body, "timeout": timeout}),
                                       timeout=max(0.001, deadline-time.monotonic()))
    except subprocess.TimeoutExpired:
        process.kill()
        process.communicate()
        raise Fault("provider_deadline_exceeded") from None
    if process.returncode != 0 or len(stdout) > 131072:
        raise Fault("provider_unavailable")
    try:
        result = json.loads(stdout)
        if result.get("ok") is not True:
            raise Fault(result.get("error", "provider_unavailable"))
        return result["result"]
    except (ValueError, TypeError, KeyError):
        raise Fault("invalid_provider_response") from None


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise Fault("provider_redirect_rejected")


class MockProvider:
    name, paid = "mock", False

    def discover(self):
        return {"name": self.name, "availability": "ready", "models": ["deterministic-v1"],
                "paid": False, "evidence": "test_double"}

    def complete(self, args, context):
        context.check_cancelled()
        return {"provider": self.name, "model": args["model"],
                "text": "mock:"+hashlib.sha256(args["prompt"].encode()).hexdigest()[:16],
                "usage": {"output_tokens": 8}, "simulated": True}


class OllamaProvider:
    name, paid = "ollama", False
    base = "http://127.0.0.1:11434"

    def _installed_models(self):
        # The HTTP worker already bounds the complete response to 64KiB.
        # A bounded settings preview is not an authoritative absence check.
        data = local_json(self.base+"/api/tags")
        try:
            return [m["name"] for m in data["models"] if type(m.get("name")) is str]
        except (KeyError, TypeError, AttributeError):
            raise Fault("invalid_provider_response") from None

    def discover(self):
        try:
            models = self._installed_models()[:100]
            return {"name": self.name, "availability": "ready", "models": models,
                    "paid": False, "evidence": "local_http", "loads_on_call": True}
        except (Fault, KeyError, TypeError, AttributeError):
            return {"name": self.name, "availability": "unavailable", "models": [], "paid": False}

    def complete(self, args, context):
        # /api/generate never downloads missing weights. No pull endpoint exists in ARL.
        if args["model"] not in self._installed_models():
            raise Fault("model_not_installed")
        context.check_cancelled()
        result = local_json(self.base+"/api/generate", {
            "model": args["model"], "prompt": args["prompt"], "stream": False,
            "keep_alive": 0, "options": {"num_predict": args["max_tokens"], "num_ctx": 2048}}, timeout=30)
        context.check_cancelled()
        if type(result.get("response")) is not str:
            raise Fault("invalid_provider_response")
        # Return the complete already-bounded response. A success must not
        # silently drop the answer tail; HTTP/frame/token budgets stay unchanged.
        return {"provider": self.name, "model": args["model"], "text": result["response"],
                "usage": {"output_tokens": result.get("eval_count")}, "simulated": False}


class DisabledProvider:
    paid = True

    def __init__(self, name):
        self.name = name

    def discover(self):
        return {"name": self.name, "availability": "disabled", "paid": True,
                "installed": bool(shutil.which("codex")) if self.name == "codex_app_server" else None,
                "reason": "Scoped cloud adapter approval and budget accounting required"}

    def complete(self, args, context):
        raise Fault("paid_provider_disabled")


class Router:
    def __init__(self, policies, local_enabled=False, providers=None):
        self.policies = policies
        self.local_enabled = local_enabled
        self.providers = providers if providers is not None else {p.name: p for p in [MockProvider(), OllamaProvider(),
                                                         DisabledProvider("codex_app_server"), DisabledProvider("jev")]}

    def check(self, owner, args):
        provider = self.providers.get(args["provider"])
        if not provider:
            raise Fault("unknown_provider")
        if provider.paid:
            raise Fault("paid_provider_disabled")
        if args["provider"] not in self.policies[owner].providers:
            raise Fault("provider_not_authorized")
        if args["provider"] != "mock" and not self.local_enabled:
            raise Fault("local_inference_disabled")
        if args["max_tokens"] > self.policies[owner].max_tokens or len(args["prompt"].encode()) > 1024:
            raise Fault("model_budget_exceeded")
        if args["provider"] == "mock" and args["model"] != "deterministic-v1":
            raise Fault("unknown_model")

    def complete(self, owner, args, context):
        self.check(owner, args)
        return self.providers[args["provider"]].complete(args, context)

    def discover(self):
        return [provider.discover() for provider in self.providers.values()]
