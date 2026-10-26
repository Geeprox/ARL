"""Consume the REAL existing Friday homeplane.arl; no parallel adapter or transport.

    Runs only when the foreground host opens the gate; uses temporary ARL home.
    No app settings, HA credentials, device APIs or real models are accessed.
"""
import asyncio
import json
import sys
import time
from pathlib import Path

from homeplane.arl import ARLRuntime


async def check(home):
    runtime = ARLRuntime(lambda: home)
    status = await runtime.status(timeout=5)
    assert status["ready"], status["status"]
    assert status["protocol"] == "arl/1"
    ping = await runtime.smoke()
    args = {"provider": "mock", "model": "deterministic-v1", "prompt": "synthetic Friday", "max_tokens": 8}
    first = await runtime.run_job("model.complete", args, deadline=time.monotonic()+3, key="reviewed-friday-smoke")
    second = await runtime.run_job("model.complete", args, deadline=time.monotonic()+3, key="reviewed-friday-smoke")
    assert first["id"] == second["id"] and second["result"]["simulated"]
    return {"app": "friday", "existing_adapter": True, "protocol": "arl/1", "ping": ping["status"],
            "deduplicated": True, "real_inference": False, "device_actions": False}


if __name__ == "__main__":
    print("prepared", flush=True)
    if sys.stdin.readline().strip() != "go":
        raise SystemExit(1)
    print(json.dumps(asyncio.run(check(Path(sys.argv[1])))), flush=True)
