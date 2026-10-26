# Connected app list — installed acceptance correction

The narrow correction is now installed as `0.1.1-a0b5138d84c5f712`; exact acceptance/source freeze is in [CONNECTED-APPS-ACCEPTANCE.md](CONNECTED-APPS-ACCEPTANCE.md). The initial source-only diagnosis and tests below are historical.

User clarified that the primary app list must contain actual discovered/established applications with real names/icons/state, with a truthful empty state when none are connected. The installed `0.1.1-1b9b1efd499223a7` does not meet that exact presentation requirement: RegistryView enumerates every `apps` descriptor, and oldoverview falls back to budget-derived static names. These rows are explicitly unconnected and do not receive authorization, but they still occupy the primary list.

The wire contract itself separates registration, connection, authentication, authorization and timestamps. Host-only descriptors support arbitrary configured app IDs and real metadata. Public settings requests do not establish a product identity. Current production has zero authenticated product connections; `apps` includes four configured/unregistered policy partitions. No product is enrolled merely to populate the UI.

Minimal correction is canonical source only: RegistryView uses an outer five-second TimelineView and a shared connected-selection function, so expired evidence removes rows even without an RPC refresh. Primary selection requires actual connected evidence, registered+verified state, both seen/verified timestamps, positive TTL and nonfuture/fresh ages. Revoked/stale/disconnected/unverified/never-seen entries do not appear. Name/icon/version comes directly from validated metadata, with no whitelist of Friday/Tisra IDs. No connections gives “尚无已连接的应用”; unsupported/failed v2 explicitly says unavailable rather than manufacturing a list from v1 budgets. Historical/configured rows are not included in this minimum primary list.

Four existing UI files changed: Models/ControlPlaneState.swift, Models/ControlAPI.swift, Views/RegistryView.swift, Views/OverviewView.swift. Tests/ConnectedAppsUnit.swift and script/test_connected_apps.sh are new. Backend wire schema/permissions are unchanged. Demo data remains selected only through explicit `--demo`; production RuntimeStore still defaults to the installed home and no demo flags. This change is not an implementation or authorization of arbitrary app discovery, registration, launch, models or tools.

Validation:14 tests cover arbitrary app name/icon/version, no connections, static/registered-but-never-connected entries, disconnect/revocation/unverified/stale, cached expiry, independent seen/identity expiry, future activity, unsupported legacy API and mixed lists. Existing46 strict schema cases pass; full SwiftUI source typecheck passes without linking/rebuilding an App bundle. Commands:

```sh
/bin/bash macOS/ARLControl/script/test_connected_apps.sh
```

Evidence: `build/connected-apps-unit.json`, `build/connected-list-schema-unit.json`, `build/connected-apps-typecheck.log`; exact file delta: `evidence/connected-apps-source-delta.json`. At the initial source-only report the installed immutable bundle was neither changed nor rebuilt. Subsequently, production identity was built from an immutable 34-file canonical copy, verified and applied as the separately approved routine update. Actual installed empty-list AX and real isolated arbitrary peer/disconnect checks now pass. Minimum resize and MenuBarExtra AX remain unverified; the new window-only capture is documented separately with its exact visible contents.
