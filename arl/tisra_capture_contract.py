"""Future capture-link outer contract only; no fetch, writer or registration.

The T3-owned source/derived codec and source-version semantics are deliberately
pending. Validating this outer binding does not validate that inner payload or
authorize a write. Context comes from the host's authenticated participant and
library/grant mapping, never a CLI display role or request field.
"""
from __future__ import annotations

import hashlib
import json
import math
import re
import uuid
from dataclasses import dataclass
from typing import Callable, Optional

from .contracts import Fault, encode

NAME = 'tisra.capture.link.v1'
REQUEST_PURPOSE = 'tisra.capture.request.v1'
RESULT_PURPOSE = 'tisra.capture.result.v1'
MAX_REQUEST_BYTES = 524288
MAX_RESULT_BYTES = 32768
MAX_OUTER_BYTES = 8192
INNER_CODEC_STATUS = 'pending_t3_source_contract'
RECEIPT_STATES = frozenset({'created', 'deduplicated', 'partial', 'needs_review'})
REQUEST_KEYS = frozenset({'schema_version', 'capture_request_id', 'library_id',
                          'codec', 'consumer_schema_sha256', 'payload', 'declared_attribution'})
REF_KEYS = frozenset({'payload_id', 'sha256', 'byte_count'})
BINDING_KEYS = frozenset({'capture_request_id', 'request_sha256', 'request_bytes',
                          'library_id', 'codec', 'consumer_schema_sha256', 'admission_sha256',
                          'writer_app', 'writing_participant', 'auth_epoch'})
RECEIPT_KEYS = BINDING_KEYS | {'schema_version', 'state', 'commit', 'result_ref'}
CONTRACT_METADATA = {
    'schema_version': 1, 'tool': NAME, 'status': 'future_contract_only_disabled',
    'request_keys': sorted(REQUEST_KEYS), 'receipt_keys': sorted(RECEIPT_KEYS),
    'payload_ref_keys': sorted(REF_KEYS), 'inner_codec': INNER_CODEC_STATUS,
    'receipt_states': sorted(RECEIPT_STATES),
    'limits': {'request_bytes': MAX_REQUEST_BYTES, 'result_bytes': MAX_RESULT_BYTES,
               'outer_bytes': MAX_OUTER_BYTES},
    'identity': 'host_verified_registered_participant_not_declared_display_role',
    'scope': 'one_host_pinned_personal_library_no_caller_path_or_registration',
    'result_validation': 'strict_frozen_codec_checks_result_request_and_outer_receipt_state',
    'strict_callbacks': {
        'request': 'request(bytes)->None',
        'result': 'result(result_bytes,request_bytes,outer_state)->None',
    },
    'writes': 'none_source_contract_pending_no_automatic_retry',
}
CONTRACT_SHA256 = hashlib.sha256(encode(CONTRACT_METADATA)).hexdigest()


def _exact(value, keys):
    if type(value) is not dict or set(value) != set(keys):
        raise Fault('capture_invalid_arguments')


def _string(value, maximum=200, *, nullable=False):
    if value is None and nullable:
        return
    if type(value) is not str:
        raise Fault('capture_invalid_arguments')
    try:
        count = len(value.encode('utf-8', errors='strict'))
    except UnicodeError:
        raise Fault('capture_invalid_arguments') from None
    if not 1 <= count <= maximum or any(ord(c) < 32 or ord(c) == 127 for c in value):
        raise Fault('capture_invalid_arguments')


def _uuid(value):
    if type(value) is not str:
        raise Fault('capture_invalid_arguments')
    try:
        valid = str(uuid.UUID(value)) == value
    except (ValueError, AttributeError):
        valid = False
    if not valid:
        raise Fault('capture_invalid_arguments')


def _digest(value):
    if type(value) is not str or re.fullmatch('[a-f0-9]{64}', value) is None:
        raise Fault('capture_invalid_arguments')


def _participant(value):
    # Preserve the existing CaptureParticipant's opaque identity domain. No
    # UUID invention, case-folding, display-role mapping or whitespace trimming.
    _string(value, 128)
    if any(char.isspace() for char in value):
        raise Fault('capture_invalid_arguments')


def _integer(value, low, high):
    if type(value) is not int or not low <= value <= high:
        raise Fault('capture_invalid_arguments')


def _ref(value, maximum):
    _exact(value, REF_KEYS)
    _uuid(value['payload_id'])
    _digest(value['sha256'])
    _integer(value['byte_count'], 1, maximum)


def _utf8_tree(value):
    if type(value) is str:
        value.encode('utf-8', errors='strict')
    elif type(value) is list:
        for item in value:
            _utf8_tree(item)
    elif type(value) is dict:
        for key, item in value.items():
            key.encode('utf-8', errors='strict')
            _utf8_tree(item)
    elif type(value) is float and not math.isfinite(value):
        raise ValueError('nonfinite number')


def parse_outer(raw):
    """Strict complete JSON decoding for the bounded outer request/receipt."""
    if type(raw) is not bytes or not 1 <= len(raw) <= MAX_OUTER_BYTES:
        raise Fault('capture_outer_too_large')
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError('duplicate key')
            result[key] = value
        return result
    def invalid_constant(value):
        raise ValueError('nonfinite constant')
    try:
        value = json.loads(raw.decode('utf-8', errors='strict'),
                           object_pairs_hook=pairs, parse_constant=invalid_constant)
        _utf8_tree(value)
    except (ValueError, UnicodeError, RecursionError):
        raise Fault('capture_invalid_arguments') from None
    return value


def submission_body(value):
    """Validate exact outer fields only; source author/content live in T3 codec."""
    if type(value) is bytes:
        value = parse_outer(value)
    _exact(value, REQUEST_KEYS)
    _integer(value['schema_version'], 1, 1)
    _uuid(value['capture_request_id'])
    _uuid(value['library_id'])
    _string(value['codec'])
    _digest(value['consumer_schema_sha256'])
    _ref(value['payload'], MAX_REQUEST_BYTES)
    declared = value['declared_attribution']
    if declared is not None:
        _exact(declared, {'role', 'display_name'})
        _string(declared['role'], nullable=True)
        _string(declared['display_name'], nullable=True)
    try:
        if len(encode(value)) > MAX_OUTER_BYTES:
            raise Fault('capture_outer_too_large')
    except (UnicodeError, ValueError, RecursionError):
        raise Fault('capture_invalid_arguments') from None
    return value


@dataclass(frozen=True)
class CaptureContext:
    """Trusted host context, never decoded from IPC JSON or a CLI --role.

    The host must establish the transport app, stable opaque registered participant,
    personal library and grant independently. Actor kind describes the peer;
    it confers no permissions. Both human and agent peers require write_granted.
    A source codec pin does not enable this future contract automatically.
    """
    writer_app: str
    participant_id: str
    actor_kind: str
    library_id: str
    auth_epoch: str
    codec: Optional[str] = None
    consumer_schema_sha256: Optional[str] = None
    active: bool = False
    write_granted: bool = False


@dataclass(frozen=True)
class CaptureBinding:
    """An immutable outer identity; not a validated inner request or a write."""
    capture_request_id: str
    request_sha256: str
    request_bytes: int
    library_id: str
    codec: str
    consumer_schema_sha256: str
    admission_sha256: str
    writer_app: str
    participant_id: str
    actor_kind: str
    auth_epoch: str

    def wire(self):
        return {
            'capture_request_id': self.capture_request_id,
            'request_sha256': self.request_sha256, 'request_bytes': self.request_bytes,
            'library_id': self.library_id, 'codec': self.codec,
            'consumer_schema_sha256': self.consumer_schema_sha256, 'admission_sha256': self.admission_sha256,
            'writer_app': self.writer_app,
            'writing_participant': {'participant_id': self.participant_id,
                                    'actor_kind': self.actor_kind},
            'auth_epoch': self.auth_epoch,
        }


@dataclass(frozen=True)
class CaptureCodec:
    """Host-supplied frozen T3 codec, never selected by a payload callback/path.

    Both callbacks validate exact original bytes and return None, not transformed
    input. The result callback also checks the outer receipt state against all
    inner per-record outcomes/failures; it must reject a success classification
    for partial results. They must be pure, strict and bounded. Configuring one
    does not install a route, grant, writer, fetcher, participant or library.
    """
    name: str
    consumer_schema_sha256: str
    validate_request: Callable[[bytes], None]
    validate_result: Callable[[bytes, bytes, str], None]


@dataclass(frozen=True)
class CommitConfirmation:
    """Acknowledgement from the separately trusted pinned Tisra writer context.

    Not an IPC type. The host creates it only after Tisra confirms per-record
    outcomes and durable receipt journal, or verifies original cached evidence.
    transaction_id identifies that future receipt/journal commit; it does not
    assert one atomic transaction for the whole source/contribution batch.
    Calling a pure receipt parser cannot manufacture transaction evidence.
    """
    library_id: str
    capture_request_id: str
    transaction_id: str
    receipt_sha256: str


def _codec_matches(codec, name, pin):
    if type(codec) is not CaptureCodec:
        raise Fault('capture_codec_unavailable')
    _string(codec.name)
    _digest(codec.consumer_schema_sha256)
    if not callable(codec.validate_request) or not callable(codec.validate_result):
        raise Fault('capture_codec_unavailable')
    if (codec.name, codec.consumer_schema_sha256) != (name, pin):
        raise Fault('capture_codec_unsupported')


def _validate_inner(callback, *args):
    try:
        if callback(*args) is not None:
            raise ValueError('validator must not transform bytes')
    except Exception:
        raise Fault('capture_inner_invalid') from None


def validate_outer(params, raw_payload, context):
    """Bind supplied exact bytes to trusted context without executing or fetching.

    T3's separately pinned inner validator must still validate the source/derived
    envelope. This helper intentionally cannot make an executable writer plan.
    """
    params = submission_body(params)
    if type(context) is not CaptureContext:
        raise Fault('capture_context_unverified')
    _string(context.writer_app)
    _participant(context.participant_id)
    _uuid(context.library_id)
    _string(context.auth_epoch)
    if type(context.actor_kind) is not str or context.actor_kind not in {'human', 'agent'}:
        raise Fault('capture_context_unverified')
    if type(context.active) is not bool or type(context.write_granted) is not bool:
        raise Fault('capture_context_unverified')
    if not context.active:
        raise Fault('capture_disabled')
    if not context.write_granted:
        raise Fault('capture_not_authorized')
    if params['library_id'] != context.library_id:
        raise Fault('capture_library_not_authorized')
    if context.codec is None or context.consumer_schema_sha256 is None:
        raise Fault('capture_codec_unavailable')
    _string(context.codec)
    _digest(context.consumer_schema_sha256)
    if (params['codec'], params['consumer_schema_sha256']) != (context.codec, context.consumer_schema_sha256):
        raise Fault('capture_codec_unsupported')
    if type(raw_payload) is not bytes or not 1 <= len(raw_payload) <= MAX_REQUEST_BYTES:
        raise Fault('capture_request_too_large')
    ref = params['payload']
    if len(raw_payload) != ref['byte_count'] or hashlib.sha256(raw_payload).hexdigest() != ref['sha256']:
        raise Fault('capture_payload_mismatch')
    # Payload handles may change after a definite upload loss. Immutable logical
    # metadata and exact body hash cannot change for the same request identity.
    logical = {key: value for key, value in params.items() if key != 'payload'}
    logical['payload'] = {'sha256': ref['sha256'], 'byte_count': ref['byte_count']}
    admission = hashlib.sha256(encode(logical)).hexdigest()
    return CaptureBinding(params['capture_request_id'], ref['sha256'], len(raw_payload),
                          context.library_id, context.codec, context.consumer_schema_sha256,
                          admission, context.writer_app, context.participant_id,
                          context.actor_kind, context.auth_epoch)


def validate_request(params, raw_payload, context, *, codec=None):
    """Outer guard plus a matching host-pinned strict consumer codec; no write."""
    binding = validate_outer(params, raw_payload, context)
    _codec_matches(codec, binding.codec, binding.consumer_schema_sha256)
    _validate_inner(codec.validate_request, raw_payload)
    return binding


def receipt_body(value, binding, *, confirmation=None):
    """Check a future outer receipt; commit evidence must originate in Tisra.

    This is validation, not proof of a transaction by itself. Only the pinned
    Tisra writer can publish it after observing the per-record outcomes and receipt
    journal commit. T3 currently commits source/contributions separately. A partial
    receipt preserves known outcomes/failures and never claims whole-batch success.
    """
    if type(value) is bytes:
        value = parse_outer(value)
    _exact(value, RECEIPT_KEYS)
    _integer(value['schema_version'], 1, 1)
    if type(binding) is not CaptureBinding:
        raise Fault('capture_receipt_mismatch')
    if any(type(value[key]) is not type(expected) or value[key] != expected
           for key, expected in binding.wire().items()):
        raise Fault('capture_receipt_mismatch')
    state = value['state']
    if type(state) is not str or state not in RECEIPT_STATES:
        raise Fault('capture_receipt_mismatch')
    if state == 'needs_review':
        if value['commit'] is not None or value['result_ref'] is not None:
            raise Fault('capture_receipt_mismatch')
    else:
        _exact(value['commit'], {'transaction_id', 'committed_at_ms'})
        _uuid(value['commit']['transaction_id'])
        _integer(value['commit']['committed_at_ms'], 1, 9007199254740991)
        _ref(value['result_ref'], MAX_RESULT_BYTES)
        if type(confirmation) is not CommitConfirmation:
            raise Fault('capture_commit_unconfirmed')
        if (confirmation.library_id != binding.library_id or
                confirmation.capture_request_id != binding.capture_request_id or
                confirmation.transaction_id != value['commit']['transaction_id'] or
                confirmation.receipt_sha256 != hashlib.sha256(encode(value)).hexdigest()):
            raise Fault('capture_commit_unconfirmed')
    return value


def validated_result(receipt, binding, raw_result, raw_request, *, codec=None, confirmation=None):
    """Verify bytes and outer state with the pinned T3 validator after commit."""
    receipt = receipt_body(receipt, binding, confirmation=confirmation)
    if receipt['state'] == 'needs_review':
        raise Fault('capture_not_committed')
    _codec_matches(codec, binding.codec, binding.consumer_schema_sha256)
    if type(raw_request) is not bytes or len(raw_request) != binding.request_bytes or hashlib.sha256(raw_request).hexdigest() != binding.request_sha256:
        raise Fault('capture_payload_mismatch')
    ref = receipt['result_ref']
    if type(raw_result) is not bytes or not 1 <= len(raw_result) <= MAX_RESULT_BYTES:
        raise Fault('capture_result_too_large')
    if len(raw_result) != ref['byte_count'] or hashlib.sha256(raw_result).hexdigest() != ref['sha256']:
        raise Fault('capture_payload_mismatch')
    _validate_inner(codec.validate_result, raw_result, raw_request, receipt['state'])
    return raw_result


def replay_decision(current, previous=None, receipt=None, *, attempt_recorded=False, confirmation=None):
    """Pure journal decision; never issues or retries a write.

    A lost commit acknowledgement or an incomplete receipt stays needs_review.
    Only an exact cached committed receipt can be reused without another effect.
    A first_attempt decision is bookkeeping, not permission or an action claim.
    """
    if type(current) is not CaptureBinding or type(attempt_recorded) is not bool:
        raise Fault('capture_invalid_arguments')
    if previous is None:
        if receipt is not None:
            raise Fault('capture_receipt_mismatch')
        return 'needs_review' if attempt_recorded else 'first_attempt'
    if type(previous) is not CaptureBinding or current != previous:
        raise Fault('capture_idempotency_conflict')
    if receipt is None:
        return 'needs_review'
    checked = receipt_body(receipt, previous, confirmation=confirmation)
    return 'needs_review' if checked['state'] == 'needs_review' else 'cached_receipt'
