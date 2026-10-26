#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/ModuleCache build/pycache
export PYTHONDONTWRITEBYTECODE=1
export PYTHONPATH=.
PYTHONPYCACHEPREFIX="$PWD/build/pycache" /usr/bin/python3 -m compileall -q arl
# These short-lived CLI binaries have no existing persistent process to terminate.
/usr/bin/swiftc -swift-version 6 -module-cache-path build/ModuleCache \
  examples/ARLClient.swift examples/SwiftSmoke.swift -o build/SwiftSmoke
/usr/bin/swiftc -swift-version 5 -module-cache-path build/ModuleCache \
  -target arm64-apple-macos14.0 apple/EventKitHelper.swift -o build/EventKitHelper
/usr/bin/swiftc -swift-version 6 -module-cache-path build/ModuleCache \
  examples/ARLClient.swift integrations/tisra/TisraRuntime.swift integrations/tisra/Smoke.swift -o build/TisraIntegrationSmoke
/usr/bin/swiftc -swift-version 6 -module-cache-path build/ModuleCache \
  apple/PeerSignatureHelper.swift -o build/PeerSignatureHelper
case "${1:---verify}" in
  --build-only) ;;
  --verify|run)
    /usr/bin/python3 -m unittest discover -s tests -v
    /usr/bin/python3 examples/clients.py
    ;;
  *) echo "Usage: $0 [--verify|--build-only]" >&2; exit 2 ;;
esac
