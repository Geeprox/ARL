"""Offline real Swift consumer -> existing sessions -> canonical catalog parser.

No socket, model process, network, credentials, grant file or production runtime.
Synthetic terminal metadata is explicit; never represented as model execution.
"""
import copy
import base64
import hashlib
import struct
import zlib
import json
import os
from pathlib import Path
import selectors
import shutil
import subprocess
import tempfile
import unittest
import uuid
from unittest.mock import Mock

from arl.application_models import ApplicationModels, METHODS, MODEL_METHODS, ICON_METHOD, validate_icon
from arl.app_connections import AppConnections
from arl.codex_execution_options import read_catalog
from arl.contracts import AppPolicy, Fault
from arl.control import AppDescriptor, AppRegistry
from arl.diagnostics import Diagnostics

ROOT = Path(__file__).resolve().parents[1]
TISRA = ROOT.parent / 'Tisra'


def synthetic_catalog():
    # Deliberately synthetic model name, full canonical model/list decoder.
    session = Mock()
    session.response.return_value = {'data': [{'model': 'offline-fixture-model',
        'defaultReasoningEffort': 'medium',
        'supportedReasoningEfforts': [{'reasoningEffort': effort} for effort in ('low', 'medium', 'high', 'xhigh')],
        'serviceTiers': [{'id': 'fast'}]}], 'nextCursor': None}
    rows = read_catalog(session)
    session.send.assert_called_once_with('model/list', {'limit': 20, 'includeHidden': False})
    return {'schema_version': 1, 'source': 'test_double', 'selection_enabled': True,
        'current': {'model': rows[0]['model'], 'reasoning_effort': 'medium', 'service_tier': 'default'}, 'models': rows}


def actual_icon():
    original = TISRA / 'assets/Tisra.icns'
    if original.is_file():
        source = original.read_bytes()
    else:
        # Public unit fixture: repack the bundled ARL 64px PNG into the tested
        # icp6 container profile. This makes no external consumer acceptance claim.
        bundled = (ROOT/'macOS/ARLControl/Resources/AppIcon/ARL.icns').read_bytes()
        index = 8
        while index < len(bundled):
            size = int.from_bytes(bundled[index+4:index+8], 'big')
            if bundled[index:index+4] == b'ic12':
                original_png = bundled[index+8:index+size]
                png = original_png[:8]
                at = 8
                while at < len(original_png):
                    count = int.from_bytes(original_png[at:at+4], 'big') + 12
                    if original_png[at+4:at+8] in {b'IHDR',b'IDAT',b'IEND'}:
                        png += original_png[at:at+count]
                    at += count
                member = b'icp6' + (len(png)+8).to_bytes(4, 'big') + png
                source = b'icns' + (len(member)+8).to_bytes(4, 'big') + member
                break
            index += size
        else: raise AssertionError('bundled 64px icon fixture missing')
    offset, members = 8, []
    while offset < len(source):
        length = int.from_bytes(source[offset+4:offset+8], 'big')
        if source[offset:offset+4] == b'icp6': members.append(source[offset+8:offset+length])
        offset += length
    assert len(members) == 1
    raw = members[0]
    return {'schema_version': 1, 'media_type': 'image/png', 'source_resource': 'CFBundleIconFile:icp6',
        'source_sha256': hashlib.sha256(source).hexdigest(), 'sha256': hashlib.sha256(raw).hexdigest(),
        'byte_count': len(raw), 'width': 64, 'height': 64, 'png_base64': base64.b64encode(raw).decode()}


def icon_with_bytes(raw):
    icon = actual_icon()
    icon.update(byte_count=len(raw), sha256=hashlib.sha256(raw).hexdigest(), png_base64=base64.b64encode(raw).decode())
    return icon


def png_chunk(tag, body):
    return struct.pack('>I', len(body)) + tag + body + struct.pack('>I', zlib.crc32(tag+body) & 0xffffffff)


class ApplicationModelTests(unittest.TestCase):
    def setUp(self):
        self.now, self.live = 1000, True
        self.policy = AppPolicy(frozenset(), methods=METHODS | {'heartbeat'},
            priority_bands=frozenset({'background', 'explicit', 'interactive'}))
        self.registry = AppRegistry({'tisra', 'other'}, Diagnostics({'tisra', 'other'}),
            clock=lambda: int(self.now * 1000), monotonic=lambda: self.now * 1000)
        self.registry.register(AppDescriptor('tisra', 'Host placeholder', 'sf:app'))
        self.connections = AppConnections(self.registry)
        self.binding = ('synthetic-kernel-binding', lambda: self.live)
        self.snapshot = synthetic_catalog()
        self.gateway = ApplicationModels(self.registry, {'tisra': self.policy}, lambda app: self.snapshot, clock=lambda: self.now)
        self.open()

    def open(self):
        opened = self.connections.dispatch('tisra', 'connection.open', {
            'client_nonce': 'b'*64, 'name': 'Tisra / 织语', 'version': '0.1.0.6',
            'icon_ref': 'sf:text.book.closed', 'capabilities': []}, self.binding, self.policy)
        self.connections.dispatch('tisra', 'connection.confirm',
            {k: opened[k] for k in ('session_id', 'challenge')}, self.binding, self.policy)
        self.session = opened['session_id']
        return opened

    def discover(self):
        return self.gateway.dispatch('tisra', 'application.models.discover.v1', {'session_id': self.session}, self.binding)

    def request(self, **changes):
        args = {'schema_version': 1, 'session_id': self.session, 'catalog_version': self.discover()['catalog_version'],
            'request_id': str(uuid.uuid4()), 'request_sha256': 'a'*64, 'task_kind': 'research',
            'package_id': 'high', 'priority': 'explicit', 'deadline_ms': 30000,
            'thinking_effort': 'high', 'service_tier': 'default', 'allow_degradation': False}
        args.update(changes)
        return args

    def submit(self, args):
        return self.gateway.dispatch('tisra', 'application.models.request.v1', args, self.binding)

    def assert_fault(self, code, action):
        with self.assertRaises(Fault) as error:
            action()
        self.assertEqual(error.exception.code, code)

    def terminal(self, receipt, **changes):
        r = receipt['resolved']
        record = self.gateway.requests.get(('tisra', receipt['request_id']))
        args = dict(binding=self.binding, session_id=self.session, job_id=(record or {}).get('job_id', str(uuid.uuid4())),
            result_sha256='c'*64, model=r['model'], effort=r['effort'], service_tier=r['service_tier'], state='succeeded')
        args.update(changes)
        record = self.gateway.requests.get(('tisra', receipt['request_id']))
        if record and 'job_id' not in record:
            self.gateway.bind_job('tisra', receipt['request_id'], receipt['request_sha256'],
                binding=self.binding, session_id=self.session, job_id=args['job_id'])
        return self.gateway.correlate_result('tisra', receipt['request_id'], receipt['request_sha256'], **args)

    def test_metadata_register_confirm_does_not_grant_data_or_tools(self):
        row = self.registry.snapshot({'tisra': self.policy, 'other': self.policy})[1]
        self.assertEqual((row['id'], row['name'], row['version'], row['icon_ref']),
            ('tisra', 'Tisra / 织语', '0.1.0.6', 'sf:text.book.closed'))
        self.assertEqual(row['authorized_tools'], [])
        self.assertEqual(row['authorization'], 'none')

    def test_five_offers_real_efforts_and_explicit_highest_downgrade(self):
        offers = self.discover()['packages']
        self.assertEqual([p['name'] for p in offers], ['低', '中', '高', '极高', '最高'])
        self.assertEqual([p['effort'] for p in offers], ['low', 'medium', 'high', 'xhigh', 'xhigh'])
        self.assertEqual(offers[-1]['target_effort'], 'max')
        self.assertEqual(offers[-1]['reasons'], ['effort_downgraded'])
        self.assertFalse(self.discover()['execution_authorized'])

    def test_highest_requires_explicit_degradation_and_never_sends_max(self):
        args = self.request(package_id='highest', thinking_effort='xhigh')
        self.assertEqual(self.submit(args)['reasons'], ['degradation_not_allowed'])
        args['allow_degradation'] = True
        receipt = self.submit(args)
        self.assertTrue(receipt['accepted'])
        self.assertEqual(receipt['resolved']['effort'], 'xhigh')
        self.assertEqual(receipt['reasons'], ['effort_downgraded'])
        self.assertFalse(receipt['queue_admitted'])

    def test_unsupported_effort_is_refused_without_substitution(self):
        self.assertEqual(self.submit(self.request(thinking_effort='max'))['reasons'], ['provider_effort_unavailable'])
        self.assertEqual(self.gateway.requests, {})

    def test_priority_effort_speed_are_separate(self):
        receipt = self.submit(self.request(priority='background', thinking_effort='low'))
        self.assertEqual(receipt['resolved']['priority'], 'background')
        self.assertEqual(receipt['resolved']['effort'], 'low')
        self.assertEqual(receipt['resolved']['service_tier'], 'default')
        self.assertEqual(receipt['reasons'], ['explicit_effort_override'])
        self.assertEqual(self.submit(self.request(priority='interactive', service_tier='fast'))['reasons'], ['fast_authorization_required'])

    def test_queue_policy_and_deadline_refusals(self):
        restricted = AppPolicy(frozenset(), methods=METHODS)
        self.gateway.policies['tisra'] = restricted
        self.assertEqual(self.submit(self.request(priority='interactive'))['reasons'], ['priority_not_authorized'])
        self.assertEqual(self.submit(self.request(deadline_ms=60001))['reasons'], ['deadline_not_authorized'])

    def test_catalog_changed_and_stale_do_not_accept(self):
        args = self.request()
        self.snapshot['models'][0]['efforts'].append({'id': 'max', 'description': ''})
        self.assertEqual(self.submit(args)['reasons'], ['catalog_changed'])
        self.snapshot['selection_enabled'] = False
        self.assert_fault('application_models_catalog_unavailable', self.discover)

    def test_normalized_empty_catalog_keeps_capabilities_and_all_packages_unavailable(self):
        for source in ('app_server_model_list', 'test_double'):
            self.snapshot = {'schema_version': 1, 'source': source, 'selection_enabled': False, 'models': []}
            discovery = self.discover()
            self.assertFalse(discovery['catalog_available'])
            self.assertEqual(discovery['catalog_source'], source)
            self.assertIn(ICON_METHOD, discovery['capabilities'])
            self.assertEqual([p['package_id'] for p in discovery['packages']],
                ['low', 'medium', 'high', 'very_high', 'highest'])
            for package in discovery['packages']:
                self.assertFalse(package['available'])
                self.assertIsNone(package['model'])
                self.assertIsNone(package['effort'])
                self.assertEqual(package['supported_efforts'], [])
                self.assertEqual(package['reasons'], ['package_unavailable'])
                receipt = self.submit(self.request(package_id=package['package_id']))
                self.assertFalse(receipt['accepted'])
                self.assertEqual(receipt['reasons'], ['package_unavailable'])
                self.assertIsNone(receipt['resolved'])
            self.assertEqual(self.gateway.requests, {})

    def test_empty_and_stale_catalog_allow_post_discovery_real_icon_registration(self):
        for source in ('test_double', 'app_server_model_list'):
            # Existing app session metadata remains usable after source stale.
            self.snapshot = {'schema_version': 1, 'source': source, 'selection_enabled': False, 'models': [],
                'current': {'model': 'previous-selection-is-not-an-available-model'}}
            self.open()
            discovery = self.discover()
            self.assertFalse(discovery['catalog_available'])
            reply = self.register_icon()
            read = self.gateway.read_icon('tisra', reply['sha256'])
            self.assertEqual(read['png_base64'], actual_icon()['png_base64'])
            self.assertEqual(read['bytes'], actual_icon()['byte_count'])
            self.assertEqual(self.submit(self.request())['reasons'], ['package_unavailable'])
        self.assertEqual(self.gateway.requests, {})

    def test_malformed_snapshot_is_not_normalized_into_unavailable_catalog(self):
        valid = synthetic_catalog()
        snapshots = [None, {}, dict(valid, schema_version=True), dict(valid, source='unavailable'),
            dict(valid, selection_enabled=0, models=[]), dict(valid, selection_enabled=True, models=[]),
            dict(valid, selection_enabled=False), dict(valid, models=[{}]),
            dict(valid, models=[None]), dict(valid, models=[valid['models'][0], valid['models'][0]])]
        invalid_default = copy.deepcopy(valid)
        invalid_default['models'][0]['default_effort'] = 'unsupported'
        snapshots.append(invalid_default)
        for snapshot in snapshots:
            self.snapshot = snapshot
            self.assert_fault('application_models_catalog_unavailable', self.discover)

    def test_available_catalog_version_changes_when_normalized_catalog_expires(self):
        request = self.request()
        self.assertTrue(self.discover()['catalog_available'])
        self.snapshot = {'schema_version': 1, 'source': 'test_double', 'selection_enabled': False, 'models': []}
        self.assertEqual(self.submit(request)['reasons'], ['catalog_changed'])
        self.assertEqual(self.submit(self.request())['reasons'], ['package_unavailable'])

    def test_unknown_effort_only_catalog_does_not_invent_packages(self):
        self.snapshot['models'][0]['efforts'] = [{'id': 'custom', 'description': ''}]
        self.snapshot['models'][0]['default_effort'] = 'custom'
        self.assertTrue(all(not p['available'] for p in self.discover()['packages']))
        self.assertEqual(self.submit(self.request())['reasons'], ['package_unavailable'])

    def test_fast_unavailable_is_distinct_from_not_authorized(self):
        self.snapshot['models'][0]['fast_available'] = False
        self.assertEqual(self.submit(self.request(service_tier='fast'))['reasons'], ['provider_service_tier_unavailable'])

    def test_identity_session_revocation_and_reconnect(self):
        args = self.request()
        self.live = False
        self.assert_fault('app_identity_unverified', lambda: self.submit(args))
        self.live = True
        self.registry.revoke('tisra')
        self.assert_fault('method_not_authorized', lambda: self.submit(args))
        self.registry.register(AppDescriptor('tisra', 'Host', 'sf:app'))
        self.open()
        self.assert_fault('app_session_changed', lambda: self.submit(args))

    def test_foreign_binding_and_expiry(self):
        self.assert_fault('app_session_changed', lambda: self.gateway.dispatch('tisra', 'application.models.discover.v1',
            {'session_id': self.session}, ('other-binding', lambda: True)))
        self.now += 31
        self.assert_fault('app_session_changed', self.discover)

    def test_exact_schema_external_icons_and_bad_ids(self):
        self.assert_fault('application_models_invalid_arguments', lambda: self.submit(self.request(callback='https://example.invalid')))
        for changes in ({'schema_version': True}, {'request_id': 'not-uuid'}, {'request_sha256': 'not-hash'}, {'service_tier': 'priority'}, {'service_tier': []}, {'task_kind': []}):
            self.assert_fault('application_models_invalid_arguments', lambda: self.submit(self.request(**changes)))
        self.assert_fault('invalid_app_descriptor', lambda: self.connections.dispatch('tisra', 'connection.open',
            {'client_nonce': 'd'*64, 'name': 'Tisra', 'icon_ref': 'https://example.invalid/icon', 'version': '1', 'capabilities': []}, self.binding, self.policy))

    def test_deduplication_and_changed_request_rejected(self):
        args = self.request()
        first = self.submit(args)
        self.assertEqual(self.submit(args), first)
        self.assertEqual(self.submit(dict(args, thinking_effort='low'))['reasons'], ['request_conflict'])

    def test_result_correlation_and_actual_preferences(self):
        receipt = self.submit(self.request())
        self.assert_fault('application_models_result_mismatch', lambda: self.terminal(receipt, effort='low'))
        result = self.terminal(receipt)
        self.assertEqual(result['request_id'], receipt['request_id'])
        self.assertEqual(result['request_sha256'], receipt['request_sha256'])
        self.assertEqual(result['resolved'], receipt['resolved'])
        self.assert_fault('application_models_result_mismatch', lambda: self.terminal(receipt, result_sha256='d'*64))

    def test_result_hash_owner_session_catalog_and_timeout(self):
        receipt = self.submit(self.request())
        self.assert_fault('application_models_result_mismatch', lambda: self.terminal(receipt, result_sha256='bad'))
        self.assert_fault('application_models_request_changed', lambda: self.gateway.correlate_result('tisra',
            receipt['request_id'], 'b'*64, binding=self.binding, session_id=self.session,
            job_id=str(uuid.uuid4()), result_sha256='c'*64, model='offline-fixture-model', effort='high', service_tier='default', state='succeeded'))
        unbound = self.submit(self.request())
        self.snapshot['models'][0]['fast_available'] = False
        self.assert_fault('application_models_catalog_changed', lambda: self.terminal(unbound))
        self.now += 31
        self.open()
        self.assert_fault('application_models_request_changed', lambda: self.terminal(unbound))

    def test_bound_long_job_survives_resolution_expiry_and_catalog_refresh(self):
        receipt = self.submit(self.request())
        job_id = str(uuid.uuid4())
        self.gateway.bind_job('tisra', receipt['request_id'], receipt['request_sha256'],
            binding=self.binding, session_id=self.session, job_id=job_id)
        self.now += 20
        self.connections.dispatch('tisra', 'connection.ping', {'session_id': self.session}, self.binding, self.policy)
        self.now += 20
        self.snapshot['models'][0]['fast_available'] = False
        # A new negotiation prunes expired unbound resolutions, not admitted work.
        self.assertTrue(self.submit(self.request())['accepted'])
        result = self.terminal(receipt, job_id=job_id)
        self.assertEqual(result['request_id'], receipt['request_id'])
        self.assertEqual(result['catalog_version'], receipt['catalog_version'])

    def register_icon(self, icon=None):
        return self.gateway.dispatch('tisra', ICON_METHOD,
            {'schema_version': 1, 'session_id': self.session, 'icon': icon or actual_icon()}, self.binding)

    def test_actual_icon_bytes_roundtrip_and_metadata_does_not_grant_tools(self):
        icon = actual_icon()
        reply = self.register_icon(icon)
        self.assertTrue(reply['registered'])
        self.assertFalse(reply['display_attested'])
        self.assertEqual(reply['sha256'], icon['sha256'])
        ref = self.gateway.icon_snapshot('tisra')
        self.assertEqual(set(ref), {'app_id', 'sha256', 'mime_type', 'width', 'height', 'bytes'})
        read = self.gateway.read_icon('tisra', icon['sha256'])
        self.assertEqual(base64.b64decode(read['png_base64']), base64.b64decode(icon['png_base64']))
        self.assertEqual(ref['bytes'], actual_icon()['byte_count'])
        self.assertEqual(self.registry.snapshot({'tisra': self.policy, 'other': self.policy})[1]['authorized_tools'], [])
        self.assertEqual(self.registry.snapshot({'tisra': self.policy, 'other': self.policy})[1]['authorization'], 'none')
        # Metadata registration works even when no inference catalog exists.
        self.snapshot = None
        self.assertTrue(self.register_icon()['registered'])

    def test_icon_schema_hash_base64_size_and_external_references_reject(self):
        icon = actual_icon()
        for changes in ({'sha256': 'f'*64}, {'png_base64': 'https://example.invalid/icon'},
                {'source_resource': '/tmp/secret'}, {'source_resource': 'https://example.invalid/icon'},
                {'width': True}, {'byte_count': 8193}, {'png_base64': icon['png_base64']+'\n'},
                {'media_type': 'image/svg+xml'}, {'callback': 'file:///tmp/icon'}):
            candidate = dict(icon, **changes)
            self.assert_fault('application_icon_invalid', lambda: self.register_icon(candidate))
        self.assertIsNone(self.gateway.icon_snapshot('tisra'))

    def test_icon_crc_png_profile_and_trailing_chunks_reject(self):
        raw = base64.b64decode(actual_icon()['png_base64'])
        corrupt = bytearray(raw); corrupt[50] ^= 1
        self.assert_fault('application_icon_invalid', lambda: validate_icon(icon_with_bytes(bytes(corrupt))))
        self.assert_fault('application_icon_invalid', lambda: validate_icon(icon_with_bytes(raw+b'x')))
        header = b'\x89PNG\r\n\x1a\n'+png_chunk(b'IHDR', struct.pack('>IIBBBBB', 64, 64, 8, 6, 0, 0, 0))
        # Valid CRC is insufficient: unknown/animated/metadata chunks stay forbidden.
        animated = header+png_chunk(b'acTL', struct.pack('>II', 1, 0))+raw[33:]
        self.assert_fault('application_icon_invalid', lambda: validate_icon(icon_with_bytes(animated)))

    def test_icon_decompression_is_bounded_and_pixel_shape_checked(self):
        header = b'\x89PNG\r\n\x1a\n'+png_chunk(b'IHDR', struct.pack('>IIBBBBB', 64, 64, 8, 6, 0, 0, 0))
        for pixels in (b'\0' * 1000000, b'\0' * 16447, b'\5'+b'\0'*16447):
            raw = header+png_chunk(b'IDAT', zlib.compress(pixels))+png_chunk(b'IEND', b'')
            self.assert_fault('application_icon_invalid', lambda: validate_icon(icon_with_bytes(raw)))

    def test_icon_expiry_revocation_reconnect_and_exact_hash_read(self):
        reply = self.register_icon()
        self.assert_fault('application_icon_unavailable', lambda: self.gateway.read_icon('tisra', 'd'*64))
        self.assert_fault('application_icon_unavailable', lambda: self.gateway.read_icon('other', reply['sha256']))
        self.now += 31
        self.assertIsNone(self.gateway.icon_snapshot('tisra'))
        self.assert_fault('application_icon_unavailable', lambda: self.gateway.read_icon('tisra', reply['sha256']))
        self.open()
        self.assertIsNone(self.gateway.icon_snapshot('tisra'))
        self.register_icon()
        self.registry.revoke('tisra')
        self.assertIsNone(self.gateway.icon_snapshot('tisra'))
        self.assert_fault('method_not_authorized', self.register_icon)

    def test_icon_optional_capability_preserves_legacy_model_policy(self):
        legacy = AppPolicy(frozenset(), methods=MODEL_METHODS | {'heartbeat'})
        self.gateway.policies['tisra'] = legacy
        self.assertNotIn(ICON_METHOD, self.discover()['capabilities'])
        self.assertTrue(self.submit(self.request())['accepted'])
        self.assert_fault('method_not_authorized', self.register_icon)

    @unittest.skipUnless(shutil.which('swiftc') and TISRA.exists(), 'requires sibling Tisra main checkout and Swift compiler')
    def test_real_swift_consumer_to_python_full_offline_loop(self):
        self.run_swift_fixture()

    @unittest.skipUnless(shutil.which('swiftc') and TISRA.exists(), 'requires sibling Tisra main checkout and Swift compiler')
    def test_unchanged_swift_consumer_registers_real_icon_with_empty_catalog(self):
        self.snapshot = {'schema_version': 1, 'source': 'app_server_model_list', 'selection_enabled': False, 'models': []}
        self.run_swift_fixture(empty_catalog=True)
        self.assertEqual(self.gateway.requests, {})

    def run_swift_fixture(self, *, empty_catalog=False):
        source = TISRA / 'Sources/TisraCore/Research/ARLApplicationModels.swift'
        fixture = ROOT / 'tests/fixtures/TisraApplicationModels.swift'
        output = ROOT / 'build/audit/application-models-20261022.noindex/swift-fixtures'
        output.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='application-models-', dir=output) as directory:
            binary = Path(directory) / 'fixture'
            if empty_catalog:
                # Reuse the already-frozen transport fixture. The temporary main
                # tests the unchanged real consumer; no Tisra source is edited.
                transport = fixture.read_text().split('@main struct ApplicationFixture')[0]
                fixture = Path(directory) / 'EmptyCatalogFixture.swift'
                fixture.write_text(transport + r'''@main struct EmptyCatalogFixture {
    static func main() async throws {
        let transport = FixtureTransport()
        let session = ARLApplicationModelSession { try await transport.call($0, $1) }
        let catalog = try await session.connect(version: "0.1.0.6")
        guard catalog.catalog_source == "app_server_model_list", catalog.packages.count == 5,
              catalog.packages.allSatisfy({ !$0.available && $0.model == nil && $0.effort == nil && $0.reasons == ["package_unavailable"] }) else {
            throw ARLApplicationModelError.incompatible
        }
        let icon = try ARLApplicationIcon(bundleICNSData: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let ack = try await session.registerIcon(icon)
        let bytes = try await transport.call("fixture.iconRead", JSONEncoder().encode(ack))
        struct IconRead: Decodable { let png_base64, sha256: String }
        let read = try JSONDecoder().decode(IconRead.self, from: bytes)
        guard read.png_base64 == icon.png_base64, read.sha256 == icon.sha256 else { throw ARLApplicationModelError.changed }
        do {
            _ = try await session.request(task: .research, requestID: UUID(), requestSHA256: String(repeating: "a", count: 64))
            throw ARLApplicationModelError.incompatible
        } catch ARLApplicationModelError.unavailable { }
        try await session.close()
        try FileHandle.standardOutput.write(contentsOf: Data("{\"fixture\":\"PASS\",\"real_inference\":0}\n".utf8))
    }
}
''')
            built = subprocess.run(['swiftc', '-swift-version', '6', '-parse-as-library',
                '-module-cache-path', str(Path(directory)/'cache'), str(source), str(TISRA/'Sources/TisraCore/Artifacts/ContentHash.swift'), str(fixture), '-o', str(binary)],
                capture_output=True, text=True, timeout=60)
            self.assertEqual(built.returncode, 0, built.stderr)
            child = subprocess.Popen([str(binary), str(TISRA/'assets/Tisra.icns')], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
            count = 0
            frame_sizes = {}
            selector = selectors.DefaultSelector()
            selector.register(child.stdout, selectors.EVENT_READ)
            try:
                while True:
                    self.assertTrue(selector.select(15), 'Swift fixture stalled')
                    line = child.stdout.readline()
                    self.assertTrue(line, 'Swift fixture closed unexpectedly')
                    message = json.loads(line)
                    if message.get('fixture') == 'PASS':
                        self.assertEqual(message['real_inference'], 0)
                        break
                    method, params = message['method'], message['params']
                    self.assertLessEqual(message['request_frame_bytes'], 16384)
                    frame_sizes[method] = message['request_frame_bytes']
                    # Match the real existing ARLClient request envelope/16KiB guard.
                    frame = json.dumps({'protocol': 'arl/1', 'app': 'tisra', 'method': method, 'params': params},
                        separators=(',', ':'), ensure_ascii=False).encode()+b'\n'
                    self.assertLessEqual(len(frame), 16384)
                    if method.startswith('connection.'):
                        result = self.connections.dispatch('tisra', method, params, self.binding, self.policy)
                        if method == 'connection.confirm': self.session = params['session_id']
                    elif method == 'fixture.iconRead':
                        result = self.gateway.read_icon('tisra', params['sha256'])
                        self.assertEqual(result['png_base64'], actual_icon()['png_base64'])
                    elif method == 'fixture.terminal':
                        result = self.terminal(params)
                        count += 1
                    else:
                        result = self.gateway.dispatch('tisra', method, params, self.binding)
                    child.stdin.write(json.dumps(result, ensure_ascii=False)+'\n')
                    child.stdin.flush()
                child.wait(timeout=5)
                self.assertEqual(child.returncode, 0, child.stderr.read())
                self.assertEqual(count, 0 if empty_catalog else 5)
                self.assertIsNone(self.gateway.icon_snapshot('tisra'))
                frame_name = 'ICON-EMPTY-CATALOG-FRAME.json' if empty_catalog else 'ICON-FRAME.json'
                (output.parent/frame_name).write_text(json.dumps({'icon_register_request_bytes': frame_sizes[ICON_METHOD], 'sdk_frame_limit': 16384, 'measured_by': 'Swift JSONEncoder params+exact SDK envelope/newline', 'all_methods': frame_sizes}, indent=2)+'\n')
            finally:
                selector.close()
                if child.poll() is None: child.kill(); child.wait()
                child.stdin.close(); child.stdout.close(); child.stderr.close()
