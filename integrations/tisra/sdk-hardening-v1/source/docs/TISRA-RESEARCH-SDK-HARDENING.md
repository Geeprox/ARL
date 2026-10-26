# Source SDK correction, 2026-10-01

This is the bounded follow-up to TISRA-RESEARCH-CONSUMER-FOLLOWUP.md. That coordination note and the frozen Notes host candidate are unchanged. The Python SDK and standalone Swift research wrapper now fix authorization-revision matching and cleanup of known input payloads on aborted upload/submission. No Tisra repo/Ledger/shared Swift client/UI/server/store/authorization gate/format was changed. No provider, socket listener, production grant, upload of personal evidence or model call was enabled.

## Interface for Tisra owner

Wire schema remains source API v1; existing payload/research RPCs and all three request/output/history formats are unchanged. Original request bytes are not wrapped into the descriptor's budget or reserialized; explicit null parent fields remain in `ARLResearchDescriptor.wire`. Codex text remains a different contract and cannot satisfy Responses negotiation or the4096 hard token cap.

Swift:

```swift
try await client.submit(rawRequest: raw, descriptor: descriptor, epoch: epoch,
    provider: provider, modelFingerprint: fingerprint,
    onPayloadCreated: { record in
        // Complete a durable cancellation/upload record BEFORE returning.
        // Must still persist when the submit task has just been canceled.
        try await uploadLedger.persist(record)
    })
// On ARLResearchCleanupPending, persist payloadIDs, retain run/cancel
// tombstones, reconnect under the same owner, then explicitly:
try await client.cleanupPayloads(pending.payloadIDs)
```

The optional new `onPayloadCreated` closure is `@Sendable (ARLResearchPayloadRecord) async throws -> Void`. The record is Codable/Sendable with owner, run_id, purpose, payload_id, sha256, epoch, byte_count; no raw body, evidence values or secrets. A known canonical ID is recorded immediately after begin, before any writes and before the post-begin cancellation check. Persistence failure aborts and cleans up. Existing call sites still compile without the optional callback; **durable product acceptance requires the consumer to supply it**, persist its run/request before begin, and retain the original accepted receipt/auth epoch separately. This wrapper does not write or replace the Ledger.

Python `upload` and `submit` add optional keyword arguments `cancelled` (zero-argument bool callback) and `on_payload_created` (synchronous durable callback with the same snake_case record). Known IDs are tracked across both request and descriptor uploads. `cleanup_payloads(ids)` makes one bounded owner-bound revoke pass. A failure raises `PayloadCleanupPending` with code `payload_cleanup_pending` and `payload_ids`; explicit later recovery uses the same method. No pending IDs are hidden in generic logs or silently treated as cleared.

## Exact matching and cancellation behavior

- The first accepted receipt pins auth_epoch (atomic across concurrent Python receipt checks). Python retains a pin for owner/job/run/hash/epoch and validates a persisted baseline before status/cancel, including a fresh SDK instance. Swift retains a job pin and passes the submission's immutable original auth_epoch on every status/cancel and therefore both response-read status checks. A drift is `research_receipt_mismatch`, never a new accepted authorization.
- Reject noncanonical UUIDs, malformed result references, unknown receipt/ref fields, empty/control auth revisions, incompatible result/state/error/cancel combinations. Success requires a result ref, no error and no cancel; non-success cannot carry a result ref; queued/running cannot carry error/cancel. Queued cannot claim external started. Cancellation/expiry state may legitimately have cancel_requested=false, so that alone is not rejected. No guarantee of upstream stop/refund is added.
- Check cancellation before/after begin, writes, seal and submit, including before an existing same-index write or same-run submit reconnect retry. Retry never creates another logical run. On any aborted path, revoke every known input handle, including an already sealed request when the descriptor upload fails, or both handles when submit acknowledgements are lost. Existing server invalidation then prevents result publication/read for a possibly accepted run.
- Swift revoke runs in a detached uncanceled task, bounded by existing RPC timeouts. Cancellation of the submitting task does not cancel cleanup. All known IDs are attempted even if one fails; pending IDs remain explicit. After successful cleanup, the original cancellation/error is rethrown. This is local cancellation/admission handling, not proof that a nonpreemptible external call stopped.
- **Lost begin acknowledgement:** server chooses the opaque ID and v1 has no lookup-by-run or client-chosen begin idempotency key. If the ack is lost before the ID reaches the SDK, that ID cannot be actively revoked by this client. Begin is not retried. Preserve an uncertain upload/run tombstone; server TTL/bounded maintenance is a remaining protocol limitation, not a reported successful cleanup. No new endpoint or schema was invented to hide it.

Consumer still validates genuine provider evidence/fingerprint/complete limits and independently persists owner/job/run/requestHash/epoch/authEpoch + cancellation binding. `capabilities()` is still a raw metadata read, not automatic provider acceptance. Consumer must discard stale/IME/revoked results and recheck its local cancellation/ledger epoch before committing any result; these changes do not authorize the product or migrate old research bytes.

## Focused reproduction

```sh
python3 -B -m unittest tests.test_research_client tests.test_research_sdk_swift -v
xcrun swiftc -swift-version 6 -module-cache-path .run/research-sdk-fix-cache \
  -typecheck examples/ARLClient.swift integrations/tisra/ARLResearchClient.swift
```

10 Python groups use a private temp SQLite store/direct dispatch;7 Swift groups compile the real wrapper with a test-only injected exchange. No listener/provider call. Tests cover first auth pin/status/cancel/final read, persisted baseline, UUID/state/ref rejection, cancellation at begin/write/seal, observer failure, second upload failure, lost submit receipts, uncanceled cleanup, partial revoke failure and explicit recovery, and lost begin with no unsafe retry. Selected existing byte-preservation/cancel/CAS/owner/dedupe/format checks run independently. The first test-selection attempt mistakenly imported an existing TestCase, collecting its real socket test; that bind failed under sandbox restrictions. The import is corrected, and no bind retry/escalation/alternate socket was performed. These results do not re-prove registered real IPC.

## Remaining Notes IPC work, unchanged

The frozen Notes host candidate needs an owner-controlled immutable parent with full dependency closure/code pin and fixed child FD handoff; helper-pin verification and kernel peer proof on both ends; a single receive owner with independent bound cancel writes and create-vs-cancel acknowledgement demultiplexing; then real registered process/EOF/expiry/reconnect-no-replay tests. No shared Python interpreter identity. Target metadata setup/TCC and genuine UI/create remain separately approved steps. Its native-review path still requires an awake local user; the headless locked Mio workflow is not implemented by this SDK increment. Friday safeguard-blocked review is not retried.
