# Bundled service dependencies

The product requirement is a formal ARL package that includes the Amap, Fliggy
and NetEase implementations and necessary runtimes. End users do not install npm,
Node, Homebrew or separate CLI tools. Credentials and login belong in ARL.

Status: the r2 runtime bridge and package-population implementation are present,
and the r2 native SDK/Control build and isolated fixtures passed. The new r3 typed
consumers and Mio-owner source await their combined build and fixture. Installed
Control build 2/current Mio v7 are unchanged. Final signed, self-contained startup
with an empty PATH remains a product acceptance gate. Distribution is **HOLD**
pending the exact NetEase license notice and provenance described below.

## Completed build input slice

`script/stage_netease_runtime.py` stages an offline, immutable NetEase runtime:

- Official Node **24.21.0**, **darwin-arm64**. Official release archive SHA256:
  `bed7eea5325e1108f32ce5228ddd6a5f0f08a499ee42aa7442aea583702f6057`.
- Official `@music163/ncm-cli` **0.1.7** and its exact retained dependency lock.
- **56** selected dependency packages, each extracted from an archive whose
  SHA512 matches the lock's SRI. No lifecycle scripts run during staging.
- Node's complete LICENSE, package notices/readmes and provenance/inventory.
- The fixed `Bridge/netease_bridge.cjs`; the current r2 sealed runtime has
  **1,563** resource files including the bridge and the **56** dependency packages.
- No npm executable, global executable search, media binaries, playback support
  or general command runner. Build/run development packages are excluded.

The archive and published checksum were obtained over the official Node HTTPS
origin. An independent release-signature check has not been performed. The
official Node image's linked libraries are all macOS system paths.

The current artifact is arm64 only. It is not an Intel/universal release.

Example build-machine invocation (not a user setup step):

```sh
python3 script/stage_netease_runtime.py \
  --node-archive INPUTS/node-v24.21.0-darwin-arm64.tar.gz \
  --cli-archive INPUTS/ncm-cli-0.1.7.tgz \
  --official-cli-root INPUTS/official-package \
  --npm-cache INPUTS/npm-cache \
  --output BUILD/ServiceRuntime
```

The builder refuses a changed archive, lock, CLI image, dependency SRI, symbolic
link or pre-existing output. It writes read-only resources and an inventory.
No download, repair or npm install is allowed at app startup.

## Evidence and limits

The earlier staging-only artifact passed three actual official-CLI probes from
the read-only directory with
an empty PATH and isolated HOME: version, honest missing-configuration rejection,
and synthetic application configuration migration followed by command help.
Its **1,562** pre-bridge resource files retained their exact hashes/modes. No global Node,
npm or Homebrew binary was used. No real user credential/account was used.

The subsequent r2 bridge passed **20** synthetic cases and the resource packager
passed **7** cases, including the complete **1,563**-file inventory, mutation
rejection and refusal to modify a signed bundle. Evidence is retained in
`service-runtime-candidate-r2/SYNTHETIC-BRIDGE-RESULTS.json` and
`service-runtime-candidate-r2/PACKAGING-RESULTS.json`. The package-population
helper copies the verified runtime into a new unsigned Control bundle and binds
its inventory digest before signing; that implementation is already present.

The admitted r2 run compiled the **25 SDK inputs and 90 Control inputs**, passed
the native UI/catalog contract and bundled prepare/missing-session protocol
fixtures, and passed all **six independent processes** of the synthetic persistent
credential fixture. `service-unified-native-r1/RESULTS.json` retains those results
and the earlier failed attempts and recoveries. The real repository and receipt
store were exercised with synthetic item/environment implementations; no real
Keychain authorization, signed identity, SecureField interaction or account login
was exercised, and the unsigned Control app was not launched.

The r3 typed consumers and Mio-owner adapter are now source candidates awaiting
their combined compile/fixture. Neither the staged clean-environment probes nor
the r2 native results prove that new chain or final signed ARL/Mio startup. The
installed Mio v7 retains its prior Homebrew/legacy-server composition; final
self-contained service-path acceptance is still required.

## Final formal build gates

- Complete the final Control/Mio packaging transaction using the implemented
  runtime-population helper and the same reviewed service catalog. Include and
  jointly verify the new typed Amap/FlyAI/NetEase consumers and credential owner;
  fail if any provider or runtime is absent.
- Put executable code in the appropriate signed bundle location; freeze nested
  code identities, resource inventory and licenses before signing the outer app.
- Never mutate resources after signing. No `.pyc`, CLI config, tokens, logs or
  npm cache in the application bundle. User state belongs to the credential owner.
- Run the final signed apps with an empty PATH and isolated synthetic state;
  test all three missing-configuration paths and the common Mio catalog.
  Prove startup and service entry without global Node/npm, Homebrew Python or
  user-home helper scripts. The final user flow remains entirely in ARL/Mio.
- Preserve upstream notice files. The NetEase package declares MIT in its
  published metadata; the tarball has no separate LICENSE file, so resolve the
  exact upstream notice text and provenance before a distributable release.
  This remains a distribution **HOLD**. Do not substitute
  the unrelated skills repository's license.

Official runtime sources: https://nodejs.org/dist/index.json and
https://nodejs.org/dist/v24.21.0/SHASUMS256.txt. Exact download/provenance receipts
are retained in the task's `service-runtime-evidence-r1` directory.
