"""Disabled-by-default fixed OpenAI Responses transport, never a Codex conversion."""
import os
import subprocess
import sys
from pathlib import Path

from .contracts import Fault, encode
from .research import FORMATS, request_body, response_body


class ResponsesAdapter:
    formats = FORMATS
    token_hard_cap = True  # API max_output_tokens, including reasoning; not a dollar cap.
    evidence = 'implementation_only'  # No real credential/network/paid acceptance yet.

    def __init__(self, model_fingerprints, credential_loader=None, *, enabled=False):
        self.model_fingerprints = dict(model_fingerprints)
        self.credential_loader = credential_loader
        self.enabled = enabled

    def complete(self, raw, args, context):
        if not self.enabled or self.credential_loader is None: raise Fault('provider_unavailable')
        request_body(raw, args)
        if self.model_fingerprints.get(args['model']) != args['model_fingerprint']:
            raise Fault('unsupported_research_provider')
        context.check_cancelled()
        key = self.credential_loader()  # Host-only opaque-reference resolver; no RPC key or path.
        if type(key) is not str or not 1 <= len(key) <= 4096 or not key.isascii() or any(ord(c)<33 or ord(c)>126 for c in key):
            raise Fault('provider_unavailable')
        timeout = context.remaining(60)
        metadata = encode({'key':key, 'timeout':timeout})+b'\n'
        # Payload is original bytes after one bounded control line, never JSON re-encoded.
        process = subprocess.Popen([sys.executable,'-B','-m','arl.responses_worker'],
            cwd=Path(__file__).resolve().parents[1], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, env={'PATH':'/usr/bin:/bin','PYTHONDONTWRITEBYTECODE':'1'})
        try:
            pending = metadata+raw
            while True:
                context.check_cancelled()
                try:
                    output,_=process.communicate(input=pending,timeout=min(.05,context.remaining(60)))
                    break
                except subprocess.TimeoutExpired:
                    pending=None
            if process.returncode != 0 or not output or len(output)>1048577:
                raise Fault('provider_unavailable')
            if output[:1]!=b'S':
                code=output[1:].decode('ascii',errors='ignore')
                raise Fault(code if code in {'provider_unavailable','provider_rejected','result_too_large'} else 'provider_unavailable')
            reply=output[1:]
            context.check_cancelled()
            response_body(reply,args)
            return reply
        finally:
            # Cancellation can stop local I/O; upstream completion/billing remains unknown.
            if process.poll() is None:
                process.terminate()
                try:process.wait(timeout=.5)
                except subprocess.TimeoutExpired:process.kill();process.wait(timeout=.5)
            for stream in (process.stdin,process.stdout):
                if stream is not None:stream.close()
