# Reminders single-item source handoff

This is a compiled, source-only native operation candidate, awaiting bounded review and explicit user permission. Nothing is installed, no TCC prompt occurred, and no personal list/item was accessed. Installed ARL metadata/UI, Calendar v2, Friday's candidate and the credential workflow remain separate.

Apple's [requestFullAccessToReminders](https://developer.apple.com/documentation/eventkit/ekeventstore/requestfullaccesstoreminders(completion:)) and [NSRemindersFullAccessUsageDescription](https://developer.apple.com/documentation/bundleresources/information-property-list/nsremindersfullaccessusagedescription) are the current permission route. The local macOS SDK's EKEventStore.h declares Reminders full access alongside Events-only write access. **Reminders has no OS write-only grant in this API.** Our operation policy is narrower than the OS permission; the OS does not restrict this helper to a single list.

## Exact proposed first use

- Bundle: `local.arl.remindersbridge`, executable `ARLRemindersBridge`, displayed name `ARL Reminders Bridge`, macOS14+. Candidate uses local ad-hoc signing and an exact CDHash pin. Bundle ID is fixed; future rebuilt CDHash/TCC continuity is not guaranteed or tested. No new certificate, entitlement or shared identity is created.
- Proposed installation: `/Users/<user>/Applications/ARLRemindersBridge.app` and `/Users/<user>/Library/Application Support/ARL/reminders-once`. No LaunchAgent/autostart; one foreground native broker owns a sealed `python3 -I` host and a registered signed native client. Existing production runtime/UI/grants/store are untouched; any isolated one-shot database belongs to this separate state home.
- OS permission: user explicitly grants this helper **full Reminders access**, if desired. No Calendar, Notes, Automation, Accessibility, Full Disk Access, Keychain, NAS, model or tunnel grant is involved.
- Action: create exactly one incomplete item titled `ARL Reminders acceptance`, operation UUID `da9b4a71-e575-4b8f-a25e-3d0a1a5d4bbd`. No due/start date, alarm, recurrence, notes, URL or location; priority0. No existing item lookup, update or delete.
- Target: only `defaultCalendarForNewReminders()` after authorization and an unlocked session. It obtains that one list's identifier/title/modification capability. A native alert shows the **actual list name and item title**, then the user chooses Create or Cancel. No list enumeration, account scan, fallback list, or arbitrary caller-provided list identifier exists. Default identifier changes before save cause `target_changed`. Actual target is currently unknown because we did not read it during development.
- Native confirmation expires after20 seconds; the whole owned broker is bounded to30 seconds. The sealed review expires in10 minutes. A timeout never acts as Create.

The candidate manifest and exact future argv are in `integrations/apple_reminders/reminders-release.json` and `reminders-approval-plan.json`. Both are **ineligible for apply** pending review/user approval. Installer and review preparation default to plan-only; no installation command was run. After review, the proposed sequence is install without launch → explicit native full-access consent → fresh exact review seal → foreground `--run-approved-reminder`. Raw `python -m`, PYTHONPATH/cwd imports and generic stdin cannot perform the effect.

## Typed operation and security boundary

`apple.reminders.create.v1` takes exactly:

```json
{"operation_id":"da9b4a71-e575-4b8f-a25e-3d0a1a5d4bbd","title":"ARL Reminders acceptance","target_policy":"system_default_at_confirmation"}
```

Strict UUID/title bounds apply; extra fields, arbitrary list paths/IDs and content are refused. Tool permissions are `reminders_full_access` and `reviewed_single_reminder`; default `RemindersWriteAdapter()` is disabled. The installed host does not register it. One-shot host grants only owner `reminders_review`, this exact payload/hash and one admitted call; public settings has no task grant.

The native effect boundary independently checks compiled exact args, private review ownership, expiry, fixed verified launcher and one-use budget. Its owned child is the only anonymous-pipe effect source. A different schema-valid request and ordinary stdin are rejected before EventKit or TCC. The isolated launcher loads already-hashed source bytes under `-I`; a shared Python interpreter path does not stand in for app identity. The actual runtime consumer is PID/birth/executable-registered and kernel-peer/signature verified.

Before store construction/list metadata, the native helper durably consumes the operation using an exclusive marker and file/directory fsync. Cancel, crash, timeout, uncertainty or restart cannot replay it. There is no product reset/unlink/replay API. Default-list failure or user cancellation after consumption requires review, not automatic retry. A new approved action needs a new explicit proposal/UUID; no service grants arbitrary repeated writes.

After native confirmation, a private precommit handshake makes the ARL worker recheck cancellation. False, missing or malformed acknowledgements refuse Save. Expiry, authorization, lock state and selected/default identifier are checked again before the synchronous save. A late cancel after commit admission cannot guarantee stopping/undoing EventKit; committed success stays success, and process interruption or save error is `outcome_unknown`/`needs_review`, never an automatic retry or delete. Known native `user_cancelled` means no Save call; the core conservatively uses `needs_review` for an already-started non-idempotent handler rather than falsely claiming all interrupted effects are canceled.

Successful tool result contains only version1, operation UUID, `target_selection=system_default_confirmed`, SHA256 of the target identifier, `persistence=saved_local`, and `cloud_sync=not_checked`. It does not expose the list name/identifier or claim cloud sync. Native save acceptance and user checking the new item still require actual first-use validation.

## Evidence and commands

Real EventKit adapter compiled with Swift6 and linked against EventKit/AppKit/CoreGraphics. Production bundle signature verifies. The injected-store fixture is separately compiled with `REMINDERS_EFFECT_FIXTURE` and cannot construct an EventKit store or request TCC. Tests use synthetic list metadata; no development list enumeration/content reads occurred.

```sh
cd /Users/<user>/Repository/ARL
python3 -m unittest discover -s tests -p 'test_reminders_write.py' -v
python3 -m unittest discover -s tests -p 'test_reminders_boundary.py' -v
```

The final boundary test binds an isolated Unix socket under `/tmp` and may require sandbox approval. It uses the actual signed native client, SDK and kernel peer verification, with an injected store. Current acceptance:5 adapter/channel tests +13 native/SDK boundary tests pass. No live EventKit, actual permission, real target selection/UI confirmation, item persistence/cloud sync, locked/unlocked first-use operation or production deployment has been accepted. No additional model call occurred.

V3 supersedes the preserved v2 after its independent P2 review: the timer is explicitly registered in `.modalPanel`, and post-confirmation acceptance also requires monotonic elapsed time below20 seconds. Only the two requested new timer/deadline regressions were run for this narrow rebuild; the18-case v2 evidence remains historical. New native binary/manifest are pinned in `reminders-release.json`; bounded recheck remains pending. See `docs/evidence/reminders-modal-deadline-v3.json`.

This first-use helper still embeds one acceptance item/UUID. It is not the ordinary Mio bridge. The independent [reusable review source increment](APPLE-REUSABLE-REVIEW.md) distinguishes optional local confirmation from a future trusted chat-authorized, headless workflow.
