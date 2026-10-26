"""Private fixed-destination I/O worker. No tools, files, redirects, proxy or retries."""
import json
import sys
import urllib.error
import urllib.request

URL='https://api.openai.com/v1/responses'
class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self,*args,**kwargs):return None

def main():
    try:
        line=sys.stdin.buffer.readline(8193)
        if len(line)>8192 or not line.endswith(b'\n'):raise ValueError()
        meta=json.loads(line)
        if type(meta) is not dict or set(meta)!={'key','timeout'}:raise ValueError()
        key=meta['key'];timeout=meta['timeout']
        if type(key) is not str or not 1<=len(key)<=4096 or not key.isascii() or any(ord(c)<33 or ord(c)>126 for c in key):raise ValueError()
        if type(timeout) not in (int,float) or not 0<timeout<=60:raise ValueError()
        raw=sys.stdin.buffer.read(524289)
        if not 1<=len(raw)<=524288:raise ValueError()
        request=urllib.request.Request(URL,data=raw,method='POST',headers={'Content-Type':'application/json','Authorization':'Bearer '+key})
        opener=urllib.request.build_opener(urllib.request.ProxyHandler({}),NoRedirect())
        with opener.open(request,timeout=timeout) as response:
            if response.status!=200:raise ValueError()
            content_type=response.headers.get('Content-Type','').split(';',1)[0].strip().lower()
            if content_type!='application/json':raise ValueError()
            result=response.read(1048577)
            if not 1<=len(result)<=1048576:
                sys.stdout.buffer.write(b'Eresult_too_large');return
        sys.stdout.buffer.write(b'S'+result)
    except urllib.error.HTTPError:
        sys.stdout.buffer.write(b'Eprovider_rejected')  # Never return upstream body or headers.
    except Exception:
        sys.stdout.buffer.write(b'Eprovider_unavailable')
if __name__=='__main__':main()
