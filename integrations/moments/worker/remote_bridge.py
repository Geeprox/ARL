"""Offline command inbox owned by signed ARL. No network, credentials or URLs."""
import datetime as dt
import re
from pathlib import Path
from moments_backup import atomic_json,load_json,now
ID=re.compile(r'[a-f0-9-]{36}\Z')
ASSET=re.compile(r'[A-Za-z0-9:_-]{1,200}\Z')
class Bridge:
    def __init__(self,home,service):
        self.home=Path(home);self.service=service;self.pending=[]
        for name in ('requests','responses'):(self.home/name).mkdir(mode=0o700,parents=True,exist_ok=True)
    def poll(self):
        for p in sorted((self.home/'requests').glob('*.json'))[:32]:
            if not ID.fullmatch(p.stem) or p.is_symlink() or p.stat().st_size>8192:continue
            reply=self.home/'responses'/p.name
            if reply.exists():p.unlink();continue
            request=load_json(p,{})
            try:
                age=dt.datetime.now(dt.timezone.utc).timestamp()-dt.datetime.fromisoformat(request['created_at'].replace('Z','+00:00')).timestamp()
                if request.get('id')!=p.stem or not -30<=age<=600:raise ValueError()
                if request.get('kind')=='refresh':
                    self.pending.append(p.stem);self.service.manual_refresh=True;p.unlink();continue
                ids=request.get('asset_ids')
                if request.get('kind')!='images' or not isinstance(ids,list) or not 1<=len(ids)<=20 or any(not isinstance(x,str) or not ASSET.fullmatch(x) for x in ids):raise ValueError()
                result=self.service.queue.submit(ids,priority=True)
                result={'accepted':result.get('accepted',[]),'rejected':result.get('rejected',[])}
            except (ValueError,KeyError,TypeError):result={'error_code':'invalid_request'}
            atomic_json(reply,{'schema':1,'id':p.stem,'at':now(),**result});p.unlink()
    def complete(self,report=None,error=None):
        for identity in self.pending:
            value={'schema':1,'id':identity,'at':now(),'status':'refreshed' if report else 'failed'}
            if report:value.update(posts=report['posts_after'],new_posts=report['new_posts'],latest_post_at=report['latest_post_at'])
            if error:value['error_code']=error
            atomic_json(self.home/'responses'/(identity+'.json'),value)
        self.pending.clear()
    def publish(self):
        q=self.service.queue.snapshot()
        # Queue snapshot contains public asset IDs/statuses/local content hashes only.
        q.update(schema=1,checked_at=now(),posts=self.service.status.get('posts',0),latest_post_at=self.service.status.get('latest_post_at'),last_success_at=self.service.status.get('last_success_at'),collecting=not self.service.collection_blocked(),refresh_scope='mac_local_cache',refreshing=bool(self.pending))
        atomic_json(self.home/'bridge-status.json',q)
