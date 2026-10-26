# Calendar awake-only trial — exact remaining decision

No installed changes. The isolated native setup source manifest `077ed53544e3ba018e2ace659b3c797ad61f4c307668e048bc0a00d67615c320` is untouched and may be reviewed in parallel. No more source fixtures were added for this research.

## What the supported APIs establish

The current macOS SDK's public AuthSession.h exposes SessionGetInfo flags for root, graphic access, TTY and remote session. It explicitly describes those attributes as set on session creation. None is a current screen-unlock attribute. Public CGSession.h exposes current user/console/login-completed information and login/console-change notifications, but not CGSSessionScreenIsLocked. CoreGraphics documents dictionary NULL outside a Quartz GUI session or when WindowServer is disabled. On-console, graphical access, login completed and missing lock key therefore do not supply our required live awake proof.

Actual prior read-only observations: restricted probe had dictionary nil; approved unsandboxed probe had dictionary present but locked field absent, so exact v5 parser returned unknown. Initializing AppKit did not establish a usable observation in the restricted probe. Moving the app, reading another helper's TCC, using last login status, or treating absent as false would not repair this verified gap. No reliable passive awake provider for this native host has been established by this bounded research; this is not a universal claim that no Apple API could ever help.

Sources:
- https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPMultipleUsers/Concepts/FastUserSwitching.html
- https://developer.apple.com/documentation/security/sessiongetinfo(_:_:_:)
- https://developer.apple.com/documentation/coregraphics/cgsessioncopycurrentdictionary()
- local SDK Security.framework/Headers/AuthSession.h and CoreGraphics.framework/Headers/CGSession.h, inspected read-only
- https://developer.apple.com/documentation/appkit/nsapplication/currentevent (the last handled event, not a durable person/awake attestation)

## Consequence for the current behavior

An unchanged **silent/headless Mio create + awake-only** policy cannot be truthfully made ready from the evidence available now. Setup-only native interaction is not a lease that proves awake during a later cloud call. No cached interaction, fixed timer or caller approved=true can repair that. Background unknown remains rejected. The code should not be packaged as usable simply because TCC/setup starts working.

## Smallest workable alternative: one live call with local effect-time review

For this initial awake-only acceptance, let the actual Mio Calendar create request reach a controlled signed native child under the existing host, then show its exact title, Asia/Shanghai start/end and already registered default-calendar target. The user's affirmative button action is the effect admission; final native/caller/policy/target/expiry checks, durable operation/budget consumption and synchronous EventKit save occur **inside that same native event dispatch**, before returning the event. Do not emit an "awake lease" and ask the background host to save later. Nothing ever sets unknown→unlocked.

Minimal code boundary, if selected:
1. A fixed private native effect-child role within the same reviewed helper identity. Host binds immutable AppleProposal bytes/hash, current registered caller/epoch, original memory-only session/target/expiry and parent birth over private pipes. No public receipt/approved flag, path, shell or arbitrary target is accepted. Child cannot be launched by an unsigned/uncontrolled parent to import a grant.
2. Use an event-dispatch-scoped AppKit reviewer, not only currentEvent (which retains the last event). Only a current matching foreground/key/visible review window's keyboard/mouse action can enter save. Direct performClick, stale/foreign input, missing graphical-session corroboration, known locked observation, cancel, expiry or policy/target/caller change produces no save. Immediately revalidate after any blocking readiness/target read. This is local interactive review, not cryptographic human identity or a per-user tunnel claim.
3. Keep source effect logic scoped to the calendar/native-trial path; do not change shared Notes/Reminders engines or enable background unknown creates. Consume the original durable operation UUID and original three-attempt budget, once; duplicate/lost/uncertain result never reopens/replays. Save outcome remains saved_local or outcome_unknown, no cloud-sync claim/compensating delete.
4. Route only the original mio_calendar_create_v1 schema/target/budget/deadline through this path. Same org audience, tunnel/key and existing14 tools, write-only TCC, one-hour/three-attempt limits and installed paths remain. No new OS privacy/security grant or certificate is needed by this design. Actual code/signing/responsible-helper continuity still requires bounded review before update.

This alternative is **not implemented or approved by this research**. It would add one local event confirmation after root's cloud tool call for the train acceptance, and may consume an attempt on cancel/uncertainty to avoid replay. That is a meaningful workflow change from silent setup-delegated creation; root must explicitly choose/disclose it before it is activated. The already approved event remains Oct2 Hangzhou West07:00→Xuzhou East10:14 Asia/Shanghai, no alarms/attendees/notes. No local event has been created.

## Exact choice to make

- Keep current silent awake-only workflow: retain fail-closed unavailable; a trustworthy passive observation remains a code prerequisite. Do not spend more live attempts on unchanged v5.
- For the initial real acceptance, approve the narrowly scoped local effect-time confirmation workflow above; implement/review it as a native trial path, then perform one Mio request and the user's exact event confirmation.
- Headless writes while locked require a separately qualified/explicitly approved locked-EventKit path; that is a different policy acceptance, not an unknown→unlocked parser fix. This research does not enable or request it.

The native-confirmed trial is a stepping stone, not a permanent local-dialog requirement for routine Mio writes. The user's eventual locked-Mac operation goal stays on the qualified headless path. No generic monitoring/session platform or additional tunnel is proposed.
