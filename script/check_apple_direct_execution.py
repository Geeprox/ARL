#!/usr/bin/env python3
"""Compile real Apple owners and run synthetic execution regressions without UI or live data."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--native-build', required=True, type=Path,
                        help='SDK modules produced by check_native_source.py')
    args = parser.parse_args()
    native = args.native_build.resolve()
    receipt = json.loads((native / 'results.json').read_text())
    for step in receipt['steps']:
        if step['step'] not in ('ARLCredentialOnboarding', 'ARLCredentialHostCore', 'archive'):
            continue
        if step['exit_code'] or not step['inputs_stable']:
            raise ValueError('native_dependency_build_failed')
        for path, digest in step['source_inputs'].items():
            if hashlib.sha256((ROOT / path).read_bytes()).hexdigest() != digest:
                raise ValueError('native_dependency_changed:' + path)
    output = ROOT / 'build' / ('apple-direct-check-' + uuid.uuid4().hex[:12])
    output.mkdir()
    print('Output:', output, flush=True)
    sdk = subprocess.check_output(['xcrun', '--show-sdk-path'], text=True).strip()
    common = ['xcrun', 'swiftc', '-sdk', sdk, '-swift-version', '6', '-j', '1', '-parse-as-library',
              '-module-cache-path', str(output / 'ModuleCache'), '-I', str(native), '-I', str(output)]
    link = ['-L', str(native), '-lARLCredentialHostCore', '-lz', '-Xcc',
            '-fmodule-map-file=' + str(native / 'FlyAICompression/module.modulemap')]
    records = []

    def run(name, argv, sources=()):
        hashes = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
        process = subprocess.run(list(map(str, argv)), cwd=ROOT, capture_output=True, timeout=240)
        (output / (name + '.log')).write_bytes(process.stdout + process.stderr)
        stable = all(hashlib.sha256((ROOT / p).read_bytes()).hexdigest() == h for p, h in hashes.items())
        records.append(dict(step=name, exit_code=process.returncode, inputs_stable=stable, source_inputs=hashes))
        (output / 'results.json').write_text(json.dumps(dict(synthetic_only=True, installed=False,
            launched=False, steps=records), indent=2) + '\n')
        print(name, process.returncode, process.stdout.decode(errors='replace')[-500:], flush=True)
        if process.returncode or not stable:
            print(process.stderr.decode(errors='replace')[-10000:])
            raise SystemExit(1)

    recipe = json.loads((ROOT / 'script/release_recipe.json').read_text())
    sources = [ROOT / p for p in recipe['source_groups']['Control_complete_link']]
    entry = next(p for p in sources if p.name == 'ARLControlApp.swift')
    declarations = output / 'ControlDeclarations.swift'
    declarations.write_text(entry.read_text().replace('@main enum ARLEntry', 'enum ARLEntry'))
    compiled_sources = [declarations if p == entry else p for p in sources]
    run('ControlModule', common + link + ['-enable-testing', '-whole-module-optimization', '-emit-module',
        '-emit-object', '-module-name', 'ARLControlVerification', '-emit-module-path', output / 'ARLControlVerification.swiftmodule',
        *compiled_sources, '-o', output / 'Control.o'], sources)
    spec = importlib.util.spec_from_file_location('reminders_static', ROOT / 'integrations/reminders_v3/build_static.py')
    reminders = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(reminders)
    for name, paths in [('ARLRemindersCore', reminders.CORE), ('ARLRemindersEventKit', reminders.EVENTKIT)]:
        inputs = [ROOT / p for p in paths]
        run(name, common + ['-whole-module-optimization', '-emit-module', '-emit-object', '-module-name', name,
            '-emit-module-path', output / (name + '.swiftmodule'), *inputs, '-o', output / (name + '.o')], inputs)
    inputs = [ROOT / p for p in reminders.HOST]
    run('RemindersProductionHost', common + inputs + [output / 'ARLRemindersCore.o', output / 'ARLRemindersEventKit.o',
        '-o', output / 'RemindersProductionHost'], inputs)
    suites = ['CalendarBusinessTests', 'CalendarBusinessIntentFlowTests', 'CalendarBusinessTaskStoreTests',
              'AppleCalendarRecoveryTests', 'AppleOwnerDeleteFlowTests', 'AppleOwnerDefaultFlowTests',
              'NotesDirectTests', 'NotesDeleteTests']
    for name in suites:
        source = ROOT / 'tests' / (name + '.swift')
        code = '@testable import ARLControlVerification\n' + source.read_text()
        extras = []
        if name == 'AppleOwnerDefaultFlowTests':
            extras = [ROOT / 'integrations/reminders_v3/adapter_source/Fixtures/FixtureRepository.swift',
                      ROOT / 'integrations/reminders_v3/RemindersProductHandler.swift',
                      ROOT / 'integrations/reminders_v3/RemindersProductRequest.swift']
            # Helper DTOs are the shared declarations already imported from Control.
        originals = extras
        extras = []
        for extra in originals:
            copied = output / (name + '-' + extra.name)
            copied.write_text('@testable import ARLControlVerification\n' + extra.read_text())
            extras.append(copied)
        test = output / (name + '.swift')
        test.write_text(code)
        run(name + '-compile', common + link + [output / 'Control.o', output / 'ARLRemindersCore.o',
            *extras, test, '-o', output / name], [source, *originals])
        run(name, [output / name, output / (name + '-fixture')])
    print('PASS Apple direct execution; no application installed or launched:', output / 'results.json')


if __name__ == '__main__':
    main()
