# Apple permission control contract — source design, not published

Draft `apple_permissions.snapshot.v1`, `apple_permissions.request.v1` and `apple_permissions.settings.v1`. Existing RPC/overview remains unchanged; no handler or UI request button is deployed by this document. UI owner implements buttons separately. `~/Applications` stays the install target. No new helper bundle identity, certificate or TCC prompt is introduced here.

Every record binds the *actual responsible helper*, not ARLControl's own TCC identity: capability_id, operation, helper_bundle_id, executable_sha256, designated_requirement_sha256, observed_at_ms, permission_kind, finite permission_state, implementation_state, request_route_state, settings_route_state, and an independent operation readiness state. Evidence missing ⇒ unknown; no tool family goes green from another helper's permission. Changed code/signing must be evaluated against old/new designated requirements and responsible-process attribution before deployment. Stable bundle ID alone is insufficient.

Finite permission states: `not_determined`, `authorized_write_only`, `authorized_full`, `authorized_automation`, `denied`, `restricted`, `unknown`, `not_applicable`. Implementation: `installed`, `source_only`, `not_implemented`. Request route: `available`, `not_installed`, `not_implemented`, `blocked_identity`, `requires_user_action`. Readiness: `ready`, `needs_permission`, `needs_setup`, `needs_unlock`, `lock_state_unknown`, `grant_inactive`, `grant_expired`, `budget_exhausted`, `unavailable`, `unknown`. An authorization state is never an execution grant.

## Exact operations and permission owners

| Capability | Required permission / evidence | Manual route and current limitation |
|---|---|---|
| `calendar.create.v1` | Actual ARLMioAppleBridge `EKEventStore.authorizationStatus(for: .event)`: write-only or full | Existing reviewed v5 `--authorize-session`; currently pre-UI lock-state blocker, so request route must report unavailable until corrected. One-hour/three-attempt/default-calendar/org scope unchanged; no creation in request API. |
| `reminders.create.v1` | Actual Reminders helper `.reminder` status; full access required, not OS write-only | First-use source package exists but not installed/approved; unavailable button with setup guidance. No list/content enumeration. |
| `notes.<operation>` | Apple Events Automation *per exact Notes target*, evaluated from responsible helper using `AEDeterminePermissionToAutomateTarget(ask=false)` | Nonzero status is classified by known error code; unknown errors stay unknown. Explicit button may use ask=true only for an implemented, approved narrow operation. Append/edit preservation/locked execution remain separate acceptance. No TCC.db or direct Notes database access. |
| `messages.<operation>` | Automation per exact Messages target for ordinary AppleScript sending; actual required-file read evidence is separate for receive path | No deployed bridge/request route. No IMCore/private bridge/SIP change or message content read. `send` and `receive` readiness are separate. |

Snapshot is bounded to these fixed operation descriptors, no calendar/list names or identifiers, messages, note contents, token/credential values, private paths or arbitrary app/PID queries. Unsupported future Notes/Messages operation IDs are not advertised as implemented.

## Requests and redirects

Proposed request shape: `{schema_version:1, capability_id:<finite installed operation>, action:"request"|"open_settings"|"retest", request_id:<canonical UUID>}`. No caller-supplied app path, target bundle, approved=true, grant, permission kind or shell. A production verified Control UI connects to the existing trusted local host; an unverified caller cannot trigger a prompt, redirect or setup. Public settings logical app ID is not authorization. Exactly one in-flight manual request; duplicate request UUID does not prompt again. Cancel/timeout cannot establish a session. Replies contain finite outcome and refreshed status, never target identifiers/content. No anonymous MCP request can enter this route.

A request button describes the actual requested permission and purpose, requires deliberate user action, then executes only the fixed signed-helper route. `open_settings` uses an allowlisted OS privacy-pane redirect (if supported), never a setting write or guessed URL advertised as verified. Refresh on foreground and explicit `retest`; status polling never calls an ask=true/TCC API or necessary network operation.

Native setup uses the already reviewed private setup→host grant channel and exact default target confirmation, not ARLControl's EventKit store. Controls must surface precise preflight errors before suggesting another attempt. `lock_state_unknown` is not denial or locked, and cannot be converted to unlocked because the user sees a screen. Before a live retry, fix/review the responsible helper's actual observation/context or an explicitly accepted interaction-based setup admission design; background write policy remains independently enforced.

## Other permissions remain separate

FDA has no dependable universal preflight: report actual required-path access as `verified`, `blocked`, `untested`, with settings guidance, without content reads during status discovery. Local Network has no explicit request API: an explicit necessary connection can trigger it; arbitrary network errors are not classified as privacy denial. Network-volume Files/Folders is separate. Keychain status is per-item ACL/reference lifecycle, not a TCC toggle. Accessibility/Screen Recording apply only to implemented UI operations; do not add blanket buttons/grants. HA and NAS policy/configuration remain owned by Friday/Tisra.

## Acceptance before UI/host activation

- Actual helper identity/read status, no prompts/content from snapshot, no impersonated UI caller.
- Not-determined/denied/restricted/unknown/full/write-only and per-target Automation error fixtures.
- Unsupported operation and unverified caller request produce zero launches/prompts.
- Manual request deduplication, timeout/cancel and foreground refresh; permission != tool/session grant.
- Exact installed helper identity and designated-requirement continuity reviewed; no new certificate silently generated.
- Calendar source blocker resolved and reviewed before another native request; live permission/UI/event acceptance remains separate from these source doubles.
