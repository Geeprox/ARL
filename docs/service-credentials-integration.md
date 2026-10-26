# Unified service credentials: implementation boundary

Status: the r2 candidate implements the unified credential SDK, native service
panels, NetEase bridge and separate local-code identity route. Its **25 SDK
inputs and 90 Control inputs compiled**, and the isolated native fixtures passed.
The installed formal **Control build 2 and current Mio v7 remain unchanged**;
candidate verification is not installed-product acceptance.

The six independent persistence processes passed `prepare → read-saved → update
→ read-updated → delete → read-removed`. They exercised the real
`CredentialOnboarding`, `LoginKeychainRepository` and `FileLoginReceiptStore`
with synthetic item calls/environment, including wrong identity, stale
generation, `commitLease` and cancelled late results. This did not exercise the
real Keychain or signed caller identity. The UI/catalog fixture checked contracts,
not actual SwiftUI/SecureField interaction. Evidence is retained in the workspace
packet `service-unified-native-r1/RESULTS.json`.

The new r3 Amap/FlyAI/NetEase typed consumers and authenticated Mio-owner route
are written as source candidates. Their combined native build and complete
Mio → owner → SDK → provider fixture remain pending; the r2 results do not
qualify these new sources.

## User flow to deliver

- ARL → 服务连接 shows 高德地图、飞猪、网易云音乐 from one bundled catalog, even
  when no credential exists. Capability rows use the same provider identifiers.
- Amap and Fliggy use their native credential forms. NetEase has App ID and a
  secure private-key field, Save, Test application, Sign in, Cancel, Refresh
  status, and Disconnect. No npm, terminal configure, global CLI or second copy
  of the key is part of the user flow.
- Saving a key produces `saved_unverified`, not `connected`. Application
  validation, account login and permission to mutate a playlist are distinct.
- A QR login is displayed only from the official bounded login response. Expiry
  and cancellation close that attempt. A late response cannot recreate a
  disconnected session. Refreshing local metadata does not renew an account
  token. Explicit login/check may renew it and must be labelled accordingly.
- Disconnect removes ARL's owned local credential/session items and invalidates
  in-flight generation IDs. Do not label local removal as server-side revocation.

## One authoritative store

The r2 candidate extends the owned login-Keychain SDK as a separate revision;
the retained fc08 SDK is unchanged. It reuses the owned-item receipt,
persistent-reference, ACL and generation guards. Amap/Fliggy scalar keys and
NetEase application/session envelopes use
purpose-bound slots. UI snapshots contain metadata only. The secure store has
no generic raw-secret export RPC.

NetEase's official 0.1.7 CLI already performs application-credential migration
into `credentials.enc.json`, coupled to `.netease_mcp_device.json`. The verified
synthetic help experiment exercised that actual migration. The device envelope,
application state and token state must remain together in Keychain; the official
CLI's device-derived encryption is not the security boundary.

The implemented native adapter supplies a purpose-bound envelope through an
anonymous pipe to a fixed, sealed official-runtime bridge. The bridge exposes
only an in-memory virtual home for the exact known official state files. Changes
return through a separate private pipe and are committed by the native owner
only if the operation's generation still matches. No private key/token in kernel
argv, environment, logs, repository, app resources or persistent scratch files.
No reading or migration of the user's existing global CLI configuration.

The implemented bridge passed 20 isolated official-CLI synthetic cases, and
the native protocol fixture passed actual bundled prepare and missing-session
status. Its state remains in a virtual home and private pipes. The separate
persistent storage fixture writes only synthetic values under its isolated home;
it is not a product design that stores a second copy of user credentials.

## Candidate identity route and remaining formal verification

The retained SDK's original `CredentialHostAuthority` route requires certificate
`CD85BA24208488935F9AC0BEC63E4BE6AAE189C4` and Team/OU `LGZF25R84Z`.
The actual formal Control is signed with certificate
`859332B7FFFBBBB33B80C7B78D30C27D2D81583F`. Therefore the existing authority route
cannot simply be marked configured.

The r2 source now includes a separate local-code-certificate route pinned to the
exact identifier, certificate, bundle path, reviewed executable SHA and stable
designated requirement, while retaining the Developer ID route. It compiled with
the new SDK/Control inputs. Final package signing, reciprocal caller authority,
hardened-runtime/entitlement checks and real Keychain authorization still require
verification against the final package; synthetic gates do not establish them.

## Common consumer

The r3 source routes bounded provider operations through ARL's native credential
owner. The Mio-owner route implements kernel peer identity plus reviewed code
identity and returns public connection status and typed provider results only.
This combined route still requires compilation and fixture verification, followed
by final signed peer-authentication checks.
No generic shell/CLI, raw Keychain value, arbitrary endpoint or playlist write
method is admitted by this increment.

- Amap: the r3 typed adapter uses the existing read catalog and a scoped
  credential lease in the owner process.
- Fliggy: the r3 typed adapter retains the inspected official FlyAI signing
  profile and bounded JSON/SSE handling for the existing read tools.
- NetEase: the r3 source adds fixed read-operation mappings to the pinned
  official runtime. Validate those mappings and output schemas in the combined
  fixture against the actual CLI.
  The root `--help` lists login/configure but does not itself enumerate search;
  synthetic adapter expectations are not proof of that external command schema.

The r3 source replaces the travel/music legacy route with the native owner
adapter. The installed Mio v7 still has its prior composition. Final acceptance
must prove removal of Homebrew Python and user-home legacy-server dependencies
from these service paths, with one catalog and the reviewed travel14/music6
descriptor ordering.

## Required verification before release

1. Freeze and compile the new combined r3 inputs under a fresh native-slot
   admission. The r2 25-input SDK/90-input Control compile already passed; it
   cannot be reused as proof for changed typed consumers or owner code.
2. Preserve the passed six-process synthetic persistence evidence. Complete the
   new typed-consumer and owner composition cases, including expiry and refresh
   failures, without treating synthetic item/identity gates as real Keychain or
   caller authorization.
3. Actual bundled official CLI: in-memory state persistence across invocations,
   malformed/oversize envelope rejection, raw secret absent from output/argv/env,
   no home/resource writes, finite timeout and proven child exit/reaping before
   replacement. The r2 fake-transport cancellation cases do not qualify native
   process cleanup; the reviewed cleanup change needs its own finite coverage.
4. Actual native peer authentication rejects an unreviewed caller; no generic
   credential RPC. Missing credentials and unavailable login report honest errors.
5. Exercise the final native forms, including SecureField entry, input clearing,
   cancellation and real Keychain authorization. Compilation and the UI contract
   fixture do not establish those interactive behaviors.
6. Final signed Control/Mio packages run with empty PATH and no global Node/npm,
   Homebrew Python or user-home helper scripts. All three provider catalogs and
   consumers must be present. User enters real credentials only in ARL.

Distribution remains **HOLD** until the exact NetEase upstream notice text and
provenance are resolved, as described in `service-runtime-packaging.md`.

No actual user credential or account effect was exercised during this stage.
