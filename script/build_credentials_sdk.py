"""Compile frozen credential SDK sources locally; no authority, Security or HTTP calls."""
from pathlib import Path
import subprocess,json,hashlib
R=Path(__file__).resolve().parents[1];owner=R/'integrations/credentials_login';out=R/'build/credential-sdk';out.mkdir(parents=True,exist_ok=True)
# A direct helper invocation must not inherit credential, Node, linker, or HOME settings.
for name in ('Home','tmp','ModuleCache'):(out/name).mkdir(mode=0o700,exist_ok=True)
ENV={'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','HOME':str(out/'Home'),'LANG':'C','LC_ALL':'C',
     'TMPDIR':str(out/'tmp'),'DEVELOPER_DIR':'/Applications/Xcode.app/Contents/Developer',
     'CLANG_MODULE_CACHE_PATH':str(out/'ModuleCache'),'SWIFT_MODULE_CACHE_PATH':str(out/'ModuleCache')}
def run(command):
 return subprocess.run(command,check=True,env=ENV,cwd=R)
sources=sorted((owner/'Module/Sources').rglob('*'))+sorted((owner/'Services').glob('*.swift'))+sorted((owner/'Views').glob('*.swift'))
source_hashes={str(p.relative_to(R)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources if p.is_file()}
manifest=out/'manifest.json'
if manifest.exists():
 old=json.loads(manifest.read_text())
 if old.get('build_version')==3 and old['source_hashes']==source_hashes and all((out/k).exists() and hashlib.sha256((out/k).read_bytes()).hexdigest()==v for k,v in old['artifacts'].items()):
  print('credential SDK source/hash cache verified; authority disabled');raise SystemExit(0)
module=out/'FlyAICompression';module.mkdir(exist_ok=True)
(module/'module.modulemap').write_text('module FlyAICompression { header "'+str(owner/'Module/Sources/FlyAICompression/include/FlyAICompression.h')+'" export * }\n')
run(['/usr/bin/clang','-target','arm64-apple-macos14.0','-c',str(owner/'Module/Sources/FlyAICompression/FlyAICompression.c'),'-I',str(owner/'Module/Sources/FlyAICompression/include'),'-o',str(out/'FlyAICompression.o')])
base=['/usr/bin/swiftc','-swift-version','6','-Xfrontend','-disable-sandbox','-target','arm64-apple-macos14.0','-module-cache-path',str(out/'ModuleCache'),'-parse-as-library','-whole-module-optimization','-emit-module','-emit-object','-I',str(out),'-Xcc','-fmodule-map-file='+str(module/'module.modulemap')]
for name,files in [('ARLCredentialOnboarding',sorted((owner/'Module/Sources/ARLCredentialOnboarding').glob('*.swift'))),('ARLCredentialHostCore',sorted((owner/'Services').glob('*.swift'))+sorted((owner/'Views').glob('*.swift')))]:
 run(base+['-module-name',name,'-emit-module-path',str(out/(name+'.swiftmodule')),*map(str,files),'-o',str(out/(name+'.o'))])
run(['/usr/bin/ar','rcs',str(out/'libARLCredentialHostCore.a'),str(out/'ARLCredentialOnboarding.o'),str(out/'ARLCredentialHostCore.o'),str(out/'FlyAICompression.o')])
artifacts={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in out.iterdir() if p.is_file() and p.suffix in {'.a','.o','.swiftmodule','.swiftdoc'}}
manifest.write_text(json.dumps({'build_version':3,'source_hashes':source_hashes,'artifacts':artifacts,'native_access':0,'environment_keys':sorted(ENV),'environment_inherited':False},indent=2)+'\n');print('credential SDK compiled from frozen source; authority disabled')
