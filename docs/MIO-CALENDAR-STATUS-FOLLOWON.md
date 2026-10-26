# Actual Mio Calendar helper status — follow-on, not implemented

This records an acceptance item only. Frozen v4 package, source hashes, signing identity and activation plan are unchanged. Installed ARL metadata/UI and existing14 tools remain unchanged. This does not block the current activation review or imply that Calendar is ready.

## Existing gap and authoritative source

V4's native `local.arl.mioapplebridge` host owns the actual EventKit effect identity, native-confirmed in-memory target/session and durable consumption journal. Its control socket currently accepts only `authorize_session`; there is no status command or status RPC. ARL's existing `settings.modules_snapshot` observes the legacy client health route only. Neither generic Apple helper permission nor loopback ready proves this helper's Calendar create readiness.

Smallest follow-on: add a strictly read-only `status` operation to this host's existing signature-verified control socket, plus a non-UI `--status` mode in the same signed helper executable. The CLI queries the authenticated live host; **EventKit permission is checked inside the actual effect host**, not ARL, Settings, a standalone different EventKit helper, or a status CLI's inherited TCC attribution. Static `EKEventStore.authorizationStatus(for: .event)` needs neither a store nor a permission request. Do not invoke any request-access API from status, initialize an unneeded store, enumerate calendars/events, or resolve an event.

The client and host must verify kernel peer identity and the expected installed helper signature/seal. Reuse the fixed private socket/installed path and accepted identity, without adding a network listener, token, tunnel tool or write grant. The helper command must not fall through to the default app-launch `authorize_session` behavior.

Native snapshot sources:

- Liveness/controlled tunnel and gateway: current captured process births and live registered peer, not only a socket file or launcher PID.
- Permission: fresh status of this exact helper; `write_only|full_access|not_determined|denied|restricted|unknown`.
- Target registration: the native-confirmed runtime binding. No identifier/title/account is returned. Registration does not prove the target is still valid. After existing authorization, an optional bounded check of only `defaultCalendarForNewEvents` against the bound target can establish current validity without enumeration/event reads. Skip the check before permission/registration; otherwise validity is unknown.
- Grant: actual in-memory session and fresh sealed policy/profile/expiry checks; `inactive|active|expired|unknown`. `activation.json.enabled` is a ceiling, never an active session. A restart cannot recover active authority from the durable session marker.
- Budget: read only the fixed maximum3 budget-slot markers for the actual policy subject/epoch, using no-follow/owner/mode checks. Add a read-only journal getter; do not call `consume`, create/reset markers or inspect operation payloads/names. Remaining0..3 includes uncertain consumed attempts. Missing/unsafe evidence yields null/unknown, never resets to3. Budget remaining is distinct from an inactive grant.
- Lock: same current session lock evidence and locked qualification0 as actual admission. Locked -> needs_unlock; unknown lock -> unknown. No forced lock/unlock, TCC or security setting operation.

## Proposed metadata contract (draft; not a callable method yet)

Separate public read `settings.mio_calendar_status`, params exactly `{}`, response schema1. Leave `settings.modules_snapshot` schema1 and existing snapshot/Apple rows unchanged. Settings public metadata access does not acquire private task/tool access.

```json
{
  "schema_version": 1,
  "checked_at_ms": 1790800000000,
  "helper_id": "local.arl.mioapplebridge",
  "capability": "calendar.create",
  "source_checked_at_ms": null,
  "stale_after_ms": 10000,
  "liveness": "unknown",
  "permission": "unknown",
  "target_registered": null,
  "target_valid": null,
  "grant": "unknown",
  "grant_expires_at_ms": null,
  "max_attempts": 3,
  "remaining_attempts": null,
  "lock_state": "unknown",
  "readiness": "unknown",
  "error_code": null
}
```

`liveness`: live/unavailable/unknown. Lock: unlocked/locked/unknown. Nullable booleans and remaining count preserve missing evidence. Error: null/helper_not_installed/probe_unavailable/probe_deadline_exceeded/identity_unverified/invalid_status. Readiness: available/needs_permission/needs_target/inactive/expired/budget_exhausted/needs_unlock/unavailable/unknown. `available` requires fresh positive permission, valid registered target, active bounded grant, remaining budget, verified live bridge/gateway and unlocked evidence; it is a snapshot, not a guarantee of a subsequent write. Each write still repeats the real effect-boundary checks. A registered but unvalidated target alone must not turn green.

ARL invokes only the fixed pinned installed executable with `--status`, bounded whole deadline2s, reply<=4096 bytes, stderr discarded and no argv/env/content logging. Cache5s, one concurrent probe; source timestamps remain the sample's actual time. Unsupported method, missing helper, deadline or stale evidence remains unavailable/unknown. No automatic install/activate/TCC/retry-effect. No event title/content, target ID/name, file paths, credentials, request payloads or key refs cross this metadata interface.

## UI mapping and acceptance

Render this as **Mio → Calendar create**, with the helper ID as its provenance. Do not recolor another Apple helper's permission row or all Calendar actions. Write/full access with an inactive/expired grant means “已获系统权限，创建授权未启用/已到期”; live alone means “服务运行”. Only fresh `available` means “可创建”. Remaining budget and grant expiry can be shown separately; they never authorize an action. Older installed hosts use existing fallback and show readiness unavailable/unknown.

Follow-on tests: different helper's TCC grant cannot enable this row; permission revoked, restart/lost memory, expired grant, zero budget, target changed/unvalidated, locked/unknown lock, missing host, stale sample, forged/wrong signer and status timeout all avoid available. Assert status causes zero TCC requests/store writes/journal changes, exposes no content, and prior methods/grants remain unchanged. After real activation, compare UI's permission/target/grant/budget to this actual host and observe expiry/restart return to inactive. Do not publish an extra cloud status tool for this.

This needs a later reviewed helper/core/UI source increment and update. Changing an ad-hoc-signed helper changes its code identity; do not assume the first TCC grant persists across that update, re-sign the frozen v4, silently trigger another prompt or declare the new identity authorized. The native permission boundary must be reverified, with separate approval if a new OS prompt is needed. No follow-on code or deployment is included here.
