# Capture host attachment source packet

The existing `arl.host.run` path constructed a metadata-only Runtime and never
attached the adopted capture process, upload, Store or native Ledger adapters.
ControlledSupervisor released its source gate before a capture participant map
could be installed. This packet adds the finite trusted attachment at those
actual composition points.

`CaptureHostAttachment` owns one fixed controlled source and one selected live
native consumer/library. Runtime constructs the Store, calls the attachment,
attaches the existing capture engine, starts its existing recovery/worker and
serves the existing Handler. A host-only `on_registered` callback completes the
opaque participant mapping and selected native binding before the child receives
`go`. Existing kernel PID/birth/image registrations remain the authority. The
capture authorizer also rechecks the supervisor's pinned source closure during
native operations; a shared Python interpreter alone never admits another app.

Shutdown revokes the source and reaps the controlled child before waiting for the
worker and handlers. It closes the selected Ledger descriptor after those users
have drained. Calling attachment.close while the runtime still owns its lifetime
lock is rejected. Startup failure never releases the source gate and reaps the
failed child. The native process remains owned by the native application.

## Defaults and finite grants

`host.run(home)` and the existing CLI keep the metadata composition. There is no
new CLI, environment, JSON, enrollment or configuration RPC. An explicitly
supplied attachment is disabled by default and does not launch or inspect a
source/native process, open a selected Ledger, attach capture or start a worker.
Its config can be absent. An enabled config defaults to `library_granted=False`
and an empty method set. With those defaults the source has no tool/provider or
method grants and no job worker. Capture grants never enable providers, models,
Apple capabilities or device actions.

Only trusted host code can construct `CaptureHostConfig`, a fixed `LaunchSpec`,
the current source image digest, an opaque participant/actor/epoch, a distinct
native owner name and a native selection callback. The callback returns an
explicit observed PID, executable digest, owned endpoint, selected Ledger path
and library/restore-instance/code/schema pin. It does not consume an RPC claim.
The existing native adapter independently checks the selected inode and current
process/library pins. Native Core separately checks its own source registration
and write grant.

## Actual-host acceptance

The finite packet has six new acceptance cases, an existing launch-pin regression
and three unchanged native-process end-to-end cases: **10 passed, zero skips**.
Tests run `arl.host.run` in a main-thread subprocess with a controlled gated source
and the preserved task-owned native fixture. All libraries, journal state and
requests are synthetic. The actual Handler, Store worker and native channel
produce exact receipt bytes and a matching journal ACK for two records. The
packet checks source code drift, source registration revocation, independent
native grant revocation, descriptor lifetime and failed-start gate/reaping.
Default startup leaves a preexisting synthetic queued job at zero attempts.
Provider execution is guarded in the host fixture and the count remains zero.

External packet receipts retain the first failed attempt and corrected passing
log. The first attempt used this Mac's Python launcher path rather than its
kernel-observed executable; it failed closed before the gate. Legacy deployment
test imports were outside the candidate Git closure, so queued-work preservation
is asserted in the actual disabled-host case. One legacy native reopen failed
transiently in that first attempt; its cause is not established. All three native
cases pass in the corrected run, including restart/ACK hold without replay.

The independent temporary build had disappeared. The preserved owner binary was
verified against its sealed source manifest and declared build digest, and the
source commit/tree against the independent review. A task-local copy is pinned
for these tests. It is a fixture only and is excluded from this source commit.

## Remaining real-app integration and admission

This is an isolated source packet based on adopted ARL `30b30a74`. It does not
modify an original source tree or activate an installed service. The existing
deployment entry still calls `run(home)` without an attachment.

1. The companion isolated Tisra source candidate now supplies the real app
   lifetime bootstrap, host-owned temporary registration handoff and independent
   native revocation. It uses the selected StreamSession Ledger and the adopted
   channel/journal without a schema/storage migration. See
   [application source slice](TISRA-CAPTURE-APPLICATION-SLICE.md) and its packet
   receipt for the current build/launch/acceptance outcome.
2. Finite per-app source profiles now exist and are wired into the host CLI,
   disabled without any launch configuration/grants. Trusted composition must
   still supply a reviewed finite closure, actual executable/principal/epoch
   and explicit selected library/method grants. The application acceptance
   selects a separately observed real TisraDesktop bundle in a synthetic store.
3. Trusted product composition must pass the configured attachment to
   `host.run`. The resulting complete installed source closure needs a new
   package seal and separate installation/acceptance. No dynamic self-enrollment
   or caller-provided path/profile substitutes for those steps.

Schema 24 remains exclusively reserved for offline reconciliation. This packet
changes no Tisra source/schema, People or Messages code. Remote publication A
remains blocked; it is not retried here.
