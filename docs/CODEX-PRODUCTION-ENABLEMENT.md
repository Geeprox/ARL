# Codex local-client enablement proposal — not deployed

2026-10-01 Asia/Shanghai. Current installed metadata-only release remains
0.1.1-a67506b6f6ad30c0, store v2, execute_jobs=False. No execution enrollment or
model calls are authorized by this document. Local models remain canceled.

## Genuine acceptance

One earlier fresh isolated ARL call returned ARL_CODEX_OK using the existing
ChatGPT account/current gpt-6.1-sol. One newly authorized cancellation call
b551dfe7-c605-439c-9835-6f3ddf7994fc started with status inProgress; while its ARL
job was running, the test requested cancellation. App Server acknowledged the
interrupt, then emitted matching turn/completed status interrupted. Total6968ms,
one persistent call, no result published, owned process exited0. The generic
non-idempotent queue retains needs_review, never automatic replay. This is terminal
App Server evidence, not a quota refund or guaranteed immediate upstream stop.
Successful turns now send no interrupt. Nine process-fixture regressions cover
success, deadline, wrong-turn/ack-only cancellation and refused actions. No more
real model calls are planned in this milestone.

Evidence: docs/evidence/codex-live-diagnostic-2.json and
codex-live-cancel-1.json. Previous needs_review evidence remains intact.

## Exact caller boundary

| Product/owner | Candidate product identity | Required before any grant |
| --- | --- | --- |
| Tisra / tisra | /Users/<user>/Repository/Tisra/dist/Tisra.app, bundle app.tisra.dev; current metadata says ad-hoc/no TeamIdentifier | Consumer-owned immutable release and exact CDHash pin; kernel audit-token Security verification AND a scoped policy. Bundle identifier alone cannot authenticate. Current moving candidate is not enrolled. |
| Friday / friday | Existing /Users/<user>/Repository/Friday/homeplane/arl.py through its owned Python entry | Reviewed fixed launch executable/entry/args/cwd and full imported source manifest; host-controlled launch gate, exact PID/UID/birth/executable registration and revoke-on-change. A shared Python interpreter path is never the product identity. No full deployable Friday launch spec has been supplied yet. |
| ARL settings / settings | Installed local.arl.control | Public bounded metadata only; never a text execution identity. |
| Mio / mio | Existing tunnel/service | No Codex execution grant in this local-client proposal. |

Read-only Friday snapshots at this handoff: homeplane/arl.py SHA256
f584b2b71f0c4d180cf21569988b46ce7f931005cb9fe3e1d7bcd4478f91b4b8;
friday/runtime.py SHA256439b56cababc39329dfc41c5634671b6e434940bda691779fa00f92d0663abe2.
These two hashes do not seal the full import graph and are not an enrollment.
Caller-supplied app/owner/priority cannot enroll or widen authority.

## First useful product profile, proposed limits

Enable ONE explicitly selected verified local product first. Grant only
codex.text.plan.v1 and codex_app_server_inference; methods health, ready,
capabilities, submit, get, cancel, heartbeat (submit_scheduled only if separately
included in the reviewed host policy). No resume/wake/stop/Apple/HA/NAS/tool grants.
Args exactly {model,input,max_output_bytes}; model must equal the existing account
configuration gpt-6.1-sol, input<=8192 UTF8 bytes, output128..32768 UTF8 bytes.
Result codex.appserver.text.v1 contains text, input/output hashes, actual private
thread/turn receipts, model, simulated=false; usage tokens/cost are unknown and
token_hard_cap_supported=false. Reject larger input rather than truncate.

Proposed persistent max_calls=10 per selected owner/profile, max_pending=2,
max_deadline_ms=30000; one active worker globally. Calls consume persistent budget
including uncertain started inference. No rolling/resetting budget or automatic
re-call. These are finite admission limits, NOT token/dollar/ChatGPT quota caps.
Account quota/possible usage impact must be accepted explicitly; no paid API,
other account/model switch, fallback or fresh credentials.

Default allowed band explicit. Interactive is available only when the host grants
it for the selected explicit foreground action; background receives no initial
grant. Queue ordering interactive>explicit>background, aging one band/30s,
oldest tie-break, original persisted deadline unchanged on reconnect. No caller
claim of foreground bypasses grants. One running inference cannot be preempted
for another job: cancellation interrupts its exact owned turn, waits for bounded
receipt, closes the owned process; no new inference admitted while that worker
remains occupied. Whole-session30s cap is not a guarantee of response delivery.

Each call gets a temporary empty workspace, ephemeral read-only thread and
network-disabled tool sandbox. Existing provider transport may reach its account
service. Every inherited MCP entry is explicitly disabled and effective controls
checked before turn. Shell/files/browser/plugins/apps/skills/memories/agents and
approvals are disabled; requests or action items fail closed. No caller path,
endpoint/env/executable/tool configuration. Pin reviewed Codex binary0.159.0 SHA
ccd1b9441d35ce30102059c78514a125d676e6765ea1d001033e8cbe88718314;
changed artifact/control/schema requires review, no self-upgrade fallback.

## Action-time permission and remaining implementation

The product must show the exact bounded user-selected text/model/format/budget
before an explicit action; retain stable reviewed UUID and receipt. Ordinary
editing, autosave, reminders and background observation never invoke Codex.
Private selected text is sent to the existing Codex account and retained in the
private owner-isolated task queue/result; this is a specific content authorization,
not permission to scan a library/workspace. Diagnostics contain fixed event/error
metadata and hashes only; never prompts, output, reasoning or credentials.

Before enablement: (1) consumer implements this distinct text action/receipt/cancel
contract, (2) product owner freezes exact native pin or full controlled launch set,
(3) review a fixed execution host with the exact selected identity/limits and safe
storev2->v3 migration/rollback handling (old runtime must not open v3),
(4) obtain approval for that persistent execution profile and selected content/
existing-account usage, then isolated product and actual installed acceptance.
Current production host still cannot execute jobs; a settings toggle alone cannot
complete this. No new OS TCC permission is needed for text-only calls, but any
unexpected OS/account/tool approval stops the operation.

Tisra Responses migration is separate: docs/TISRA-CODEX-MIGRATION.md remains a
consumer proposal, not implemented research compatibility. Never reinterpret its
512KiB raw-body/1MiB response/encrypted reasoning/4096 hard-token requirement as
this small text result. Friday planning likewise returns only an advisory proposal;
Friday owns validation, review and household effects, not arbitrary ARL HA calls.
