# NAS Codex v2 consumer and native package settings

Deployed 2026-10-24 for the existing Friday NAS PDFMathTranslate and BiliNote audiences. The primary ARL app exposes owner-controlled package configuration through PreferencesView.swift (build 133). Existing v1 callers keep their policy; no implicit registration or public model API is added.

`nas/` contains the fixed host, SDK worker, OpenAI compatibility and original-application launch integration. `core/` contains the v2 package registry and atomic resolution/admission gateway. `runtime-v2.patch` applies only to the identified frozen NAS host baseline, whose manifest digest is recorded in `source-manifest.json`; it is not a blind patch for the current primary runtime. Preserve the existing private host configuration, peer registration/signature pins when rebuilding. The historical provider hash is provenance only; current official updates require a valid OpenAI code signature and a fresh protocol/model preflight. Admission and completion still pin the exact running binary. Credentials and live configuration are intentionally absent.

The five stable package IDs are low, medium, high, very_high, highest. Each independently selects a catalog model, supported reasoning effort and default/Fast tier. Legacy rows without service_tier retain default. Current model/list metadata refreshes during host preflight independently of inference readiness; the native preferences reread it every five seconds and preserve unsaved drafts. Removed choices remain visible and invalid rather than being silently reassigned. Owner edits use revision checks and atomic writes. Admitted jobs retain their resolved tuple and package revision. The wire gateway reuses confirmed arl/1 sessions, binds canonical content hashes and resolves original request IDs without replay.

Current NAS policy inherits the existing Codex account with no cumulative local call cap, one inference at a time, provider-enforced model context (no fixed 8 KiB input cap; 64 MiB transport envelope, no silent truncation), 32 KiB output, 180 seconds execution for existing consumers and 600 seconds for Robin analysis, owner-selected upstream tier and explicit queue priority. Fast is admitted only when advertised by the selected model; package revisions and actual tier are frozen in each resolution/receipt. Tools, MCP, browser, files and multi-agent actions remain unavailable. Unsupported token caps are rejected. Missing upstream usage windows remain unknown.

OpenAI clients can use real model + reasoning_effort, a server-issued readable option such as arl/option/gpt-6.1-sol/low, or only arl/package/medium. Treat option IDs as catalog-issued identifiers, rather than guessing combinations. BiliNote connectivity testing checks model metadata and does not claim inference success.

Validation: 16 focused v2 tests and 13 existing v1 regression tests passed. Four actual application tasks passed (both explicit and package mode in both apps); provider model/effort/default-tier acknowledgements matched, and the durable admitted-call counter increased by exactly four. Live receipts and synthetic PDF/video outputs are retained in the owning task workspace, not published here.

Reproduce the 16 focused checks against the identified staged NAS runtime:

```sh
ARL_V2_RUNTIME=/absolute/path/to/runtime PYTHONDONTWRITEBYTECODE=1 python3 -B -m unittest discover -s integrations/nas_codex_v2_20261024/tests -v
```

These tests use temporary state and a synthetic provider, without account or network calls.

To stage a tested update from an intact existing private closure, run `python3 integrations/nas_codex_v2_20261024/stage_update.py --base /private/existing/release --output /private/new/staging`. The output retains private configuration and identities and must remain private. The helper never installs or starts a service.

Running requests retain their frozen admission across metadata/preflight refreshes. Authorization and exact binary integrity remain checked throughout execution and completion. Official binary updates are deferred while a turn is running. Admitted failures return HTTP 422 with `x-should-retry: false`; clients must inspect the retained request rather than automatically replay it. Native token usage/context receipts describe the actual selected model.

Robin long analysis uses a frozen 600-second execution deadline and a 720-second queue intent lifetime; other consumers retain 180/300 seconds. The gateway applies the resolved schedule to the durable job deadline, rather than merely echoing it in metadata. SDK and HTTP waits include completion/cancellation margin. This is a bounded execution allowance, independent of token context capacity.

The NAS Robin launcher is `nas/robin_launch.py`; it loads `nas/robin_client.py` before the upstream LLM factory. Only the owned loopback ARL endpoint gets a 740-second HTTP wait and zero automatic retries, including transport failures after possible admission. Other provider factories and upstream 50/10/8000/4 collection defaults are unchanged. A client failure requires inspecting the retained original request.

## Stream timing and read-only RPC recovery (2026-11-01)

The provider keeps full binary and closure verification. JSONL events already read in one bounded pipe batch are parsed together; full context checks run before the next OS read/wait and before inference/result publication. This avoids hashing the same provider binary again for every buffered text delta. The original binary/closure hash implementations are unchanged. Buffered completion after cancellation remains rejected.

Only explicitly rejected, idempotent `config/read`, `account/read`, and `model/list` requests with a recognized temporary error can recover, at most twice within the original deadline/session. Initialization, thread creation, inference and ambiguous transport failures are never replayed. Failed results retain finite RPC method, error code/category and timing without input, output, reasoning or raw error text. The SDK transport still has zero automatic inference retries.

`nas/robin_timing.py` records stage boundaries through the upstream callback without altering collection settings; `robin_ui.py` installs it in the actual Streamlit child. Core receipts separately mark metadata readiness, turn send/ack, first output and completion, and count pipe reads versus stream events. These measurements include network/local processing and are not GPU compute telemetry.

Regression checks: `python3 -m unittest tests.test_codex_rpc_diagnostics -q` plus the staged v2 suite above. Use the private run receipts for installed/live performance acceptance; do not publish captured requests or user reports.
