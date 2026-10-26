# Tisra sourced Research: production activation proposal

This source packet wires the already reviewed `FormalResearchActivation` into
`arl.host.main()`. It is **not installed**. The currently installed ARL host
still runs its prior metadata composition. Source GO is not live product GO.

## Exact grant

The production host defaults to metadata only. Its one new local approval is
`~/Library/Application Support/ARL/tisra-research-consent-v1.json`, owner-only
mode 0600, regular file, no symlink, at most 4 KiB. Only the separate interactive
`python -m arl.research_product grant --model EXACT_MODEL` command creates it;
the host does not create or renew it. The command displays scope and the absence
of a hard token/cost cap and requires the exact typed confirmation
`AUTHORIZE TISRA RESEARCH`. A new approval is one hour, never silently
renewed. The model is an exact existing Codex model; it is not changed by this
command. The approval contains no credential or user content.

| Boundary | Value |
| --- | --- |
| Sole principal | Current kernel PID of the exact pinned, signed `/Applications/Tisra.app/Contents/MacOS/Tisra`, same account UID |
| Sole tool and task kind | `tisra.codex.research.v2`, `model.inference` |
| Sole RPC provider | `codex_app_server`, existing installed Codex CLI and existing ChatGPT account |
| Model | Exact user-approved `--model`; one model per approval |
| Grant lifetime | At most 3,600,000 ms from issue; no automatic renewal |
| Per-request limits | 8,192 request bytes; 32,768 descriptor bytes; 32,768 generated text bytes; 262,144 result envelope bytes; 30,000 ms deadline; one provider turn and zero automatic retries |
| Capacity | One host model slot; background or interactive maximum; host readiness observation lasts 60 seconds and is refreshed only during an active grant |
| Data | Only Tisra's explicit selected Research request and bound source excerpts/snapshots uploaded through the existing typed payload protocol; no general Ledger, file, calendar, Reminders, NAS or shell access |
| Cost | No token or money hard cap in the existing transport; explicit confirmation acknowledges this. Each new Research submission still requires Tisra's own user action. |

The source reuses Tisra's explicit prepare/review/submit action and its current
snapshot bindings as the per-request user decision. It reuses the installed
Tisra binary/helper pins and the existing signed audit-token verifier. It may
reuse a currently signed-in ChatGPT account after a bounded read-only model
preflight. None of these already provides ARL's persistent cross-app Research
approval; the one-hour local record above is new and has not been issued.

## Startup and user state

`main()` reads the approval, builds the exact model, priority profile and
admission, and passes it to `run()`. No approval, expired/unsafe approval,
missing pinned peer or missing Codex binary leaves the metadata host active
without Research execution. `python -m arl.research_product status` shows a
specific state and next action using the consent and existing settings snapshot.
The frozen `settings.snapshot` schema and all Portal/logs methods are unchanged.
The ordinary host health `ready=true` is only host readiness.

On the first local connection, the signed Tisra audit token and exact binary
pin are checked before the host observes and registers the kernel PID. No RPC
can provide a PID or register another app. An active different Tisra PID is
rejected. The host then performs bounded read-only account/model readiness
checks; this is not a model turn. Until that check succeeds, the status says
`model_preflight_pending` internally. The local status command reports
`host_composed` only after observing existing settings fields, without claiming
model readiness. Tisra's own typed route preflight and the host's private
capability gate both require a fresh successful model check before upload or
submit. No UI or client may infer Research readiness from metadata host health.

The admission rereads the exact approval on publication and before external
execution, checks signed/registered identity, exact provider/model, explicit
priority, and byte/deadline ceilings. Deleting the approval with
`python -m arl.research_product revoke` denies subsequent work immediately at
admission and causes the host monitor to shut the Research runtime down. An
already issued upstream request cannot be unsent; cancellation remains bounded
best effort and uncertain work remains marked for review, never replayed.

## Actual enablement gate

After independent source review, the minimum user choices/actions are:

1. Confirm the exact existing ChatGPT/Codex model and approve the one-hour
   principal, data and budget scope above. This creates a new local persistent
   approval; do not do it as part of source review.
2. Authorize packaging/installing the reviewed ARL host source and restarting
   the existing service. This does not follow automatically from source GO.
3. Open the exact installed Tisra app and explicitly review/submit each
   Research request. Tisra and host must both pass read-only protocol and
   model readiness checks first.

To revoke later, run the dedicated revoke command or remove only the approval
file. The host has no RPC method to widen scope, install a model, add credentials,
extend TTL or bypass Tisra's review. Stable signing and installed Control/helper
pairing are separate gates; this packet does not change Keychain ACL/trust,
signing identity, installation, or deployment.
