#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 -B - <<'PY'
from pathlib import Path
import shutil
import subprocess
import sys

sys.path.insert(0, str(Path('../../script').resolve()))
from local_build_area import build_area

with build_area("arl-connected-apps", toolchain="swift-macos-arm64",
                reproduce=("bash", "macOS/ARLControl/script/test_connected_apps.sh")) as area:
    work = area / "work"
    work.mkdir()
    try:
        binary = work / "unit"
        subprocess.run([
            "/usr/bin/swiftc", "-swift-version", "6", "-target", "arm64-apple-macos14.0",
            "-module-cache-path", str(work / "ModuleCache"),
            "../../examples/ARLClient.swift", "Models/RuntimeSnapshot.swift", "Models/ControlPlaneState.swift",
            "Models/ControlAPI.swift", "Models/CodexExecutionOptions.swift",
            "Services/NASModelRouting.swift", "Services/ApplicationModelUsage.swift", "Tests/ConnectedAppsUnit.swift",
            "-lsqlite3",
            "-o", str(binary),
        ], check=True)
        subprocess.run([str(binary), str(work)], check=True)
    finally:
        shutil.rmtree(work)
PY
