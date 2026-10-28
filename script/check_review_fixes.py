#!/usr/bin/env python3
"""Compile actual source seams and run synthetic regressions. No app launch or live services."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--native-build', type=Path)
    parser.add_argument('--suite', choices=['all','nas-and-policy'], default='all')
    args = parser.parse_args()
    output = ROOT / 'build' / ('review-fixes-' + uuid.uuid4().hex[:12])
    output.mkdir(parents=True)
    native = args.native_build.resolve() if args.native_build else output / 'native'
    if not args.native_build:
        subprocess.run(['python3', '-B', str(ROOT/'script/check_native_source.py'), '--output', str(native)], check=True)
    receipt = json.loads((native/'results.json').read_text())
    for step in receipt['steps']:
        if step['exit_code'] or not step['inputs_stable']:
            raise ValueError('native_build_failed')
        # Reused modules need exact SDK/host inputs. Control sources are
        # independently rebuilt below when checking the native policy seam.
        if args.native_build and step['step'] == 'Control_complete_link': continue
        for name, digest in step['source_inputs'].items():
            if hashlib.sha256((ROOT/name).read_bytes()).hexdigest() != digest:
                raise ValueError('native_sources_changed:' + name)
    sdk = subprocess.check_output(['xcrun', '--show-sdk-path'], text=True).strip()
    base = ['xcrun', 'swiftc', '-sdk', sdk, '-swift-version', '6', '-j', '1', '-parse-as-library',
            '-module-cache-path', str(output/'ModuleCache'), '-I', str(native), '-L', str(native),
            '-lARLCredentialHostCore', '-lz', '-Xcc', '-fmodule-map-file='+str(native/'FlyAICompression/module.modulemap')]
    records = []

    def run(name, argv, timeout=180):
        result = subprocess.run(list(map(str, argv)), cwd=ROOT, capture_output=True, timeout=timeout)
        (output/(name+'.log')).write_bytes(result.stdout+result.stderr)
        records.append(dict(name=name, exit_code=result.returncode))
        (output/'results.json').write_text(json.dumps({'synthetic_only': True, 'installed': False, 'suite': args.suite, 'steps': records}, indent=2)+'\n')
        print(name, result.returncode, result.stdout.decode(errors='replace')[-200:], flush=True)
        if result.returncode:
            print(result.stderr.decode(errors='replace')[-6000:]); raise SystemExit(1)

    for name in ([] if args.suite == 'nas-and-policy' else ['MusicWriteArchiveTests', 'MusicWriteRecoveryTests', 'MusicWriteRecoveryConcurrencyTests', 'MusicWriteReconciliationTests']):
        source = ROOT/'tests'/(name+'.swift')
        compiled = output/(name+'.swift')
        compiled.write_text('@testable import ARLCredentialOnboarding\n'+source.read_text())
        run(name+'-compile', base+[compiled, '-o', output/name])
        run(name, [output/name, output/(name+'-fixture')], timeout=60)
    notes = [ROOT/p for p in ['macOS/ARLControl/Services/AppleDirectEvents.swift',
        'macOS/ARLControl/Services/AppleDirectJournal.swift',
        'macOS/ARLControl/Models/AppleConnectionState.swift',
        'macOS/ARLControl/Services/AppleStatusCoordinator.swift', 'macOS/ARLControl/Models/NotesDirectModels.swift',
        'macOS/ARLControl/Services/NotesDirectBackend.swift']]
    for name in ([] if args.suite == 'nas-and-policy' else ['NotesDeleteTests', 'NotesDirectTests']):
        run(name+'-compile', base+notes+[ROOT/'tests'/(name+'.swift'), '-o', output/name])
        run(name, [output/name, output/(name+'-fixture')], timeout=30)
    mio = [ROOT/x['path'] for x in json.loads((ROOT/'script/mio_native_recipe.json').read_text())['sources'] if not x['path'].endswith('/main.swift')]
    name = 'NASDownloadIntegrationTests'
    run(name+'-compile', base+mio+[ROOT/'macOS/ARLControl/Services/NASFileExecutor.swift',
        ROOT/'macOS/ARLControl/Services/NASFileMutationContract.swift',
        ROOT/'macOS/ARLControl/NASSettings/NASSetupContract.swift',
        ROOT/'macOS/ARLControl/NASSettings/NASAddressInput.swift', ROOT/'tests'/(name+'.swift'), '-o', output/name])
    run(name, [output/name, output/(name+'-fixture')], timeout=60)
    name = 'NASFileOperationsTests'
    run(name+'-compile', base+[ROOT/'macOS/ARLControl/Services/NASFileMutationContract.swift', ROOT/'tests'/(name+'.swift'), '-o', output/name])
    run(name, [output/name])
    control = []
    for path in json.loads((ROOT/'script/release_recipe.json').read_text())['source_groups']['Control_complete_link']:
        source = ROOT/path
        if path.endswith('/ARLControlApp.swift'):
            entry = output/'ControlDeclarations.swift'
            entry.write_text(source.read_text().replace('@main enum ARLEntry', 'enum ARLEntry'))
            source = entry
        control.append(source)
    name = 'CodexScopePolicyTests'
    run(name+'-compile', base+control+[ROOT/'tests'/(name+'.swift'), '-o', output/name], timeout=240)
    run(name, [output/name])
    print('Selected synthetic native regressions passed; receipt:', output/'results.json')


if __name__ == '__main__':
    main()
