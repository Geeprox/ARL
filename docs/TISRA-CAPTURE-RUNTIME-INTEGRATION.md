# Optional Tisra capture host

This isolated source implementation is inactive by default. `Runtime(...,
capture=None)` installs no capture tool, route, participant, library or grant.
`CaptureRuntime()` also defaults to `active=False` with empty mappings and no
callbacks. No host transport factory or native grant has been installed. The
frozen `arl/tisra_capture_contract.py`, inner schema and 19 fixtures are unchanged.

`arl/tisra_capture_runtime.py` supplies executable typed dispatch, current
authority gates, immutable payload capability checks and non-replayable delivery
tracking using the actual ARL `Store`. ARL retains IDs, binding metadata and
digests; Tisra retains source/contribution records, exact inner receipts and the
durable source receipt journal. ARL never stores raw request, result or declared
display attribution in its SQLite delivery table or job result.

## Exact API

All requests use the existing `arl/1` Unix RPC envelope. `Handler` passes the
kernel-verified app from `identity_verifier`; capture dispatch requires it to
equal the app namespace, including when the general verifier is absent.
An active engine also requires an installed verifier and the independent live
registered-peer callback described below. Captures reject duplicate JSON keys.
Complete request and response frames, including envelope and newline, cannot
exceed 16,384 bytes. Oversize frames are rejected, never trimmed.

| Method | Exact params | Result |
| --- | --- | --- |
| `capture.capabilities.v1` | `{library_id}` | Current host-derived writer/participant/epoch, library/instance/code/schema pins, fixed limits; does not enroll anything |
| `capture.submit.v1` | `{key, request}` | Delivery projection; `key` must equal `request.capture_request_id`; `request` is the frozen exact outer request |
| `capture.status.v1` | `{capture_request_id, admission_sha256}` | Delivery state, immutable binding, confirmed frozen outer receipt or a `needs_review` receipt |
| `capture.cancel.v1` | `{capture_request_id, admission_sha256}` | Before contact: cancelled; after consumer contact: held for review with unknown external stop |
| `capture.result.read.v1` | `{capture_request_id, admission_sha256, offset, limit}` | Confirmed result capability, base64 chunk and EOF; limit 1–8192 |

The complete inner request limit is 524,288 bytes; complete inner result limit is
32,768 bytes; complete outer receipt limit is 8192 bytes. Chunks preserve exact
bytes. Results exceeding the full limit are held, never truncated. Generic
`submit`/`submit_scheduled` for `tisra.capture.link.v1`, and generic
`get`/`cancel`/`resume` for its jobs, require typed capture methods instead.
The durable caller key is the capture request UUID.

## Host composition dependencies

`CaptureRuntime` receives only trusted host configuration:

* `participants`: actual authenticated app -> `RegisteredCaptureParticipant`
  containing the existing opaque participant ID, actor kind and auth epoch.
* `library_grants`: `(app, participant_id)` -> explicitly allowed library UUIDs.
* `method_grants`: `(app, participant_id, library_id)` -> explicit capture methods.
* `pins` and `consumers`: one selected library -> `CaptureConsumerPin` and its
  separately authenticated native consumer adapter. Pins include library UUID,
  instance UUID, observed consumer executable/code digest, frozen codec and exact
  schema digest. `metadata()` must derive these from the authenticated channel
  and selected Ledger instance; an IPC self-report is insufficient.
* `registered_peer(app, participant) -> bool`: required when active. Query the
  host's current PID/birth/executable registration. Comparing app names or the
  stored job `identity_authorized` boolean is insufficient.
* `authorizer(CaptureAuthority, method) -> bool`: required live permission check.
  Admission first checks library access; after strict validation and before each
  effect it checks the exact immutable admission digest. Native authorization
  must use the real app, registered participant, library, instance and epoch.
* `codec`: host-pinned `CaptureCodec` with the frozen strict request and result
  callbacks. Callbacks consume original bytes, return `None` and do not transform
  input. The result validator receives `(result_bytes, request_bytes, outer_state)`.
* `payload_resolver`: authenticated immutable upload registration adapter.
  `resolve(CapturePayloadRequest)` must return exact `UploadedCapturePayload`
  including owner, capture ID, auth epoch, `tisra.capture.request.v1` purpose,
  payload UUID/hash/count, sealed status, expiry and immutable original bytes.

The existing `ResearchEngine.limits` only admits research payload purposes. It
does **not** provide a capture upload facility. The missing source upload adapter
must register immutable owner/request/epoch/purpose capabilities before resolving
them. This implementation provides no path, URL, arbitrary resolver registration,
shell command, CLI `--app` authority or generalized payload enrollment route.

`CaptureAuthority` and native `LinkCaptureHostAuthority` are non-wire data. Their
auth epoch is the same opaque string as the frozen outer contract, compared as
exact UTF-8 bytes. Do not convert it to an integer, hash it, normalize it or infer
it from attribution. Native authority and journal binding also carry the full
`tisra.link-capture.inner.v1` codec identifier and exact frozen consumer schema
digest; native authorization must supply both pins explicitly.
Native `registeredActorKind` is immutable registered host metadata (`human` or
`agent`) and must match frozen outer `writing_participant.actor_kind` exactly.
It confers no permissions and cannot be inferred from declared attribution.

## Native consumer seam and journal confirmation

The host adapter implements `CaptureConsumer.metadata`, `cached`, `capture`,
`confirm`, `acknowledge` and `report_uncertain`. All are host objects; no IPC
argument chooses, installs or replaces them.

`capture(binding, raw_request, authority, guard)` uses
`guard.perform(actual_effect)` for each effect, with native equivalents atomically
inside each Ledger and journal write. It must also apply Tisra's actual reference
validator and current native authorizer. Merely calling an ARL preflight before
a later native transaction does not meet this contract. The adapter may only
return `CaptureCommit` after observing the native journal, exact inner receipt,
stable transaction/commit timestamp and stable result capability UUID.

`cached(binding, raw_request, authority)` and
`confirm(commit, exact_outer_receipt_bytes, raw_request, authority)` receive the
already checked sealed immutable request bytes directly from ARL. The adapter
must pass those bytes unchanged to native cache and confirmation calls; it needs
no additional resolver or raw request cache.

`confirm` must call native
`confirmDelivery(_:requestBytes:outerReceiptBytes:)`, which re-reads the durable
journal entry and checks exact receipt bytes, transaction and binding against
fresh native authority and live Ledger references. It returns a freshly inspected
`LinkCaptureRuntimeResult`; the adapter must compare its returned binding and
receipt/transaction data with the original host admission. Only after that check
may the trusted adapter return the pure outer `CommitConfirmation`
including the exact outer digest. `journalProof` is integrity metadata; it cannot
alone mint confirmation. Constructing a transaction object, parsing a receipt or
recomputing its proof does not establish a durable commit. The outer confirmation
is minted only by the trusted adapter after that native durable-entry check.
Native confirmation must durably freeze the first exact outer receipt SHA-256
with the bound inner journal entry. Subsequent confirmation and ACK may only
reuse that same digest; neither an arbitrary new outer digest nor a caller
transaction object may mint confirmation. The adapter supplies the digest of
the exact bounded outer bytes it received from ARL and verifies the native
confirmation returns the same frozen `outerReceiptHash` and
`outerReceiptByteCount`. Before invoking native confirmation, the adapter must
strictly validate all outer fields against the observed native binding, receipt
state, transaction, commit timestamp and stable `resultPayloadID`. It must not
allow an RPC-supplied transaction object to choose a native commit. Do not reconstruct request bytes
from parsed JSON, a receipt, a proof, attribution or mutable library content.
ARL validates the bounded result with the strict codec, persists delivery hashes,
then calls `acknowledge` with a fresh guard. Native
`acknowledgeDelivery(_:outerReceiptBytes:)` rechecks current completion authority,
exact transaction/inner receipt and the frozen outer hash/count before ACK.
Any missing callback, callback error, lost ACK, cancel or restart of unfinished
work produces `needs_review`; there is no automatic source replay or reconciliation.
`report_uncertain` may only hold the original journal entry; it may not write or
replay source content. A lost safety notification leaves ARL's durable hold intact.

An already acknowledged success may reuse only the exact cached outer receipt and
result bytes, after current registration/grants/pins, exact request bytes, journal
confirmation and strict live reference validation pass again. Missing or changed
cached evidence holds the delivery. A definite input upload loss may use a new
capability handle for identical logical metadata and exact content; the capture
ID/admission digest/authority cannot change. After input expiry, exact request
bytes must be available through a newly registered identical capability before
cached result validation can succeed. Held attempts remain held even if cached
evidence later appears; manual resolution belongs to the native journal workflow.

The real Ledger validator owns first-writer source deduplication semantics,
contribution writer/version binding, historical source versions and exact
`source`, `bound_source` and `adopted_from` record references in the selected
Ledger, including the referenced source/adoption/version relationships. These are
the frozen capture reference fields. ARL does not infer them from declared
attribution or require a retry peer to overwrite the stored first writer.

## Exact missing binding touchpoints

`arl/service.py` now accepts the optional `capture` engine and delegates typed
dispatch, worker completion, attach and recovery. Its shipped host compositions
have not supplied that engine, a reverse native channel, payload upload adapter,
participant/library/method grants or activation.

The read-only original consumer files
`/Users/<user>/Repository/Tisra/Sources/TisraUI/Runtime/ARLClient.swift` and
`ARLRuntimeConnection.swift` currently implement outgoing ARL Unix requests and
metadata inspection. They do not expose an authenticated reverse capture endpoint.
The explicit host binding factory, current process registration lookup, exact
consumer executable pin and native channel ownership remain required integration
work at those SDK/connection and ARL host composition touchpoints.

The isolated Swift touchpoints are
`TisraCapture/Sources/TisraCore/Import/LinkCaptureRuntimeService.swift` and
`LinkCaptureReceiptJournal.swift`, using actual `LedgerStore`, non-Codable
`LinkCaptureHostAuthority`, `execute(captureID:requestBytes:)`,
`cached(captureID:requestBytes:)`,
`confirmDelivery(_:requestBytes:outerReceiptBytes:)`,
`acknowledgeDelivery(_:outerReceiptBytes:)` and
`reportDeliveryUncertain(captureID:)`. The adapter
must map observed `receiptBytes`, `receiptHash`, `transactionID` and `committedAt`
to `CaptureCommit`, using the native stable `resultPayloadID` rather than creating
a new result capability on each retry, then obtain native durable confirmation
before minting outer confirmation. Native returned `binding` is non-Codable audit
metadata and cannot grant authority. The adapter must compare the returned
`outerReceiptHash` and `outerReceiptByteCount` with the exact outer bytes supplied
to confirmation and ACK. It must compare native `codecIdentifier` and
`consumerSchemaSHA256`, current opaque epoch, and code/library/instance pins over
the separately authenticated native channel. `journalProof` supports integrity
checking of the bound native journal data and supplies no independent authority
or durable-entry evidence; no endpoint or proof format has been guessed here.

## Focused evidence

`python3 -m unittest tests.test_tisra_capture_runtime` uses the actual isolated ARL
SQLite Store, typed Runtime dispatch, worker and Unix Handler. Only the consumer,
upload capability resolver, live registration/authorizer and strict fixture pair
validators are synthetic doubles. Tests cover all eight exact frozen fixture
pairs, bounded full inputs/results, independent grants, fresh registration/policy/
epoch/code/schema/instance checks, revocation between effects, typed bypass
rejection, unchanged cached bytes, callback/ACK/cancel/restart holds and no raw
source content in ARL storage. These doubles establish host gate behavior; they
do not establish live authority, production transport or native Ledger semantics.
