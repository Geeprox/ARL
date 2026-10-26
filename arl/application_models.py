"""Application model negotiation. Source-only host composition; never executes jobs.

Uses the existing AppConnections identity session, AppPolicy queue bands and
canonical Codex catalog validator. No enrollment, credentials, grant or new queue.
"""
import copy
import base64
import binascii
import struct
import zlib
import hashlib
import json
import re
import secrets
import time
import uuid
from .app_connections import token
from .codex_execution_options import selection, identifier
from .contracts import Fault
from .scheduling import BANDS, resolve

MODEL_METHODS = frozenset({'application.models.discover.v1', 'application.models.request.v1'})
ICON_METHOD = 'application.icon.register.v1'
METHODS = MODEL_METHODS | {ICON_METHOD}
ICON_MAX_BYTES = 8192
ICON_SOURCE = 'CFBundleIconFile:icp6'
PACKAGES = (('low', '低', 'low'), ('medium', '中', 'medium'),
            ('high', '高', 'high'), ('very_high', '极高', 'xhigh'), ('highest', '最高', 'max'))
# Only known ordered efforts can be degraded; catalog-defined unknown IDs remain
# selectable explicitly when provided by a trusted package mapping in future.
EFFORT_ORDER = ('none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max')


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()).hexdigest()


def exact(value, keys):
    if type(value) is not dict or set(value) != set(keys):
        raise Fault('application_models_invalid_arguments')


def canonical_uuid(value):
    try:
        return type(value) is str and str(uuid.UUID(value)) == value
    except ValueError:
        return False


def validate_icon(value):
    """One bounded RGBA PNG profile; never resolves URLs, paths or SVG content."""
    keys = {'schema_version', 'media_type', 'source_resource', 'source_sha256',
            'sha256', 'byte_count', 'width', 'height', 'png_base64'}
    if type(value) is not dict or set(value) != keys:
        raise Fault('application_icon_invalid')
    if (type(value['schema_version']) is not int or value['schema_version'] != 1 or
            value['media_type'] != 'image/png' or value['source_resource'] != ICON_SOURCE or
            not token(value['source_sha256']) or not token(value['sha256']) or
            type(value['byte_count']) is not int or not 1 <= value['byte_count'] <= ICON_MAX_BYTES or
            type(value['width']) is not int or value['width'] != 64 or
            type(value['height']) is not int or value['height'] != 64 or
            type(value['png_base64']) is not str or len(value['png_base64']) > 10924):
        raise Fault('application_icon_invalid')
    try:
        raw = base64.b64decode(value['png_base64'], validate=True)
    except (binascii.Error, ValueError):
        raise Fault('application_icon_invalid')
    if (len(raw) != value['byte_count'] or base64.b64encode(raw).decode() != value['png_base64'] or
            hashlib.sha256(raw).hexdigest() != value['sha256'] or raw[:8] != b'\x89PNG\r\n\x1a\n'):
        raise Fault('application_icon_invalid')
    at, compressed, chunks = 8, bytearray(), []
    while at < len(raw):
        if at + 12 > len(raw) or len(chunks) >= 16:
            raise Fault('application_icon_invalid')
        length = struct.unpack('>I', raw[at:at+4])[0]
        tag = raw[at+4:at+8]
        end = at + 12 + length
        if end > len(raw) or tag not in {b'IHDR', b'IDAT', b'IEND'}:
            raise Fault('application_icon_invalid')
        body = raw[at+8:end-4]
        if zlib.crc32(tag + body) & 0xffffffff != struct.unpack('>I', raw[end-4:end])[0]:
            raise Fault('application_icon_invalid')
        if tag == b'IHDR':
            if chunks or body != struct.pack('>IIBBBBB', 64, 64, 8, 6, 0, 0, 0):
                raise Fault('application_icon_invalid')
        elif tag == b'IDAT':
            if not chunks or chunks[-1] not in {b'IHDR', b'IDAT'}:
                raise Fault('application_icon_invalid')
            compressed.extend(body)
        elif body or not chunks or chunks[-1] != b'IDAT' or end != len(raw):
            raise Fault('application_icon_invalid')
        chunks.append(tag)
        at = end
    if len(chunks) < 3 or chunks[-1] != b'IEND':
        raise Fault('application_icon_invalid')
    expected = 64 * (1 + 64 * 4)
    try:
        inflater = zlib.decompressobj()
        pixels = inflater.decompress(bytes(compressed), expected + 1)
    except zlib.error:
        raise Fault('application_icon_invalid')
    if (len(pixels) != expected or not inflater.eof or inflater.unused_data or
            inflater.unconsumed_tail or any(pixels[i] > 4 for i in range(0, expected, 257))):
        raise Fault('application_icon_invalid')
    return copy.deepcopy(value)


class ApplicationModels:
    """Host supplies current, already scoped catalog and existing app policies.

    catalog(app) must be a local snapshot, never a live preflight/model invocation.
    Optional package_models(app) maps package IDs to host-selected catalog models.
    Acceptance means parameters resolved, not a queued job or execution authority.
    """
    def __init__(self, registry, policies, catalog, *, package_models=None, clock=time.monotonic):
        self.registry, self.policies, self.catalog = registry, policies, catalog
        self.package_models = package_models
        self.clock = clock
        self.requests = {}
        self.icons = {}

    def _session(self, app, session_id, binding):
        if (binding is None or not callable(binding[1]) or binding[1]() is not True or
                not token(session_id)):
            raise Fault('app_identity_unverified')
        entry = self.registry.entries.get(app)
        if entry is None or entry['registration'] != 'registered':
            raise Fault('method_not_authorized')
        guard = entry.get('active_guard')
        if guard is not None and guard() is not True:
            raise Fault('app_identity_unverified')
        session = self.registry.live_session(entry)
        if not session or session['id'] != session_id or session['binding'] != binding[0]:
            raise Fault('app_session_changed')
        return session

    def _discovery(self, app, session_id):
        snapshot = copy.deepcopy(self.catalog(app))
        if (type(snapshot) is not dict or type(snapshot.get('schema_version')) is not int or snapshot.get('schema_version') != 1 or
                type(snapshot.get('selection_enabled')) is not bool or
                type(snapshot.get('source')) is not str or snapshot['source'] not in {'app_server_model_list', 'test_double'} or
                type(snapshot.get('models')) is not list or
                bool(snapshot['models']) != snapshot['selection_enabled']):
            raise Fault('application_models_catalog_unavailable')
        # A normalized stale/unconfigured catalog is metadata, not a protocol
        # failure. Preserve the existing source enum and never invent rows.
        rows = snapshot['models']
        current = None
        if snapshot['selection_enabled']:
            try:
                seen = set()
                for row in rows:
                    model = identifier(row['model'])
                    efforts = row['efforts']
                    if (model in seen or type(efforts) is not list or not 1 <= len(efforts) <= 16 or
                            type(row['fast_available']) is not bool):
                        raise Fault('provider_catalog_invalid')
                    ids = [identifier(e['id'], 40) for e in efforts]
                    if len(set(ids)) != len(ids):
                        raise Fault('provider_catalog_invalid')
                    # Reuse the canonical validator for real supported efforts;
                    # this checks a local snapshot only, with no provider RPC.
                    selection(rows, model, row['default_effort'], 'default')
                    seen.add(model)
                current = snapshot.get('current', {}).get('model')
            except (Fault, TypeError, KeyError, AttributeError):
                raise Fault('application_models_catalog_unavailable')
        mapping = self.package_models(app) if self.package_models else {p[0]: current for p in PACKAGES}
        policy = self.policies[app]
        offers = []
        for package_id, name, target in PACKAGES:
            model = mapping.get(package_id)
            row = next((r for r in rows if r.get('model') == model), None)
            reasons, effort = [], None
            if row:
                supported = [e['id'] for e in row['efforts']]
                if target in supported:
                    effort = target
                else:
                    candidates = [e for e in EFFORT_ORDER[:EFFORT_ORDER.index(target)] if e in supported]
                    if candidates:
                        effort = candidates[-1]
                        reasons = ['effort_downgraded']
                if effort:
                    # Sole canonical validator for model/effort/Fast support.
                    selection(rows, model, effort, 'default')
            available = effort is not None
            offers.append({'package_id': package_id, 'name': name, 'available': available,
                'model': model if available else None, 'effort': effort,
                'target_effort': target, 'supported_efforts': [e['id'] for e in row['efforts']] if row else [],
                'service_tiers': ['default', 'fast'] if row and row['fast_available'] else ['default'],
                'reasons': reasons if available else ['package_unavailable']})
        base = {'protocol': 'arl/1', 'schema_version': 1, 'session_id': session_id,
            'capabilities': sorted(METHODS.intersection(policy.methods)), 'packages': offers,
            'queue_priorities': sorted(policy.priority_bands.intersection(BANDS)),
            'catalog_source': snapshot['source'], 'catalog_available': snapshot['selection_enabled'], 'resolution_only': True,
            'execution_authorized': False, 'fast_authorized': False,
            'deadline_max_ms': policy.max_deadline_ms}
        base['catalog_version'] = digest(base)
        return base, rows

    def dispatch(self, app, method, params, binding):
        if method not in METHODS:
            raise Fault('unknown_method')
        if app not in self.policies or method not in self.policies[app].methods:
            raise Fault('method_not_authorized')
        with self.registry.lock:
            if type(params) is not dict:
                raise Fault('application_models_invalid_arguments')
            self._session(app, params.get('session_id'), binding)
            if method == ICON_METHOD:
                exact(params, {'schema_version', 'session_id', 'icon'})
                if type(params['schema_version']) is not int or params['schema_version'] != 1:
                    raise Fault('application_icon_invalid')
                icon = validate_icon(params['icon'])
                self.icons[app] = {'session_id': params['session_id'], 'icon': icon}
                return {'schema_version': 1, 'app_id': app, 'session_id': params['session_id'],
                    'registered': True, 'storage': 'session_memory', 'display_attested': False,
                    **{k: icon[k] for k in ('sha256', 'source_sha256', 'source_resource', 'byte_count', 'media_type', 'width', 'height')}}
            discovery, rows = self._discovery(app, params['session_id'])
            if method == 'application.models.discover.v1':
                exact(params, {'session_id'})
                return discovery
            exact(params, {'schema_version', 'session_id', 'catalog_version', 'request_id',
                'request_sha256', 'task_kind', 'package_id', 'priority', 'deadline_ms',
                'thinking_effort', 'service_tier', 'allow_degradation'})
            if (type(params['schema_version']) is not int or params['schema_version'] != 1 or
                    not canonical_uuid(params['request_id']) or
                    type(params['request_sha256']) is not str or
                    re.fullmatch('[a-f0-9]{64}', params['request_sha256']) is None or
                    type(params['task_kind']) is not str or params['task_kind'] not in {'research', 'explain', 'rerank'} or
                    type(params['allow_degradation']) is not bool or
                    type(params['package_id']) is not str or type(params['thinking_effort']) is not str or
                    type(params['service_tier']) is not str or params['service_tier'] not in {'default', 'fast'}):
                raise Fault('application_models_invalid_arguments')
            base = {k: params[k] for k in ('session_id', 'catalog_version', 'request_id', 'request_sha256', 'package_id')}
            base['requested'] = {k: params[k] for k in ('task_kind', 'priority', 'deadline_ms', 'thinking_effort', 'service_tier', 'allow_degradation')}
            base.update(schema_version=1, accepted=False, reasons=[], resolved=None,
                resolution_only=True, execution_authorized=False, queue_admitted=False)
            def reject(reason):
                return dict(base, reasons=[reason])
            if params['catalog_version'] != discovery['catalog_version']:
                return reject('catalog_changed')
            try:
                band, deadline = resolve(self.policies[app], {k: params[k] for k in ('priority', 'deadline_ms')})
            except Fault as error:
                return reject(error.code)
            offer = next((p for p in discovery['packages'] if p['package_id'] == params['package_id']), None)
            if not offer or not offer['available']:
                return reject('package_unavailable')
            if offer['reasons'] and not params['allow_degradation']:
                return reject('degradation_not_allowed')
            # Effort is explicit and independent of queue priority and speed tier.
            # Do not silently replace an unsupported caller effort with the offer.
            try:
                selection(rows, offer['model'], params['thinking_effort'], params['service_tier'])
            except Fault as error:
                return reject(error.code)
            # This component never owns paid acceleration approval.
            if params['service_tier'] == 'fast':
                return reject('fast_authorization_required')
            now = self.clock()
            self.requests = {k: v for k, v in self.requests.items() if ('job_id' in v and 'result' not in v) or 0 <= now-v.get('finished_at', v['at']) < 30}
            key = (app, params['request_id'])
            existing = self.requests.get(key)
            if existing:
                if existing['params'] != params:
                    return reject('request_conflict')
                return copy.deepcopy(existing['receipt'])
            if len(self.requests) >= 128:
                return reject('resolution_capacity')
            resolved = {'model': offer['model'], 'effort': params['thinking_effort'],
                'service_tier': params['service_tier'], 'priority': band, 'deadline_ms': deadline}
            reasons = list(offer['reasons'])
            if params['thinking_effort'] != offer['effort']:
                reasons.append('explicit_effort_override')
            receipt = dict(base, accepted=True, reasons=reasons, resolved=resolved,
                resolution_id=secrets.token_hex(32), valid_for_ms=30000)
            self.requests[key] = {'params': copy.deepcopy(params), 'receipt': receipt, 'at': now}
            return copy.deepcopy(receipt)

    def icon_snapshot(self, app):
        """Host-only projection for the existing registry, without inline bytes.

        Call only after the host has established its normal metadata reader.
        No registration/data grant, file access, probe or heartbeat side effect.
        """
        with self.registry.lock:
            entry = self.registry.entries.get(app)
            record = self.icons.get(app)
            if not entry or entry['registration'] != 'registered' or not record:
                return None
            guard = entry.get('active_guard')
            if guard is not None and guard() is not True:
                return None
            session = self.registry.live_session(entry)
            if not session or record['session_id'] != session['id']:
                return None
            icon = record['icon']
            return {'app_id': app, 'sha256': icon['sha256'], 'mime_type': 'image/png',
                    'width': 64, 'height': 64, 'bytes': icon['byte_count']}

    def read_icon(self, app, expected_sha256):
        """Host-only, exact hash lookup; never opens any path or URL.

        Shared settings dispatch must separately enforce its existing public
        read-only metadata policy before exposing this to the Control app.
        """
        with self.registry.lock:
            snapshot = self.icon_snapshot(app)
            if snapshot is None or not token(expected_sha256) or snapshot['sha256'] != expected_sha256:
                raise Fault('application_icon_unavailable')
            return dict(snapshot, png_base64=self.icons[app]['icon']['png_base64'])

    def bind_job(self, app, request_id, request_sha256, *, binding, session_id, job_id):
        """Trusted existing execution admission fixes one job before lease expiry.

        This neither creates a job nor grants execution. Existing host grant,
        scope/budget/queue admission must succeed before calling this seam.
        Bound jobs survive resolution TTL until a terminal result; total retained
        records remain bounded to 128. No second queue or worker exists here.
        """
        with self.registry.lock:
            self._session(app, session_id, binding)
            record = self.requests.get((app, request_id))
            if (not record or record['params']['session_id'] != session_id or
                    record['params']['request_sha256'] != request_sha256 or not canonical_uuid(job_id)):
                raise Fault('application_models_request_changed')
            if 'job_id' in record:
                if record['job_id'] != job_id:
                    raise Fault('application_models_result_mismatch')
                return
            if not 0 <= self.clock()-record['at'] < 30:
                raise Fault('application_models_request_changed')
            current, _ = self._discovery(app, session_id)
            if current['catalog_version'] != record['receipt']['catalog_version']:
                raise Fault('application_models_catalog_changed')
            if any(key != (app, request_id) and value.get('job_id') == job_id for key, value in self.requests.items()):
                raise Fault('application_models_result_mismatch')
            record['job_id'] = job_id

    def correlate_result(self, app, request_id, request_sha256, *, binding, session_id,
                         job_id, result_sha256, model, effort, service_tier, state):
        """Trusted execution-host seam only; intentionally not an RPC method.

        The execution host must check its existing grant/job receipt and provider
        acknowledgement first. This merely binds that terminal metadata to the
        exact resolution. A caller cannot publish results or grant inference.
        """
        with self.registry.lock:
            self._session(app, session_id, binding)
            record = self.requests.get((app, request_id))
            if (not record or record.get('job_id') != job_id or
                    record['params']['session_id'] != session_id or
                    record['params']['request_sha256'] != request_sha256):
                raise Fault('application_models_request_changed')
            receipt = record['receipt']
            resolved = receipt['resolved']
            if (not canonical_uuid(job_id) or type(result_sha256) is not str or
                    re.fullmatch('[a-f0-9]{64}', result_sha256) is None or
                    state not in {'succeeded', 'failed', 'cancelled'} or
                    (model, effort, service_tier) != (resolved['model'], resolved['effort'], resolved['service_tier'])):
                raise Fault('application_models_result_mismatch')
            result = {k: receipt[k] for k in ('schema_version', 'session_id', 'catalog_version',
                'request_id', 'request_sha256', 'package_id', 'resolution_id', 'resolved')}
            result.update(job_id=job_id, result_sha256=result_sha256, state=state)
            if 'result' in record and record['result'] != result:
                raise Fault('application_models_result_mismatch')
            record['result'] = result
            record.setdefault('finished_at', self.clock())
            return copy.deepcopy(result)
