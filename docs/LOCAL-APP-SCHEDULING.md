# Local app scheduling

The existing ARL worker remains the single, nonpreemptible executor. Local apps
use the existing `submit_scheduled` request with `tool`, `args`, `key`, `priority`
and `deadline_ms`; the verified app identity selects its server `AppPolicy`.
Only policy-granted priority bands and deadlines are admitted. Scheduling does
not authorize a tool, grant a permission, load a provider, or change identity.

## Selection and fairness

`arl.scheduling.order` retains the existing three bands (`background`, `explicit`,
`interactive`), 30-second aging steps capped at interactive, then creation-time
and ID ordering. For each eligible app, `select` first chooses that app's best
job using this ordering. Apps with larger backlogs get no additional weight.

Priority ordinarily chooses among these app heads. After eight claims by other
apps (`MAX_PRIORITY_BYPASSES`), an app joins the overdue queue. The oldest waiting
app in that queue receives the next claim; existing priority/aging/FIFO ordering
resolves a simultaneous wait. New arrivals cannot overtake an older overdue app.
With `N` eligible apps including itself, a continuously eligible app receives a claim after at
most `8 + N - 1` claims by other apps. This is a dispatch-count bound, not a
wall-clock or completion guarantee. A running call remains nonpreemptible, and
an app's deadline or cancellation can end its wait before dispatch.

Eligibility requires a queued job whose retry time has arrived and whose cancel
flag is clear. Deadline-expired queued jobs fail before selection. Retry backoff,
`needs_unlock`, cancellation and empty queues do not reserve a fairness turn.
When an app becomes eligible again, it begins a fresh wait. Within an app, the
original priority/aging/FIFO ordering still selects jobs; the app-level bound
does not make each of its individual jobs immediately eligible for execution.

`Store.claim` maintains a monotonic dispatch counter (`scheduler_state`) and the
first unserved dispatch per eligible owner (`scheduler_apps`) in the same SQLite
transaction as claiming the job. Service restarts preserve unserved apps' places.
Fairness metadata contains owner names and counters only. It is internal and adds
no wire fields or consumer-visible payload. These additive metadata tables keep
the existing store version 3; older jobs, deadlines, idempotency keys and results
remain unchanged. An older runtime ignores these optional tables, so its claims
are not counted; the fairness guarantee requires using the updated runtime for
all dispatches.

## Consumer adoption

1. Include `submit_scheduled` in the app's existing server-authorized methods.
2. Grant only the priority bands the app needs in `AppPolicy.priority_bands` and
   set `default_priority` and `max_deadline_ms` on the server. A consumer cannot
   raise these limits by sending a request.
3. Send an authorized band and an integer deadline in milliseconds with the
   existing stable idempotency key. Reconnect using that same key; do not create
   a new request merely to renew an expired deadline.
4. Use the existing `get`, `cancel` and `resume` contracts. The fairness queue
   requires no SDK or consumer changes beyond the existing scheduled request.

All verification uses synthetic handlers and transport doubles. There is no
model inference, provider installation, credential access, signing or deployment.
An actual app integration must still verify its existing trusted identity and
policy configuration against its consumer build before any live run.
