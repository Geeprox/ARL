#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source_root="$(cd ../.. && pwd)"
test_root="$(mktemp -d /tmp/arl-control-test.XXXXXX)"
trap 'rm -rf "$test_root"' EXIT
python_bin="${ARL_TEST_PYTHON:-python3}"
"$python_bin" -c 'import sys; assert sys.version_info >= (3,10), "Set ARL_TEST_PYTHON to Python 3.10+"'
/usr/bin/swiftc -swift-version 6 -target arm64-apple-macos14.0 -module-cache-path "$test_root/ModuleCache" \
  "$source_root/examples/ARLClient.swift" Models/*.swift \
  Services/*.swift Tests/ControlHarness.swift \
  -o "$test_root/harness"
ARL_CONTROL_TEST_DIR="$test_root" ARL_CONTROL_SOURCE="$source_root" \
  "$python_bin" Tests/control_transport_checks.py

if [[ -n "${ARL_TEST_EVIDENCE:-}" ]]; then
  cp "$test_root/fixed-evidence.json" "$ARL_TEST_EVIDENCE"
fi
