#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source_root="$(cd ../.. && pwd)"
test_root="$(mktemp -d /tmp/arl-control-meta.XXXXXX)"
trap 'rm -rf "$test_root"' EXIT
python_bin="${ARL_TEST_PYTHON:-python3}"
"$python_bin" -c 'import sys; assert sys.version_info >= (3,10)'
/usr/bin/swiftc -swift-version 6 -target arm64-apple-macos14.0 -module-cache-path "$test_root/ModuleCache" \
 "$source_root/examples/ARLClient.swift" Models/*.swift Services/ControlFixtures.swift Services/CredentialVault.swift \
 Services/SettingsService.swift Tests/ControlMetadataUnit.swift -o "$test_root/unit"
"$test_root/unit" --fixtures "$test_root/fixtures.json" > "$test_root/unit.json"
/usr/bin/swiftc -swift-version 6 -target arm64-apple-macos14.0 -module-cache-path "$test_root/ModuleCache" \
 "$source_root/examples/ARLClient.swift" Models/*.swift Services/*.swift Tests/ControlMetadataHarness.swift -o "$test_root/harness"
PYTHONDONTWRITEBYTECODE=1 ARL_CONTROL_SOURCE="$source_root" ARL_CONTROL_HARNESS="$test_root/harness" \
 ARL_CONTROL_FIXTURES="$test_root/fixtures.json" ARL_METADATA_EVIDENCE="$test_root/integration.json" \
 "$python_bin" Tests/control_metadata_checks.py
if [[ -n "${ARL_TEST_EVIDENCE_DIR:-}" ]]; then
 mkdir -p "$ARL_TEST_EVIDENCE_DIR"
 cp "$test_root/unit.json" "$ARL_TEST_EVIDENCE_DIR/unit.json"
 cp "$test_root/integration.json" "$ARL_TEST_EVIDENCE_DIR/integration.json"
fi
