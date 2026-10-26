# Control metadata API v2 — frozen wire contract

Installed metadata-only release `0.1.1-a0b5138d84c5f712` serves these schema2 reads and preserves `overview` schema1. Methods use existing `arl/1` framing, `app="settings"`; unsupported methods in older hosts return `unknown_method`, so the UI must fall back to overview and mark absent fields unavailable. No write/config/enrollment RPC is added. The `apps` wire array includes configured unregistered partitions; it is not an online-app list. Primary UI rows require registered + verified + connected and fresh nonfuture seen/verified evidence; static partitions or budgets are never connection evidence.

Bounds: name/purpose/catalog model <=200 Unicode scalars (no control/surrogate characters); IDs <=64 ASCII `[A-Za-z0-9_.-]`; capability IDs/version <=80; SF-only icon ref `sf:[a-z0-9.]+`, total <=80. Arrays <=100 except controlled processes <=32. Opaque credential aliases <=200; not shown as credential values or Keychain persistent references. Runtime start time/uptime are nullable until run begins; root checked_at_ms is nonnull. Metadata snapshot is capped at120000 UTF-8 bytes; oversized trusted manifests fail `metadata_response_too_large` instead of emitting an oversized frame.

`settings.snapshot`, params `{}` → schema_version **2**. Epoch timestamps are integer **milliseconds**, missing evidence is `null`. Numeric resource values use explicit units below. Fields:

```json
{
  "schema_version": 2,
  "protocol": "arl/1",
  "version": "…",
  "checked_at_ms": 0,
  "runtime": {"state":"starting", "started_at_ms":0, "uptime_seconds":0.0, "ui_required":false, "task_execution_enabled":false},
  "apps": [{"id":"friday", "name":"Friday", "icon_ref":"sf:house", "version":null,
    "registration":"unregistered", "connection":"never_seen", "authentication":"unverified", "authorization":"none",
    "last_verified_at_ms":null, "last_seen_at_ms":null, "stale_after_ms":30000,
    "advertised_capabilities":[], "authorized_tools":[]}],
  "providers": [{"id":"ollama", "state":"unknown", "checked_at_ms":null, "stale_after_ms":10000,
    "evidence":"none", "catalog_models":[], "model_load_state":"unknown", "inference_enabled":false}],
  "resources": {"state":"unknown", "sampled_at_ms":null, "minimum_interval_ms":5000,
    "cpu_logical_count":null, "system_cpu_percent":null, "memory_total_bytes":null,
    "memory_pressure":"unknown", "swap_used_bytes":null, "processes":[],
    "attribution":"controlled_process_set_shared_counted_once", "gpu_allocation":"unavailable"},
  "diagnostics": {"redaction_version":1, "retention":"current_process", "max_records":1024, "max_age_ms":86400000},
  "credentials":[], "apple_apps":[],
  "household": {"owner_app":"friday", "state":"not_registered", "read_capabilities":[], "actuation_capabilities":[]}
}
```

Finite enums:

- runtime.state: `starting|ready|stopping|stopped|error|unknown`.
- app.registration: `unregistered|registered|revoked`; connection: `never_seen|connected|stale|disconnected`; authentication: `unverified|verified|stale`; authorization: `none|limited`.
- provider.state: `discovered|starting|ready|degraded|unavailable|disabled|unknown`; evidence: `none|local_http|test_double|host_observation`; model_load_state: `unknown|not_applicable` (no claim of loaded from catalog); inference_enabled reflects policy, not catalog availability. Disabled remains disabled even when endpoint discovery succeeds. Timestamp describes actual check; cached results carry their original time.
- resources.state: `available|partial|unavailable|unknown`; memory_pressure: `normal|warning|critical|unknown`.
- credential.state: `not_configured|fixture|reference_only|removed|unknown`; reference_status: `unresolved|fixture|unknown`. Entries have `id`, `service`, `purpose`, `state`, `reference_id` (opaque/null), `reference_status`, `provider_revocation:"not_performed"`. No credential values, account names, endpoints or Keychain lookup. Local removal is not provider revocation.
- apple action.state: `not_implemented|needs_permission|locked|ready|unavailable|unknown`; permission: `not_checked|not_determined|denied|restricted|authorized|not_applicable`; lock: `unknown|unlocked|locked|not_applicable`. Apple app fields: `id,name,icon_ref,actions`; action fields: `id,state,implementation,permission,lock,authorized,checked_at_ms`; implementation `absent|adapter`. Authorizations are explicit host metadata, never inferred from whole-app connection; no TCC/data calls.
- household.state: `not_registered|unverified|stale|available|unavailable`; read/actuation arrays only use trusted Friday advertised capability IDs. No HA/NAS endpoint/config/token returned.

Host owns names/icons/version/capability descriptor registration. It is volatile and does not itself authenticate or grant tools. A registered app's heartbeat updates only after actual verifier acceptance; revocation clears observed identity and heartbeat. `heartbeat`, params `{}` is an app method requiring **registered verified peer + method grant**, never part of settings' public metadata exception. Authenticated `connected` is recent verified traffic, not inferred process launch. No app can submit registration/version/icon/PID over RPC. Snapshot exposes a safe descriptor with unregistered/unverified/never_seen until verified evidence exists. Advertised and authorized capabilities are separate.

Process entries: `id` (host-controlled label), `app_ids` (trusted IDs), `rss_bytes`, `cpu_percent`, `state` (`available|warming_up|unavailable`); no PID/path/argv/env. CPU is interval process CPU-time / elapsed wall time ×100, so multithreaded processes can exceed100; system CPU is non-idle/total tick delta ×100, 0–100. First interval CPU is null. Shared process appears once, with all attributable apps; RSS is resident size, not exclusive memory. Minimum sample interval5s, no arbitrary PID params. System metrics include unrelated system load; app attribution is controlled processes only. GPU allocation not measured. Pressure is an OS signal, not inferred from free RAM or swap. Unsupported values are null/unknown.

Provider discovery uses fixed local health/catalog endpoints with existing wall-clock deadlines, cached >=5s. No start/load/inference/download or paid fallback. `ready` means the provider's narrow health contract; catalog-only evidence is `discovered`. Host can record lifecycle observations only in trusted composition.

`settings.logs`, params optional `cursor`, `limit` (1–100, default50), `level` (`info|warning|error`), `event` (below), `since_ms`, `until_ms` → `{schema_version:2,redaction_version:1,records:[…],next_cursor,more,truncated}`. Default time window last15min; requested span ≤24h, no future-unbounded window. Cursor is opaque boot-specific string, maximum64 characters; invalid/foreign/future cursor → `invalid_cursor`. Dropped/expired records → `truncated=true`. Cursor advances over scanned records including filtered-out events to avoid repeated empty pages.

Record fixed fields: `sequence,at_ms,level,event,code,app_id`; `code/app_id` nullable. Events: `runtime_starting|runtime_ready|runtime_stopping|app_verified|app_revoked|provider_check|rpc_rejected`. Codes: `identity_unverified|method_not_authorized|unknown_app|unknown_method|invalid_request|invalid_arguments|not_ready|internal_error|provider_unavailable|probe_failed` only. No free text, prompt/output/model response/path/key/header/Apple content. Unknown diagnostic values are omitted/replaced with fixed safe values, not echoed.

`settings.logs_export` accepts the same filters/cursor with `limit`1–500 default500. Result `{schema_version:2,redaction_version:1,format:"jsonl",content,records_count,next_cursor,more,truncated,max_bytes:65536}`. UTF-8 JSONL ≤64KiB, ≤500records; no file-system writing. No logs of arbitrary subprocess stdout/errors or imported logs. Query/export are same-UID public redacted metadata, not authenticated private logs.

Credentials/Apple/household metadata are typed gates, not implementations of credential storage, Notes/iMessage writes, NAS browsing or HA access. Real permissions/references remain separate approvals. UI must label absent/unknown evidence truthfully.

Native credential workflow source now has a compiled separate handoff. Its opaque DTO matches this schema, but real Keychain acceptance, authenticated host registration and adapter resolution remain pending; see [CREDENTIAL-INTEGRATION.md](CREDENTIAL-INTEGRATION.md). No public mutation method or credential authority is added.

Source-only additive method `settings.modules_snapshot` schema1 is now implemented; see [Mio health API](MIO-STATUS-API.md) for exact frozen fields/states. It does not alter this v2 snapshot or its existing UI. Installed release remains unchanged; older hosts return unknown_method. It exposes fixed local-client health only, without asserting provider readiness/tool publication.
