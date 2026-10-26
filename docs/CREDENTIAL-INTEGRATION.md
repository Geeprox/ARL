# Native credential workflow: remaining integration

This records the native UI owner's handoff; it does not activate credential access, change the wire contract, or make the installed runtime ready to use a saved key.

Source evidence: [opaque metadata handoff](/Users/<user>/Documents/Codex/2026-10-01/task/credential-handoff/CORE-METADATA.md) and [first-use acceptance](/Users/<user>/Documents/Codex/2026-10-01/task/credential-handoff/FIRST-USE.md). The SecureField/Security implementation compiled and injected-store tests ran. Real Keychain operations, provider calls, existing-key migration and installed-app changes have not occurred. Signing/access-boundary review remains with the reviewer. Friday planning and Calendar v2 remain frozen independently.

## Existing metadata contract

The handoff DTO matches the seven existing `ControlCredential` fields in [CONTROL-API.md](CONTROL-API.md); no new RPC is introduced:

```json
{"id":"amap.maps-weather","service":"amap","purpose":"地图与天气 Web 服务","state":"reference_only","reference_id":"<opaque UUID alias>","reference_status":"unresolved","provider_revocation":"not_performed"}
```

The second slot is `id=fliggy.travel`, `service=fliggy`, `purpose=出行服务 API 凭据`. Local removal retains the alias/purpose with `state=removed`. A successful replacement rotates the alias. Aliases are app-created UUID metadata, not Keychain persistent references, secret fragments, lookup authority or provider grants. Names/purposes fit the existing 200-scalar bound; IDs fit the 64-character ASCII bound; opaque references fit the 200-scalar bound.

Native **本机服务凭据** presence and host **运行时登记** are separate evidence. Native save success does not register a host entry, resolve a reference, validate a supplier key, or enable a tool. Local removal does not revoke a supplier credential. Fliggy's single key/token slot does not implement AppKey/AppSecret pairing or OAuth.

## Concrete remaining acceptance

- [ ] Reviewer accepts production signing/default application Keychain access for `local.arl.control`; deployment is separately coordinated. A missing entitlement/access boundary stops acceptance, without broad/shared access groups or plaintext fallback.
- [ ] User explicitly checks the two fixed local slots and supplies a key directly in SecureField. Verify save, relaunch presence, revision-bound replace/cancel/remove and finite denied/locked errors using FIRST-USE.md. No key goes into chat, RPC, logs, argv, environment, preferences, evidence or input screenshots.
- [ ] Implement and review authenticated native-to-host metadata registration with explicit ownership. Current `CredentialReferences` supports fixtures only; this path is not implemented. The public same-UID settings identity remains read-only. A caller-provided alias never authorizes secret retrieval or provider use.
- [ ] Separately implement a purpose-scoped broker/resolver if a provider needs a stored key, with authenticated consumers, lock/availability handling, per-action grants and budgets. The native store currently exposes no secret-read/reveal/export/resolver API. Secret bytes must remain outside ARL metadata/RPC/logs/argv.
- [ ] Validate a specific supplier adapter only after the user authorizes its real use. Keep reference status `unresolved` and provider readiness unverified until evidence exists. No automatic migration/read of existing Mio keys or tunnel token; no provider activation from local presence.

The native namespace is fixed to `local.arl.service-credentials.v1`, with nonsynchronizable `WhenUnlockedThisDeviceOnly` items and default app access. Passive checks are attribute-only and noninteractive; explicit user mutations may show native Keychain authentication. This records the handoff's intended boundary, not proof of actual Keychain acceptance.
