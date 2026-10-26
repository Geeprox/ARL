# NAS Codex v2 consumer and native package settings

Deployed 2026-10-24 for the existing Friday NAS PDFMathTranslate and BiliNote audiences. The primary ARL app exposes owner-controlled package configuration through PreferencesView.swift (build 133). Existing v1 callers keep their policy; no implicit registration or public model API is added.

`nas/` contains the fixed host, SDK worker, OpenAI compatibility and original-application launch integration. `core/` contains the v2 package registry and atomic resolution/admission gateway. `runtime-v2.patch` applies only to the identified frozen NAS host baseline, whose manifest digest is recorded in `source-manifest.json`; it is not a blind patch for the current primary runtime. Preserve the existing private host configuration, peer registration/signature pins and provider binary pin when rebuilding. Credentials and live configuration are intentionally absent.

The five stable package IDs are low, medium, high, very_high, highest. Each independently selects a catalog model and supported reasoning effort. Owner edits use revision checks and atomic writes. Admitted jobs retain their resolved tuple and package revision. The wire gateway reuses confirmed arl/1 sessions, binds canonical content hashes and resolves original request IDs without replay.

Current NAS policy inherits the existing Codex account with no cumulative local call cap, one inference at a time, 8 KiB total input, 32 KiB output, 180 seconds execution, default upstream tier and explicit queue priority. Tools, MCP, browser, files and multi-agent actions remain unavailable. Unsupported token caps are rejected. Missing upstream usage windows remain unknown.

OpenAI clients can use real model + reasoning_effort, a server-issued readable option such as arl/option/gpt-6.1-sol/low, or only arl/package/medium. Treat option IDs as catalog-issued identifiers, rather than guessing combinations. BiliNote connectivity testing checks model metadata and does not claim inference success.

Validation: 16 focused v2 tests and 13 existing v1 regression tests passed. Four actual application tasks passed (both explicit and package mode in both apps); provider model/effort/default-tier acknowledgements matched, and the durable admitted-call counter increased by exactly four. Live receipts and synthetic PDF/video outputs are retained in the owning task workspace, not published here.

Reproduce the 16 focused checks against the identified staged NAS runtime:

```sh
ARL_V2_RUNTIME=/absolute/path/to/runtime PYTHONDONTWRITEBYTECODE=1 python3 -B -m unittest discover -s integrations/nas_codex_v2_20261024/tests -v
```

These tests use temporary state and a synthetic provider, without account or network calls.
