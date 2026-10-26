# Reusable Apple approval source increment

The frozen Calendar v2 helper embeds one exact acceptance event/UUID; Reminders first-use helper embeds one exact acceptance item/UUID. Their compiled seals do **not** support ordinary user proposals without a rebuild. Their tests demonstrate effect-boundary protection, not a completed production bridge. They remain controlled acceptance fixtures; Calendar is unchanged, and the separate Reminders v3 timer fix is awaiting bounded recheck.

This increment is independent source under `integrations/apple_review/`. It implements reusable native proposal validation, optional local review, a signed workflow-permit verifier, exact target binding, durable consumption and actual EventKit save adapters. Different proposals run through the same compiled code; proposals are not embedded in it. Nothing is installed/published or registered in the current host. The built library has internal composition APIs, not a published SDK/RPC/daemon. No policy or issuer is configured by default. Existing ARL/UI, tunnel tools, secrets, first-use package contents and credential workflow are unchanged.

## Two approval paths

1. **Optional local native action.** A registered, kernel-peer/signature-verified caller with a specific native-review grant supplies a strictly validated proposal. Native confirmation displays the actual target name, title, exact start/end or due time and time zone. Modal timer plus a monotonic20-second gate limits the review window. Cancellation, late confirmation, expired/revoked authority or target drift refuses Save. This path requires an unlocked session because it uses a local window.
2. **Future trusted Mio workflow.** The existing authenticated tunnel's bounded adapter performs a user-facing authorized workflow and a trusted issuer binds that decision to a cryptographic permit. The native gate verifies it instead of opening a confirmation window. There is no `NativeReviewer` dependency on this path and no `approved=true` flag. TCC is a separate first-time setup action, not an operation-time permission prompt. This path is **not published or wired to Mio**; the signer/confirmation workflow and registered native consumer are still missing.

The design therefore does not replace chat authorization with mandatory local UI. `lockedQualified` is an explicit per-operation trusted policy gate: the headless path can run with known locked state only after its actual locked-session operation has been authorized and tested. No current operation has that qualification. Unknown lock state fails closed. The fixture proves control flow without a window, not that EventKit works under the real Mac lock. Other ARL background tools are unaffected; no global lock pause, unlock/security/sleep change or FileVault shortcut is introduced.

## Proposal and permit contracts (source-only, unpublished)

Proposal tags are `apple.calendar.create.v2` and `apple.reminders.create.v2`; these are not installed tool names. Flat JSON is capped at16384 bytes, rejects duplicate/extra keys, booleans as versions, control characters and arbitrary paths/list IDs. Common fields:

```json
{"schema_version":1,"tool":"apple.calendar.create.v2","operation_id":"<UUID>","caller_id":"<trusted registered subject>","target_alias":"<granted alias>","title":"<1..300 scalars>","time_zone":"Asia/Shanghai","start":"2026-10-02T10:00:00+08:00","end":"2026-10-02T10:05:00+08:00"}
```

Calendar requires start/end, explicit offsets consistent with the named zone, exact valid civil dates and duration at most24 hours. Reminders replaces start/end with `due`, either null or the same strict timestamp; no custom alarm is added. Only one create operation exists; no existing-item reads, arbitrary lists, updates/deletes, notes, URLs, invitations or recurrence. Request SHA256 covers the **exact original bytes**; no reserialization/truncation after approval. Caller ID in the request must match the verified context, not establish identity.

Target aliases resolve through a trusted host policy to exact private identifiers and operation kinds. Clients cannot provide that map. Current real adapters resolve only the configured system default target and refuse default-ID drift, without enumeration or item fetch. The target-binding digest covers operation kind, alias and identifier. Actual target setup is still unimplemented/unperformed; fixture IDs are not real registrations.

A source `SignedWorkflowPermit` consists of issuer ID, exact signed payload bytes (at most8192), and an Ed25519 signature (64 bytes). CryptoKit public keys are supplied by trusted policy; default none. Signed payload has exactly:

```text
schema_version=1, issuer_id, permit_id(UUID), workflow_id(UUID), caller_id,
operation_id(UUID), tool, request_sha256, target_alias, target_binding_sha256,
issued_at_ms, expires_at_ms, max_effects=1, policy_epoch
```

The issuer must be individually granted to that caller; all proposal/target fields match, signature verifies, epoch matches, issued time is recent, and TTL is at most10 minutes. A monotonic deadline supplements wall expiry. Native grants, workflow issuers, public keys, target bindings, registered peer generation and authorization/readiness are rechecked before commit. Public settings gets no write authority. The MAC verifier takes a kernel socket token and controlled registration epoch; it validates dynamic Security code identity and refuses old registrations after revoke/re-enroll. An arbitrary audit-token JSON or shared Python executable is not a trusted peer.

Private journal markers use exclusive creation and file/directory fsync for operation UUID, permit UUID and bounded policy budget (1..16 effects per caller/epoch). They contain no title/body/list identifier/key. The operation is consumed before metadata/review/effect; restart, concurrent call, canceled review, uncertain save or lost receipt cannot replay it. No reset/delete/resume API exists. Initial cancellation occurs before admission; precommit cancellation/revocation refuses the effect. After entering synchronous EventKit Save, cancellation/revocation cannot guarantee an immediate stop or undo. Success is not relabeled by a late cancel; error/interruption remains uncertain and requires review, with no automatic compensating delete. The future host must provide a bounded owned-process runner and persisted ARL receipt handling; the source library alone is not that production lifecycle.

Receipt includes numeric schema_version1, operation UUID, request/target-binding hashes, `persistence=saved_local`, `cloud_sync=not_checked`. No secret, target identifier, title or content is logged/exported by these mechanics.

Library proposal/permit size bounds are separate. A future transport must enforce its whole-frame limit, rejecting oversized envelopes or using the existing owner-scoped immutable payload mechanism. It must not truncate or reserialize already-approved request bytes to fit arl/1.

## Minimum remaining work before ordinary Mio writes

- Reconcile and review a real host/helper embedding this gate under approved stable app identities; install a bounded runner and adapter, register its signed process, and integrate ARL job cancellation/receipt matching. No per-event rebuild is then needed.
- Implement the trusted adapter's exact human-facing authorization workflow using **actual** existing tunnel authentication/confirmation evidence. A tool argument saying approved is insufficient. If the connector provides no verifiable confirmation evidence, define an explicit bounded workflow rather than infer it from model prose. No new tunnel is needed.
- Provision/review the issuer authority and secret storage separately. This increment creates only ephemeral in-memory test keys; no real signing key, token, credential resolver or persistent grant exists. Do not reuse or expose existing Amap/travel/tunnel keys as approval material.
- User approves exact tools, target registration/default-ID metadata scope, bounded effect budget and normal chat authorization policy. Initial OS permission is Calendar write-only for event create, Reminders full access for reminder create; OS Reminders access is broader than this app's operation policy.
- Perform approved real unlocked and then locked-session per-operation acceptance before enabling lock qualification. No restart/logout/automatic unlock, real personal reads or writes occurred during source tests.
- Publish only the approved capability through the existing Mio entrypoint, preserving current tools; verify tool visibility, typed schemas, refusal/error states, owner isolation, actual target/item persistence and uncertain-outcome handling. None of these deployment/publication steps is approved by this source increment.

Permission alone does not implement the missing consumer/issuer/workflow/runner. The acceptance helpers remain useful for first TCC/one-shot validation but do not make Mio's ordinary requests operational.

## Source evidence

`/bin/sh integrations/apple_review/build.sh` compiles the real EventKit/AppKit/Security adapter library without launching it. `python3 -m unittest discover -s tests -p 'test_apple_reusable_review.py' -v` runs seven grouped regressions with synthetic proposals, injected effects and ephemeral fixture keys. It includes real kernel audit-token/signature/revocation checks, two different proposals using one binary, no-window locked workflow control flow, forbidden flags/identities/permits, expiry, budgets, concurrent/restart suppression and late cancellation. Actual EventKit/TCC/GUI/Mio behavior remains unaccepted. See `docs/evidence/apple-reusable-review-source.json` for exact hashes/results.


Next source increment: [concrete Mio Calendar consumer](MIO-APPLE-CONSUMER.md) implements controlled native stdio host/gateway and an explicitly setup-delegated private-tunnel route. It does not assert a verified human-chat permit. Its signed source bundle seals UNAPPROVED, setup/production paths remain inactive, and frozen first-use packages are unchanged.
