"""Verify the exact reviewed Mio runtime from an existing full package archive."""
import argparse,json,sys,tempfile,zipfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'script'))
from stage_mio_runtime import verify_runtime,RUNTIME_MODES

def main():
 parser=argparse.ArgumentParser();parser.add_argument('--archive',type=Path,required=True);args=parser.parse_args()
 prefix='package/ARL.app/Contents/Library/LoginItems/ARLMioAppleBridge.app/Contents/Resources/MioRuntime/'
 with tempfile.TemporaryDirectory(prefix='mio-mode-',dir=ROOT/'build/audit') as folder:
  base=Path(folder)
  with zipfile.ZipFile(args.archive) as z:
   for name in [*RUNTIME_MODES,'manifest.json']:
    (base/name).write_bytes(z.read(prefix+name));(base/name).chmod(0o600)
  try:verify_runtime(base);raise AssertionError('bad_modes_accepted')
  except ValueError as e:assert str(e)=='mio_runtime_mode_changed'
  verify_runtime(base,repair_modes=True);verify_runtime(base)
  target=base/'tunnel-client';target.write_bytes(b'unsealed');target.chmod(0o600)
  try:verify_runtime(base,repair_modes=True);raise AssertionError('bad_content_accepted')
  except ValueError as e:assert str(e)=='mio_runtime_resource_changed'
  assert target.stat().st_mode&0o777==0o600
 print(json.dumps({'status':'PASS','exact_sealed_modes_restored':True,'unsealed_file_not_made_executable':True,'runtime_started':False}))
if __name__=='__main__':main()
