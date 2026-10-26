# ARL local protocol v1

Transport: Unix stream, owner-only directory, 0600 socket, one UTF-8 JSON line per connection. New connection per RPC naturally reconnects; max request 16384 bytes incl newline, max result 65536 bytes; socket read/write deadline 5 seconds. Production remote access is not enabled.

```json
{"protocol":"arl/1","app":"tisra","method":"submit","params":{"tool":"text.sha256","args":{"text":"example"},"key":"stable-logical-request-uuid"}}
```

```json
{"protocol":"arl/1","ok":true,"result":{"id":"uuid","tool":"text.sha256","state":"queued","attempts":0,"result":null,"error":null,"updated":0}}
```

```json
{"protocol":"arl/1","ok":false,"error":{"code":"app_identity_unverified"}}
```

Top-level fields are exactly protocol/app/method/params. No owner, executable, command, path, URL, environment, key material or caller-declared verified identity. Unknown fields/methods/tools/apps/versions fail closed. Model prompt and text are bounded data and never interpreted as runtime shell commands. Each app's capabilities descriptor contains only its allowed tools. An available tool still must pass all submit policy checks.

| Method | Params | Semantics |
|---|---|---|
| health | `{}` | live, ready, version, PID, UI requirement; available while initializing |
| ready | `{}` | not_ready before recovery completed; separate from live |
| capabilities | `{}` | version 1, protocol, strict tool schema/permissions/idempotency/availability and identity boundary |
| overview | `{}` | settings-only public metadata; available while initializing; precise schema in SETTINGS-API.md |
| providers | `{}` | fixed local health/model-list discovery; no inference; paid routes remain disabled |
| submit | tool, args object, key | server validates identity/policy/schema/budget; durable id returned; same owner+key+body dedupes |
| get | id | current state/result for the same owner; private result requires verified transport identity |
| cancel | id | durable cancellation request, not proof that an external effect stopped |
| resume | id | only resumable idempotent needs_unlock; caller must resolve original blocker |
| wake | target | registered app ID only; host callback or durable inbox; no arbitrary path/command |
| poll_wakes | `{}` | consume this app's bounded inbox; events include source/sequence/time |
| stop | `{}` | local OS account administrator action: durable disabled, no automatic bootstrap |

Default app IDs tisra/friday/mio are logical declarations inside one OS account. They are not credentials or proof of app identity. Normal logical cross-owner job access rejects; a process spoofing a known ID remains possible for non-sensitive logical data. Sensitive Apple and provider travel calls are blocked unless verified_app is supplied by the trusted **transport implementation**, never JSON. When an identity verifier is composed, task-app RPCs require valid registered/signed peer identity and matching claimed app. Independent settings allows only health/ready/overview under an explicit same-UID public metadata exception, never a private identity grant. Its method allowlist also applies without a verifier. See [SETTINGS-API.md](SETTINGS-API.md). No RPC registration or trust-reset API exists.

Useful errors: unsupported_protocol, unknown_app/method/tool, invalid_frame/arguments/request, tool_not_authorized, method_not_authorized, app_identity_unverified, job_not_found, idempotency_conflict, model_budget_exceeded, queue_budget_exceeded, call_budget_exceeded, paid_provider_disabled, local_inference_disabled, provider_not_authorized, model_not_installed, not_ready, disconnected, ready_timeout, user_disabled. Job errors are stable codes; raw provider/Apple exceptions are suppressed.

SDKs: Python `arl.client.Client` and `RuntimeLauncher`, usable by Friday without framework imports. Native Swift 6 `examples/ARLClient.swift` is Codable / Sendable and an actor, usable from Tisra without MainActor socket I/O. `connect` accepts a host-supplied trusted launcher closure, `submit` resends the exact key after disconnect. Swift smoke compiles and runs against the real ARL process, including a kernel-registered peer test. Real Tisra project is untouched.

Wake host callbacks are constructed in `WakeRegistry`, not transmitted as code. Bootstrap launches only the local ARL module fixed at SDK installation. Actual native offline launch adapter is not enabled: implement fixed approved bundle IDs or a supervised Friday executable, verify the newly launched peer, and treat successful launch separately from application ready handshake.

Store v2 persists job permissions/contract/security classification; descriptor removal/downgrade cannot expose private results. Pending contract drift and non-idempotent failures after execution started enter needs_review without automatic replay. Revocation is atomic at RPC acceptance; already accepted work retains its narrow durable grant, so cancellation/policy removal is separate.
