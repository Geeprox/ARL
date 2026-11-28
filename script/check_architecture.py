#!/usr/bin/env python3
"""Check Python runtime import direction and application storage boundaries."""
import argparse
import ast
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from script.export_public_core import import_targets

PACKAGES = ('arl', 'arl_nas_credential', 'arl_nas_ui_composition', 'arl_nas_upload_new')


def import_graph(root=ROOT):
    modules = {}
    for package in PACKAGES:
        for path in (root / package).rglob('*.py'):
            parts = path.relative_to(root).with_suffix('').parts
            name = '.'.join(parts[:-1] if parts[-1] == '__init__' else parts)
            modules[name] = path
    return {
        name: set(import_targets(path, name)).intersection(modules) - {name}
        for name, path in modules.items()
    }


def reachable(graph, source):
    visited = set()
    pending = list(graph[source])
    while pending:
        target = pending.pop()
        if target not in visited:
            visited.add(target)
            pending.extend(graph[target] - visited)
    return visited


def cyclic_imports(graph):
    reachable_modules = {source: reachable(graph, source) for source in graph}
    return {(source, target) for source, targets in graph.items() for target in targets
            if source in reachable_modules[target]}


def application_storage_violations(root=ROOT):
    path = 'arl/application_platform.py'
    tree = ast.parse((root / path).read_bytes(), filename=path)
    violations = []
    for node in ast.walk(tree):
        direct_connection = isinstance(node, ast.Attribute) and node.attr == 'db'
        sqlite_import = (
            isinstance(node, ast.Import) and any(item.name == 'sqlite3' for item in node.names)
            or isinstance(node, ast.ImportFrom) and node.module == 'sqlite3'
        )
        if direct_connection or sqlite_import:
            violations.append(f'{path}:{node.lineno}: use Store operations for application persistence')
    return sorted(violations)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--graph', action='store_true', help='Print the graph and current cycle edges as JSON')
    args = parser.parse_args(argv)
    graph = import_graph()
    cycles = cyclic_imports(graph)
    violations = application_storage_violations()
    if args.graph:
        print(json.dumps({'imports': {source: sorted(targets) for source, targets in sorted(graph.items())},
                          'cyclic_imports': sorted(cycles), 'boundary_violations': violations}, indent=2))
    else:
        print(f'{len(graph)} modules, {sum(map(len, graph.values()))} static imports, {len(cycles)} cyclic imports')
    for source, target in sorted(cycles):
        print(f'Cyclic import: {source} -> {target}', file=sys.stderr)
    for violation in violations:
        print(violation, file=sys.stderr)
    return int(bool(cycles or violations))


if __name__ == '__main__':
    raise SystemExit(main())
