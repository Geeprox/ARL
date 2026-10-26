"""Regressions for representation budgets and independent application intents."""
import importlib.util
import json
from pathlib import Path
import time
import unittest
import uuid

from arl.codex_server import Session, PROVIDER_FRAME_BYTES
from arl.contracts import Fault


class PayloadBoundaryTests(unittest.TestCase):
    def receive(self, value):
        session=Session.__new__(Session)
        session.buffer=bytearray(json.dumps(value).encode()+b'\n')
        session.messages=0;session.context=None;session.observer=None;session.deadline=time.monotonic()+5
        return session.receive()

    def test_codex_accepts_equal_decoded_text_despite_double_json_escaping(self):
        for text in ('a'*20000,'"'*20000,'\\'*20000,'中'*6000):
            inner=json.dumps({'text':text})
            result=self.receive({'method':'item/completed','params':{'text':inner}})
            self.assertEqual(json.loads(result['params']['text'])['text'],text)

    def test_codex_still_bounds_the_actual_provider_frame(self):
        with self.assertRaises(Fault):
            self.receive({'text':'a'*(PROVIDER_FRAME_BYTES+1)})

    def contract(self):
        path=Path(__file__).resolve().parents[1]/'integrations/nas_codex_v2_20261024/nas/contract.py'
        spec=importlib.util.spec_from_file_location('review_nas_v2_contract',path)
        module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
        return module

    def test_nas_codex_new_intents_get_new_ids_but_explicit_retry_keeps_one(self):
        contract=self.contract()
        catalog={'published_at':time.time(),'models':[{'id':'fixture-model','reasoning_efforts':['low']}]}
        value={'model':'fixture-model','messages':[{'role':'user','content':'same request'}]*24}
        first=contract.normalize('pdf2zh',value,catalog)
        second=contract.normalize('pdf2zh',value,catalog)
        self.assertNotEqual(first['id'],second['id'])
        self.assertEqual(first['content_sha256'],second['content_sha256'])
        retry=str(uuid.uuid4())
        self.assertEqual(contract.normalize('pdf2zh',value,catalog,request_id=retry)['id'],retry)

    def test_nas_codex_uses_the_declared_input_budget(self):
        contract=self.contract()
        catalog={'published_at':time.time(),'models':[{'id':'fixture-model','reasoning_efforts':['low']}]}
        value={'model':'fixture-model','messages':[{'role':'user','content':'a'*7750}]}
        self.assertEqual(len(contract.normalize('pdf2zh',value,catalog)['messages']),2)

    def test_more_than_128_tiny_messages_follow_total_content_budget(self):
        from arl.contracts import validate
        messages=[{'role':'user','content':''}]*150
        schema={'type':'array','minItems':1,'items':{'type':'object','properties':{'role':{'type':'string'},'content':{'type':'string'}},'required':['role','content']}}
        validate(messages,schema)
        contract=self.contract()
        catalog={'published_at':time.time(),'models':[{'id':'fixture-model','reasoning_efforts':['low']}]}
        self.assertEqual(len(contract.normalize('pdf2zh',{'model':'fixture-model','messages':messages},catalog)['messages']),151)
        with self.assertRaises(Fault):validate(messages,dict(schema,maxItems=10))

    def test_admitted_v2_completion_survives_catalog_refresh_deadline(self):
        import sys
        from types import SimpleNamespace
        from unittest.mock import Mock
        root=Path(__file__).resolve().parents[1]/'integrations/nas_codex_v2_20261024/core'
        for name in ('codex_packages','codex_service_v2'):
            spec=importlib.util.spec_from_file_location('arl.'+name,root/(name+'.py'))
            module=importlib.util.module_from_spec(spec);sys.modules['arl.'+name]=module;spec.loader.exec_module(module)
        service_module=sys.modules['arl.codex_service_v2'];package=sys.modules['arl.codex_packages']
        service=service_module.CodexServiceV2.__new__(service_module.CodexServiceV2)
        messages=[{'role':'user','content':'bounded request'}]
        row={'job_id':'admitted','expires_at':0,'content_sha256':package.digest({'messages':messages}),
             'resolved':{'model':'old-model','reasoning_effort':'low','service_tier':'default'},'output':{'max_bytes':128}}
        service.caller='fixture';service.current=lambda:True;service.gateway=SimpleNamespace(resolution=lambda *_:row)
        service.catalog=[];service.checked_mono=time.monotonic()-120;service.max_output_bytes=32768;service.adapter=Mock()
        args={'schema_version':2,'resolution_id':'a'*64,'messages':messages}
        with self.assertRaises(Fault):service.admit('fixture',service_module.NAME,args)
        admitted,base=service.admit('fixture',service_module.NAME,args,completion=True)
        self.assertEqual(base['model'],'old-model');service.adapter.verify.assert_called_once()
        service.current=lambda:False
        with self.assertRaises(Fault):service.admit('fixture',service_module.NAME,args,completion=True)
