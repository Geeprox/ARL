# Mio reusable Calendar consumer — candidate v4

Source-only, installed metadata/UI and existing14 tools unchanged. Frozen Calendar v2/Reminders v3 first-use fixtures are independent and unchanged. `integrations/mio_apple_deployment/ACTIVATION.md` is the single conditional activation/rollback scope; candidate requires independent review and explicit user approval. Local models remain canceled.

## Actual consumer

Native controlled host → official tunnel-client → signed gateway. Kernel audit token/signature and actual direct-parent PID/birth bind the gateway; shared interpreter paths/client-supplied app ID are not identity. Existing14 responses/schema order remain exact. New `mio_calendar_create_v1` is listed only during a granted session. Org delegation is not owner authentication or signed user-chat approval. Same tunnel/plugin/formal key reference; no key values travel over RPC/logs/argv.

Seven required fields: operation_id UUID, target_alias approved_calendar, title<=300, time_zone IANA, explicit start/end matching zone offsets and duration<=24h, expires_at_ms within60s. Strict schema rejects caller/approved/permit/paths/extra fields. Canonical request bytes/hash/target are bound; durable operation/permit/budget consumption precedes target resolution/save. Unknown effects do not replay. EventKit save_local does not claim cloud sync. Calendar write-only access requested only by explicit native setup; existing full access recognized without requesting it.

## Supported setup and identity

Static schema2 deployment ceiling fixes private state/profile/health paths, org/tunnel, default-calendar target rule, three attempts, one hour and locked qualification0. Candidate package seals this ceiling into signed Info BEFORE any TCC; no target/expiry or app bytes change afterwards.

Host starts read-only, lazily avoiding EventKit store initialization. Opening the installed helper sends authorize_session through a signature-verified local control socket. No target/grant fields accepted. Host spawns the same signed helper as a controlled child, checks its live signature and receives only its private stdout pipe. Native child displays org-level delegation, requests write-only TCC if needed and confirms the exact default target with modal/monotonic20s expiry. Runtime target/expiry stay in memory; an exclusive durable session marker prevents renewal. Disk files cannot import authority. Child setup has a180s host deadline and bounded owned termination; consent/TCC are injected in tests, never run on real data.

Expiry/revocation disables only creation, keeps original14/health available. Gateway idle/reconnection does not end host/client; registered peers reverified each connection. Restart loses session, stays read-only and does not reset consumed attempts or read an authority receipt from disk. This initial3-attempt trial is reusable for arbitrary valid user fields; it is not an acceptance-event-only helper. Renewed/persistent grants are separate future reviewed scope.

## Lifecycle

Host single-instance flock/private700 state; listener/lock descriptors close on exec. Native launcher verifies parent signature/config/client hash, creates a dedicated process group then execs the fixed official client. Preserves original health-url-file. Shutdown signals only captured PID/birth/controlled group, escalates boundedly and proves/reaps group disappearance. Recovery never kills a PID from a stale marker; absent old group plus exclusive lock required to remove fixed runtime objects. Journal retained. Unknown identity/quiescence stops rather than starting a second client.

Installer uses fixed python -I launcher, fullset/hash guards before imports, exact original agent/profile baselines and named launchd PID/kernel controlled group. Original live profile/server/key remain untouched; same agent points at native read-only host. Failure restores byte-exact original agent after proven quiescence, one bootstrap/health check, no blind retry. App/journal retained inactive; no event undo or TCC revocation claim.

## Reviewed effect/transport boundaries retained byte-identical

Independent parent-reported recheck closed P1/P2 at aggregate424cc6be…0547. ApprovalEngine final readiness is followed by fresh caller/epoch/target/authority/expiry/deadline/cancel admission checks; four zero-save mutations remain durable no-replay across process restart. Cancellation after synchronous save admission cannot guarantee stop; actual saved result is retained. Transport30s slices wait to absolute monotonic deadline, retry EINTR and distinguish EOF/error; virtual600s and real pipe tests retained. Neither reviewed file changed in v3 or v4.

The v3 launcher/rollback review found two release blockers; v3 is superseded evidence, never approval-eligible. V4 disables bytecode writes before local imports and handles owned registered/no-PID, native host/no-client and setup-child states, retaining prior births/groups and fail-closed orphan checks. The legacy launchd Python container and actual official libexec payload are pinned from read-only kernel/path evidence. A new clean package and repeated isolated launcher regression are required; no cache exclusions weaken its fullset.

## Acceptance evidence and limits

16 controlled consumer groups,7 shared gate groups, native host lifecycle/profile groups and fake-HOME installer tests are separately recorded in frozen evidence. Host/setup private pipe/signature, process group termination, reconnection and kernel peers are actual processes. Official `profiles add` parses an offline equivalent dummy-reference profile without run/doctor or credential resolution. It does not prove official daemon's runtime spawn semantics: first explicitly approved start must verify actual direct child, ready/health and14 schemas before setup/publication; fail-closed rollback if unsupported. Native TCC/real effects/tunnel start/publication/locked write not tested.

Observed audience: Personal org <USER_ORGANIZATION_ID>, empty workspace associations, one visible current member and no invitations, per parent. No creator-only ACL proven. Explicit org-wide limited delegation can be accepted based on supported tunnel access; exact intended app/profile/tunnel association still requires coordinator corroboration. All legitimate org tunnel invokers/other connections may use approved capability, including access changed during window. Do not use openai/subject/approved=true as verified owner identity. If user wants owner-only, supported per-user auth path remains additional work. See official [tunnel](https://developers.openai.com/api/docs/guides/secure-mcp-tunnels) and [auth](https://developers.openai.com/plugins/build/auth) docs.
