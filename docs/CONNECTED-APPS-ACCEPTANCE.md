# Installed connected-app correction

Approved narrow update installed on 2026-09-30, release `0.1.1-a0b5138d84c5f712`. Runtime PID23017 is launchd-running/live/ready; updated installed UI PID23564/window6592 has title `Agent Runtime Layer`, identity `local.arl.control` / executable `ARLControl`. PIDs are acceptance observations. Previous installed release `0.1.1-1b9b1efd499223a7` is retained for rollback.

Same current-user paths: `/Users/<user>/Library/Application Support/ARL/runtime`, state home `/Users/<user>/Library/Application Support/ARL`, `/Users/<user>/Applications/ARLControl.app`, `/Users/<user>/Library/LaunchAgents/local.arl.runtime.plist` / `gui/501/local.arl.runtime`. State/disabled=false and existing preferences were preserved. No new credentials, OS privacy/security grants, TCC, models/inference/downloads, Apple/Friday/HA/NAS data, tunnels or power/security settings. No reboot/login/logout test.

| Verified identity | SHA256 |
| --- | --- |
| Canonical 34-file UI/shared-client/build/test set | `de8027b82e34f44e9335db9c8ac3dd9b6667d8f3a6818a9d71292fd49ce60875` |
| Approved six-file correction | `61ff070f8662f91d03b150729ca6cab6b75800c3602c97c8bf68b125bb7a7d0e` |
| Installed production UI binary | `7aa0ea046d640ad32a35085cac6aa01853f0c3a4a668aa98b75eb645539ce921` |
| Package manifest | `53f8fa3ab29011f46caa85517f59ec6906d78b4a2a2339c92500a879897ffa93` |
| Complete 27-file package, including manifest | `06c6b532d4b472acd9a79428a13ae7ddd847846b1eb58f25abac35c65bd6a4b6` |

Package: `deployment/packages/connected-apps-20260930`. The only changed installed payload file versus the previous first-four release is the production UI binary. Backend/API/profile, Info.plist and already-fixed manager are unchanged. No Dev bundle was renamed. Build provenance: immutable copied source `build/connected-apps-release-20260930/source`, compiled with the existing safe `--build-only` production flag. Copy and canonical source hashes were equal before build and are still equal at freeze.

Actual metadata acceptance: health/ready, schema1 overview and schema2 snapshot, sanitized logs/export, correct selected release/binary identity and zero jobs/attempts. Four configured wire descriptors produce **zero connected primary rows** through the same Swift selection used by RegistryView. Task execution and every provider's inference remain disabled. No task/model call was made.

Installed UI was refreshed only at the exact known bundle/executable path: old PID10781 quit gracefully, new PID23564 was launched by bounded NSWorkspace; no force-kill, unrelated app, indefinite getApp or new permission request. Existing authorized AX read of this exact installed PID confirmed `已连接的应用` and `尚无已连接的应用` on the overview. Existing Screen Recording grant was checked without prompting. Window-only screenshot `evidence/connected-apps-installed-window.png` is 1640×1180; the restored scroll position shows the lower overview cards, not the connected-list card. The AX evidence separately proves the actual empty-list labels. No Library upload capability was available in this worker.

Primary rows require registered + verified + connected, positive TTL, and both fresh nonfuture connection and identity evidence. A five-second TimelineView expires cached entries even without a new RPC. Unknown/unregistered/disconnected/stale/revoked entries and static v1 budgets never create primary rows. Historical disconnected/configured apps are omitted in this minimum version, rather than mixed into the connected list. Arbitrary names/version/icon references come from the validated host descriptor; there is no Friday/Tisra whitelist in primary selection. Icon support in this release is a trusted `sf:` descriptor reference, not native `.icns`/third-party logo extraction. Authentication and authorization remain separate; appearing connected does not grant a tool.

Required evidence remains bounded:14 connected-list tests +46 strict protocol/schema cases +full SwiftUI source typecheck; production build succeeds. Seven isolated native peer checks pass: configured→empty; registered/no heartbeat→empty; actual kernel-verified arbitrary peer `papercrane_42`, name `晚风 · 家庭照片`, SF icon `photo.on.rectangle`, version2.1.0→one correct row; host-clock +31s simulated expiry→empty; real child exit/revocation→empty; unregistered parent spoof rejected; worker absent/jobs0. The expiry clock was simulated; identity/heartbeat/disconnect were real Mac processes. All peer fixtures used private `/tmp` state, not the production registry. No production Friday/Tisra or arbitrary fixture was enrolled.

Evidence:

- `evidence/connected-apps-update-result.json`
- `evidence/connected-apps-installed-acceptance.json`
- `evidence/connected-apps-installed-ui-launch.json`
- `evidence/connected-apps-installed-window-check.json`
- `evidence/connected-apps-source-freeze.json` (full canonical path/hash map)
- `build/connected-apps-release-20260930/isolated-peer-acceptance.json`
- `build/connected-apps-release-20260930/production-build.log`
- `build/connected-apps-unit.json`, `build/connected-list-schema-unit.json`, `build/connected-apps-typecheck.log`

Reproducible source test and metadata-only installed reads:

```sh
/bin/bash macOS/ARLControl/script/test_connected_apps.sh
/usr/bin/python3 build/connected_apps_installed_acceptance.py
```

The latter requires access to the existing Unix socket in the execution sandbox. It does not enroll apps or submit jobs. Exact executed update/retained rollback argv are in `deployment/connected-apps-update-plan.json`. One bounded lifecycle update succeeded after ten absent-label checks/556ms wait; no retry loop or new lifecycle change.

Canonical UI/client source and immutable installed release are now frozen for the parent-coordinated design handoff. No broad visual changes started. Requested light native redesign, actual performance charts, native/third-party logos and product copy cleanup are next work, not delivered here. Real Tisra/Friday/Mio product registration/connection, credential vault, Apple operations and Friday content remain separate missing engineering/grants. Minimum resize and MenuBarExtra AX interactions remain unverified. This closes the connected-primary-list correction without claiming the whole ARL product complete.
