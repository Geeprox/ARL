# Notes create source slice

Source-only, default disabled; no installed helper, RPC/tool registration, TCC request, Notes launch, personal-data read or real note effect occurred. Calendar/Mio v4, Calendar/Reminders first-use packages, installed runtime/UI and Friday candidate bytes are unchanged by this slice.

## Actual implementation

`NotesProposal.swift` parses the private `apple.notes.create.v1` flat request. `NotesApprovalEngine.swift` binds it to an actual `AuthenticatedCaller` (registered socket audit token/PID/signature/registration generation), a trusted host policy and an exact registered account/folder. `NotesAutomation.swift` is the compiled real native effect adapter: it constructs typed Apple Event object specifiers and sends `core/crel` to `/System/Applications/Notes.app`. No AppleScript/shell source is interpolated or executed. Request strings are Unicode descriptors; title and plain body are HTML escaped. Only the NEW note gets its initial `pnam/body` properties. No existing note identifier/body/plaintext/attachment is read or edited.

Codes and behavior were inspected only from local `/System/Applications/Notes.app/Contents/Resources/Notes.sdef`, `/System/Library/ScriptingDefinitions/CocoaStandard.sdef` and the installed SDK headers. `make` returns a specifier; body is HTML, plaintext read-only. This is not an append/editor or a preservation guarantee for existing rich Notes. Real Notes interoperability, exact rendered title/line breaks, cloud synchronization and locked execution are untested.

## Contract (not published)

Request <=16 KiB, exact keys, duplicate keys rejected; no truncation:

```json
{
  "schema_version": 1,
  "tool": "apple.notes.create.v1",
  "operation_id": "11111111-1111-4111-8111-111111111111",
  "caller_id": "registered_app",
  "target_alias": "notes_inbox",
  "title": "Synthetic note",
  "text": "Plain text only\nSecond line",
  "issued_at_ms": 1790811000000,
  "expires_at_ms": 1790811060000
}
```

Title nonblank <=300 Unicode scalars and1024 UTF-8 bytes, no controls; text <=8192 UTF-8 bytes, only LF/CR/tab controls permitted. Arbitrary HTML, paths, attachments, app IDs, scripts and client `approved` flags are not accepted. CRLF/CR render as line breaks; raw request SHA still binds the original exact bytes. TTL <=60s, engine monotonic admission-validity window <=20s, starting BEFORE metadata/review. This is not a hard whole-call wall-time guarantee: an arbitrary synchronous reviewer or synchronous OS call cannot be preempted by this library. Each native Apple event has <=5s reply timeout limited by the same deadline; timeout does not prove the remote effect stopped.

Receipt schema1 includes operation ID, exact request SHA, target binding SHA, `persistence=created_local`, `cloud_sync=not_checked`; no note/body/target IDs or credentials in the receipt. It confirms the scripting operation's returned specifier, not iCloud availability. Errors before admission include invalid_arguments/duplicate_key/caller_unverified/capability_not_granted/needs_permission/needs_unlock/lock_state_unknown/target_changed/approval_expired/user_cancelled/cancelled_before_effect/permit_unverified/permit_binding_mismatch/effect_budget_exceeded/operation_consumed. Errors after effect admission are conservatively `outcome_unknown`; never automatically replay them.

## Source consumption and authority

Compile these three Notes source files with the unchanged shared `apple_review/{Proposal,PeerAuthentication,ConsumptionJournal}.swift`; the build script does so. The library API is internal to the compiled trusted host; no public execute helper or arbitrary stdin bridge exists. A future pinned, signed host must expose only the engine admission route, not `NativeNotesEffects.create` directly, and must own the serialized policy and fixed private journal home. Never use app ID strings or a shared Python path as authentication.

`performNative` uses an in-process `NotesReviewer` supplied by the trusted native host: display exact title, full body and exact target name, then return the local decision. Its `confirm(proposal,target,context:)` receives a live `NotesReviewContext` with the absolute monotonic deadline, wall expiry, remaining time and cancellation signal. The engine rechecks validity immediately after target metadata and BEFORE invoking the reviewer, and again after it returns. The concrete future dialog MUST check context before display, poll `context.shouldDismiss` in the modal-panel run-loop mode, dismiss on expiry/cancel, and check again before accepting. Do not start a new20s timer when the dialog opens; metadata time counts. This source slice supplies/test-drives that cooperative protocol but does not implement/install a confirmation window or claim a proven GUI wall-time bound. `performWorkflow` supports a strictly bounded Ed25519 permit from an explicitly configured issuer, bound to raw request SHA, target SHA, caller, operation, policy epoch and identical issue/expiry times. No issuer/key/production grant is supplied. This is not a claim that Mio chat produces signed approval receipts; its separately approved organization-delegation path has not been connected to Notes here. Native per-action UI is not asserted as the eventual mandatory Mio workflow.

Before any Notes event the engine checks permission and awake state. Budget/op/permit markers are exclusively created and fsynced before external target metadata/review/effect; cancellation/refusal/uncertainty after that consumes the attempt. After the final metadata/readiness callbacks it revalidates caller registration, policy epoch, target, grant/budget, issuer, cancellation, wall expiry and monotonic deadline immediately before the synchronous make event. No callback follows admission except the actual effect. Late cancellation cannot undo/nonpreempt a sent event; success remains success, uncertain outcome remains consumed across restart. No delete/rewrite/replay/reset API exists. Changes to policy must be trusted, serialized and advance its epoch.

The target is a specifically registered top-level non-shared folder, matched by unique account+folder IDs AND expected name; no name/default fallback during writes and no global list enumeration. `NativeNotesEffects.defaultFolderCandidate(alias:deadline:)` provides a real metadata-only first-use reader after existing permission: it reads default account/folder properties, validates exact top-level IDs, and returns a candidate, without registering/granting it. The user must approve that exact target; a trusted setup host must persist the binding. Arbitrary/nested folders are not supported in this MVP. Subsequent writes inspect only the registered folder metadata. External Notes sharing/renaming/lock changes after the last read cannot be made transactional with make using the scripting API; no atomic folder-policy guarantee is claimed.

## Concrete first-use permission/target setup (not performed)

1. Implement/review the small signed-host/consumer packaging around this source library. Proposed helper identity `local.arl.notesbridge` is not yet built/signed/installed, so no stable code hash/TCC continuity is claimed. Use a fixed installation target such as `~/Library/Application Support/ARL/notes/ARLNotesBridge.app`, a private journal, controlled trusted caller registration and `NSAppleEventsUsageDescription` describing creating notes in the selected folder. Hardened packaging needs the Apple Events automation entitlement. No new LaunchAgent is part of this slice.
2. With explicit approval, first use asks macOS **Automation → Notes** permission for THAT signed helper. macOS does not provide an OS create-only Notes grant; code restricts the broader automation permission to new-note creation. This adapter never requests consent: `AEDeterminePermissionToAutomateTarget(...,false)` and all send options include `kAEDoNotPromptForUserConsent`, never-interact and don't-record. A separately reviewed setup route is needed for the initial prompt.
3. After consent, explicitly approve reading only default account/folder metadata and registering that named, top-level, non-shared folder (or provide exact metadata for another existing top-level folder). No folder/note enumeration, existing note content, target creation, or whole-account note access is needed by the implemented operation.
4. Approve one exact synthetic new-note title/body and one durable attempt in that folder, with fresh <=60s request and awake session. Test actual rendering and Notes receipt. No existing rich-note preservation claim follows. Locked-session acceptance is a later separate test; current engine denies locked/unknown session states. Background non-UI runtime is unaffected.

Granting Automation alone cannot finish the missing trusted host packaging/consumer composition or publish a Mio tool. Those are explicit remaining code/review items, not an invitation to approve a non-runnable installation now.

## Reproduce

```sh
sh integrations/apple_notes/build.sh
python3 -B -m unittest tests.test_notes_create -v
```

`build.sh` compiles real automation library only. Fixture builds that same source with test-only caller construction, ephemeral signing keys, synthetic effects, private temporary journals and descriptor inspections. It never invokes `NativeNotesEffects` effect/permission/registration methods; no Notes/TCC/real content is touched. The tests cover strict schema, escaping/descriptors, forged caller/target/hash/signature, awake/permission gates, readiness invalidation, native exact review, cancellation, budget, restart and uncertain no-replay. Timing regressions use a synthetic poll loop and virtual monotonic clock: slow review dismisses at20s; cancellation dismisses at its next poll; cancel/expiry during metadata shows no confirmation;7s metadata leaves13s rather than resetting the deadline. These are API/cooperation/admission tests, not an actual AppKit modal-dialog deadline test. A real bounded dialog remains a prerequisite before the future host is offered for activation.

## Timing P2 correction

The prior protocol lacked deadline/cancellation arguments; the engine only rejected a late result. This narrow correction passes live review signals, rejects invalid requests before opening review and preserves expiry/cancel classification after automatic dismissal. Original inputs/manifest are retained under `superseded-timing-v1/`. The original20s whole-review claim is superseded by the admission-validity/cooperative-review statement above. No Friday recheck/reproduction, Notes effect, TCC, installed change or Calendar/Keychain operation was performed for this correction.
