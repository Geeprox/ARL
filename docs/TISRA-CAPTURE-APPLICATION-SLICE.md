# Tisra application capture source slice

This delta builds on host attachment d53861a6 and the reviewed process-v2
Ledger/channel/journal/upload adapters. It adds real TisraDesktop application
bootstrap and finite per-app host source profiles. It does not change an
installed runtime or enroll any production Tisra, Mio or Friday principal.

`arl.tisra_capture_profiles.production_profiles()` has three disabled entries,
without launch configuration, process inspection or method/library grants.
The real host CLI uses these entries. Trusted host code may bind exactly one
profile using CaptureHostConfig: fixed reviewed LaunchSpec/source closure,
observed executable digest, participant/actor/epoch, selected native instance
and explicit finite method/library grants. No RPC/env/JSON selects a production
profile or launches arbitrary commands. CaptureHostAttachment still owns the
gated source and native adapter through the actual host Runtime lifecycle.

TisraApp creates the default-disabled TisraCaptureApplicationProfile. Its task
waits for the actual LibraryWorkspace StreamSession Ledger. The application
TisraCaptureBootstrap independently verifies observed identities, opens the
adopted receipt journal, starts the adopted native channel and retains their
lifetime. Termination revokes volatile registrations before stopping the
listener. There is no model/provider launch or automatic production grant.

The only external bootstrap parser is `--isolated-capture-application`, accepted
only for an empty/existing marked owner-only `/private/tmp/tisra-slice-*/native`
(including Foundation's canonical `/tmp` alias)
synthetic store. Host-owned inherited stdin carries separately observed process
pins and grants. The app re-observes PID/birth/uid/image/hash rather than trusting
the descriptor. The test host independently observes the launched app and exact
selected Ledger; channel peer identity is still kernel checked. The descriptor
does not reach a registration RPC, and cannot select a production library.
The synthetic profile prevents switching its selected workspace while active.

The composed acceptance uses `/usr/bin/open -n -W` with a task-owned ad-hoc app
bundle and inherited private control FIFO. Actual TisraApp/LibraryWorkspace,
real arl.host.run, gated source, immutable upload/Store worker, native channel,
Core save, journal confirmation/ACK and exact result chunks are exercised.
Tests require the actual bundle and never skip or substitute the old consumer
fixture. Lost ACK injections run before/after the real journal ACK; cancellation
is sent through the actual source RPC after the native save. Holds survive
application and host restart and reject a fresh upload without replay.

Actual application acceptance passes eight tests, with zero skips/providers and
no forced native termination. The initial frozen candidate compiled, then
failed its temporary path guard and initial-library gate. Those logs are kept.
The corrected gate allows the first library open and termination after channel
revocation, while blocking switching during the active capture lifetime.
An inherited stop must run through the main run loop: calling NSApp.terminate
from a running MainActor Task prevented the delegate's asynchronous flush.
The retained diagnostics establish requested-but-unflushed termination; after
the run-loop fix every native exit has a successful flush and no forced signal.

The old host packet's transient native reopen failure remains unresolved: its
native stderr was not retained, so the log only establishes process exit before
readiness. This slice preserves that log, reports exit/stderr for every startup
and reopen, and tests repeated reopen of the real application. Passing new
reopens cannot establish the old failure's cause or justify changing fail-closed
behavior. Schema remains 23; schema24 and sync/UI storage paths are untouched.
The exact legacy lost-ACK/reopen case was also run four times with the verified
sealed historical fixture: all pass, with fresh stderr collection on failure.
The original failure is not reproduced and remains unclassified because its
original native stderr was lost. This limitation is retained in the receipt.

The packet handoff and machine receipt give current build/launch/test outcome.
No source integration result implies installed production activation.
