#!/usr/bin/env python3
"""Create a reviewable source snapshot without local state or Git ancestry.

Never mutates the source checkout, pushes, changes visibility or rewrites history.
Historical deployment/evidence material stays private in the original checkout.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT))
from script.privacy_audit import scan,write_report

OMIT_PREFIXES=(
 '.codex/','deployment/','docs/evidence/','vendor/release/',
 'integrations/calendar_background_candidate/','integrations/calendar_setup_diagnostic/',
 'integrations/mio_nonce_candidate/','integrations/mio_apple_deployment/',
 'integrations/apple_calendar/superseded-','integrations/apple_notes/superseded-',
 'integrations/apple_reminders/superseded-','integrations/tisra/capture-inner-v1/',
 'integrations/codex/schema-current/',
)
OMIT_FILES={
 'integrations/calendar_native_setup/source/StartupDiagnostics.swift',
 'integrations/apple_calendar/calendar-package.json','integrations/apple_calendar/calendar-release.json',
 'integrations/apple_reminders/reminders-package.json','integrations/apple_reminders/reminders-release.json',
 'integrations/friday/planning-v3-proposal.json','integrations/friday/planning-v4-proposal.json',
 'integrations/tisra/capture-inner-frozen-v1.json',
 'SOURCE-PROVENANCE.json','SOURCE-VERIFICATION.md','script/build_future_control.py',
 'integrations/apple_calendar/package.py','integrations/apple_reminders/package.py',
 'integrations/notes_permission_v2/prepare_permission_candidate.py',
 'integrations/notes_permission_v2/verify_closure.py',
 'integrations/notes_permission_v2/source/scripts/build_host.py',
 'integrations/mio_weather/deploy_approved_weather.py',
 'integrations/mio_weather/server.before.py','integrations/mio_weather/server.production-backup.py',
 'integrations/mio_weather/server.weather.py','vendor/nas/CACHE.json',
 'macOS/ARLControl/Resources/BrandAssets/amap.ico',
}
HISTORICAL=re.compile(r'(?i)(?:handoff|evidence|verification|approval|provenance|baseline|source-manifest|source-ownership|checkpoint|build-inputs|key-repair|upstream-pins|superseded|deployment-|update-plan|milestone|installed|source-reconciliation|copy-update)')
SOURCE={'.py','.swift','.c','.h','.cjs','.mjs','.sh','.plist','.entitlements','.toml','.json','.md','.txt','.html','.css','.js','.svg','.yaml','.yml','.patch','.modulemap'}
DOCS_WITH_PRIVATE_CONTEXT={'docs/FRIDAY-PLANNING-HANDOFF.md','docs/TAOBAO-INSTALLED-VERIFICATION.md','docs/product/MOMENTS-LOCAL-ARCHIVE.md'}
PUBLIC_SOURCE_RECORDS={'macOS/ARLControl/Resources/AppIcon/provenance.json'}

def selected(name):
 p=Path(name)
 if name in OMIT_FILES or name in DOCS_WITH_PRIVATE_CONTEXT or name.startswith(OMIT_PREFIXES):return False
 if any(part in {'__pycache__','node_modules','dist','module-cache'} or part.endswith('.app') for part in p.parts):return False
 if p.suffix in {'.json','.md'} and HISTORICAL.search(p.name) and name not in PUBLIC_SOURCE_RECORDS|{'OPEN-SOURCE-REVIEW.md'}:return False
 return p.suffix in SOURCE or p.name in {'.gitignore','LICENSE','LICENSE.proposed','NOTICE','build.sh','Build.command'} or name.startswith('macOS/ARLControl/Resources/AppIcon/') and p.suffix in {'.png','.icns'}

def export(output):
 output=output.resolve()
 if (ROOT/'build').resolve() not in output.parents or output.exists():raise ValueError('new_build_output_required')
 names=sorted(set(n for n in subprocess.check_output(['git','ls-files','-z','--cached','--others','--exclude-standard'],cwd=ROOT).decode().split('\0') if n))
 output.mkdir(parents=True)
 omitted=[];inventory={};pending=[]
 try:
  for name in names:
   src=ROOT/name
   if not selected(name):omitted.append(name);continue
   if src.is_symlink() or not src.is_file():raise ValueError('source_file_boundary:'+name)
   raw=src.read_bytes();types=scan(raw,name)
   # Documentation can describe a private deployment; never export it by accident.
   if src.suffix=='.md' and set(types)-{'private_app_reference'}:
    omitted.append(name);continue
   target=output/name;target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(src,target)
   target.chmod(0o755 if src.stat().st_mode & 0o111 else 0o644)
   inventory[name]=hashlib.sha256(raw).hexdigest()
   if types:pending.append({'path':name,'sha256':inventory[name],'types':types})
  # Missing a production input is a failed export, not a partial public product.
  recipe=json.loads((ROOT/'script/release_recipe.json').read_text())
  required={n for group in recipe['source_groups'].values() for n in group}
  missing=sorted(required-set(inventory))
  if missing:raise ValueError('production_source_missing:'+','.join(missing))
  manifest={'schema':1,'profile':'full-source-no-history','git_history_included':False,
   'production_source_inputs':len(required),'files':inventory,'omitted_private_or_generated_files':omitted,
   'pending_private_review':pending,'publish_ready':False}
  (output/'PUBLIC-SOURCE-MANIFEST.json').write_text(json.dumps(manifest,indent=2)+'\n')
  write_report(ROOT/'build/public-source-export-private.json',manifest)
  # The public manifest carries only source hashes, never names of omitted private files.
  public={k:v for k,v in manifest.items() if k not in {'omitted_private_or_generated_files','pending_private_review'}}
  (output/'PUBLIC-SOURCE-MANIFEST.json').write_text(json.dumps(public,indent=2)+'\n')
  return {'files':len(inventory),'omitted':len(omitted),'pending_review_files':len(pending),'publish_ready':False}
 except Exception:
  shutil.rmtree(output);raise

def main():
 parser=argparse.ArgumentParser();parser.add_argument('--output',type=Path,required=True);args=parser.parse_args()
 print(json.dumps(export(args.output)))
if __name__=='__main__':main()
