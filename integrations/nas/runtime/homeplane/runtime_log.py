"""ARL private NAS diagnostics adapter; finite metadata only, no payload/logger/HTTP dependency."""
from collections import deque
from contextlib import contextmanager
from functools import wraps
import asyncio
import inspect
import time

ROWS = deque(maxlen=64)
STAGES = frozenset({"nas.start", "nas.configure", "nas.resume", "nas.disable", "nas.owner",
                    "nas.read", "nas.health", "nas.close", "nas.connect"})

@contextmanager
def stage_span(stage, *, upstream="nas", **_):
    if stage not in STAGES or upstream != "nas":
        raise ValueError("unknown_stage")
    started = time.monotonic()
    outcome = "ok"
    try:
        yield
    except asyncio.CancelledError:
        outcome = "cancelled"
        raise
    except BaseException:
        outcome = "failed"
        raise
    finally:
        ROWS.append({"stage": stage, "outcome": outcome, "elapsed_ms": int((time.monotonic()-started)*1000)})

def observe(stage, *, upstream="nas", **_):
    def decorate(call):
        if inspect.iscoroutinefunction(call):
            @wraps(call)
            async def run(*args, **kwargs):
                with stage_span(stage, upstream=upstream):
                    return await call(*args, **kwargs)
        else:
            @wraps(call)
            def run(*args, **kwargs):
                with stage_span(stage, upstream=upstream):
                    return call(*args, **kwargs)
        return run
    return decorate
