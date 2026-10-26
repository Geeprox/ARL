"""Public same-UID settings metadata. No object IDs, payloads or host paths."""
import re

from . import PROTOCOL, VERSION


def label(value):
    # Model IDs may have a vendor/name component, but never an absolute path,
    # traversal, whitespace, exception body, URL or environment value.
    return (type(value) is str and len(value) <= 200 and
            re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.:/-]*", value) is not None and
            ".." not in value and "://" not in value)


def overview(runtime):
    providers = []
    for discovered in runtime.router.discover()[:100]:
        name = discovered.get("name")
        if not label(name):
            continue
        availability = discovered.get("availability")
        providers.append({"name": name,
            "availability": availability if availability in {"ready", "unavailable", "not_ready", "disabled"} else "unknown",
            "models": [m for m in discovered.get("models", []) if label(m)][:100],
            "paid": discovered.get("paid") is True,
            "inference_policy": "disabled" if discovered.get("paid") or
                (name != "mock" and not runtime.local_enabled) else "explicit_route_only",
            "allowed_apps": sorted(app for app, policy in runtime.policies.items()
                if label(app) and name in policy.providers and "model.complete" in policy.tools)})

    if getattr(runtime, 'codex_service', None) is not None:
        providers = [p for p in providers if p["name"] != "codex_app_server"]
        providers.append(runtime.codex_service.provider_overview())
    capabilities = []
    for tool in list(runtime.tools.values())[:100]:
        if not label(tool.name):
            continue
        availability = tool.availability
        capabilities.append({"name": tool.name,
            "availability": availability if availability in {"ready", "needs_permission", "adapter", "disabled", "unavailable", "not_configured"} else "unknown",
            "identity_gate": "verified_peer_required" if tool.requires_identity else "none",
            # Adapter presence never asserts real OS permission or lock state.
            "authorization_gate": "permission_required" if availability == "needs_permission" else
                "authorization_not_checked" if tool.requires_identity else "not_required"})
    states = ("queued", "running", "succeeded", "failed", "cancelled", "needs_unlock", "needs_review")
    return {"schema_version": 1, "protocol": PROTOCOL, "version": VERSION,
        "health": {"live": not runtime.stopping.is_set(), "ready": runtime.ready.is_set(), "ui_required": False},
        "queue": {"available": runtime.store is not None,
                  "counts": runtime.store.state_counts() if runtime.store else dict.fromkeys(states, 0)},
        "providers": providers, "capabilities": capabilities,
        "policy": {"local_inference_enabled": runtime.local_enabled, "paid_inference_enabled": False,
                   "automatic_fallback": False, "model_downloads": False,
                   "identity_verifier_configured": runtime.identity_verifier is not None},
        "budgets": [{"app": app, "max_pending": p.max_pending, "max_calls": p.max_calls,
                     "max_output_tokens": p.max_tokens, "max_prompt_utf8_bytes": 1024}
                    for app, p in sorted(runtime.policies.items()) if label(app)]}
