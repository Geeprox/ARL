"""Narrow music review regression; synthetic provider and credentials only."""
import argparse
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--service-runtime', type=Path, required=True)
    args = parser.parse_args()
    runtime = args.service_runtime.resolve(strict=True)
    output = ROOT / 'build/audit/music-rich-frame'
    output.mkdir(parents=True, exist_ok=True)
    fixture = output / 'pages.json'
    with (output / 'cli-result.json').open('w') as log:
        subprocess.run([str(runtime / 'Runtime/node'), str(ROOT / 'tests/NetEaseRichSearchFrameTests.cjs'),
            str(ROOT / 'integrations/service_runtime/netease_bridge.cjs'), str(runtime), str(fixture)],
            cwd=ROOT, stdout=log, check=True, timeout=60)
    recipe = json.loads((ROOT / 'script/mio_native_recipe.json').read_text())
    sources = [ROOT / row['path'] for row in recipe['sources'] if row['path'] != 'integrations/mio_apple/main.swift']
    sources += [ROOT / 'tests/fixtures/MusicRepairProjectionSupport.swift',
                ROOT / 'integrations/credentials_login/Module/Sources/ARLCredentialOnboarding/MusicReadContract.swift',
                ROOT / 'tests/MioMusicRichFrameTests.swift']
    binary = output / 'native-tests'
    with (output / 'compile.log').open('w') as log:
        subprocess.run(['/usr/bin/xcrun', 'swiftc', '-swift-version', '6', '-j', '1', '-target',
            'arm64-apple-macos14.0', '-module-cache-path', str(ROOT / 'build/cache/ModuleCache'),
            *map(str, sources), '-framework', 'Security', '-framework', 'EventKit', '-framework', 'AppKit',
            '-framework', 'CoreGraphics', '-o', str(binary)], cwd=ROOT, stdout=log, stderr=log, check=True, timeout=180)
    with (output / 'native-result.json').open('w') as log:
        subprocess.run([str(binary), str(fixture)], cwd=ROOT, stdout=log, check=True, timeout=15)
    print(json.dumps({'status': 'PASS', 'report_directory': str(output.relative_to(ROOT)), 'real_network': 0, 'real_credentials': 0}))

if __name__ == '__main__':
    main()
