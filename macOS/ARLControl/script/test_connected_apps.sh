#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_root="$(mktemp -d /tmp/arl-connected-apps.XXXXXX)"
trap 'rm -rf "$test_root"' EXIT
/usr/bin/swiftc -swift-version 6 -target arm64-apple-macos14.0 -module-cache-path "$test_root/ModuleCache" \
 ../../examples/ARLClient.swift Models/RuntimeSnapshot.swift Models/ControlPlaneState.swift Models/ControlAPI.swift Tests/ConnectedAppsUnit.swift -o "$test_root/unit"
"$test_root/unit"
