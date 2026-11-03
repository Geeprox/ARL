import importlib.util,json,tempfile,types,unittest
from pathlib import Path
spec=importlib.util.spec_from_file_location('robin_timing',Path(__file__).parents[1]/'nas/robin_timing.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
class TimingTests(unittest.TestCase):
 def test_stage_receipt_preserves_callbacks_and_never_saves_query_content(self):
  with tempfile.TemporaryDirectory() as folder:
   callbacks=[];result=types.SimpleNamespace(status='ok',saved_as='investigation_synthetic.json')
   def original(query,**kwargs):
    for name in ('search','filter','scrape','summarize'):kwargs['on_stage'](name,result)
    return result
   pipeline=types.SimpleNamespace(run_investigation=original);m.configure(pipeline,folder)
   self.assertIs(pipeline.run_investigation('private synthetic secret',on_stage=lambda name,value:callbacks.append(name)),result)
   receipt=json.loads(next(Path(folder).glob('*.json')).read_text())
   self.assertEqual(callbacks,['search','filter','scrape','summarize']);self.assertEqual(receipt['status'],'ok');self.assertNotIn('private synthetic',json.dumps(receipt))
 def test_failure_receipt_keeps_interruption_and_does_not_mask_exception(self):
  with tempfile.TemporaryDirectory() as folder:
   def original(**kwargs):raise RuntimeError('private failure')
   pipeline=types.SimpleNamespace(run_investigation=original);m.configure(pipeline,folder)
   with self.assertRaises(RuntimeError):pipeline.run_investigation()
   receipt=json.loads(next(Path(folder).glob('*.json')).read_text());self.assertEqual(receipt['status'],'interrupted');self.assertNotIn('private failure',json.dumps(receipt))
