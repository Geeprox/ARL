# Future Tisra capture-link seam: outer contract and T3 handoff

2026-10-01. Prepared locally for existing T3 owner
`01a0f77a-2134-7669-8d1e-39947ee28011`; the outer handoff was successfully routed
after that owner's explicit coordination request. Research remains the priority and its finalized
package/schema pin remains unchanged. This additive capture component is
**future contract only**. Importing `arl/tisra_capture_contract.py` creates no
route, writer, grant, participant, library registration, fetcher or capability.
There is no write function. Activation needs a separate confirmed root scope and
a reviewed T3 consumer implementation; test contexts grant no product authority.

## Existing source seam and ownership

The original `/Users/<user>/Repository/Tisra` was inspected read-only:

- `Sources/TisraCore/Web/WebCaptureRequest.swift` validates an explicit HTTP(S)
  URL locally, lowercases scheme/host, removes fragments/default ports and supplies
  an empty path as `/`. Validation alone does not fetch.
- `WebCaptureService.fetch` performs the existing explicit bounded retrieval and
  prepares bytes for review. `save` saves the same reviewed bytes without another
  GET. Its `PreparedWebCapture` requires an actual fetched raw copy; this future
  already-retrieved-text contract must not fabricate one.
- `Sources/TisraCore/Storage/LedgerStore+WebCapture.swift` owns transactional
  source import keys/changed versions. Only the source address enters the editable
  note; source title/body stay sourced metadata/derived extraction. The existing
  unchanged branch calls `writeExtractedText`, so blindly forwarding future
  receipt replays to that path would not establish immutable no-overwrite behavior.
- `Model/Record.swift`, `ArtifactTextService`/`AttachmentService` and existing
  managed blobs provide record identity/source boundaries; reuse them through the
  T3-owned seam. Do not add an independent ARL record writer or raw SQL route.

T3's read-only isolated path is
`/Users/<user>/Documents/Codex/2026-10-01/task-20/work`. Its source candidate files are
`Sources/TisraCore/Import/LinkCaptureModels.swift`,
`Sources/TisraCore/Import/LinkCaptureCodec.swift` and
`Sources/TisraCore/Import/LinkCaptureService.swift`. T3 has frozen and locally
accepted this source-only consumer at commit
`676aed1204a0528605406c50b1035f35625c813a`; its packaging checkpoint is
`36a69a26afd25306eb0964137048e037ec78807c`. This does not establish a live
capability, authenticated identity, grant or receipt journal. Strict host
callbacks remain pending. T3 owns that bounded already-retrieved source/derived envelope, exact field names,
URL normalization/dedup hashes, deterministic changed-source versions, CLI
`capture-link` receipts and the consumer writer. This lane deliberately does not
invent a second URL/version algorithm or inner schema. No original repository,
Ledger schema, consumer service, UI or capture source was edited here.

## Concrete outer submission

The reserved future tool label is `tisra.capture.link.v1`; it is not advertised or
registered. The pure outer request has exactly these fields:

```json
{
  "schema_version": 1,
  "capture_request_id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
  "library_id": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
  "codec": "tisra.link-capture.inner.v1",
  "consumer_schema_sha256": "f6a6618c280e78389cce1846f24613689ba4c166604597f93aafe9904cef3ce8",
  "payload": {
    "payload_id": "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
    "sha256": "<SHA256 of the entire original payload byte sequence>",
    "byte_count": 123
  },
  "declared_attribution": null
}
```

`declared_attribution` may instead be the exact object
`{"role":null,"display_name":null}` with either value a bounded display string.
These are untrusted declarations, including any CLI `--role`; they do not select
an app identity, participant, grant, target library or privilege. Unknown root
fields such as `writer_app`, `participant_id`, `grant`, `callback_url`, `file_path`,
`fetch_url`, generic `write` or `retry` are rejected. Outer request/library/payload/
transaction IDs are canonical lowercase UUIDs; SHA256s are lowercase. Writing
participant IDs remain opaque and are not required to be UUIDs. Integers exclude
booleans, text must be strict UTF-8, JSON keys cannot
be duplicated and nonfinite numbers are rejected. No field is trimmed.

The outer serialized ceiling is 8192 bytes. The complete immutable payload
ceiling is 524288 bytes; future results are at most 32768 bytes. These are outer
ceilings, not a promise that T3's codec permits such a large source/body. T3's
tighter per-field/complete-body bounds also apply. The request retains its exact
payload SHA256/count/ref. References are existing authenticated payload handles,
not paths, URLs to fetch, callbacks, signed keys or endpoint registration.
Reserved purposes are `tisra.capture.request.v1` and `tisra.capture.result.v1`,
separate from all research formats; these labels install no payload route.

`CaptureContext` comes only from the host's trusted app-bound connection and
registered-participant mapping. It carries actual `writer_app`, stable opaque
`participant_id` (nonempty, no whitespace, at most 128 UTF-8 bytes, such as
`agent:mio`), descriptive `actor_kind` (`human` or `agent`), host-pinned
personal `library_id`, original authorization epoch and expected codec/schema
pin. `active` defaults false and `write_granted` defaults false. Missing source
codec configuration fails `capture_codec_unavailable`; a different codec/pin fails
`capture_codec_unsupported`. App-principal identity must not be used as a substitute
for the writing participant. Humans and all agents are peer participants;
permissions and library scope are granted independently of actor kind/name.

`validate_outer` checks only these transport/binding facts and exact original
payload bytes. It does not approve a source record. `validate_request` additionally
requires a host-supplied `CaptureCodec` with the matching
`consumer_schema_sha256` and strict `validate_request`/`validate_result` callbacks.
Callbacks are trusted host configuration, never IPC arguments; they must be
pure/bounded and return `None` after checking the exact bytes, not replace or
normalize bytes. Their exact signatures are `validate_request(raw_request)` and
`validate_result(raw_result, raw_request, outer_state)`. The result callback must
validate the outer `created`/`deduplicated`/`partial` classification against the
complete inner source/per-contribution outcomes and failures; a confirmed receipt
alone cannot promote a partial result to whole-capture success. There is no
default inner codec. A synthetic test codec does
not become a product schema or grant.

## Frozen T3 inner evidence and remaining host validation dependency

The consumer discriminator is `tisra.link-capture.inner.v1`. Its schema pin
`f6a6618c280e78389cce1846f24613689ba4c166604597f93aafe9904cef3ce8`
hashes the exact UTF-8 schema bytes **including the final LF**. It is separate
from the outer metadata pin
`acfd368accaf445b0b57021b49f1821479afea61f28a2af87a52b0a3f6b7fb4e`.
The existing outer code and metadata pin remain unchanged; its dependency status
was recorded at the earlier outer checkpoint. Use the additive
[frozen consumer evidence](../integrations/tisra/capture-inner-frozen-v1.json)
for the updated consumer binding and host-validation status.

The exact [schema bytes](../integrations/tisra/capture-inner-v1/link-capture-inner-v1.schema.json)
and [T3 manifest](../integrations/tisra/capture-inner-manifest-v1.json) are copied
without reserialization. Schema entries are `#/$defs/request`,
`#/$defs/receipt` and `#/$defs/envelope`. This lane verified all 19 fixture hashes,
byte counts and six source-file hashes against T3's source commit read-only.
All eight request/receipt cases fit the stricter outer bounds. T3 reports 195
Core tests with zero failures (27 history, eight capture) and 29 synthetic CLI
calls; this lane did not rerun the consumer CLI or Swift tests.

Normative `x-*` semantics and selected-Ledger live reference validation require
strict host callbacks beyond a stock JSON Schema validator. Copied synthetic
receipts provide no authenticated participant, grant or durable ARL journal
confirmation. The byte-fixture callbacks in this lane's tests recognize only
those exact fixtures and cannot be installed as a product validator.

Read-only frozen field evidence from the three T3 files is:

| Object | Frozen v1 wire fields |
| --- | --- |
| `LinkCaptureRequest` | `schema_version`, `source`, `writer`, optional `body`, `contributions` |
| `LinkCaptureSource` | `original_url`, optional `resolved_url`, `title`, `author`, `authored_at` |
| `CaptureParticipant` | `participant_id`, `display_name`, `actor_kind` (`human` or `agent`) |
| `LinkCaptureBody` | `content_kind` (`original` or `excerpt`), `text` |
| `LinkCaptureContribution` | `writer`, `content_kind` (`summary`, `analysis` or `annotation`), `text`, optional `adopted_from` |
| `CaptureRecordReference` | `record_id`, `revision`, `content_hash` |
| Managed `LinkCaptureEnvelope` | `schema_version`, `source`, `canonical_url`, `writer`, `writer_trust`, `content_kind`, `body_state`, optional `text`, `source_content_hash`, optional `bound_source`, optional `adopted_from`, `captured_at` |
| `LinkCaptureRecordReceipt` | `record_id`, `revision`, `content_hash`, `provenance_blob_hash`, `content_kind`, `body_state`, `writer`, `writer_trust`, `outcome` |
| `LinkCaptureReceipt` | `schema_version`, `source`, `contributions`, `failures` (`index`, `message`) |

The inner source limit is 2 MiB per request, 1 MiB per original/excerpt body,
256 KiB per contribution and eight contributions. The outer ARL 512 KiB complete
request bound is deliberately stricter; do not trim a valid larger Swift request
to cross that boundary. Current metadata limits include title 4096 bytes, author
512 bytes and authored date 128 bytes. `authored_at` needs a real calendar date
and explicit timezone offset; unknown dates remain absent. `participant_id` is
opaque, not required to be a UUID; record/reference IDs remain existing stable
UUIDs. Current per-record outcomes are `saved`, `unchanged` or `version`, body
state is `provided` or `metadata_only`, and **writer trust is `declared`**.

Those declared inner `writer` values do not establish authentication or grant a
peer's permissions. The future strict host codec must validate them as declared
provenance and keep the actual registered writing participant from authenticated
context separate; it cannot promote a CLI role, display name or actor kind into
trusted identity. Any trusted registered-participant persistence/mapping remains
a separate integration gate. The current CLI target is explicit isolated
`TISRA_HOME`; ARL's opaque library scope must map to a registered target through
trusted host configuration, never a body-provided filesystem path.

The managed envelope preserves `source.original_url` while its preparation
uses the existing `WebCaptureRequest` canonicalization for source keys. T3 owns
its namespace/canonical URL/source-and-body fingerprint and changed-version
semantics. The frozen schema and exact fixtures pin optional/null serialization
and those algorithms; host callbacks must enforce them and live references before
using the consumer pin for a write. ARL implements no duplicate
normalization or replacement algorithm here.

The frozen consumer fields and fixtures retain these distinct provenance axes;
host integration must preserve them:

- **Writing participant:** the trusted registered participant that submits the
  write, independent of transport app or declared display role.
- **Original source authorship:** the article's original author, or explicit
  unknown/unavailable provenance. Never attribute external source text to the
  writer or turn a claimed byline into authenticated identity.
- **Content kind:** original article/source, summary, assistant analysis and user
  annotation remain distinct. Later editing/adoption by a participant is another
  fact; it cannot retroactively rewrite original authorship or source content.

The incoming source must preserve the exact human-supplied URL, available title,
original author and any explicit offset-bearing source date, without inventing
missing date/byline/body. Available original/excerpt body has provenance and
explicit completeness/status, separately from assistant summary/analysis and
user annotation. An absent/null `body` produces explicit
`body_state:"metadata_only"` in the managed envelope/receipt and contains no body; lack of
body does not become a fake extraction or permission to retrieve it. Body and
analysis have separate bounded fields/records. Full excess input is rejected,
not shortened. Already-retrieved content is supplied as data: neither ARL nor the
consumer typed-write handler receives generic URL-fetch authority.

T3's frozen canonical-URL/dedup fixtures retain exact original URL bytes alongside
the normalized key. Same URL/same source must
deduplicate without overwriting existing sourced content, analysis or local edits;
changed source gets a deterministic distinct source version preserving the
original. Summary/analysis/user-annotation records receive their own stable IDs
and source linkage. No record or citation ID is replaced on retry. The exact
writer/result schema, source/version dedup and managed JSON are T3-owned frozen
evidence. This outer module intentionally implements none of those inner rules.

An unchanged source retry by a different declared peer returns the stored
**first writer**. Validate that writer against the original stored provenance;
never require equality with the later request writer or replace the source's
writer. The pinned `peer-retry-request.json` and `peer-deduplicated.receipt.json`
exercise this case. Contributions include their own writer in their version key.

## Receipt, immutable request identity and uncertainty

`CaptureBinding` retains capture request ID, exact request SHA/count, library,
codec/schema pin, actual writer app/registered participant, original auth epoch
and an admission digest. The admission digest covers the complete logical outer
metadata plus payload SHA/count using existing `arl.contracts.encode`; it excludes
only the transport payload ID. A new handle for definitely identical uploaded
bytes cannot change the logical request. Changed payload, declaration, actor,
library, codec/pin or first epoch is a conflict, not permission to rewrite.

The future outer receipt has exactly the binding fields from `CaptureBinding.wire`
plus `schema_version:1`, `state`, `commit` and `result_ref`. The allowed states are
`created`, `deduplicated`, `partial` and `needs_review`. A committed or partial
state requires the exact
immutable binding, `commit:{transaction_id,committed_at_ms}` and bounded result
SHA/count/ref. Only a strict frozen T3 result validator may map the actual
`saved`/`unchanged`/`version` outcomes and failures into the outer classification.
`validated_result` passes that outer state explicitly to the callback, which must
reject any mismatch even when the outer receipt has trusted journal confirmation.
Do not infer success from a source ID alone or rename inner outcomes to imply a
different write. `partial` must retain the known source/per-contribution receipts
and failures without claiming whole-capture success. `needs_review` has null commit
and result; it makes no action claim and does not imply that no earlier part wrote.

The frozen `LinkCaptureService.save` commits the source and each contribution
independently, collects contribution failures, and has no durable ARL receipt
journal yet. It does not atomically commit the whole capture. Those facts keep
activation blocked even though a source seam exists.

A transaction-shaped JSON object alone is not commit evidence. `receipt_body`
requires a separate host `CommitConfirmation` from the pinned Tisra writer or
verified original receipt journal, bound to library/request/transaction and the
whole receipt digest. Here `transaction_id` is a **future durable receipt/journal
commit identifier**, not proof of one atomic T3 source/contribution transaction.
No confirmation is accepted from request fields. It must be created only after
the pinned writer confirms the per-record outcomes and durable receipt-journal
commit; this module does not implement that journal. `validated_result` also
verifies original request/result SHA/count and
the matching T3 result validator before returning the exact result bytes. None
of these pure helpers creates a record or proves an unobserved transaction.

`replay_decision` is pure bookkeeping:

- Exact prior binding plus a confirmed committed or partial receipt returns
  `cached_receipt`; reuse the unchanged receipt, including per-record failures,
  not another source/derived write. A cached partial result remains partial.
- Same request identity with changed bytes/metadata/binding fails
  `capture_idempotency_conflict`; original source and analysis stay untouched.
- A recorded attempt without confirmed commit, missing acknowledgement or a prior
  uncertain outcome returns `needs_review`. Never retry an uncertain write, renew
  identity to evade that hold or infer successful rollback/deletion.
- `first_attempt` records absence of a prior attempt; it does not grant permission,
  validate the inner source, invoke a writer or claim an action.

Future integration must use the existing authenticated SDK/payload/discovery/wake
patterns and an isolated explicit personal-library target. Host identity/grant
and library checks remain independent from display metadata. Tisra's existing
writer transaction and durable receipt ownership must resolve crash uncertainty;
no new runtime, generic SQL/write API or hidden local/global library is introduced.

## Evidence and activation blockers

`python3 -m unittest tests.test_tisra_capture_contract -v` exercises only synthetic
bytes/contexts/receipts and pure callbacks. It covers excess input, exact hashes,
unknown fields, forged CLI roles, peer actor permissions, library scope, unavailable
codec/pin mismatch, transform rejection, unchanged cached receipts, conflicts,
uncertain no-retry decisions, confirmed partial retention, unconfirmed-commit
rejection and pinned-validator rejection of a success state for partial results.
It also proves default host context denies before any inner callback;
`active` and `write_granted` are strict host booleans, not request authority.
No source/user
notes, URLs, network, inference, actual CLI capture, grants or writes were used.

`python3 -m unittest tests.test_tisra_capture_frozen_evidence -v` adds exact schema/
manifest/fixture integrity, complete byte ceilings, disabled defaults and all eight
consumer receipt cases through byte-recognizing transport doubles. It rejects
success classification for the partial fixture and verifies that recovered output
preserves completed record IDs, revisions, content and provenance hashes. It also
checks the different-peer retry keeps the first writer. These doubles do not
establish live reference validity or a durable journal confirmation.

Generic Ledger edits preserve immutable original capture provenance but do not
yet log every later editor Participant. Adoption remains a separate exact-reference
annotation; do not infer user agreement or a complete edit-event log.

Remaining blockers are host-pinned strict codec callbacks, registered-participant/grant/library
composition, real transaction/receipt-journal confirmation and separately
confirmed activation scope. No production registration, direct callback/URL fetch,
signing, original-repository edits or deployment is authorized by this artifact.
The finalized research schema/package and held Friday component remain untouched.
