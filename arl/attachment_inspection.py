"""One parent-owned stdin request. No state, NAS, logs, URLs in arguments or replay."""
import json
import os
import re
import time

MAX_INPUT = 65536


def run(stream, output, parent_pid, *, inspector=None):
    deadline = time.monotonic()+25
    def verify():
        if type(parent_pid) is not int or parent_pid <= 1 or os.getppid() != parent_pid:
            raise RuntimeError('parent_exited')
        if time.monotonic() >= deadline:
            raise TimeoutError('deadline')
    try:
        verify()
        raw=stream.readline(MAX_INPUT+1)
        if not raw or len(raw)>MAX_INPUT or not raw.endswith(b'\n') or stream.read(1):
            raise ValueError('frame')
        from .wire import strict_json
        value=strict_json(raw)
        if inspector is None:
            from integrations.nas.file_params_importer import inspect_attachment
            inspector=inspect_attachment
        result=inspector(value, verify=verify)
        verify()
        reply={'ok':True,'result':result}
    except Exception as error:
        # Never serialize an exception, header, input or signed URL.
        code=getattr(error,'code',None)
        if not isinstance(code,str) or re.fullmatch(r'attachment_[a-z_]{1,80}|invalid_import_request|verified_caller_required',code) is None:
            code='attachment_inspection_unavailable'
        reply={'ok':False,'error':{'code':code}}
    output.write(json.dumps(reply,sort_keys=True,separators=(',',':')).encode()+b'\n')
    output.flush()
    return 0
