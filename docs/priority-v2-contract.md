# ARL trusted task/resource negotiation v2 — source contract

`priority.negotiate.v2` takes exactly the v1 `requested_profile` parameters. Its
response has `schema_version: 2` and adds `task_bindings`. v1 negotiation keeps
its exact old field set. Submission scheduling and accepted facts remain v1;
there are no extra caller-selected route or authorization fields.

Each binding has exactly `submit_method`, `tool`, `task_kind`, `route`,
`resource_kind`, `allowed_classes`, `estimate_floor_ms`, `execution_budget_ms`.
`route` has exactly `provider`, `model`, `model_fingerprint`. Null is an exact
value, never a wildcard. Typed research routes require their already validated
provider/model/fingerprint; generic model completion uses its validated
provider/model and a null fingerprint. Friday planning uses its existing
codex_app_server adapter and selected model. Other generic tools use three
null route fields. Capture bindings are unavailable in this version.

The sole authority is a bounded read-only host callback returning immutable
`RouteBinding` snapshots. Ready is false by default. The host must populate
these only from current validated capabilities, without performing discovery,
launch, permission changes, or provider calls while negotiating. No producer is
configured by this source change. Missing, unavailable, ambiguous, unsupported,
or unready routes produce no usable binding. Kernel identity, current app tool
and method policy, task policy, resource capacity and profile ceilings still
apply. Limits intersect; the higher estimate floor and lower execution budget
win. A task label cannot independently grant a resource or class.

The client selects one exact method/tool/task/provider/model/fingerprint tuple
through `select_binding_v2` or `Client.priority_request_v2`. Zero or multiple
matches are held. The helper copies the host resource, never picks the first
resource or fabricates a provider pool. It does not authorize submission.

The server derives internal `RouteContext` after validating the actual generic
arguments or current typed grant. v2 profile IDs pin the full canonical binding
map. Admission, idempotent lookup, claim, running checks and publication checks
compare that map with the current snapshot and revalidate the stored actual
route. Changed registration, policy epoch, provider capability or route causes
failure/hold before further work. No old profile is restored across restart.
The policy epoch remains distinct from native authorization/execution epochs.
Existing v1 profiles retain their host TaskPolicy semantics and exact wire
schema; they do not provide the v2 tuple negotiation contract. Hosts requiring
route-specific production admission must use v2 profiles and validated route
producers; production readiness requires a separate review and live checks.

Responses SDK pins full opt-in submit parameters and the first accepted facts
as immutable canonical bytes, bound to owner/job and full run/hash/epoch/auth
scope. Status and cancel cannot replace them with otherwise valid facts.
Friday's adapter similarly fixes the request and first accepted facts, and
compares every subsequent status before publishing a result. Lost opt-in
submissions are still sent once; these pins never restore grants or resubmit.

Fairness considers aged ordinary heads from every currently eligible resource
before choosing new realtime work. It preserves the effective class and cannot
consume reserved capacity. Ordinary eligibility requires both total occupancy
below N and ordinary occupancy below N−R. A realtime lease does not count twice
as reserved plus ordinary occupancy. Actual worker return still releases the
lease; cancel acknowledgment does not. N=1 protection windows and explicit
infeasible deadline refusal remain. This is not a realtime guarantee.

This candidate repairs the three independent source blockers and the client
mapping gap together. Historical six before traces are reused; the new six
after traces and necessary focused regressions are generated in an isolated
source environment. No native, real model, NAS, IPC, credentials, permissions,
installation, deployment, push, or original repository mutation is authorized.
