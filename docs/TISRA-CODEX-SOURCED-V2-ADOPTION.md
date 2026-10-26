# Tisra citation-preserving Codex v2: consumer adoption handoff

2026-10-01. This is a source-only handoff for Tisra's existing T2 research route.
It describes the consumer changes needed to adopt the separate sourced native
contract. The existing T2 owner is task `01a0f779-ccf8-7333-8eab-238f3527f021`.
Its current delegated scope is **codec-only**: native format/codec, source
projection, public history and result/citation validation. Ledger migration,
`ResearchService`, executor integration and UI changes belong to distinct future
owners or separately scoped follow-ups, not the current T2 codec lane. It does
not claim consumer acceptance, an installed capability, a
production grant, deployment or live inference. `/Users/<user>/Repository/Tisra`
is active WIP and was inspected read-only. Its owning task must apply any consumer
changes. No duplicate development thread was created. Automatic approval review
blocked the earlier coordinator message for missing recognized destination
authorization; it was not retried. After T2 explicitly requested the contract,
the frozen schema, pins, fixture paths and bounds were successfully sent to the
existing T2 owner above. This document remains the local adoption handoff.

The earlier [native implementation guide](TISRA-CODEX-NATIVE-IMPLEMENTATION.md)
describes the historical text-only v1 candidate. It is not an acceptable substitute
for this citation-preserving v2 path. Reviewed input bindings alone do not prove
that an answer contains valid generated citations.

## Pinned provider evidence and distinct limits

The current official [Codex App Server documentation](https://learn.chatgpt.com/docs/app-server)
describes `turn/start.outputSchema`, including a structured output example. It also
states that generated schemas are specific to the CLI version used. The local
version-matched source evidence is
[packaged TurnStartParams.json](../integrations/codex/schema-current/TurnStartParams.json), SHA256
`2dfcf68705896fadc344ccfeb2e9fe5a6bcbbb8b9a90cf449ce232b636daf05a`.
Its `outputSchema` property is present and constrains the final assistant message.
The inspected binary SHA256 is
`50ac633af64851511f9bbc71032cdae7f1ba20b3234c189687d61ba846c354c5`;
verify this exact pin against the finalized delivery manifest before host adoption.
The inspected CLI reports `codex-cli 0.159.2`. The existing adapter's
`model_evidence.protocol_version = "0.159.0"` identifies its pinned protocol
contract baseline; it does not claim the installed CLI has that release number.
The source schema,
adapter control/schema pin and binary pin must remain distinct evidence.

`outputSchema` support permits the fixed v2 `{text,citations}` generated body.
ARL supplies one constant provider schema, with every key required and extra keys
forbidden, using the supported basic JSON Schema subset. The caller cannot pass
an arbitrary schema. Provider constraints never replace strict local parsing,
byte/count limits, source binding and quote/range validation of the final body.
It does not provide an upstream output-token or cost hard cap. Native descriptor
`maximumOutputTokens` and submit `max_output_tokens` must be explicit `null`;
`token_hard_cap_supported` remains `false`. Do not fabricate a 4096-token limit or
cost/usage evidence. If the product requires either hard cap, adoption stays
blocked on that requirement independently of citation support. Byte bounds and
the absolute deadline do not prove a billing cap or immediate upstream stop.

The packaged [schema evidence](../integrations/codex/schema-current/evidence.json)
also checks stable and experimental `TurnStartParams`, `ThreadStartParams` and
the typed `Config` definition from the same binary. No supported hard output-token
field is exposed. Arbitrary `thread/start.config` overrides are not proof of
an enforced upstream limit. This is a limitation of the pinned supported path,
not a claim about all future Codex versions. To preserve a mandatory hard-cap
requirement, keep native execution unavailable until upstream exposes a verified
cap, or separately select the existing Responses route with its explicit token
budget and structured citations. That selection needs its own authorized route;
it is never an automatic fallback. Neither alternative removes evidence fields,
changes original references, silently truncates input or triggers a call now.

| Contract or limit | Sourced native v2 value |
| --- | --- |
| Tool | `tisra.codex.research.v2` |
| Request / result / public history | `tisra.codex.request.v2` / `tisra.codex.result.v2` / `tisra.codex.history.v2` |
| Descriptor purpose / format / version | `tisra.codex.descriptor.v2` / `tisra.codex.v2` / `2` |
| Native content schema version | `2` |
| Existing `arl/1` RPC schema version | `1` |
| Existing native RPC methods | `codex.research.capabilities.v1`, `codex.research.submit.v1`, `codex.research.status.v1`, `codex.research.cancel.v1`; `codex.payload.begin.v1`, `write.v1`, `seal.v1`, `read.v1`, `revoke.v1` |
| Complete original request / provider text | Each at most 8192 UTF-8 bytes |
| Separate descriptor | At most 32768 bytes |
| Generated text | At most the submitted `max_output_bytes`, ceiling 32768 UTF-8 bytes |
| Complete generated `{text,citations}` body | At most 32768 serialized bytes, independently of text length |
| Result envelope | At most 262144 serialized bytes and the descriptor's tighter limit |
| Flat evidence parts / citations / public history pairs | At most 100 / 50 / 20; entire request still must fit 8192 bytes |
| Provider turns / automatic inference retries | 1 / 0 |
| Deadline | At most 30000 ms, fixed from submission including queue wait |

The generated-body bound includes JSON keys, escaping and all citations. A text
that fits `maximumTextBytes` can still overflow the complete-body limit. A large
local evidence snapshot, a 512 KiB Responses payload or twenty prior turns do
not gain native acceptance from the existing storage capacity. Reject every
excess explicitly before upload/admission; never trim fields, units, history,
quotes, references or answer bytes, summarize, change account/model or fall back
to a paid provider. Provider protocol frame limits are additional independent
transport bounds.

## Current Tisra contracts that require explicit adoption

The inspected files expose a Responses-only route:

- `Sources/TisraCore/Research/ResearchExecution.swift`: the sole
  `ResearchPayloadFormat.openAIResponsesV1`; descriptor token limit is a non-null
  `Int`; snapshot bindings already hash complete sorted-key snapshot encoding.
- `Sources/TisraCore/Research/ResearchModels.swift`: `ResearchRun.version == 1`,
  a Responses-shaped `request`, and a replayable Responses `response.output`
  array. `ResearchFieldKey.requireKnown` rejects unknown run fields, deliberately
  preventing a future discriminator from being discarded.
- `Sources/TisraCore/Research/ResearchPayloadCodec.swift`: every run selects the
  Responses codec; native text must not be converted into a Responses envelope.
- `Sources/TisraCore/Storage/LedgerStore+ResearchFormats.swift`: the current
  schema-19 format table CHECKs allow only Responses. Run triggers reject a v2
  version or native discriminator fields and bind newly inserted v1 runs to
  Responses. Removing those guards without replacement would break immutability.
- `Sources/TisraUI/Runtime/ARLResearchExecutor.swift` and
  `ARLResearchContract.swift`: preflight requires the Responses format, 4096-token
  hard cap, 1 MiB result and exact Responses capability/receipt fields.
- `Sources/TisraCore/Research/ResearchRuntimeBinding.swift`: payload purposes are
  Responses-only; an accepted source record is limited to 4096 bytes. The complete
  sidecar in `Storage/LedgerStore+ResearchRuntime.swift` is limited to 8192 bytes.
- `Sources/TisraUI/Runtime/ARLResearchSourceRecord.swift`: restoration pins the
  original acceptance digest, then requires 4096 tokens and a 60000-ms deadline.
  Those fixed checks cannot accept the distinct native v2 policy.

These are explicit compatibility gates, not permission to edit the consumer from
this ARL lane or to broaden the T2 codec delegation. Re-read the owning checkout
before applying changes; WIP can move
after this source review. The sibling `consumer-source-manifest.json` preserves
the earlier consumer snapshot used for the v1 guide; it is not a substitute for
checking the additional v2 models, formats, materials and backup paths above.

## Complete adoption plan and ownership boundaries

Steps 3–5 describe the codec-facing contract for the current T2 owner. References
there to Ledger preparation, persisted models, restore/replication, attachment
resolution or UI mean integration dependencies for separate future owners;
the current codec lane must not edit Ledger, `ResearchService` or UI. Steps 1–2
and 6–9 are distinct future work. Durable run/format migration remains a separate
adoption blocker until that owner implements and verifies it.

1. **Introduce a durable native run discriminator in Core.** In
   `Research/ResearchModels.swift` and `Research/ResearchExecution.swift`, add an
   explicit `ResearchRun` version-2 representation carrying the agreed native
   format and exact v2 request/result/history versions. Native runs must survive
   save/load, JSON decode/re-encode, causal fingerprints, replication and backup
   with that discriminator intact. Keep strict unknown-key and unsupported-version
   rejection in the v1 decoder. Never infer the format from provider/model labels,
   reinterpret a v1 run as native, or silently add a format only in a UI sidecar.
   Represent absent token caps explicitly and keep response/text/body byte limits
   separate. A native result's structured body is not an OpenAI output item array.

2. **Migrate sealed format storage explicitly.** Update
   `Storage/LedgerStore+ResearchFormats.swift` and the owning Ledger migration in
   `Storage/LedgerStore.swift` with a new schema migration, typed v1/v2 insert and
   update guards, immutable per-run wire bindings, and protection against older
   open writers. Keep all existing v1 bytes, parent/fingerprint identities and
   Responses bindings unchanged. Extend `Research/ResearchLineage.swift`,
   `Storage/LedgerStore+ResearchReplication.swift`,
   `LedgerStore+ResearchReplicaApply.swift` and `LedgerStore+Backup.swift` to
   validate/preserve v2 runs. Unsupported peers and legacy readers must fail
   closed; migration must not rewrite an old result into native or manufacture
   a replayable encrypted-reasoning record.

3. **Make the native reviewed request in the existing preparation path.** Update
   `Storage/LedgerStore+Research.swift` (`PreparedResearch`, `prepareResearch`,
   `beginResearch`) and `Research/ResearchPayloadCodec.swift` with a distinct
   native codec. Add a narrow new Core codec file rather than routing through
   `OpenAIRequest.make/decode`. The native request has exactly
   `{schema_version,text,public_history,evidence,migration}`. Preserve its entire
   original UTF-8 byte sequence from review through hashing, upload and provider
   input. No provider-side filesystem, URL or Ledger retrieval is authorized.

   For every reviewed `EvidenceItem` selected by the prepared scope, flatten its
   complete note plus all reviewed extracted units into flat parts with exactly
   `{evidence_id,snapshot_digest,record_id,revision,unit,attachment_sha256,text,title,locator,extraction_state}`.
   A note uses `record.document.plainText`, `unit:null`,
   `attachment_sha256:null`, `locator:null`, including an empty note. Each
   extracted unit uses its original integer `ordinal`, exact
   `text` and exact `locator`; do not stringify the ordinal. Use
   `record.source.title ?? record.document.title` and
   `extractedSummary?.state.rawValue ?? "unavailable"`, matching the current
   source-material projection. Unit ordinals are 0...1999; extracted units require
   a locator and `ready` or `partial`. Keep title, locator and extraction state;
   unavailable/failed extraction never becomes invented body text. Preserve
   already-reviewed text without normalization or trimming. Reject a part-count,
   title/locator/string or complete-request overflow. A smaller scope requires
   a new explicit review, not invisible removal from the prepared evidence.

   `attachment_sha256` is required on every part. An extracted unit supplies the
   canonical lowercase SHA256 from the original `record.source.blobHash`, equal
   to the saved `extractedSummary.blobHash`. Every unit part for that record uses
   the same attachment hash. It is the existing source attachment identity, not
   a hash of unit text, locator or generated output. Reject a missing, malformed
   or mismatched extraction attachment; note parts keep an explicit null even
   when the record also has an attachment. The model cannot invent attachment
   references, and the adapter never fetches blobs, files or URLs from this field.

   `snapshot_digest` must remain SHA256 of the **entire immutable
   `EvidenceSnapshot`** encoded with the existing Swift
   `JSONEncoder.outputFormatting = [.sortedKeys]`, as in `ResearchExecution` and
   `Replication/ReplicatedEvidence.swift`. It includes contexts, records, source
   metadata and extraction values, including material not represented by an
   individual part. Do not hash a flattened projection, note, unit, current live
   record or arbitrary pretty-printing. Multiple records, notes and units can
   share an evidence ID and digest: uniqueness is
   `(evidence_id,record_id,revision,unit)`, not evidence ID alone. One evidence ID
   has one digest; each record has consistent revision/title/extraction state.
   Descriptor evidence deduplicates snapshot ID/digest pairs in first-appearance
   order. Do not use flattened part count as descriptor snapshot count.

4. **Preserve citation identity and validate every citation locally.** Extend
   `Research/ResearchModels.swift` with a versioned citation representation or
   separately persisted v2 validation fields. Keep the original Tisra identity
   `(evidenceID,recordID,revision,unit,quote)`, including `unit:Int?`. Do not append
   digest/range to the UI identity, stringify `unit`, or discard those validation
   fields during persistence. Each native wire citation has exactly the six
   binding fields `evidence_id,snapshot_digest,record_id,revision,unit,attachment_sha256`,
   plus `quote,start_utf8,end_utf8`. Notes require `unit:null` and
   `attachment_sha256:null`; extracted-unit citations require the exact supplied
   canonical attachment SHA256. The original `ResearchCitation.id` continues to
   exclude attachment/snapshot digests and range fields. Duplicate original
   citation identities fail.

   Before successful publication, and again after local restore/replication,
   find the original pinned snapshot on the reviewed causal path; verify its full
   digest, record ID, original revision and original note/unit. For a unit,
   independently recheck `attachment_sha256` against both the original
   `record.source.blobHash` and saved `extractedSummary.blobHash`, including
   consistency across all its unit parts. The adapter validates the exact supplied
   attachment/source binding, quote and range without any blob/file fetch. A
   separate consumer integration owner must use the existing attachment resolver
   and UI for source navigation, after local snapshot/extraction validation;
   the current codec lane adds no resolver, UI or fetch operation. Require integer
   offsets excluding booleans, `0 <= start_utf8 < end_utf8 <= source.utf8.count`,
   valid UTF-8 slice boundaries and exact slice bytes equal to nonempty
   `quote.utf8`. End is exclusive and offsets refer to the whole supplied source
   part, not a shortened quote window. Reject missing sources, changed extraction,
   wrong attachment/snapshot digest/revision/ordinal, normalized text, invalid boundaries, duplicate
   citations and any bad range. An invalid present citation leaves the whole
   generated result `needs_review`; do not silently filter it into a successful
   answer. Do not copy the existing Responses decoder's invalid-citation filtering
   into native v2. Zero citations may preserve the existing missing-citation
   notice; all present citations must pass. An exact
   source passage does not prove the answer's inference true.

   Update `Storage/LedgerStore+ResearchMaterials.swift` and
   `LedgerStore+Backup.swift` together with the native codec: their current checks
   compare Responses `input` and test `String.contains`. They must validate the
   native reviewed request, public history and exact ranges against original
   snapshots before considering restored or replicated output verified.

5. **Use public native history v2 and explicit migration.** Each public pair
   has exactly `{run_id,request_sha256,output_sha256,question,answer,citations}`.
   Include the old pinned source parts needed to validate its citations; missing
   historical material is a rejection, not permission to fetch or drop citations.
   `output_sha256` binds the **v2 public answer/citations projection**, canonical
   `{text:answer,citations}`, using the v2 contract's `output_digest`. It is not a
   text-only hash, full native result-envelope hash or former Responses wire-output
   digest. Keep the immutable old run's original request/result digests separately
   in Ledger; never overwrite them with the projection hash. Preserve original
   accepted request hashes and causal parent references.
   A migration from Responses or another format is a new explicitly reviewed
   alternate path with the frozen migration fields and
   `encrypted_reasoning_replayed:false`. Preserve the old wire output locally;
   project only reviewed public question/answer/citations. For an old citation
   without attachment/range/digest, derive the full snapshot digest and attachment
   binding and review its exact
   original-source occurrence against the trusted saved original snapshot locally.
   Reject migration if that snapshot/occurrence is unavailable; never invent a
   range or relabel an old result as native. Do not replay encrypted
   reasoning, native hidden history, Responses items or a fabricated Responses
   envelope in the native request.

   Add cross-language digest fixtures: `arl.contracts.encode` uses Python
   `json.dumps(..., ensure_ascii=False, sort_keys=True, allow_nan=False)` with its
   default separators. Swift's ordinary sorted-key JSON encoding is a different
   byte representation. The v2 output/history hash must match the frozen contract
   formatter exactly. Keep that hash domain distinct from the existing complete
   Swift snapshot digest and the raw request/result payload hashes.

6. **Extend the sole existing runtime route and scoped SDK.** In
   `Sources/TisraUI/Runtime/ARLResearchExecutor.swift`, `ARLResearchContract.swift`,
   `ARLResearchClient.swift`, `ARLResearchPayloadTransfer.swift` and
   `ARLResearchSDK.swift`, branch on the reviewed durable format, select the exact
   v2 tool/purposes/formats and native `codex.*.v1` methods, and validate exact
   capabilities before reservation/upload. Content version 2 must not silently
   change the native RPC schema version 1. Port or reuse the focused
   `CodexSourcedResearchClient` from `arl/codex_research_client.py` through the
   existing `ARLResearchRPC`/`ARLClient` socket connection. Keep purpose namespaces
   separate from `research.*`/`payload.*`, which remain Responses-only. Validate
   descriptor version 2, null token cap, `maximumTextBytes`, source schema/control
   pins, complete bounds and model/fingerprint evidence. Never relabel
   `implementation_only` evidence as `upstream_api` or accepted live evidence.

7. **Keep restore metadata separate from source validation.** Extend
   `ResearchRuntimeBinding.swift`, `Storage/LedgerStore+ResearchRuntime.swift`,
   `ARLResearchSourceRecord.swift` and `ARLResearchRecovery.swift` for native purposes,
   immutable accepted parameters/first authorization epoch, acknowledged native
   IDs and independently observed terminal/interrupt facts. Preflight the entire
   acceptance record and sidecar against consumer storage limits before upload;
   v2 metadata cannot be trimmed to fit the current 4 KiB/8 KiB bounds. A deliberate
   storage-version/budget change needs its own migration and fixtures.

   Preserve the exact original owner/job/run/request-hash/epoch/first-auth-epoch,
   provider/model/fingerprint and three format bindings for every status/cancel
   operation. Tisra's local thread UUID and acknowledged native `thread_id` and
   `turn_id` are different identities; never substitute one for another or guess
   a lost acknowledgement. All strict native objects reject unknown/duplicate
   keys, invalid UTF-8, noncanonical UUID/digests and booleans as integers.

   Persist only bindings/digests/receipts/payload handles and newer local
   cancellation/pending-cleanup facts in device-local runtime records; never note,
   unit, quote, generated answer or original request plaintext there. Restore
   validates the originally persisted digest, does zero RPC, and never derives a
   new acceptance pin from supplied restore bytes. After restore, native
   `read_response(...,source_request=original_raw_bytes)` requires the original
   trusted request for source/range validation. Reconstruct that validation input
   from the canonical local run and pinned snapshots and verify its original hash;
   metadata-only restoration cannot establish citation validity. If sources are
   unavailable, expose only status/cancel/cleanup, not a verified answer.

8. **Retain publication and cancellation ordering.** Keep
   `Research/ResearchService.swift` and Ledger cancellation gates: commit durable
   local completion before finalize, close local publication before remote cancel,
   discard late replies, retain unknown/pending cleanup handles and never replay
   uncertain inference. Revoke is run invalidation even after remote success, not
   deletion-only cleanup. A locally committed result remains a separate consumer
   fact. Recovery status inspection stays observation and does not backfill Ledger
   results or start/resume App Server. Receipt terminal and interrupt acknowledgement
   are independent; a stop request does not prove stopped inference or a refund.

9. **Compose the host through the existing runtime.** The ARL source composition
   uses `arl/codex_sourced_contract.py`, `CodexSourcedAdapter` and
   `CodexSourcedResearchEngine` in `arl/codex_sourced_research.py`, and
   `Runtime(..., codex_research=CodexSourcedResearchEngine(...))`. Reuse the existing
   `CodexResearchGrant` shape with the v2 pure `CONTRACT_SHA256`, existing trusted
   peer identity, supervisor/discovery/wake registry, SDK connection and one
   scheduled worker. Keep source/code/control/schema/binary/confirmed-model pins;
   the fingerprint does not claim immutable backend weights. The host owns any
   future narrow grant/policy; this handoff creates none. No new runtime, listener,
   launcher, provider fallback or broad capability grant is needed. Scheduling
   uses existing priority/deadline policy and [app fairness](LOCAL-APP-SCHEDULING.md).

## Focused consumer verification and remaining live gates

The current T2 owner should add codec-only fixtures for the projected source and
result/history contracts, including note-null versus extracted attachment hashes,
attachment mismatch and invented-reference rejection. Existing Ledger/service/UI
tests below are for the distinct future integration owners, using synthetic
snapshots and transport doubles only:

- `Tests/TisraCoreTests/ResearchFormatTests.swift`, `ResearchTests.swift` and
  `ResearchExecutionTests.swift`: exact v2 negotiation; persistent discriminator;
  strict v1 rejection; full note/all-unit projection with title/locator/state;
  complete snapshot digests and original attachment hashes; multiple records/units per snapshot; complete-byte
  overflow without truncation; public history migration; cross-language hashes.
- `ResearchLineageTests.swift`, `CloudResearchSyncTests.swift` and `BackupTests.swift`:
  unchanged old v1 fingerprints; v2 format/range fields retained through storage,
  restore and replication; incompatible writer rejection; missing/changed original
  snapshots rejected; UTF-8 multibyte range and duplicate-identity rejection.
- `ResearchRuntimeBindingTests.swift` and
  `Tests/TisraMacTests/ARLResearchConsumerTests.swift`: exact native receipt pins,
  zero-RPC metadata restore, no source plaintext in sidecars, source-required reply
  validation after restore, cancellation-first publication, uncertain no-replay,
  known pending cleanup and record/sidecar overflow before upload.

Each owning task must run its applicable build/check workflow within its scope; this guide
does not claim those tests or the original consumer build have run. ARL source
tests and historical text-only saved evidence cannot establish live v2 consumer
acceptance. Remaining gates are explicit product agreement on the 8 KiB/full-source
budget and absent token/cost hard caps, codec adoption and tests, the separate
durable run/format migration and consumer integration, accepted
binary/schema/control/model evidence, trusted Tisra identity/dependency closure,
and separately authorized narrow host composition/policy. No live model call is
required to prepare this source increment. Any later live scope must be reported
before execution and separately authorized; do not switch to another account,
install/load a local model, or invoke a paid fallback. The held Friday component,
its blocked review and its tests remain untouched.
