"""One bounded local failure record. Never retain exception text or credentials."""
import errno
import json
import os
from pathlib import Path
import pwd
import re
import time

def failure_record(error, stage):
    if stage not in {'server_login','share_list','directory_list'}:return
    chain=[]; current=error; seen=set()
    for _ in range(8):
        if current is None or id(current) in seen:break
        seen.add(id(current))
        name=type(current).__name__
        row={'type':name if re.fullmatch('[A-Za-z_]{1,80}',name) else 'Error'}
        status=getattr(current,'status',None)
        if type(status) is int and 0 <= status <= 0xffffffff:row['smb_status']=status
        number=getattr(current,'errno',None)
        if type(number) is int and 0 <= number <= 0x7fffffff:
            row['errno']=number
            row['errno_name']=errno.errorcode.get(number,'UNKNOWN')
        # Code locations only: never format the exception, source line, locals,
        # request, endpoint, credential envelope or absolute filesystem path.
        frames=[]; tb=current.__traceback__
        while tb is not None:
            code=tb.tb_frame.f_code
            module=tb.tb_frame.f_globals.get('__name__','unknown')
            function=code.co_name
            frames.append({'module':module if type(module) is str and re.fullmatch(r'[A-Za-z_][A-Za-z0-9_.]{0,159}',module) else 'unknown',
                'function':function if re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]{0,79}',function) else 'frame',
                'line':tb.tb_lineno})
            tb=tb.tb_next
        row['frames']=frames[-12:]
        if len(frames)>12:row['frames_truncated']=True
        chain.append(row)
        cause=current.__cause__
        if cause is not None:current=cause
        elif not current.__suppress_context__:current=current.__context__
        else:current=None
    record={'schema':1,'at':int(time.time()),'stage':stage,'exception_chain':chain}
    # HOME belongs to the disposable credential pipe. Use only this fixed,
    # existing user-owned ARL diagnostics folder, not a caller-supplied path.
    root=Path(pwd.getpwuid(os.getuid()).pw_dir)/'Library/Application Support/ARL/nas'
    try:
        if root.is_symlink() or not root.is_dir() or root.stat().st_uid != os.getuid():return
        path=root/'login-diagnostic.json'
        fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_NOFOLLOW,0o600)
        with os.fdopen(fd,'wb') as stream:
            info=os.fstat(stream.fileno())
            if info.st_uid != os.getuid() or info.st_nlink != 1:return
            os.fchmod(stream.fileno(),0o600);stream.truncate(0)
            stream.write(json.dumps(record,separators=(',',':')).encode())
    except OSError:pass
