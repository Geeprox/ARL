# Codex text and scheduling — source increment

Source only. Installed0.1.1-a67506b6f6ad30c0 remains metadata-only/storev2/
execute_jobs=False. Frozen Calendar is a separate package, now superseded pending
native-boundary fixes/review. UI source/artifact remains under its own owner.
Local models canceled; no download/install/inference.

## Genuine account boundary

The separately authorized fresh isolated ARL diagnostic returned exactly
ARL_CODEX_OK (simulated=false) using existing ChatGPT/current gpt-6.1-sol, one job/
one call, total23.287s. The userMessage protocol completion is verified against
exact input as a receipt; tools/actions/approvals still fail closed. Earlier
needs_review/provider_action_rejected evidence is preserved; its old diagnostics
do not establish the rejected event's category.

The one new authorized in-flight cancellation test
b551dfe7-c605-439c-9835-6f3ddf7994fc requested cancel after turn/start response
status inProgress and while the ARL job was running. One interrupt was acknowledged,
then matching thread/turn turn/completed status interrupted observed separately.
Total6968ms, no result published; generic non-idempotent queue remains needs_review/
no replay, owned process exit0. Successful completion sends no interrupt. Ack-only
and wrong-turn fixture receipts are not successful cancellation evidence. Nine
process-fixture regressions pass. No quota refund or guaranteed immediate upstream
stop claimed; no further real model calls planned in this milestone.

Evidence: docs/evidence/codex-live-smoke.json (historical needs_review),
codex-live-diagnostic-2.json (successful text), codex-live-cancel-1.json (active
interrupt terminal), codex-cancel-acceptance.json (current delta). Historical
completed-turn interrupt was rejected and was not an active-cancel test.

## Opt-in text tool

codex.text.plan.v1 has exactly model(string<=200), input(string<=8192 UTF8 bytes),
max_output_bytes(integer128..32768). No caller endpoint/binary/cwd/env/key/tool/
schema option. Default production host has no adapter or task grant. A reviewed
host must construct it AND grant codex_app_server_inference/tool/method/budget to
a verified product. Same-account logical IDs are not authentication.

Existing binary is /Applications/ChatGPT.app/Contents/Resources/codex-cli/
CodexCLI.app/Contents/MacOS/codex, version0.159.0, SHA256
ccd1b9441d35ce30102059c78514a125d676e6765ea1d001033e8cbe88718314.
PATH npm wrapper failed ENOENT and was not repaired. Account/model remain unchanged;
no credentials copied, paid API/fallback or local-model use. Actual configured
model/account and effective controls are verified before each turn.

Each call owns an empty temporary workspace and stdio server. Every inherited
MCP entry is explicitly disabled (empty-table override merges); shell/execution/
apps/plugins/web/browser/hooks/skills/memories/agents/tools are disabled. Fixed
instructions, ephemeral read-only thread, networkAccess=false tool sandbox and
empty inherited instruction sources checked. All server requests or nontext
items rejected. Model/thread/turn receipts must match. Byte/schema overflow is
rejected without truncation; no raw reasoning/error/stdio enters diagnostics.

Result codex.appserver.text.v1 carries text, input/output SHA256, private actual
thread/turnIDs, model and simulated flag. It is not Responses envelope/history or
Tisra research/citations. Codex0.159 TurnStartParams has no hard output-token
parameter: only output BYTES, monotonic whole-session TIME and persistent call
admission are bounded. Token/cost usage remain null and token_hard_cap_supported
false. Do not imply a4096-token/dollar/plan quota ceiling.

Cancellation/deadline is polled<=50ms; one turn/interrupt only for a known unfinished
turn. Cancellation drains ack/terminal for<=3s without extending original deadline,
then closes its owned process with bounded kill fallback. Ack and exact terminal
are separate; terminal completed during a cancel race is not interrupted. No new
inference is admitted while its worker is occupied. Non-idempotent uncertain calls
retain needs_review/no replay; result publication checks local cancellation.
See CODEX-PRODUCTION-ENABLEMENT.md for the bounded product proposal and remaining
actual identity/consumer/host approval gaps.

## Priority/deadline source API

Source storev3 adds persisted priority/deadline_at/deadline_span; installed storev2
is untouched. Older core must not open v3. Execution-profile deployment/migration/
rollback needs a separate reviewed plan, not a metadata-only update.

submit retains {tool,args,key}. submit_scheduled requires verified registered peer,
explicit method grant and exactly {tool,args,key,priority,deadline_ms}. Allowed
bands background|explicit|interactive are constrained by host policy; arbitrary
caller owner/foreground claims cannot grant priority. Default policies allow
explicit only and do not grant submit_scheduled. Deadlines are positive integers
within host max_deadline_ms; Boolean/fractional/unbounded values rejected. Original
schedule participates in logical-key digest; reconnect never refreshes deadline,
changed schedule conflicts.

One global worker deliberately bounds concurrency. Eligible work ranks
interactive>explicit>background; each30s aging promotes one band, capped interactive,
oldest-created tie-break. Background reaches equal rank after60s. Persisted
arrival/deadline survive restart; retry backoff, owner pending/call limits remain.
No invented memory/GPU admission or instantaneous preemption claims.

Expired queued jobs fail deadline_exceeded without handler execution. Cooperative
read tools reject stale results. A committed non-idempotent external write remains
a completed effect on late cancel, not fictitious undo. Noncooperative handlers
occupy the worker until ending. Tisra publication instead uses its independently
versioned typed owner/run/hash/epoch/CAS contract and explicit migration acceptance.
