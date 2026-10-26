# Notes native host candidate

Source-only, default-off follow-on to the independently reviewed Notes timing-v2 engine. No installation, service restart, TCC prompt, Notes metadata/content access, effect, production caller registration, Mio publication or private-key signing has occurred. Bundle `local.arl.notesbridge` / executable `ARLNotesBridge` is ad-hoc signed; a production consumer must pin the exact approved helper build, not trust this bundle ID alone. Neither the installed ARL release nor UI/shared SDK is changed.

## Implemented

- Concrete AppKit `NSAlert`: exact plaintext title/body and registered folder name, selectable scrollable text, create/cancel. Timer runs in modal-panel and common modes; shared absolute monotonic/wall expiry and bound cancel dismiss the modal. The final engine admission rechecks peer/policy/target/budget/time after external readiness. Already-reviewed engine sources are unchanged.
- Private typed consumer/host: immutable original proposal <=16 KiB, canonical base64/hash/count, request frame <=32 KiB including LF, response <=4 KiB including LF. This is a helper protocol, not an enlargement of `arl/1` or a published tool. Canonical operation UUID, raw hash and target hash bind the receipt; no note ID/content/path is returned or logged.
- `NotesHostConnection`: fixed inherited connected FD 3; kernel peer PID/uid/audit token and exact code requirement plus live registration generation are checked through existing `AuthenticatedCaller`. No listener, executable/path selection, enrollment endpoint or caller-supplied grant/approved flag. Poll slices continue to the absolute deadline. Same-session cancel binds active UUID+raw hash; disconnect cancels admission. Cancel acknowledgement is not evidence that a non-preemptible AppleEvent stopped or was undone.
- Actual `--serve-controlled` composition: signed resource with SHA compiled into executable; current resource disabled with null caller requirement/target/expiry. A separately reviewed active build can supply one exact pinned parent, registered top-level non-shared target, fixed policy epoch, 1–3 durable attempts and <=5-minute remaining lifetime. The state directory comes from OS uid home lookup at `Library/Application Support/ARL/notes/state`, must already exist with safe ownership/mode, and cannot be chosen over RPC/environment. Repeated starts with the same policy epoch retain attempt claims. Only after verified peer and state setup does the host initialize AppKit. Every create uses native review; no workflow issuer/key is enabled.
- The real Notes adapter compiles into the bundle; no arbitrary script, existing-note rewrite, attachment or URL input. Permission checks do not request TCC. Default/helper flags cannot enable the profile.

## Verification and reproduction

From ARL root:

```sh
python3 -B -m unittest tests.test_notes_host -v
sh integrations/apple_notes_host/build.sh /tmp/arl-notes-host-new-output
```

Build output must not exist. The Swift fixture uses the real host, wire, consumer, native review controller and modal-mode timer, but injects a fake presentation/store/in-memory transport. It proves request→full review→one injected creation→matched receipt, modal expiry/cancel/disconnect, pre-display expiry, decline/revocation, spoof rejection, mismatched cancel isolation, raw hash tampering, durable restart replay rejection, budget and lost/mismatched replies with no auto retry. No real NSAlert is shown and no Notes method is invoked. The bundle compiles actual NSAlert/native effects/kernel verifier; disabled launch/help/status/controlled-serve are tested as closed gates.

## What this candidate does not prove

Actual native pixels/AX/modal dismissal latency, registered signed producer roundtrip over macOS IPC, TCC approval, folder metadata setup, real create, cloud sync and locked-session behavior are untested. The consumer's synchronous socket exchange is intended for a controlled producer worker, not an app UI thread. It does not yet provide product-level concurrent cancel-response demultiplexing; a producer must serialize receive ownership and arrange an independent bound cancellation write. In-memory cancellation tests do not prove that product integration.

This native-review path requires an awake local user for each create. It is not the user's eventual locked-session Mio workflow. The reserved engine workflow-permit route has no issuer and is not connected here; a separately approved authenticated/org-scoped Mio consumer, exact payload/target/expiry/idempotency and actual available workflow authority remain necessary. Do not accept `approved=true` or invent a platform chat approval receipt.

## Concrete first-use prerequisites

1. Owner supplies/approves an immutable controlled parent entrypoint + full dependency closure and exact code pin; implement its fixed child/FD handoff, helper pin and single-reader cancellation handling. No shared Python interpreter identity.
2. User separately approves Notes Automation for this exact helper and bounded default-account/top-level folder metadata selection, then confirms the exact non-shared target. Notes Automation is not an OS create-only permission; create-only is enforced by code. This candidate contains no TCC setup command or target discovery action.
3. Freeze/review the active sealed profile (target alias/IDs/name, absolute expiry, policy epoch, budget) and exact installer/state path. No installer/autostart/production grant is provided by this candidate. General request title/body are runtime fields, not a hardcoded acceptance note or per-note rebuild.
4. After those approvals, test one exact nonsensitive awake create and native UI expiry/cancel. Locked/headless Mio creation requires a separate implementation/permission review and real locked-session acceptance; do not infer it from shell availability or Calendar/EventKit readiness.

Calendar/Keychain packages remain frozen and inactive. Friday safeguard-blocked review is not retried by this work.
