# Build 91–92 source checkpoint

This checkpoint preserves the reviewed source used by the installed Build 92,
including the Build 91 dependencies absent from the preceding Build 90 commit.
It records implementation boundaries; it does not grant system permissions or
stand in for business acceptance.

## Product paths

- Calendar uses the main app's EventKit handler for UI and authenticated owner
  calls. Full access is required for discovery, query and editing. Write-only
  access supports default-calendar creation with an explicitly unreadable result.
  Updates and deletions bind the event occurrence and revision; series-wide edits
  and invitations remain outside this implementation.
- Reminders shares typed list/item operations, durable task receipts and the
  existing native helper. The main bundle declares its usage purpose. Permission
  failures retain their native phase and code; metadata access is not a successful
  list or item mutation.
- Notes and Messages use their shared domain handlers with trusted target
  selection. Notes editing binds the source item and body digest and accepts only
  the supported plain-text format. Messages sending uses its existing durable
  intent boundary; public scripting APIs do not provide message-history reading.
  Business logs publish independent complete segments after short writes.
- NAS reports missing scope, unavailable credentials and changed source identity
  before attempting business access.
- NetEase playlist covers use an explicit playlist target and image reference or
  HTTPS image URL. Preserve the original request UUID and target after uncertain
  results. Complete provider replies survive the native private pipe, durable
  cache, owner framing and MCP text/structured representations. Staged images
  recover only within the reviewed lock and reservation boundaries. Playlist
  songs and cloud files are outside cover-update scope.

## Build and validation boundaries

`script/release_recipe.json`, `script/mio_native_recipe.json` and
`integrations/reminders_v3/build_static.py` enumerate the production source sets.
The canonical recipe contains placeholders for local signing configuration.
Ignored local recipes, signing material, generated binaries, runtime credentials,
logs, screenshots and audit artifacts are not source inputs to this Git commit.

The accompanying targeted tests cover domain admission, durable claims, revision
binding, journal failures, response preservation and the package/update boundary.
Existing synthetic test and installed-package receipts remain local audit
evidence; this checkpoint does not rerun or broaden business acceptance.

The production registry composes 57 descriptors, including
`mio_netease_playlist_update_cover`. Source registration and an installed signed
binary do not prove that a connector has refreshed its public tool catalog.
Calendar, Notes, Reminders, Messages and NAS business acceptance still requires
the applicable trusted selection, permission and explicit test intent. Cover
acceptance uses the same existing connector and original request UUIDs after the
public cover tool becomes available.
