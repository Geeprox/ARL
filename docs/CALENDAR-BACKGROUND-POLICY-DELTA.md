# Pending Calendar background-policy scope — exact minimal source delta

Preparation only. User reply to the proposed locked/unknown scope has not been forwarded; no policy code or installed activation is changed. Native setup source remains frozen at manifest 3a7f4ef0fc9c583300b42ca9427cf476b46bab1ab64999da8da9119a7ceffac8. Per-event native effect confirmation expansion is stopped. `~/Applications` remains the target.

## Proposed code after explicit approval

1. **CallerGrant / AppleApprovalEngine.ready**, in an isolated overlay of ApprovalEngine.swift: add an immutable native-composition-only calendar execution policy with default `awake_required`. A value such as `calendar_os_tcc_only` applies only to `.calendar`, non-native, already authorized `delegatedTunnel` callers. Validate real write-only/full EventKit permission exactly as today, then omit only the extra app-level lock predicate for that explicitly granted Calendar path. Do not modify the effect adapter's lockState, report unknown as unlocked, or mark lock support as qualified. Legacy clients, native review, Reminders and Notes retain defaults.
2. **MioActivation / NativeSession / runHost**, isolated Host.swift overlay: strict new sealed activation revision names `calendar_execution_policy: os_tcc_only`. Old schema-v2 always means awake_required; missing/unknown values refuse rather than infer approval. Host's current policy constructs the new grant from that sealed activation only, after existing code/profile/birth/caller checks. Private setup reply remains unchanged; public tool requests cannot set this policy. Keep original epoch/budget counters and consumption rules; do not reset/renew session_consumed.
3. **Package activation and seal**, future reviewed package only: include the exact user's approved policy ceiling, retain fixed org/tunnel/profile/default-target, one-hour/max-three limits and grant_on_install=none. Seal changed config before TCC. The actual app identity/designated requirement needs bounded review; no new certificate or bundle ID. No installation until approval evidence/review.
4. **Native setup**: reuse the frozen corrected source; no new per-event dialog. User performs initial OS permission/default-target confirmation while present. Background create subsequently needs no local UI. Setup continues to reject known locked when it actually needs UI; this does not restrict an already established session's approved headless create.

## All other effect admission remains unchanged

AuthenticatedCaller current/birth/registration/subject; strict AppleProposal/schema/UUID/hash; exact registered target; authorization/epoch/expiry/monotonic deadline/cancel rechecks after blocking readiness/target reads and immediately before save; durable operation+permit+three-slot consumption; no automatic replay/renewal; synchronous save cannot guarantee cancellation after admission. Non-idempotent save uncertainty is outcome_unknown, never retry/compensating delete. No requestFullAccessToEvents, no event enumeration, no blanket Apple grants, no new tool/tunnel/key.

## Focused tests when source change is authorized

Approved delegated Calendar + actual write-only/full permission admits fake effects for locked and unknown; unapproved/default/old-schema policy rejects both; actual denied/restricted/unknown TCC rejects with zero save; other tool/native modes remain denied. Retain duplicate/budget/expired/cancel/revoke/target-change regressions. Tests of save under locked/unknown use doubles until the actual helper receives OS permission; they are not real locked execution acceptance.

## What EventKit establishes and what is untested

The public EventKit SDK separates per-app authorization/request methods from synchronous saveEvent methods. The real EventKitEffects save adapter calls no permission-request/UI API; it creates a fresh event in the registered default calendar and calls save. The inspected SDK documentation does not specify an app-required unlocked-screen condition, but neither it nor this research establishes a guaranteed success contract while locked on this macOS. Missing permission, store/target failures and OS data-protection errors must be respected.

Therefore removing the ARL awake-only predicate implements the proposed authorization policy; actual Calendar locked save remains a real acceptance test, not a bypass or guarantee. Keep lock_support=not_tested until evidence. No Mac lock/reboot/security change is performed by preparation. Wait for an already locked session or separately approved lock-only test; use one new explicit test operation/payload and count it in the same three-attempt budget. An uncertain save must not be replayed.

Primary references (read-only research):
- https://developer.apple.com/documentation/eventkit/ekeventstore/save(_:span:commit:)
- https://developer.apple.com/documentation/eventkit/ekeventstore/requestwriteonlyaccesstoevents(completion:)
- Local SDK EventKit.framework/Headers/EKEventStore.h: authorization per app, separate write-only request and event save; no documented screen-lock qualification for save.
