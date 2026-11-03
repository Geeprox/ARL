"""Explicit, complete Python test inventory with honest prerequisite reporting.

Defaults to self-contained portable tests and native tests on macOS. Each module
runs in its own process. --all also reports unavailable external/private gates.
"""
from __future__ import annotations

import argparse
import ast
import importlib
import importlib.util
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT/'script/test_profiles.json'
PROFILES = frozenset({'portable', 'native', 'dependency', 'external', 'private'})


class InventoryError(ValueError):
    pass


def module_name(path, root=ROOT):
    return '.'.join(path.relative_to(root).with_suffix('').parts)


def declared_cases(path):
    """Own methods only; inherited base tests run in their owning module once."""
    tree = ast.parse(path.read_text(encoding='utf-8'), filename=str(path))
    return [n.name+'.'+method.name for n in tree.body if isinstance(n, ast.ClassDef)
        for method in n.body if isinstance(method, (ast.FunctionDef, ast.AsyncFunctionDef))
        and method.name.startswith('test_')]


def load_catalog(path=CATALOG, root=ROOT, *, strict_inventory=True):
    value = json.loads(Path(path).read_text(encoding='utf-8'))
    if (type(value) is not dict or type(value.get('schema_version')) is not int or value.get('schema_version') != 1
            or set(value) != {'schema_version', 'profiles', 'requirements', 'modules'}
            or type(value['profiles']) is not dict or set(value['profiles']) != PROFILES
            or type(value['requirements']) is not dict or type(value['modules']) is not dict):
        raise InventoryError('invalid_test_catalog')
    actual = {module_name(p, root): p for p in (root/'tests').rglob('test_*.py') if p.is_file()}
    missing, stale = sorted(actual.keys()-value['modules'].keys()), sorted(value['modules'].keys()-actual.keys())
    if strict_inventory and (missing or stale):
        # No wildcard default. A new file or an omitted exported test requires a
        # reviewed inventory change rather than silently reducing CI coverage.
        raise InventoryError(json.dumps({'unclassified_modules': missing, 'missing_modules': stale}, sort_keys=True))
    for name, spec in value['modules'].items():
        if name not in actual and not strict_inventory:
            continue
        if type(spec) is not dict or spec.get('profile') not in PROFILES or spec.get('kind') not in {'unittest', 'command'}:
            raise InventoryError('invalid_test_module:'+name)
        cases = declared_cases(actual[name])
        if len(set(cases)) != len(cases):
            raise InventoryError('duplicate_test_declaration:'+name)
        if spec['kind'] == 'unittest' and not cases:
            raise InventoryError('unittest_module_has_no_declared_cases:'+name)
        if spec['kind'] == 'command' and (cases or type(spec.get('argv')) is not list
                or not spec['argv'] or spec['argv'][0] != '{python}'
                or not all(type(item) is str for item in spec['argv'])):
            raise InventoryError('invalid_test_command:'+name)
        for selector, override in spec.get('overrides', {}).items():
            if (not any(c == selector or c.startswith(selector+'.') for c in cases)
                    or override.get('profile') not in PROFILES):
                raise InventoryError('stale_test_partition:'+name+'.'+selector)
        if any(r not in value['requirements'] for r in spec.get('import_requires', [])):
            raise InventoryError('unknown_test_requirement:'+name)
        for part in [spec, *spec.get('overrides', {}).values()]:
            if any(r not in value['requirements'] for r in part.get('requires', [])):
                raise InventoryError('unknown_test_requirement:'+name)
        for relative in spec.get('python_paths', []):
            if not (root/relative).resolve().is_relative_to(root.resolve()):
                raise InventoryError('external_test_python_path:'+name)
    return value, actual


def partition(spec, case):
    matches = [(key, part) for key, part in spec.get('overrides', {}).items()
        if case == key or case.startswith(key+'.')]
    return max(matches, key=lambda item: len(item[0]))[1] if matches else spec


def prerequisite(spec, root=ROOT):
    """Read-only metadata checks; never fetches evidence or prepares accounts."""
    kind = spec['kind']
    if kind == 'platform':
        return sys.platform == spec['value']
    if kind == 'executable':
        return shutil.which(spec['value']) is not None
    if kind == 'path':
        return (root/spec['value']).exists()
    if kind == 'any_path':
        return any(((Path.home() if item['base'] == 'user_home' else root)/item['path']).exists()
            for item in spec['values'])
    if kind == 'env_path':
        base = os.environ.get(spec['variable']) or spec.get('default')
        if not base:
            return False
        base = Path(base)
        if not base.is_absolute():
            base = root/base
        return (base/spec.get('suffix', '')).exists()
    if kind == 'python_module':
        try:
            return importlib.util.find_spec(spec['value']) is not None
        except (ImportError, ValueError, AttributeError):
            return False
    if kind == 'python_locked_modules':
        try:
            from importlib.metadata import version
            lock = json.loads((root/spec['lock']).read_text())
            expected = {r['name']: r['version'] for r in lock['wheels']}
            return all(version(name) == expected[name] for name in spec['distributions'])
        except (OSError, ImportError, KeyError, ValueError):
            return False
    if kind == 'release_cache':
        try:
            recipe = json.loads((root/spec['recipe']).read_text())
            cache = root/recipe['cache']
            descriptor = json.loads(cache.read_text())
            return (cache.parent/descriptor['resource_shell']).is_dir()
        except (OSError, KeyError, TypeError, ValueError):
            return False
    raise InventoryError('unsupported_requirement_kind:'+kind)


def plan(catalog, files, profiles, *, root=ROOT):
    capabilities = {name: prerequisite(spec, root) for name, spec in catalog['requirements'].items()}
    jobs, blocked, excluded = [], [], []
    for name, spec in sorted(catalog['modules'].items()):
        cases = declared_cases(files[name]) if spec['kind'] == 'unittest' else [None]
        selected = []
        for case in cases:
            part = partition(spec, case) if case is not None else spec
            label = name+('.'+case if case else '')
            entry = {'test': label, 'profile': part['profile']}
            if part['profile'] not in profiles:
                excluded.append(entry)
                continue
            needed = sorted(set(spec.get('import_requires', [])+part.get('requires', [])))
            unmet = [r for r in needed if not capabilities[r]]
            if unmet:
                blocked.append(dict(entry, unmet_requirements=unmet))
            else:
                selected.append(case)
        if selected:
            jobs.append({'module': name, 'kind': spec['kind'], 'cases': selected,
                **({'argv': spec['argv']} if spec['kind'] == 'command' else {}),
                'timeout_seconds': spec.get('timeout_seconds', 240)})
    return {'schema_version': 1, 'profiles': sorted(profiles), 'capabilities': capabilities,
        'module_inventory_count': len(files), 'selected_case_count': sum(len(j['cases']) for j in jobs),
        'test_source_sha256': {name: hashlib.sha256(path.read_bytes()).hexdigest() for name, path in files.items()},
        'jobs': jobs, 'blocked': blocked, 'not_selected': excluded}


def filter_modules(test_plan, names):
    """Explicit partial scope; the full inventory remains validated separately."""
    result = dict(test_plan)
    result['module_filter'] = sorted(names)
    result['jobs'] = [j for j in test_plan['jobs'] if j['module'] in names]
    result['blocked'] = [b for b in test_plan['blocked'] if any(
        b['test'] == name or b['test'].startswith(name+'.') for name in names)]
    omitted = [{'test': job['module']+('.'+case if case else ''), 'reason': 'explicit_module_filter'}
        for job in test_plan['jobs'] if job['module'] not in names for case in job['cases']]
    result['not_selected'] = test_plan['not_selected']+omitted
    result['selected_case_count'] = sum(len(j['cases']) for j in result['jobs'])
    return result


def worker(module, selectors, output, spec=None):
    """Internal isolated worker. Called only for a catalog-validated module."""
    sys.path[:0] = [str(ROOT), str(ROOT/'tests')]
    sys.path[:0] = [str(ROOT/p) for p in (spec or {}).get('python_paths', [])]
    imported = importlib.import_module(module)
    suite = unittest.TestSuite()
    for selector in selectors:
        suite.addTests(unittest.defaultTestLoader.loadTestsFromName(selector, imported))
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    details = {'tests_run': result.testsRun, 'failures': len(result.failures), 'errors': len(result.errors),
        'skipped': [{'test': str(t), 'reason': reason} for t, reason in result.skipped],
        'ok': result.wasSuccessful() and not result.skipped,
        'status': 'failed' if not result.wasSuccessful() else 'incomplete' if result.skipped else 'passed'}
    Path(output).write_text(json.dumps(details, sort_keys=True))
    return 0 if details['ok'] else 1 if not result.wasSuccessful() else 2


def python_command(python, arguments):
    # -I ignores PYTHONDONTWRITEBYTECODE. A command-line flag is required even
    # when the outer runner already has sys.dont_write_bytecode enabled.
    return [python, '-B', *arguments]


def execute(test_plan, directory, *, python=sys.executable):
    # Runtime caches are sealed release inputs. Tests that need their locked
    # dependencies must use an independent copy, including for grandchildren
    # whose production launcher may provide a deliberately clean environment.
    if Path(python).resolve().is_relative_to((ROOT/'vendor').resolve()):
        raise InventoryError('release_cache_test_interpreter: copy the locked interpreter to build before executing tests')
    directory.mkdir(parents=True, exist_ok=True)
    results = []
    started = time.monotonic()
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE='1')
    for index, job in enumerate(test_plan['jobs']):
        name = job['module']
        prefix = directory/(str(index).zfill(3)+'-'+name)
        metadata = Path(str(prefix)+'.json')
        log = Path(str(prefix)+'.log')
        # Never accept a previous worker receipt after this invocation fails
        # before it can write its own result.
        metadata.unlink(missing_ok=True)
        with tempfile.TemporaryDirectory(prefix='arlcheck-', dir=Path('/tmp').resolve()) as temporary:
            if job['kind'] == 'unittest':
                selection = Path(temporary)/'selection.json'
                selection.write_text(json.dumps(job['cases']))
                command = python_command(python, [str(Path(__file__).resolve()), '--worker', name,
                    '--selection', str(selection), '--worker-output', str(metadata)])
            else:
                bindings = {'python': python, 'root': str(ROOT), 'temporary': temporary}
                command = python_command(python, [item.format(**bindings) for item in job['argv'][1:]])
            begin = time.monotonic()
            with log.open('w') as stream:
                try:
                    process = subprocess.run(command, cwd=ROOT, env=env, stdout=stream,
                        stderr=subprocess.STDOUT, timeout=job['timeout_seconds'])
                    code = process.returncode
                except subprocess.TimeoutExpired:
                    code = 124
            if metadata.exists():
                result = json.loads(metadata.read_text())
            else:
                result = {'ok': code == 0, 'status': 'passed' if code == 0 else 'failed',
                    'tests_run': 1 if job['kind'] == 'command' else 0,
                    'failures': 0, 'errors': int(code != 0), 'skipped': []}
            if code != 0 and result['status'] == 'passed':
                result.update(ok=False, status='failed', errors=result['errors']+1)
            result.update(module=name, kind=job['kind'], exit_code=code,
                elapsed_ms=int((time.monotonic()-begin)*1000), log=str(log))
            results.append(result)
            print(json.dumps({k: result[k] for k in ('module', 'status', 'tests_run', 'exit_code')}), flush=True)
    failed = any(r['status'] == 'failed' for r in results)
    incomplete = bool(test_plan['blocked']) or any(r['status'] == 'incomplete' for r in results)
    return {'schema_version': 1, 'status': 'failed' if failed else 'blocked' if incomplete else 'passed',
        'all_green': not failed and not incomplete, 'results': results,
        'tests_run': sum(r['tests_run'] for r in results),
        'failures': sum(r['failures'] for r in results), 'errors': sum(r['errors'] for r in results),
        'unexpected_skips': sum(len(r['skipped']) for r in results),
        'blocked_case_count': len(test_plan['blocked']), 'blocked': test_plan['blocked'],
        'not_selected_case_count': len(test_plan['not_selected']),
        'elapsed_ms': int((time.monotonic()-started)*1000)}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--profile', action='append', choices=sorted(PROFILES | {'self-contained'}))
    parser.add_argument('--all', action='store_true')
    parser.add_argument('--module', action='append', help='Run only an explicitly named catalog module; repeatable')
    parser.add_argument('--list', action='store_true', help='Validate and write the plan without importing test modules')
    parser.add_argument('--output', type=Path, default=ROOT/'build/test-profiles')
    parser.add_argument('--worker', help=argparse.SUPPRESS)
    parser.add_argument('--selection', type=Path, help=argparse.SUPPRESS)
    parser.add_argument('--worker-output', type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    try:
        catalog, files = load_catalog(strict_inventory=not bool(args.worker))
        if args.worker:
            if (args.worker not in files or args.worker not in catalog['modules']
                    or args.selection is None or args.worker_output is None):
                raise InventoryError('invalid_internal_worker')
            chosen = json.loads(args.selection.read_text())
            allowed = declared_cases(files[args.worker])
            if (type(chosen) is not list or not chosen or len(set(chosen)) != len(chosen)
                    or not set(chosen) <= set(allowed)):
                raise InventoryError('invalid_internal_selection')
            return worker(args.worker, chosen, args.worker_output, catalog['modules'][args.worker])
        profiles = set(PROFILES) if args.all else set(args.profile or ['self-contained'])
        if 'self-contained' in profiles:
            profiles.remove('self-contained'); profiles.add('portable')
            if sys.platform == 'darwin': profiles.add('native')
        selected = plan(catalog, files, profiles)
        if args.module:
            if not set(args.module) <= set(files):
                raise InventoryError('unknown_selected_module')
            selected = filter_modules(selected, set(args.module))
        if not selected['jobs'] and not selected['blocked']:
            raise InventoryError('no_selected_tests')
        args.output.mkdir(parents=True, exist_ok=True)
        if not args.list and (args.output/'result.json').exists():
            raise InventoryError('test_output_exists: choose a new output directory to preserve receipts')
        if not args.list and 'native' in profiles and sys.platform == 'darwin':
            fixtures = [ROOT/'build'/name for name in ('EventKitHelper', 'SwiftSmoke', 'TisraIntegrationSmoke', 'PeerSignatureHelper')]
            if not all(p.is_file() for p in fixtures) and shutil.which('xcrun'):
                with (args.output/'prepare-native.log').open('w') as log:
                    subprocess.run(['/bin/bash', str(ROOT/'script/build_and_run.sh'), '--build-only'],
                        cwd=ROOT, env=dict(os.environ, PYTHONDONTWRITEBYTECODE='1'),
                        stdout=log, stderr=subprocess.STDOUT, timeout=240, check=True)
                selected = plan(catalog, files, profiles)
                if args.module:
                    selected = filter_modules(selected, set(args.module))
        (args.output/'plan.json').write_text(json.dumps(selected, ensure_ascii=False, sort_keys=True, indent=2)+'\n')
        if args.list:
            print(json.dumps({'profiles': selected['profiles'], 'modules': selected['module_inventory_count'],
                'selected': selected['selected_case_count'], 'blocked': len(selected['blocked']),
                'not_selected': len(selected['not_selected']), 'plan': str(args.output/'plan.json')}))
            return 0
        result = execute(selected, args.output)
        try:
            _, final_files = load_catalog()
            if set(final_files) != set(selected['test_source_sha256']):
                raise InventoryError('module_inventory_changed_during_run')
            tested_modules = {job['module'] for job in selected['jobs']}
            changed = sorted(name for name, path in final_files.items()
                if name in tested_modules
                and hashlib.sha256(path.read_bytes()).hexdigest() != selected['test_source_sha256'].get(name))
            if changed:
                result.update(status='failed', all_green=False, source_changed_during_run=changed)
        except InventoryError as error:
            result.update(status='failed', all_green=False, inventory_changed_during_run=str(error))
        result.update(profiles=selected['profiles'], module_inventory_count=selected['module_inventory_count'])
        (args.output/'result.json').write_text(json.dumps(result, ensure_ascii=False, sort_keys=True, indent=2)+'\n')
        print(json.dumps({k: result[k] for k in ('status', 'all_green', 'tests_run', 'failures', 'errors', 'blocked_case_count')}))
        return 1 if result['status'] == 'failed' else 2 if result['status'] == 'blocked' else 0
    except InventoryError as error:
        print(str(error), file=sys.stderr)
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
