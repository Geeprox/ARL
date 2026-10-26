# Mio health API, source increment 2026-10-01

New read-only method `settings.modules_snapshot`, `arl/1`, app `settings`, params exactly `{}`. Response schema1 is separate from unchanged overview1/settings.snapshot2. Installed0.1.1-a0b5138d84c5f712 does not yet have this method: old-host `unknown_method` must remain unavailable/fallback. No UI/shared-client changes in this increment.

```json
{"schema_version":1,"checked_at_ms":1790790365915,"modules":[{"id":"mio.gateway","name":"Mio","checked_at_ms":1790790365915,"stale_after_ms":10000,"liveness":"live","readiness":"ready","evidence":"local_client_health","external_roundtrip":"not_checked","tool_publication":"not_checked","tool_count":null,"provider_readiness":"not_checked","error_code":null}]}
```

Finite liveness `live|unavailable|unknown`, readiness `ready|unavailable|unknown`; evidence is only `local_client_health`. Other states shown above remain literal `not_checked`: this probe does not perform cloud roundtrip, tools/list or provider calls, and must never mark their permission/readiness ready. tool_count remains null instead of the outdated13 schema or presumed14 publication. Errors null or `probe_unavailable|probe_deadline_exceeded`. Timestamps integer ms, module check time nullable before evidence. Cached module check time is not refreshed by a snapshot; client treats >10000ms or future evidence as stale/unknown. Root checked_at_ms is snapshot time. Poll no faster than5s; host caches5s and permits one concurrent probe (other requests return cached/unknown immediately).

No request fields for URL/PID/path/token/provider; strict empty params. Same-UID settings public metadata exception only, no enrollment or private tool grant. Host metadata composition still execute_jobs=False and zero tool budgets. Fake settings identity cannot submit/read/cancel tasks. No owner titles/content/keys/paths returned.

Probe subprocess overall2s, stderr discarded, reads only current-user private regular O_NOFOLLOW fixed health-url.txt. Locator must be root-path http127.0.0.1 with port and no credentials/query/fragment. Only healthz/readyz GET, proxy/redirect disabled, body<=256 and exact live/ready required. No model, weather or business calls. Process cache and fixed syscall read have no persistent access setup.

Real acceptance: temporary source-host Unix RPC returned live/ready at1790790365915 with0 tasks and execution disabled. Existing installed runtime/Mio profile/service/tunnel unaffected. UI designer can consume this new method after explicit contract handoff; source-only work is not an installed connected UI claim.

Reproduce: `PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 -I script/modules_live_smoke.py`. It starts/stops only a temporary source runtime and reads only the existing fixed loopback health endpoints. Source and existing settings/Calendar scoped tests:17 passed.

UI coordination: designer01a0f313 may add this only as a minimal separate read using existing generic rpc; installed UI ships independently. This worker has no callable cross-thread message transport, so parent should forward this exact method/schema document. Do not alter ARLSettingsMethod/shared client or frozen UI here; older-host unknown_method retains unavailable/fallback.

Installed UI-only baseline is now0.1.1-f12148172f69d4ab; runtime bytes/grants still identical to prior metadata core and new method remains uninstalled. Do not delay/rebuild the delivered UI for this source method.
