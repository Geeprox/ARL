# Tisra native Codex adapter: isolated source candidate

Historical text-only v1 candidate. Tisra has not accepted removal of generated
citations. Use the separately frozen citation-preserving
[sourced v2 adoption guide](TISRA-CODEX-SOURCED-V2-ADOPTION.md) for current consumer
work; v1 is retained for source provenance and regression compatibility only.

2026-10-01. This candidate implements the missing native server path and a Python
typed SDK, using the existing ARL worker, SQLite store, payload transfer, app
policy, identity verifier, discovery and wake mechanisms. It was developed in
an isolated copy. The canonical ARL checkout and the original Tisra/Friday WIP
repositories were read-only. No installed host, product grant, signer, credential,
deployment, local model or real inference was changed or invoked. The held Friday
v4 component and its blocked review/tests remain untouched.

The canonical proposal and `codex-native-proposal-v1.json` remain frozen historical
proposal inputs. Their `execution_implemented:false` applies to that baseline;
this patch is a new source candidate, not production publication or consumer
acceptance. The grammar's original SHA256 is
`9cdc14e57d1528f4d257c8a1cd79c9c96097b39652ba7272f0a47f650dddeed1`.

## Exact source API

Typed tool: `tisra.codex.research.v1`. The opt-in methods are
`codex.research.capabilities.v1`, `codex.research.submit.v1`,
`codex.research.status.v1`, `codex.research.cancel.v1`, and
`codex.payload.begin.v1|write.v1|seal.v1|read.v1|revoke.v1` (each operation is a
separate method). They use the existing `arl/1` transport. The existing
`research.*`/`payload.*` methods remain Responses-only; purpose checks prevent
cross-namespace payload reads, writes and revocations. Generic task methods
cannot submit/get/cancel/resume either typed research tool.

| Field | Native value/bound |
|---|---|
| request_format | `tisra.codex.request.v1` |
| output_format | `tisra.codex.result.v1` |
| history_version | `tisra.codex.history.v1` |
| Descriptor purpose / format | `tisra.codex.descriptor.v1` / `tisra.codex.v1` |
| Provider | `codex_app_server` |
| Renderer | `tisra.codex.raw-json.v1` |
| Complete original request / provider text | each <=8192 UTF-8 bytes |
| Separate descriptor | <=32768 bytes |
| Generated text | <=32768 UTF-8 bytes; submit selects 128..32768 |
| Result envelope | <=262144 serialized bytes; descriptor may choose less |
| Upload / download chunks | 8192 / 32768 bytes |
| Local app request / reply frame | 16384 / 65536 bytes |
| Provider outgoing frame / incoming complete line | 32768 / 65536 bytes |
| Deadline | 1..30000 ms, from submission, including queue wait |
| Upstream turns / automatic retries | 1 / 0 |
| Output-token hard cap / cost hard cap | unavailable; explicit null, never 4096 |

The provider outgoing bound includes JSON escaping and overhead, independently
from the reviewed request byte budget. The full 8 KiB escaped-request plus separate
32 KiB descriptor transport test passes. Highly escaped generated output can still
hit the upstream 64 KiB line bound; the text ceiling is not a guaranteed yield.

`codex_contract.py` strictly checks the frozen request grammar: exact/duplicate
keys, UTF-8 including escaped surrogates, canonical lowercase UUIDs and digests,
explicit nulls, integers excluding booleans, <=20 public history pairs and <=100
included evidence snapshots. Every historical citation must match the included
snapshot's ID/digest/record/revision/unit and quote an exact substring. References
authorize no filesystem, URL or server-side evidence retrieval. The original
request bytes, including whitespace and field ordering, are the sole provider
text; no reserialization, truncation, summarization or Responses conversion occurs.
Oversize input raises `codex_input_too_large` before executable-job/call-budget
admission. Invalid grammar and descriptor bindings also fail before admission.

Submit exact keys are the original research submit keys plus `max_output_bytes`;
`max_output_tokens` remains present as **null**. The descriptor keeps the original
research descriptor keys, uses `format:"tisra.codex.v1"`, keeps
`maximumOutputTokens:null`, and adds `maximumTextBytes` matching submit. Evidence
ID/digest pairs must exactly match request snapshots in order. A non-null migration
also requires an alternate path with matching parent run/fingerprint. The complete
frozen history/evidence grammar is in `integrations/tisra/codex-native-proposal-v1.json`.

Receipts retain the original 18 research fields and add exactly `native`:
`{thread_id,turn_id,terminal,interrupt}`. Native IDs start null and are populated
only from validated acknowledgements. Terminal is
`not_started|unknown|completed|interrupted|failed`; interrupt is independently
`not_requested|sent|acknowledged|rejected|unknown`. `external_stop` equals the
observed terminal, including unknown. An interrupt acknowledgement never proves
interrupted. The result envelope uses the proposal's exact keys, verified native
IDs and completed/not_requested evidence. It contains text and ordered reviewed
input evidence bindings, **not validated model-generated citations**.

## Binding, cancellation and recovery

`ResearchEngine` now has extension hooks with the original Responses defaults.
`CodexResearchEngine` reuses its payload reservation, immutable owner/run/job
registration, first authorization epoch, request/descriptor refs and hashes,
reply slot, cancellation and publication transaction. Both engines share one
worker. No caller registration or alternate socket/runtime is introduced.

Before provider launch, native admission verifies bytes/schema/pins and durably
records external-start uncertainty attached to the immutable original binding.
`research_native` stores acknowledged thread/turn IDs and model evidence in private
SQLite metadata. Each acknowledgement is committed before the next provider
operation. The admitted adapter's evidence stays fixed even if the host registry
changes during acknowledgement. Native evidence is excluded from diagnostic/audit
logs and never replaces owner/run/request/epoch/auth-epoch authorization.

Model fingerprint = SHA256 of the existing canonical `encode` representation of
`{adapter_binary_sha256,protocol_version,control_contract_sha256,confirmed_identifier}`.
The identifier is verified against `thread/start` and the configured existing
ChatGPT account/model; backend weights/revision remains null. This fingerprints
the adapter binary/protocol/controls/identifier, not immutable backend weights.
For transport doubles, the interpreter and fixture control pins are explicitly
synthetic evidence. Actual transport source metadata is `implementation_only`,
never silently `upstream_api` or accepted live consumer evidence.

`CodexTextAdapter` pins one absolute <=30-second provider deadline before its first
process launch, and passes the same deadline through MCP-discovery session
replacement, writes, receives and bounded cancellation drain. An expired deadline
prevents launch/write; process reaping does not renew it. Process termination is
local cleanup, not proof of upstream stop, billing cessation or refund. Controls
still disable inherited MCP, tools/actions, network, workspace access, skills,
hooks and inherited instructions, with one empty ephemeral read-only workspace.
Genuine terminal turns are never interrupted again.

Cancel first closes publication in the durable job/run transaction. The active
transport then sends one interrupt when IDs are known, retaining independently
observed acknowledgement and terminal evidence. Matching completed output after
cancel/revoke/expiry/auth drift is discarded; it cannot reopen success. Known
failed terminals also retain evidence without a success envelope. Uncertain
external outcomes remain `needs_review`; no automatic inference replay occurs.

Restart retains original IDs, params, fingerprint and first auth epoch. Recovery
marks started work `needs_review`; status/cancel/cleanup use its exact original
binding and never start or resume an App Server. Ephemeral IDs are correlation
evidence, not an upstream resume promise. Owner-bound status/cancel/revoke remain
available after research-grant loss, provided the current trusted app identity and
narrow method policy still authorize those RPCs.

Payload revoke remains **run invalidation**, even after success: result visibility
is cleared, reply handles are revoked, the same logical run remains a tombstone.
It is not deletion-only cleanup or a still-readable completed remote run. A local
durably saved result is a separate consumer fact. Retain pending known cleanup IDs;
lost begin acknowledgements cannot be guessed, reacquired by retry, or reported as
cleaned. No deletion-only release endpoint was added.

`CodexResearchClient` reuses the existing SDK's upload/cleanup through a scoped
transport wrapper. It validates all native request/descriptor parameters before
upload, submits once without retry, tracks first pins and monotonic native facts,
validates chunks/base64/eof/final receipt and the exact result envelope, and exposes
`durable_record` / `restore_submission`. The <=8192-byte canonical record retains
the original accepted receipt/params and ordered evidence metadata, never evidence
text. Restore requires the original trusted digest and performs zero RPC. Status
and cleanup remain explicit. Consumer cancellation/pending cleanup facts must be
persisted separately before calling cancel; an old acceptance record cannot serve
as a replacement for the consumer's newer cancellation tombstone.

## Current Tisra adoption steps

Read-only evidence is in `consumer-source-manifest.json` beside the patch. These
steps refer to that source snapshot; the original active WIP was not edited or
tested. Tisra's current `ARLResearchExecutor.preflight`, `ARLResearchRoute`,
`ResearchPayloadCodec` and payload Purpose enum accept Responses only, require a
4096-token hard cap, and decode/validate structured generated citations. They must
continue to reject this candidate until a distinct native product path is agreed.

1. Agree the 8 KiB/one-turn/30-second/no-token-hard-cap and model-evidence basis,
   including whether an explicitly attributed text-only result is a useful
   product format. If Tisra still requires generated citations, hold adoption
   until a separate output schema/validator is implemented and accepted. Never
   interpret reviewed input bindings as generated citation evidence.
2. In TisraCore, add a distinct native format/codec and per-run budget/descriptor
   representation that can encode null token limits. Keep version1 historical
   Responses bodies/envelopes/encrypted reasoning and existing format bindings
   unchanged. Add explicit new-path migration of reviewed public history/evidence,
   with original parent/hash/fingerprint references; do not convert old wire data.
3. In the existing sole `ARLResearchExecutor` route, select exact native methods,
   formats, descriptor and capabilities when a native run was explicitly reviewed.
   Retain the shared `ARLClient` socket SDK/connection identity checks. Port the
   Python native SDK's exact checks into a narrow Swift typed wrapper or Tisra's
   existing consumer transport; no new process launcher/runtime/listener is needed.
4. Extend device-local `ResearchRuntimeBinding`/payload records/source acceptance
   storage for native purposes and native evidence. Preserve original acceptance
   bytes/digest/first auth epoch without recomputing pins on restore; keep local
   cancel, pending revoke and origin-instance checks. Preflight the consumer's
   actual private acceptance/sidecar byte budgets before upload; its current raw
   record 4 KiB/whole binding 8 KiB limits are independent from this SDK record ceiling.
   Reject excess metadata explicitly without trimming it.
5. Keep `ResearchService` local completion-before-finalize and cancellation-first
   ordering. Native receipt checks must accept cancellation invalidation after
   completed success, keep acknowledged IDs/terminal fixed, clear result visibility
   and forbid reopening. Recovered status remains observation, not late Ledger
   result publication. Unknown native IDs stay null.
6. In an independently reviewed host composition, use
   `Runtime(..., codex_research=CodexResearchEngine(...))` and the existing signed
   peer verifier/controlled supervisor/dependency closure. A host-only
   `CodexResearchGrant` must pin the exact `CONTRACT_SHA256`, model/fingerprint and
   first auth epoch; app policy grants only these methods/tool and allowed
   priorities/deadlines/call/pending budgets. No such product grant was created.
   Default installed discovery/execution remains absent.
7. Adopt generic fairness by using the updated Store/scheduling code. Native
   submit's priority/deadline goes through the same AppPolicy checks; keep its
   stable run key. See `LOCAL-APP-SCHEDULING.md` for the 8+N-1 competing-claim bound
   and nonpreemptible/deadline limitations. No scheduling SDK wire change is needed.

Remaining live gates: actual consumer agreement and Swift/Core adoption; verified
immutable Tisra actor/dependency closure; separately reviewed executable host and
narrow product policy/grant; accepted provider evidence/quota authorization. No
live call is unavoidable for this source increment. A later, separately scoped
synthetic test would need one existing-account/configured-model native turn to
verify this new whole native path, and a separately approved active cancel case
if required; transport tests and old saved evidence do not grant that scope.

## Validation evidence

`focused-test-output.txt` records native grammar, server/store, typed SDK, absolute
deadline, existing Codex transport, Responses 512 KiB/1 MiB preservation, existing
SDK, scheduling and Responses transport-double tests. The real temporary ARL
Unix socket/worker roundtrip uses the synthetic stdio provider, never a model.
Existing registered-kernel-peer synthetic tests are retained. No Apple/UI,
original Tisra build, held Friday review, real provider or deployment test is
claimed. The packaged verifier also includes eight generic cancellation/recovery/budget
regressions, independently exercised in the scheduling lane.

Saved `codex-live-diagnostic-2.json` and `codex-live-cancel-1.json` were read only.
Their prior synthetic text success and matching interrupted terminal concern the
older text adapter. They support reusing its transport pattern, not live acceptance
of this new native engine, consumer, binary/dependency closure or installed host.
Their hashes and this increment's final source/test hashes are in the delivery
manifest.
