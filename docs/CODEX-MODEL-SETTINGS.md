# Codex model and package settings

The main window's **模型** page contains one five-package editor and the shared
model queue's concurrency setting. Each package ID (`low`, `medium`, `high`,
`very_high`, `highest`) has an independent name, model, reasoning effort and Fast
selection. Edits remain drafts until **保存套餐** is clicked. Existing mappings
are preserved, including legacy entries without an explicit service tier.
New package requests resolve the saved mapping; already admitted work keeps its
original parameters. Application integration uses the SDK protocol documented in
[APPLICATION-PLATFORM.md](APPLICATION-PLATFORM.md); internal aliases and protocol
versions are not exposed as ordinary user settings.

## Discovery and upgrades

Available models, reasoning efforts, default efforts and Fast support come from
the installed Codex app-server's paginated `model/list` response. The model list
is not embedded in the package editor. ARL refreshes the catalog during its
45-second background monitor and the editor reads published changes every five
seconds. A stale catalog disables saving until the background refresh succeeds.
No maintenance refresh button is required in the healthy flow.

An official Codex binary replacement is revalidated and re-pinned at an idle
preflight boundary. ARL then refreshes the catalog and connection preflight;
active work prevents a binary transition. An unverified replacement is rejected.
Directory presence is not proof of inference success or account entitlement for
every listed model. The installed Codex may supply its own cached directory.

On macOS the provider child additionally denies reads of the two global Codex
AGENTS files. This isolates text-service requests from personal coding rules
without modifying shared files or copying account credentials. The original
zero-instruction-sources, disabled-tools and read-only acknowledgements remain
mandatory. A missing isolation facility fails closed.

The editor preserves dirty drafts during polling, rechecks the latest catalog
under the shared package lock, rejects stale writes and automatically merges
untouched rows from newer revisions while preserving local drafts. It writes
private configuration atomically. Unsupported saved combinations are shown for
correction instead of silently replacing the user's five mappings.

## Pointer targets

The shared `EditorialMenu` places its complete padded surface inside the native
menu label, including the arrow and trailing blank area. Main-window model menus,
package menus, Notes folders, Reminders lists and NAS access-mode menus share this
behavior. Sidebar rows fill their column; decorative outlines do not receive
pointer events. Toolbar icon buttons use a minimum 40-point target.

## Validation boundaries

Synthetic regressions cover a verified binary upgrade followed by a changed
catalog, preservation of package mappings, Swift/Python configuration round trips,
new model/effort values, concurrent revisions, stale catalogs and disabled access.
They do not call real models or establish availability of every account/model
combination. Installed UI acceptance is recorded separately from these tests.

On the maintenance machine, build 151 additionally completed five actual
non-synthetic package calls: `low` = Luna/high, `medium` = Luna/xhigh,
`high` = Sol/low, `very_high` = Sol/medium, `highest` = Sol/high, using the saved
`gpt-5.6-luna` and `gpt-6.1-sol` selections. Each matched thread-start reasoning
and service-tier acknowledgements and a completed native turn. Package file
hashes were unchanged. This establishes those five configured combinations on
that account at verification time, not every catalog entry or future availability.
