# Application SDK registration and model tasks (v1)

ARL is a persistent local base service. Supported applications discover its
published local socket, register on startup and maintain a session. There is no
compiled application list, per-product enrollment file or second model queue.

## Current integration checkpoint

The Python implementation is in `arl/application_platform.py` and the lifecycle
SDK in `arl/application_session.py`. The native SDK is `examples/ARLClient.swift`.
Protocol/queue tests use real Unix sockets, actual kernel process identity and
explicitly synthetic provider subprocesses. Installed-host and real-model
acceptance are separate checks; a passing source test does not establish them.

## Discovery, handshake and lifecycle

The default endpoint is `~/Library/Application Support/ARL/runtime.sock`.
Do not launch a private ARL copy or switch to a per-application runtime directory.
Use the public `settings` identity for readiness/discovery, then the application's
own stable ID for registration. `runtime.describe` advertises
`application_registration: 1`, `application_tasks: 1`, `model_scheduler: 1` when
this platform is active.

`connection.open` takes `client_nonce`, `name`, `icon_ref`, `version`,
`capabilities` and optional `scenarios`. The server validates the actual socket
peer, returns a fresh challenge and session ID; `connection.confirm` echoes
those two fields over the same process identity. Only confirmation establishes
a connected session. `connection.ping` renews it; the default SDK heartbeat is
10 seconds and the server lease is 30 seconds. On disconnect/restart/expiry,
repeat discovery and the complete handshake. Close on application shutdown.
Only valid confirmed sessions appear in ARL's connected-app list.

The local trust boundary is the current OS account plus kernel PID, process
birth identity and executable identity. A caller-supplied PID is never accepted;
another process cannot take over the same application ID's active session. Names and icons
are validated display metadata, not a claim of publisher/code-signing
attestation. Existing host-reserved identities retain their stronger checks.
Registration may use the already enabled model service; it never grants NAS,
Apple automation, credentials, device control or unrelated tools.

## Scene declarations

Each application declares up to 32 model-use scenarios, each with:

| Field | Meaning |
| --- | --- |
| `id` | Stable scenario identifier, e.g. `summary` |
| `name` | Human-readable use case |
| `task_kind` | Bounded machine identifier describing the task |
| `priority` | `interactive`, `explicit`, or `background` |
| `package_id` | `low`, `medium`, `high`, `very_high`, or `highest` |
| `deadline_ms` | Queue plus execution budget, 1,000–180,000; default 180,000 |
| `max_output_bytes` | 128–32,768; default 4,096 |

Queue priority and model package are independent. Apps declare what they need;
ARL resolves the package's current model, reasoning effort and Fast tier at
admission. The resolved arguments are frozen for that job. Changes to package
settings apply to new jobs. Never hardcode supplier model names in consumers or
silently substitute another model if a selected package is unavailable.

```python
from pathlib import Path
from arl.application_session import ApplicationSession

home = Path.home() / 'Library/Application Support/ARL'
session = ApplicationSession(home, 'org.example.myapp', 'My App', [
    {'id': 'summary', 'name': 'Summarize selected text', 'task_kind': 'summarize',
     'priority': 'interactive', 'package_id': 'high'}
], icon_ref='sf:doc.text', version='1')
# Start with the application; this thread only registers and sends heartbeats.
session.start()
# Submit only when that application's business flow actually requests a task.
job = session.submit('summary', 'Text supplied by the user')
result = session.wait(job, timeout=180)
# Shutdown: session.close()
```

Supply an explicit, persisted `request_id` for retry/recovery of an application
intent; never allocate a new ID merely because an acknowledgement was lost.
The durable intent-to-job binding preserves the original selection even if the
user changes packages before the same intent is submitted again. Reusing an ID
with different input or a different scenario is rejected.
`application.tasks.submit.v1` takes exactly `schema_version: 1`, `session_id`,
`request_id`, `scenario_id`, `input`. The acknowledgement includes the job ID,
resolved model/effort/tier/priority and package/scenario IDs.
`application.tasks.get.v1` and `.cancel.v1` take `schema_version`, `session_id`,
`job_id`. Final success uses the existing durable job and native Codex receipt.
The response model/effort must be checked against the admitted arguments and
native acknowledgements; asking the model what it is does not verify routing.

An optional icon uses the existing `application.icon.register.v1` contract:
64×64 PNG, at most 8,192 bytes, validated base64/digest metadata. The Python SDK
accepts this as `icon=...`; SF Symbols remain available via `icon_ref`.

## Scheduling and parallelism

All applications share the existing durable Store scheduler. It preserves
priority, FIFO and the existing anti-starvation policy. Running inference is
not interrupted simply because a higher-priority request arrives. Admission is
bounded to 16 pending jobs per application and 64 current application identities.
The enabled provider's finite call budget, if configured, is shared globally;
registering more applications does not multiply it.

The user sets 1–8 simultaneous model tasks on ARL's model page (default 2).
The private `model-scheduler-v1.json` contains exactly `schema_version: 1` and
`max_parallel`. The host applies changes within five seconds without restarting.
Reducing the limit lets current jobs finish, then admits work under the new
limit. `settings.scheduler.v1` exposes counts and configured parallelism only,
not prompts, results, credentials or private application state.

## Consumer acceptance

Verify startup registration, icon/name/scenario metadata, heartbeats, expiry,
ARL restart and automatic re-registration, duplicate live-instance rejection,
priority ordering, bounded concurrency, idempotent retry, cancellation and exact
package/native model-effort acknowledgements. Registration itself must cause
zero inference or device actions. Keep synthetic and real inference receipts
separate, and avoid compiling an app-specific registration path into ARL.
