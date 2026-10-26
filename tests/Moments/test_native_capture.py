import importlib.util,json,sys,tempfile,unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'integrations/moments/worker'))
import local_service
class NativeCaptureTests(unittest.TestCase):
    def test_refresh_uses_immutable_native_copy(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d); manifest=root/'capture.json';manifest.write_text(json.dumps({'schema':1,'fingerprint':'abc','sns_db':str(root/'generation/sns.db'),'contact_db':str(root/'generation/contact.db')}))
            config={'native_capture_manifest':str(manifest),'native_capture_lock':str(root/'capture.lock'),'sns_db':'native-capture-only','keys_file':str(root/'private-keys'),'output':str(root/'data')}
            result=type('Result',(),{'stdout':'{"status":"ok"}','stderr':'','returncode':0})()
            with patch('local_service.subprocess.run',return_value=result) as call:
                self.assertEqual(local_service.source_fingerprint(config),'abc')
                self.assertEqual(local_service.run_refresh(config),{'status':'ok'})
                args=call.call_args.args[0]
                self.assertEqual(args[args.index('--sns-db')+1],str(root/'generation/sns.db'))
                self.assertEqual(args[args.index('--contact-db')+1],str(root/'generation/contact.db'))
                self.assertNotIn('native-capture-only',args)
    def test_unpublished_capture_never_reads_live_source(self):
        with tempfile.TemporaryDirectory() as d:
            config={'native_capture_manifest':str(Path(d)/'missing'),'native_capture_lock':str(Path(d)/'lock'),'sns_db':'/must/not/read/live.db'}
            with patch('local_service.subprocess.run') as run:
                with self.assertRaises(FileNotFoundError):local_service.source_fingerprint(config)
                with self.assertRaisesRegex(RuntimeError,'native_capture_not_ready'):local_service.run_refresh(config)
                run.assert_not_called()
if __name__=='__main__':unittest.main()
