# Typed research source API v1

Source implementation for review, **not installed or published**. Protocol remains `arl/1`. Module/store-extension version1. This replaces the research portion of historical draft-0 in TISRA-RESEARCH-LAYA-COORDINATION.md. No local-model work, production product registration, credential reads or paid calls occurred.

## Gates and exact transport

Every method below requires a kernel-verified registered peer whose app ID matches the request, an explicit AppPolicy method grant, and a host-owned ResearchGrant. No JSON owner, enrollment endpoint, arbitrary file path/URL/binary or caller approval flag. The default host has no ResearchEngine, tools or method grants. The settings metadata exception never covers this API. A real product must use a reviewed signed-app/controlled-process identity; registering test process lifetimes is evidence for transport only.

Requests have exactly `{protocol:"arl/1",app,method,params}`. All params/nested references reject unknown/missing fields. Integers reject booleans/fractions. UUIDs are canonical lowercase; SHA256 is64 lowercase hex. Duplicate JSON keys are rejected for these methods. Full request envelope plus newline <=16384 bytes; full response envelope plus newline <=65536 bytes. Input chunks8192 bytes, output chunks32768 bytes. Shared Swift SDK stays frozen with its legacy131072 receive cap; new methods enforce64KiB on the server, and the new wrapper additionally bounds its result projection.

| Method | Exact params | Result |
| --- | --- | --- |
| research.capabilities.v1 | `{}` | schema_version1, tool, formats(request/output/history), provider, provider_evidence, models(model->fingerprint), max_request_bytes524288, max_descriptor_bytes32768, max_response_bytes1048576, max_output_tokens<=4096, token_hard_cap_supported, request_frame_bytes16384,response_frame_bytes65536 |
| payload.begin.v1 | `{purpose,run_id,epoch,sha256,byte_count}` | `{schema_version:1,payload_id,expires_at_ms,chunk_bytes:8192}` |
| payload.write.v1 | `{payload_id,index,data_base64,sha256}` | `{schema_version:1,accepted_index}` |
| payload.seal.v1 | `{payload_id,sha256,byte_count}` | `{schema_version:1,payload_id,sha256,byte_count}` |
| payload.read.v1 | `{payload_id,offset,limit}` | `{schema_version:1,payload_id,sha256,byte_count,offset,data_base64,eof}` |
| payload.revoke.v1 | `{payload_id}` | `{schema_version:1,revoked:true,external_stop:"unknown"}` |
| research.submit.v1 | See below | Typed receipt |
| research.status.v1 | `{job_id,run_id,request_sha256,epoch}` | Typed receipt |
| research.cancel.v1 | `{job_id,run_id,request_sha256,epoch}` | Typed receipt |

Begin purpose only `tisra.research.request.v1` or `tisra.research.descriptor.v1`; clients cannot create response objects. Request is **original raw bytes <=524288**, independently from descriptor<=32768. No source-budget shrinkage for base64/JSON overhead. Epoch0..2147483647. Byte count1..purpose limit. Staging/sealed input TTL900 seconds; beginning/writing/reconnecting does not extend TTL. Chunk index0..63, contiguous, raw length1..8192; same-index same-hash/size retry accepted, different content rejected. Exact canonical base64 and chunk/content SHA256 checked. Seal requires complete count/hash; sealed objects immutable. Read offset0..1048576, limit1..32768. Same owner and unexpired/unrevoked sealed object required. Revocation tombstones are idempotent; future reads fail.

## Descriptor (separate immutable payload)

Exactly these fields, nullable parent fields **present as explicit null**, not silently omitted:

```json
{"version":1,"executionID":"<run UUID>","threadID":"<matter UUID>","sequence":0,
 "parentRunID":null,"parentFingerprint":null,"startsAlternatePath":false,
 "model":"<exact registered model>","format":"openai.responses.v1",
 "requestDigest":"<SHA256>","requestBytes":524288,
 "maximumResponseBytes":1048576,"maximumOutputTokens":4096,
 "evidence":[{"evidenceID":"<UUID>","snapshotDigest":"<SHA256>"}]}
```

Sequence0..1000000; evidence<=100, unique evidence UUIDs; parent fingerprint nullable SHA256. Model1..150 characters, no controls. Response budget1..1048576; output tokens1..4096. Execution/model/hash/byte count/output-token budget must match submit and raw request. Evidence digest is the consumer's immutable snapshot digest; ARL binds it, does not read/independently reconstruct the Ledger. Tisra remains responsible for evidence extraction, citations and local ledger commit validation.

## Submit and receipt

```json
{"schema_version":1,"run_id":"<reviewed execution UUID>","epoch":0,
 "request":{"payload_id":"<UUID>","sha256":"<SHA256>","byte_count":524288},
 "descriptor":{"payload_id":"<UUID>","sha256":"<SHA256>","byte_count":1234},
 "provider":"<host-selected registered provider>","model":"<exact model>",
 "model_fingerprint":"<registered adapter/model revision>",
 "request_format":"openai.responses.request.v1",
 "output_format":"openai.responses.envelope.v1",
 "history_version":"openai.responses.history.v1",
 "max_output_tokens":4096,"priority":"explicit","deadline_ms":60000}
```

Three wire versions negotiate independently; local semantic format string is not authentication/compatibility proof. Host grant pins provider/model/model fingerprint/auth_epoch/max tokens. Adapter must explicitly implement these formats and upstream hard token cap. Source ResponsesAdapter is disabled by default and declares evidence `implementation_only`; fixtures declare `test_double`. Neither implies a real accepted provider. Host must separately grant the provider, call budget and any credential resolver. Provider string/fingerprint<=200 characters. Deadline1..600000 additionally bounded by AppPolicy max_deadline_ms; host bands constrain interactive/explicit/background. Default policy only explicit/60000ms. No caller can promote itself. One shared tool worker, existing aging and nonpreemptible-call behavior retained.

Receipt has exactly:

```json
{"schema_version":1,"job_id":"<UUID>","owner":"<verified app fact>","run_id":"<UUID>",
 "request_sha256":"<SHA256>","epoch":0,"auth_epoch":"<host grant revision>",
 "state":"queued","provider":"<registered provider>","model":"<exact model>",
 "model_fingerprint":"<revision>","request_format":"openai.responses.request.v1",
 "output_format":"openai.responses.envelope.v1","history_version":"openai.responses.history.v1",
 "result_ref":null,"error_code":null,"cancel_requested":false,"external_stop":"not_started"}
```

States queued/running/succeeded/failed/cancelled/needs_unlock/needs_review. Result_ref null or `{payload_id,sha256,byte_count}`. External_stop only `not_started|unknown`: we do not claim upstream cancellation confirmation. Owner is matching evidence, never caller authority. SDK verifies job/owner/run/hash/epoch/provider/model/formats. Consumer must also validate local ledger epoch/cancellation before committing. Generic submit/get/cancel/resume reject this tool; use typed methods. No1MiB reply in a single RPC.

Owner+run UUID persists as a unique tombstone. Semantic digest includes both content hashes/counts, descriptor, epoch/provider/model/versions/budgets/schedule, excluding only opaque handles. Resubmitting with reuploaded identical content returns original job; changed semantics conflicts. Same run never renews deadline or starts a second inference, even after blobs expire. Crash during external invocation recovers as needs_review, not replayable. Tool invocation and call admission use the existing persistent queue/call budget; one transaction registers job/run/request binding/reply reservation together.

Cancellation, payload revocation, grant revision/revocation (`replace_grant`, host-only), input expiry and in-flight deadline invalidate publication. The worker's result publication and job completion are one SQLite transaction/CAS against these facts. Late external completion is discarded; uncertain external work is needs_review. Cancelling after success revokes future reply reads; previously delivered bytes cannot be recalled or an external call undone. Input TTL/deadline no longer invalidates a committed success merely by time passing: reply has independent24h TTL. Explicit request/reply revoke or grant cancellation still invalidates it. Reply expiry returns payload_expired and never starts a new run.

Storage bounds: <=16 active objects/owner, <=8MiB reserved bytes/owner, <=16MiB globally. Maximum response storage is reserved **before** inference/call-budget admission. <=4096 persistent payload tombstones total and <=256 run tombstones/owner; exhaustion fails closed until reviewed maintenance. Cleanup clears expired/revoked logical blob content/chunk records; SQLite/WAL forensic erasure is not promised. No automatic tombstone deletion permitting key reuse. Private service home/state mode inherited; original research bytes are private durable data, excluded from diagnostics/audit. This optional extension belongs to an execution profile, not metadata-only deployment.

Finite failures include invalid_arguments, invalid_payload, descriptor_mismatch, payload_not_found/expired/revoked/immutable/not_sealed/hash_mismatch/binding_mismatch, invalid_chunk_order, chunk_conflict, payload_budget_exceeded, research_budget_exceeded/not_authorized/not_found/receipt_mismatch/invalidated, idempotency_conflict, unsupported_research_format/provider, typed_research_method_required, deadline_exceeded, result_too_large, invalid_provider_response, provider_unavailable/rejected, research_provider_error. No upstream exceptions/body/keys enter error messages or logs. Outer existing identity/policy/frame errors remain.

## Provider boundary

The raw OpenAI body is parsed only to reject unsupported fields/types/budget drift, then transmitted **unchanged**. Current Tisra fixed root accepts model,store=false,stream=false,background=false,truncation=disabled,max_output_tokens,include=[reasoning.encrypted_content],input,text,instructions. Unknown root/action/tool fields are rejected, never silently stripped. User string content and prior message/reasoning output are supported; encrypted fields preserved. Structured format name sourced_research/strict=true required. Upstream reply must have ID, exact registered model, completed|incomplete status and output array; all envelope fields/bytes retained, including encrypted reasoning and incomplete details. Token usage, if supplied, is validated against the cap. Exact model snapshots should be registered; aliases that resolve to a different returned model currently fail closed.

ResponsesAdapter posts only https://api.openai.com/v1/responses via owned killable I/O worker, no redirects/proxies/retries. Host credential callback only when explicitly enabled; key passes over private stdin, never argv/env/files/logs. Whole-call deadline/cancel terminates local worker; upstream outcome/cost remains uncertain. It is implementation-only, not an approved cloud fallback. Official [reasoning guide](https://developers.openai.com/api/docs/guides/reasoning) documents max_output_tokens including reasoning and preservation/replay of encrypted reasoning output; this does not establish model availability, price, input-token or dollar-budget acceptance on this Mac.

Codex0.159 text adapter remains **codex.appserver.text.v1**, lacks the required hard output-token parameter, and is explicitly rejected by this Responses research contract. No string-to-Responses conversion, missing history substitution or fake token ceiling. To use Codex for Tisra requires explicit consumer migration to a separate typed request/output/history contract with honest byte/time/call budget, or a future upstream protocol that really supports the required hard token cap. This is a concrete compatibility decision, not a missing permission.

## Reproduction and evidence

```sh
cd /Users/<user>/Repository/ARL
swiftc -swift-version 6 -module-cache-path .run/swift-module-cache examples/ARLClient.swift integrations/tisra/ARLResearchClient.swift integrations/tisra/ResearchSmoke.swift -o .run/research-swift-smoke
PYTHONPYCACHEPREFIX="$PWD/.run/pycache" python3 -m unittest tests.test_research tests.test_research_swift tests.test_responses_adapter tests.test_scheduling tests.test_codex_server tests.test_review_regressions tests.test_runtime -v
```

Socket/process tests need the existing isolated-test approval outside sandbox bind restriction. New standalone Swift wrapper does not modify shared SDK, UI or Tisra repo. Real compiled native peer + kernel PID/birth/executable registration -> source runtime -> synthetic provider exercised512KiB request and1MiB response. Python path also tests arbitrary extra upstream envelope fields and encrypted reasoning byte preservation. HTTPS worker network is mocked; real credentials/network/paid Responses and real Codex turn are unaccepted. Calendar frozen package/TCC/personal events untouched.
