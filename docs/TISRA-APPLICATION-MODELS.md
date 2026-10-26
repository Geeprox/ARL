# Tisra ↔ ARL application model negotiation v1

Source-only, offline-verified integration. No production Runtime registration,
new permission, model invocation, paid acceleration, signing, installation or restart.
Tisra UI is unchanged. Existing uncommitted changes are preserved.

## Ownership and reused contracts

ARL owns `arl/application_models.py`, this document, `tests/test_application_models.py`
and `tests/fixtures/TisraApplicationModels.swift`. Tisra owns the new
`Sources/TisraCore/Research/ARLApplicationModels.swift`,
`Sources/TisraUI/Runtime/ARLApplicationModelClient.swift`,
`Tests/TisraCoreTests/ARLApplicationModelsTests.swift` and
`docs/validation/arl-application-models-20261022.md`.

Release coordinator 01a152d8-0d2c-7565-86d3-35b79de71018 owns existing SDK,
Runtime/compat_host, owner/recipe and formal builds. No existing file was modified
by this integration. The coordinator confirmed the new paths before writing.

Reuse, rather than duplicate: AppConnections open/confirm/ping/close and
AppRegistry/AppDescriptor; `codex_execution_options.read_catalog` and `selection`;
`scheduling.resolve(AppPolicy, requested)`. Tisra receives protocol DTOs, not a
second model/Fast list. Host `catalog(app)` must supply a local, current,
app-scoped `execution_catalog` snapshot. It must not run preflight: existing
Codex preflight can create an external thread and is outside this task.

## Message contract

Transport remains `arl/1`: authenticated `app=tisra`, `method`, `params`.
`binding` is transport-owned peer identity plus registration generation, never a
request parameter. Host AppRegistry registration must already exist; this code
cannot enroll Tisra or register a process. Existing explicit host policies must
allow the two new methods and existing heartbeat/connection methods.

1. `connection.open` sends `client_nonce`, name `Tisra / 织语`, version from bundle
   short version + build, `icon_ref=sf:text.book.closed`, `capabilities=[]`.
   The stable logical application ID is `tisra`, already used by the SDK.
   Existing challenge/nonce/arl/1 checks and `connection.confirm` establish a
   30-second renewable session. The empty capability declaration deliberately
   requests no tool/data grants. The icon is a trusted local SF symbol, **not the
   native Tisra logo**. Real icon registration follows below; the symbol remains
   only a backward-compatible fallback. No external URL or file path is loaded.
2. `application.models.discover.v1 {session_id}` returns `protocol`,
   `schema_version=1`, session, `catalog_version` (SHA-256 of the finite projected
   catalog and policy), supported method names, queue priorities/deadline maximum,
   `catalog_source`, `resolution_only=true`, `execution_authorized=false`,
   `fast_authorized=false`, and five package offers.
3. Each offer has `package_id`, `name`, `available`, `model`, `effort`,
   `target_effort`, `supported_efforts`, `service_tiers`, `reasons`.
   Five host-owned package targets: low/低→low, medium/中→medium, high/高→high,
   very_high/极高→xhigh, highest/最高→max. These are product policy targets,
   not claims that the provider supports them. The selected model comes from
   host current selection, or host-only `package_models(app)` policy. No model
   identifier is hardcoded. Exact effort support is validated by canonical
   `selection`. If the target is absent, only an actually supported lower known
   effort can be advertised, with `effort_downgraded`. Unknown-only catalogs or
   missing model mappings mark the offer unavailable. Multiple offers can resolve
   to the same actual effort; they do not pretend to be distinct capabilities.
4. Tisra sends `application.models.request.v1` with exactly:
   `schema_version`, `session_id`, `catalog_version`, canonical UUID `request_id`,
   `request_sha256`, `task_kind` (research/explain/rerank), `package_id`, `priority`,
   `deadline_ms`, `thinking_effort`, `service_tier`, `allow_degradation`.
   Tisra chooses quick/standard/research/deep/exhaustive → the five package IDs;
   actual effort defaults to the advertised offer, or an explicit caller override.
   It never translates a package into a model or provider effort itself.
5. Receipt echoes session/catalog/request/hash/package and `requested` (task,
   priority, deadline, effort, tier, degradation flag), `accepted`, `reasons`,
   `resolved` (model/effort/service_tier/priority/deadline), and an opaque
   `resolution_id`/`valid_for_ms=30000` when accepted. Every receipt states
   `resolution_only=true`, `execution_authorized=false`, `queue_admitted=false`.
   An accepted resolution is neither an execution permission nor a queued job.
6. Optional `application.icon.register.v1` transfers the real own-bundle icon
   after confirmed-session capability discovery, independently of model execution.
   See the exact image contract below.
7. Trusted host-only `bind_job` fixes an existing admitted job to the resolution
   within its 30-second lease, with a fresh catalog/session check. It creates no
   job or grant. `correlate_result` then binds independently verified terminal
   job metadata to the exact accepted app/session/request/hash/resolution/catalog,
   actual model/effort/tier, the pinned job UUID, result SHA-256 and terminal state.
   Bound long-running jobs survive resolution expiry and later catalog refresh;
   client session freshness remains independently required.
   It is intentionally not a public RPC. Tisra's `ARLApplicationResult.validate`
   rejects changed request, resolution, model/effort/tier or terminal identity.
   Existing execution host still verifies provider acknowledgement, job grant,
   payload bytes/hash and cancellation; this metadata seam does not replace them.

## Failures, lifecycle and independent dimensions

- Invalid schema/UUID/digest, unverified peer, revoked/expired/foreign session or
  unauthorized method fail closed with typed Fault codes.
- Stale catalog: `catalog_changed`; unavailable mapping: `package_unavailable`;
  unsupported actual effort: `provider_effort_unavailable`; no silent replacement.
- Advertised package degradation requires `allow_degradation=true`; Tisra blocks
  it locally by default and ARL independently rejects `degradation_not_allowed`.
  Explicit actual effort override is echoed with `explicit_effort_override`.
- Priority/deadline uses existing background/explicit/interactive bands and actual
  AppPolicy limits; rejects `priority_not_authorized`/`deadline_not_authorized`.
  This validates a declaration only. Later submission must independently go
  through the existing queue/admission; there is no additional scheduler or
  real-time promise. Existing priority-v2 background/interactive/realtime resource
  profiles are a separate contract, not silently translated here.
- Fast metadata comes from canonical catalog support. Unsupported Fast rejects
  `provider_service_tier_unavailable`; advertised Fast still rejects
  `fast_authorization_required`. This module never grants paid acceleration.
  Interactive queue priority remains independent of thinking effort and Fast.
- Up to 128 records are retained in memory. Unbound resolutions expire after
  30 monotonic seconds; admitted job bindings remain until terminal metadata and
  30 seconds after that. Capacity is still finite; exact
  duplicate requests return the same receipt, changed accepted UUIDs reject
  `request_conflict`. No persistent grant, retry queue or background timer.
- Explicit ping/close reuse existing connection methods. Reconnect creates a new
  session/catalog and requires a fresh request. Restart loses transient
  resolutions; it never replays inference. Uncertain transport failures require
  fresh inspection, not automatic model submission.
- Protocol use is an explicit preflight action. No UI entry was added; ordinary
  typing never invokes this client. No Tail/focus/selection/undo behavior changes.
  New adapter wrappers reuse finite ARL connect/request diagnostic spans and do
  not log models, request IDs/digests/content or paths.

## Offline verification and run

From the ARL main checkout:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -B -m unittest tests.test_application_models tests.test_codex_execution_options -v
```

The integration test compiles the actual sibling Tisra Core protocol source and
runs its real Swift actor client over bounded stdio requests into Python's
existing AppConnections and canonical catalog parser. Compiler outputs are
kept in the main checkout audit directory. Registration→confirmation→
discovery→five task choices→request resolution→synthetic terminal metadata→Swift
result validation→ping/close all run without sockets or model processes.
`fixture.terminal` exists only in the unittest harness and is not registered as an
ARL method. Synthetic terminal metadata is not a model response or proof of
provider/Fast execution. Existing Codex tests invoke their isolated synthetic
stdio provider, not a real model.

Current complete Core source module and new UI adapter + actual existing socket
SDK are independently typechecked; five native XCTest protocol groups run in an
isolated test bundle. See the Tisra validation note and final evidence manifest.
The full `script/check.sh`, native app build/run and physical UI acceptance are
not run because this task expressly excludes formal App builds and UI changes.

## Remaining production integration, owned by coordinator

- Register/package these reviewed source inputs only after final source pins.
- Compose gateway dispatch behind real existing signed/registered peer binding,
  app-specific host catalog/policies and trusted AppRegistry registration. Do not
  expose caller-supplied bindings or copy the `arl-control` production scope.
- Connect accepted parameters and original request identity to existing reviewed
  Tisra execution/queue submission; recheck catalog, grant, budget and provider
  acknowledgements at actual admission. No inference is enabled by this patch.
- The actual native logo sender/validator/session storage/read APIs are now
  implemented in the owned files. Coordinator owns the exact shared registry/
  settings/Control projection delta described below; no new AppDescriptor path
  or URL semantics are needed, and the existing `sf:` field stays intact.
- Real inference, Fast acceptance/performance, credentials, persistent permission
  or formal signing/install/restart require their own authorization and review.
  The earlier denied Fast thread probe was neither retried nor indirectly called.


## Revision 2 · actual native application icon

The existing `Tisra/assets/Tisra.icns` is authoritative. Its original `icp6`
member is PNG64×64 RGBA8, **4213 bytes**, SHA-256
`a7d5b97ba454614fea1b7107054b1751bdb15e87b3df780117cefcb4e650924b`.
ICNS source SHA-256 is
`283915cb333c70795c0dfd1c67e829e9c92580b8c3d4a2cbc0e7a8b743da50d4`.
These hashes document the tested sample, not hardcoded runtime allowlists.
`build/audit/application-models-20261022.noindex/Tisra-real-icon-64.png`
is the exact extracted real icon, visually inspected; it is not a generated or
redrawn approximation. No icon asset was added to Tisra or its Package manifest.

`ARLApplicationModelClient.applicationIcon(bundle:)` opens only fixed
`Resources/Tisra.icns` under the application's own Bundle resource directory;
CFBundleIconFile must equal Tisra[.icns]. The name is checked, never used to form
an arbitrary file path. O_NOFOLLOW/CLOEXEC, regular-file fstat, ≤512KiB size and
exact bounded read apply. The pure Core parser checks the ICNS container/chunk
bounds and selects exactly one original icp6 PNG, without image resizing or an
image decoder. No URL, arbitrary file path, user note, credential, native UI or
additional OS/data permission is involved. Identity comes from the existing
signed/kernel transport binding, not from a claimed resource digest. The source
digest is an authenticated application's declaration, not independent host proof
that it reread the signed bundle resource.

The production adapter, after existing connect/discover, sends this extension
only when advertised. Old servers retain the existing call sequence;
`session.iconRegistration == nil` honestly means no real-icon acknowledgement.
A supported extension failure is propagated, never relabeled successful. The
existing connection.open `icon_ref=sf:text.book.closed` remains a compatible
fallback, and is no longer presented as final native icon delivery.

Request method: `application.icon.register.v1`, exact params:

```
{schema_version:1, session_id:<confirmed token>, icon:{
 schema_version:1, media_type:"image/png",
 source_resource:"CFBundleIconFile:icp6", source_sha256:<ICNS SHA-256>,
 sha256:<PNG SHA-256>, byte_count:4213, width:64, height:64,
 png_base64:<canonical base64 of the original PNG>
}}
```

The endpoint requires the existing confirmed identity/session and explicit host
method policy, but does not consult/enable any model catalog, tools, grants,
provider, credentials or queue. It does not mutate AppDescriptor or acquire a
file/network capability. ARL's validator rejects unknown fields, arbitrary
resource names/URLs/paths/SVG, noncanonical base64, byte/hash/size mismatch,
incorrect CRC, metadata/animation/unknown PNG chunks and trailing bytes. The only
accepted PNG profile is 64×64, bit depth8, color type6, noninterlaced, IHDR/IDAT/
IEND, ≤16 chunks, ≤8192 compressed bytes and **exactly16448** bounded decompressed
scanline bytes with valid filter types. No general image decoder executes in
ARL. The existing SDK request envelope remains ≤16384 bytes, tested with the real
4213-byte member. This is a transport/image-profile bound, not a model limit.

Acknowledgement exact fields: schema_version1, app_id, session_id, registered=true,
storage="session_memory", display_attested=false, sha256, source_sha256,
source_resource, byte_count, media_type, width, height. Tisra binds all fields to
the exact submitted descriptor; wrong acknowledgement digest/session fails.
Registered means memory metadata registered for this authenticated session;
display_attested=false does not pretend the shared Control UI already rendered it.

Coordinator-facing host APIs (fixed signatures):

- `icon_snapshot(app) -> dict | None`: exactly
  `{app_id,sha256,mime_type:"image/png",width:64,height:64,bytes:1..8192}`.
  No PNG/base64 or file reference is included in the apps snapshot.
- `read_icon(app, expected_sha256) -> dict`: same six fields plus
  `png_base64`, canonical base64≤10924 chars. Unavailable/hash mismatch throws
  `Fault("application_icon_unavailable")`; it never fetches a URL or file.
- Session-memory only. Ping before expiry preserves it; close, expiry, revoke,
  registration replacement, inactive guard or reconnect/new session immediately
  hide the old icon. A new session must explicitly register its own bytes again.
  Identical digest from another app does not authorize reading that app's icon.

Exact shared delta is owned by the coordinator, who has confirmed this API:

1. Existing Runtime gateway dispatch accepts ICON_METHOD only through its strict
   JSON and real signed/kernel session binding. Production remains closed unless
   a host explicitly injects the gateway and metadata-only policy.
2. AppRegistry snapshot projects optional `application_icon` from
   gateway.icon_snapshot(app). Existing AppDescriptor.icon_ref validation and
   existing constructors remain unchanged. If no callback/ref, omit the new key
   or emit null; do not replace sf: with an arbitrary path.
3. Existing read-only settings adds `settings.app_icon.v1 {app_id,sha256}` that
   calls gateway.read_icon; it returns only the bounded DTO above. It must use the
   existing settings metadata authorization and session visibility, no filesystem
   fallback. A digest reference is not an app enrollment or data-access grant.
4. ControlAPI/WireSchema accepts optional application_icon with exactly the six
   validated fields. ControlApp.presented propagates it to an optional
   AppRegistration member (default nil preserves call sites). SettingsService
   fetches the exact digest DTO; a finite cache validates bytes/hash/dimensions
   before decoding. Stale/missing/changed refs stop use and retain the old SF
   fallback. No remote URL, NSWorkspace arbitrary lookup or broad file read.
5. Coordinator's independent AppIcon.swift receives the verified bytes/ref;
   RegistryView owner performs its one-line connection. Existing image-free
   consumers stay compatible. This task edits none of these shared/UI sources.

Offline tests now include actual ICNS extraction/hash, Swift→Python register→
exact readback, real frame bound, malformed/oversize/URL/SVG/CRC/APNG/trailing-data/
decompression rejection, no-tools grant, unavailable catalog independence,
expiry/revoke/reconnect, optional legacy capability and digest-bound receipt.


## Revision 3 · normalized unavailable catalog preserves metadata handshake

An explicit unavailable snapshot is accepted only when it has schema_version1,
source `app_server_model_list` or `test_double`, exact boolean
`selection_enabled=false` and `models=[]`. It is not a synthesized model catalog.
None, a missing/malformed shape, disabled nonempty models, enabled empty models,
unknown source or invalid enabled catalog remain rejected with
`application_models_catalog_unavailable`. Enabled snapshots still require a
bounded valid canonical model/effort projection; canonical identifier/selection
validators are reused without reading a provider or duplicating its mapping.

Discovery retains the existing source enum for old Swift clients and adds optional
`catalog_available=false`. It returns the same five package IDs/names, each
`available=false`, `model=null`, `effort=null`, `supported_efforts=[]` and
`reasons=["package_unavailable"]`; capability discovery remains available.
`catalog_available=true` means a valid selectable snapshot exists, not execution
permission, call budget or an actual package/provider guarantee. A missing host
package mapping can still mark individual packages unavailable.

Thus the existing Tisra connect sequence confirm→discovery→actual-icon registration
can finish even with an unconfigured/stale model catalog, without any Tisra source
change. Register/read of the real PNG remains session-bound and independent of
model availability. A direct model request pinned to the current unavailable
catalog is rejected `package_unavailable`, with no resolution/job/worker/provider
call. A request from the previous available catalog is rejected `catalog_changed`;
the client must inspect again, never silently substitute a model.

The production factory owner supplies the normalized empty snapshot instead of
None; stale Codex status reuses its existing canonical empty snapshot. No preflight,
model/list refresh, external thread or turn is added by this contract. Factory/
Handler/socket regression is coordinator-owned; this three-file revision changes
no Tisra file, identity pin, execution scope, factory or installed process.
