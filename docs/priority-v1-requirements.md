# ARL task priority and negotiated admission v1

User requirement recorded from the root handoff at 04:57:30 and 04:59:16: ARL's
model queue must let time-sensitive household work pass Tisra background work;
priority belongs in the App handshake and submission protocol, with negotiation
that handles future Apps. Implement in an isolated source candidate first.

Task kind determines realtime, interactive, or background service. Friday is not
permanently above Tisra: Friday household realtime passes Tisra background;
Tisra interactive passes Friday background. A trusted host grants tool/task kind,
maximum class, resources and limits. An App request never grants itself a class.

`priority.negotiate.v1` accepts `requested_profile` and returns an opaque,
identity-bound `profile_id`, boot/policy `policy_epoch`, effective allowed classes,
task kinds, per-resource concurrency/reservation/queue and per-App burst limits,
adapter cancellation facts, and finite reasons. Unknown authenticated Apps get
background only and no new tool permission. Unauthenticated negotiation fails.
All connections of one App share durable call, pending, burst and service budgets.

`priority.submit.v1` carries the tool/key/args plus a scheduling request containing
profile and policy epoch, task kind, requested class, absolute total deadline,
resource kind, estimate, interrupt/fallback flags and optional minimum class.
The server computes the effective class. Existing typed research/Codex and
capture submissions accept the same optional `scheduling` object. Existing App
clients retain their wire format and receive conservative background treatment
when the trusted host enables this policy. No second Runtime or jobs queue.

Permission, identity, current grant, budget, deadline and resource checks precede
ordering. Equal-class Apps use durable weighted service accounting and deadline
ordering within each App. Bounded non-realtime bypass/aging gives waiting work a
turn without granting realtime. Overload rejects within fixed queue limits; an
explicitly permitted class downgrade stays within the negotiated grant and the
caller minimum. Low estimates are clamped to trusted task bounds and actual
overruns remain accounted for.

The existing Store claims from its single jobs queue into independent model, NAS
and deterministic-control resource ledgers. Short DB transactions never cover
adapter execution. Runtime workers share this queue; worker capacity is bounded
by explicit host resource capacity. N actual slots may reserve R for realtime.
N=1 nonpreemptible resources constrain background starts with a protection
window; impossible deadlines are refused. A busy lease past its expected return
is still busy and its future capacity is unverified. No realtime guarantee for
an unqualified or noncooperative adapter.

Cancel acknowledgement does not release a lease. Release occurs after the owning
worker/adapter actually returns, with job/attempt matching. Cancellation before
start prevents dispatch; in-flight, post-return/pre-publication, and
post-publication cancellation preserve observed committed or uncertain effect
facts. Non-idempotent or uncertain work never replays. Policy changes, restart,
reconnect and duplicate keys cannot extend an absolute deadline or restore an
old authorization. Old running leases are cleared only during Runtime recovery
after its existing lifetime lock, not by negotiation or cancellation.

Acceptance covers both App ordering directions; N2 reservation and N1 refusal;
unknown/forged profiles and shared multi-connection budgets; weighted fairness,
aging and low estimates; bounded overload/expiry with zero handler dispatch;
four cancellation cuts and completion races; restart/epoch/idempotency without
replay; resource isolation with one queue. Tests use generated data and controlled
local adapters. Actual native/model cancellation, pause/yield, slot capacity and
latency qualification remain separate and held.

No real model, NAS, credential, account, device, permission, installation,
deployment or service activation is authorized by this source work. Do not enable
a paid provider, restore Laya, kill a process to release capacity, or retry a
possibly committed effect. Upload-consumer r2 remains independently blocked and
is not part of this c699-based candidate.
