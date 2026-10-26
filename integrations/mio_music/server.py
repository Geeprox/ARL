#!/usr/bin/env python3
"""Fixed travel14 + music entry; requires separately reviewed deployment binding.

No credential path, account enrollment, executable override, or login RPC.
The legacy source remains byte-pinned and owns its existing travel transports.
"""
import hashlib
from pathlib import Path
import runpy
import sys

# This entry is inside the signed app. -I ignores PYTHONDONTWRITEBYTECODE;
# set the runtime flag before importing bundled modules to preserve its seal.
sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from arl.contracts import Fault
from arl.mio_music import MioMusicGateway, serve

LEGACY = Path.home()/'Library/Application Support/MioReadOnly/service/tunnel-experiment/travel-draft/server.py'
LEGACY_SHA = '6ee0c94953cdf6ee643841d793d347de8580d3f140e869e0acfd1e682c5e55a5'

def main():
    if LEGACY.is_symlink() or hashlib.sha256(LEGACY.read_bytes()).hexdigest() != LEGACY_SHA:
        raise Fault('travel_source_changed')
    module = runpy.run_path(str(LEGACY), run_name='reviewed_travel14')
    gateway = MioMusicGateway(module['respond'])
    serve(gateway, sys.stdin, sys.stdout)

if __name__ == '__main__':
    # Retired CLI only. Keep the byte-bound library for local compatibility review;
    # the product uses the signed native owner inside ARL.app.
    sys.stderr.write("legacy_mio_entry_retired_use_arl_app\n")
    raise SystemExit(2)
