"""Bounded model/list projection. No inference, config writes or guessed tiers."""
from .contracts import Fault
import re
import time

def identifier(value, maximum=150):
 if type(value) is not str or len(value)>maximum or re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._/-]*',value) is None:
  raise Fault('provider_catalog_invalid')
 return value

def text(value, maximum):
 if type(value) is not str:raise Fault('provider_catalog_invalid')
 return value.encode('utf-8')[:maximum].decode('utf-8', errors='ignore')

def read_catalog(session):
 rows=[];cursor=None;seen=set();deadline=time.monotonic()+60
 while True:
  if time.monotonic()>=deadline:raise Fault('provider_catalog_deadline')
  page=session.response(session.send('model/list',{'limit':20,'includeHidden':False,**({'cursor':cursor} if cursor else {})}))
  if type(page.get('data')) is not list:raise Fault('provider_catalog_invalid')
  for row in page['data']:
   if type(row) is not dict:raise Fault('provider_catalog_invalid')
   modalities=row.get('inputModalities',['text','image'])
   if type(modalities) is not list or any(type(v) is not str for v in modalities):raise Fault('provider_catalog_invalid')
   if row.get('hidden') is True or 'text' not in modalities:continue
   model=identifier(row.get('model'))
   if any(m['model']==model for m in rows):raise Fault('provider_catalog_invalid')
   efforts=row.get('supportedReasoningEfforts')
   if type(efforts) is not list or not efforts:raise Fault('provider_catalog_invalid')
   if any(type(e) is not dict for e in efforts):raise Fault('provider_catalog_invalid')
   efforts=[{'id':identifier(e.get('reasoningEffort'),40),'description':text(e.get('description',''),1024)} for e in efforts if type(e) is dict]
   default=identifier(row.get('defaultReasoningEffort'),40)
   if default not in [e['id'] for e in efforts] or len({e['id'] for e in efforts})!=len(efforts):raise Fault('provider_catalog_invalid')
   # Fast is a catalog service tier. Never reinterpret API priority as Fast.
   tiers=row.get('serviceTiers',[])
   if type(tiers) is not list:raise Fault('provider_catalog_invalid')
   fast=next((t for t in tiers if type(t) is dict and t.get('id')=='fast'),None)
   legacy=row.get('additionalSpeedTiers',[])
   if type(legacy) is not list:raise Fault('provider_catalog_invalid')
   available=fast is not None or 'fast' in legacy
   rows.append({'model':model,'display_name':text(row.get('displayName',model),200),
    'description':text(row.get('description',''),2048),'default_effort':default,'efforts':efforts,
    'fast_available':available,'fast_description':text(fast.get('description','') if fast else '',2048)})
  cursor=page.get('nextCursor')
  if cursor is None:return rows
  if type(cursor) is not str or not cursor or len(cursor)>2048 or cursor in seen:raise Fault('provider_catalog_invalid')
  seen.add(cursor)
 raise Fault('provider_catalog_invalid')

def selection(catalog, model, effort, tier):
 row=next((m for m in catalog if m['model']==model),None)
 if row is None:raise Fault('provider_model_change_not_authorized')
 if effort not in [e['id'] for e in row['efforts']]:raise Fault('provider_effort_unavailable')
 if tier not in {'default','fast'} or tier=='fast' and not row['fast_available']:raise Fault('provider_service_tier_unavailable')
 return row
