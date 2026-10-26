# Minimal Tisra Codex text migration, proposal1

**Draft for explicit consumer acceptance; not implemented/published as a research tool.** The real smoke uses existing codex.text.plan.v1, not tisra.research.v1. Existing Responses requests/envelopes/history are preserved; no automatic conversion or provider fallback. Local models remain cancelled.

Naming/schema note (2026-10-01): this is retained historical draft evidence. The current source proposal is TISRA-CODEX-NATIVE-PROPOSAL.md revision2 and integrations/tisra/codex-native-proposal-v1.json, using `tisra.codex.request.v1`, `tisra.codex.result.v1`, `tisra.codex.history.v1`. The `codex.research.*` strings and example renderer below were never published and are not accepted aliases. Neither draft is an executable research capability. The newer proposal uses byte-preserving raw reviewed JSON and explicitly keeps structured generated citations unimplemented.

## What the consumer must accept

1. A distinct `codex.research.request.v1 / codex.research.result.v1 / codex.research.history.v1` lineage. Preserve existing Responses raw bytes and encrypted history in the local ledger. An old Responses branch cannot silently continue as Codex. Switching creates a newly reviewed execution UUID and explicit alternate path; record prior run/fingerprint and the format transition. Original request hash and newly rendered Codex input hash are separate facts.
2. Codex0.159 has byte/time/call bounds, **not** the old4096-token hard ceiling. Usage/cost are unknown unless real upstream evidence supplies them; no cost estimate, token count or dollar guarantee inferred from output length. Consumer preflight must reject the old hard-token contract rather than ignore its field. A new reviewed Codex budget can say input<=8192UTF8 bytes, output<=32768UTF8 bytes, one call, whole-session<=30 seconds; this is the existing adapter's limit, not512KiB/1MiB research compatibility.
3. Any larger research evidence must fail preflight or be reduced through an explicit new reviewed selection/excerpt snapshot. Never silently cut original request bytes, evidence, history, citations or encrypted reasoning to fit. The prepared small input contains only question and user-selected immutable evidence; no project files, arbitrary paths or server-side retrieval. The renderer version/hash must bind exactly which fields were transformed.
4. Existing consumer lexical reminder review, IME/stale handling and Apple writes are unrelated; research produces an answer, never an EventKit/task/device side effect.

## Minimal typed proposal

Reuse the completed owner-isolated payload/run/epoch/CAS infrastructure with a **new explicitly negotiated format implementation**, not a permissive change to existing Responses validators. Payload purpose and hard bounds are distinct. Draft input:

```json
{"version":1,"question":"<reviewed question>","evidence":[
 {"evidence_id":"<snapshot UUID>","snapshot_digest":"<SHA256>","record_id":"<UUID>",
  "revision":1,"unit":null,"text":"<exact selected source passage>"}],
 "history":[{"run_id":"<UUID>","request_sha256":"<SHA256>","output_sha256":"<SHA256>",
             "question":"<reviewed text>","answer":"<accepted public answer>"}],
 "migration":{"from_format":"openai.responses.v1","parent_run_id":"<UUID>",
              "parent_fingerprint":"<SHA256>","source_request_sha256":"<SHA256>",
              "encrypted_reasoning_replayed":false},
 "renderer_version":"tisra.codex.reviewed-text.v1"}
```

For a brand-new Codex branch migration is null. No raw reasoning transcript is generated/replayed. Public answer history is a new explicitly accepted continuity model, **not equivalent** to encrypted Responses history. Draft evidence/history arrays remain bounded by the8192-byte full rendered input; exact item counts/renderer template and schema digest must be frozen with Tisra before implementation.

Existing codex.text.plan.v1 returns `{text}` only, so it does **not** already implement citation-schema research. The next minimal adapter must constrain/validate a typed answer `{text,citations:[{evidenceID,recordID,revision,unit,quote}]}` and bound citations<=50. Tisra validates each quote against the exact bound evidence snapshot; existence of a quote does not prove the inference. Refusal/incomplete/schema mismatch are visible states, not a fabricated successful answer. Keep upstream private thread/turn IDs in the execution receipt as evidence, never fake a Responses responseID/output array.

Typed receipt must retain job/owner/run/requestHash/epoch/auth_epoch/provider/model fingerprint/request-output-history versions, and the immutable result-ref hash. Pin model and adapter/renderer revision; do not equate thread configured model with independent execution telemetry. Validate every receipt and local ledger epoch before publishing/committing. Cancellation first invalidates local ledger; ARL CAS rejects cancelled/revoked/expired results. In-flight uncertainty is needs_review with no automatic re-call. OS process termination or an interrupt acknowledgement alone does not prove upstream stop/refund.

## Scope and acceptance sequence

- Consumer explicitly accepts the new formats/budgets/alternate-path semantics; no research execution before this.
- Implement one bounded small-evidence typed adapter and its renderer/output validator, using current reviewed payload/CAS rather than a second queue/framework.
- Isolated real Swift consumer tests for exact bytes/hash/citations/format drift/epoch/cancel/no replay. Existing real text smoke establishes account/transport only, not research quality or compatibility.
- Separately review signed Tisra registration, narrow research task methods, actual call budget/model/account permission and execution-profile DB migration. Metadata-only installed service remains execute_jobs=False/storev2.

Parent-declared current installed baseline0.1.1-a67506b6f6ad30c0 (Mio metadata-only), retained rollbackf12148172f69d4ab. No current source research/storev3/Calendar/Codex execution is included there. Frozen Calendar package stays unchanged and awaits its own permission.
