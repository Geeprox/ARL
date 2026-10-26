# Shared connection catalog and Mio music boundary

`docs/service-connections.json` is the source for Control service rows, capability
grouping and the Python/Mio connection explanation. Packaging copies those exact
bytes to `Contents/Resources/ServiceConnections.json`. The production Control
uses `ServiceConnectionsView`, while the already-reviewed credential SDK remains
byte-identical. No credential SDK rebuild, new secret field or login RPC is added.

ARL now registers five unavailable music descriptors in its existing tool registry.
Metadata-only host policies still grant none of those tools and execute no tasks.
Application enrollment alone is never used as CLI configuration/login evidence.

The existing native Mio host's `legacy` route is wired to a signed bundle resource
entry. The nine resource files are hashed in a manifest whose hash is sealed in
Info.plist before signing. The entry composes the unchanged pinned travel server
with `MioMusicGateway`. Its `tools/list` preserves the exact current fourteen travel
descriptors, then adds five music actions and one local connection-status action.
The existing Calendar consumer can retain its own separately gated descriptor.
No original travel server, agent, policy, credential reference or travel call
implementation is changed. The source `docs/mio-tools.json` recovers the already
deployed weather descriptor that was absent from its prior thirteen-item snapshot.

The music entry has no real account transport or credential probe. It returns
`music_app_configuration_required` while setup remains unverified. The composed
API also handles a host-observed login-required state. All real writes are paused;
the public gateway rejects create/append before invoking any transport, including
when a synthetic read transport is injected. Caller `approved`/scope fields are
not accepted. No actual official login, playlist create/add/remove or account
content call is part of this candidate.

## Gates still required

This source candidate is not installed and not publicly published. Review must
cover the shared catalog, actual Control consumer, runtime metadata registration,
Mio resource closure and native `Host.swift` binding together. Native builds require
root slot allocation. The signed Control package and native Mio package need their
own exact package GO before a paired formal update. Live Mio list acceptance is
separate from local stdio tests; neither establishes account or write acceptance.

Calendar's previous schema3-only attempt has been rolled back to exact old v7.
Its immediate gateway-child predicate was too early after ready; no retry is
authorized by this file. Any later migration must retain both historical receipts,
use bounded generation-aware readiness and separately qualify gateway emergence.
