"""Compile-only fixed overlay; never launch, sign, install or change a service."""
import hashlib,json,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parent;CORE=ROOT.parents[1]
canonical=[CORE/'integrations/mio_apple'/n for n in ['main.swift','Consumer.swift','Transport.swift','Host.swift','OwnedProcesses.swift']]
review=[CORE/'integrations/apple_review'/n for n in ['Proposal.swift','PeerAuthentication.swift','ConsumptionJournal.swift','ApprovalEngine.swift','EventKitEffects.swift']]
local=[ROOT/'source'/n for n in ['StartupDiagnostics.swift','Setup.swift','SetupFlow.swift','NativeSetupReview.swift']]
sources=canonical+local+review
h=lambda p:hashlib.sha256(p.read_bytes()).hexdigest();before={str(p.relative_to(CORE)):h(p) for p in sources}
baseline=json.loads((ROOT/'BASELINE.json').read_bytes())
for n,v in baseline['canonical_sources'].items():assert h(CORE/'integrations/mio_apple'/n)==v,'canonical_source_changed'
OUT=ROOT/'build';OUT.mkdir(exist_ok=True)
subprocess.run(['/usr/bin/xcrun','swiftc','-swift-version','6','-module-cache-path',str(OUT/'module-cache'),*[str(p) for p in sources],'-framework','Security','-framework','AppKit','-framework','EventKit','-framework','CoreGraphics','-o',str(OUT/'ARLMioAppleBridge')],check=True,capture_output=True,timeout=60)
assert before=={str(p.relative_to(CORE)):h(p) for p in sources},'source_changed_during_build'
(ROOT/'BUILD-INPUTS.json').write_text(json.dumps({'sources_sha256':before,'output_binary_sha256':h(OUT/'ARLMioAppleBridge'),'compiled_not_launched':True,'signing_or_installation':False},indent=2)+'\n')
print(json.dumps({'build':'passed_not_launched','binary_sha256':h(OUT/'ARLMioAppleBridge')}))
