"""Opt-in execution binding v1 over unchanged sourced-v2 content/citations.

Legacy empty capabilities, schema1 submit, descriptor2 and envelope2 remain
byte/shape compatible. Explicit options use submit schema2, descriptor3,
envelope3 and receipt2; they are never inferred on restore or silently removed.
"""
import copy
from . import codex_sourced_contract as base
from .application_models import ApplicationModels, PACKAGES
from .codex_execution_options import identifier, selection
from .contracts import Fault, encode
from .research import exact, integer, digest, sha

CONTRACT = 'tisra.codex.execution.v1'
MAX_OPTIONS_BYTES = 1024
MAX_PREFERENCES_BYTES = 256
ACCEPTANCE_DELTA = 2 * MAX_OPTIONS_BYTES + MAX_PREFERENCES_BYTES
ACCEPTANCE_BYTES = 4096 + ACCEPTANCE_DELTA
SIDECAR_BYTES = 8192 + 4 * ((ACCEPTANCE_DELTA + 2) // 3) + MAX_OPTIONS_BYTES + 64
SPEC = {'contract': CONTRACT, 'submit_schema': 2, 'descriptor_version': 3,
        'envelope_schema': 3, 'receipt_schema': 2, 'service_tier': 'default',
        'binding': 'original_options_descriptor_run_auth_epoch_native_ack',
        'legacy': 'unchanged_no_options', 'fallback': False,
        'acceptance_bytes': ACCEPTANCE_BYTES, 'sidecar_bytes': SIDECAR_BYTES,
        'execution_options_bytes': MAX_OPTIONS_BYTES, 'execution_preferences_bytes': MAX_PREFERENCES_BYTES}
CONTRACT_SHA256 = sha(encode(SPEC))
KEYS = {'contract', 'contract_sha256', 'schema_version', 'catalog_version',
        'package_id', 'thinking_effort', 'priority', 'service_tier', 'allow_degradation'}


def __getattr__(name):
    return getattr(base, name)


def options(value):
    exact(value, KEYS)
    integer(value['schema_version'], 1, 1)
    if value['contract'] != CONTRACT or value['contract_sha256'] != CONTRACT_SHA256:
        raise Fault('unsupported_execution_contract')
    digest(value['catalog_version'])
    if (type(value['package_id']) is not str or value['package_id'] not in {p[0] for p in PACKAGES} or
            type(value['priority']) is not str or value['priority'] not in {'background','explicit','interactive'} or
            type(value['allow_degradation']) is not bool):
        raise Fault('invalid_execution_options')
    identifier(value['thinking_effort'], 40)
    if value['service_tier'] != 'default':
        raise Fault('fast_authorization_required')
    if len(encode(value)) > MAX_OPTIONS_BYTES:raise Fault('invalid_execution_options')
    return copy.deepcopy(value)


def catalog(snapshot, owner, policy, allowed_models):
    snapshot = copy.deepcopy(snapshot)
    if type(snapshot) is dict and type(snapshot.get('models')) is list:
        snapshot['models'] = [row for row in snapshot['models'] if type(row) is not dict or row.get('model') in allowed_models]
        if not snapshot['models']:
            snapshot['selection_enabled'] = False
    projection = ApplicationModels(None, {owner: policy}, lambda _: snapshot)
    # This pure projection does not authenticate or create a session. The
    # endpoint already enforces the actual owner; no synthetic session is sent.
    result, rows = projection._discovery(owner, None)
    return {'contract': CONTRACT, 'contract_sha256': CONTRACT_SHA256,
        'schema_version': 1, 'catalog_version': result['catalog_version'],
        'catalog_available': result['catalog_available'], 'packages': result['packages'],
        'queue_priorities': result['queue_priorities'], 'deadline_max_ms': min(30000, result['deadline_max_ms'])}, rows


def resolve(value, args, projected, rows):
    value = options(value)
    if value['catalog_version'] != projected['catalog_version']:
        raise Fault('catalog_changed')
    if value['priority'] != args['priority'] or value['priority'] not in projected['queue_priorities']:
        raise Fault('priority_not_authorized')
    offer = next((p for p in projected['packages'] if p['package_id'] == value['package_id']), None)
    if not offer or not offer['available']:
        raise Fault('package_unavailable')
    if offer['model'] != args['model']:
        raise Fault('execution_options_mismatch')
    if offer['reasons'] and not value['allow_degradation']:
        raise Fault('degradation_not_allowed')
    selection(rows, args['model'], value['thinking_effort'], value['service_tier'])
    return value


def preferences(value, selected):
    exact(value, {'reasoning_effort','service_tier','source'})
    if (value['reasoning_effort'] != selected['thinking_effort'] or
            value['service_tier'] != selected['service_tier'] or
            value['source'] not in {'thread_start_confirmed','test_double'}):
        raise Fault('provider_preferences_unverified')
    if len(encode(value)) > MAX_PREFERENCES_BYTES:raise Fault('provider_preferences_unverified')
    return copy.deepcopy(value)


def descriptor(raw, args):
    if 'execution_options' not in args:
        return base.descriptor(raw, args)
    selected = options(args['execution_options'])
    obj = base._parse(raw, base.LIMITS[base.DESCRIPTOR], 'descriptor_mismatch')
    if obj.get('version') != 3 or obj.get('executionOptions') != selected:
        raise Fault('descriptor_mismatch')
    legacy = dict(obj); legacy.pop('executionOptions'); legacy['version'] = 2
    base.descriptor(encode(legacy), args)
    return obj


def result_body(raw, args, **kwargs):
    if 'execution_options' not in args:
        return base.result_body(raw, args, **kwargs)
    selected = options(args['execution_options'])
    obj = base._parse(raw, base.LIMITS[base.RESPONSE], 'codex_result_invalid')
    if obj.get('schema_version') != 3 or obj.get('execution_options') != selected:
        raise Fault('execution_options_mismatch')
    preferences(obj.get('execution_preferences'), selected)
    legacy = dict(obj)
    legacy.pop('execution_options'); legacy.pop('execution_preferences'); legacy['schema_version'] = 2
    base.result_body(encode(legacy), args, **kwargs)
    return obj
