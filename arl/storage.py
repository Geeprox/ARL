from __future__ import annotations

import hashlib
import json
import os
import sqlite3
import threading
import time
import uuid
from contextlib import contextmanager, nullcontext

from .contracts import Fault, encode
from .scheduling import resolve, select
from . import priority as priorities

TERMINAL = {"succeeded", "failed", "cancelled", "needs_review"}


class Store:
    """One transaction lock per process; the service lifetime lock excludes other writers."""
    def __init__(self, path):
        self.lock = threading.RLock()
        self.publication_admission = None
        fd = os.open(str(path), os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        os.close(fd)
        self.db = sqlite3.connect(str(path), check_same_thread=False, isolation_level=None)
        self.db.row_factory = sqlite3.Row
        if self.db.execute("PRAGMA user_version").fetchone()[0] > 4:
            self.db.close()
            raise Fault("unsupported_store_version")
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA synchronous=FULL")
        self.db.executescript('''
        CREATE TABLE IF NOT EXISTS jobs(
            id TEXT PRIMARY KEY, owner TEXT NOT NULL, key TEXT NOT NULL,
            digest TEXT NOT NULL, tool TEXT NOT NULL, args TEXT NOT NULL,
            idempotent INTEGER NOT NULL, state TEXT NOT NULL, attempts INTEGER DEFAULT 0,
            cancel INTEGER DEFAULT 0, next_at REAL DEFAULT 0, result TEXT, error TEXT,
            created REAL NOT NULL, updated REAL NOT NULL,
            requires_identity INTEGER NOT NULL DEFAULT 1,
            permissions TEXT NOT NULL DEFAULT '["legacy_unknown"]',
            tool_contract TEXT NOT NULL DEFAULT '',
            identity_authorized INTEGER NOT NULL DEFAULT 0, UNIQUE(owner,key));
        CREATE TABLE IF NOT EXISTS audit(
            seq INTEGER PRIMARY KEY AUTOINCREMENT, at REAL, owner TEXT, job TEXT, event TEXT);
        CREATE TABLE IF NOT EXISTS wakes(
            seq INTEGER PRIMARY KEY AUTOINCREMENT, target TEXT, source TEXT, at REAL);
        CREATE TABLE IF NOT EXISTS budget(owner TEXT PRIMARY KEY, calls INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS scheduler_state(
            singleton INTEGER PRIMARY KEY CHECK(singleton=1), dispatch_seq INTEGER NOT NULL);
        INSERT OR IGNORE INTO scheduler_state(singleton,dispatch_seq) VALUES(1,0);
        CREATE TABLE IF NOT EXISTS scheduler_apps(
            owner TEXT PRIMARY KEY, waiting_since INTEGER NOT NULL);
        ''')
        columns = {r[1] for r in self.db.execute("PRAGMA table_info(jobs)")}
        with self.transaction():
            if "requires_identity" not in columns:
                # Historical jobs have no durable classification: conservatively private
                # and unverified until explicitly reconciled, never silently downgraded.
                self.db.execute("ALTER TABLE jobs ADD COLUMN requires_identity INTEGER NOT NULL DEFAULT 1")
                self.db.execute("ALTER TABLE jobs ADD COLUMN permissions TEXT NOT NULL DEFAULT '[\"legacy_unknown\"]'")
                self.db.execute("ALTER TABLE jobs ADD COLUMN tool_contract TEXT NOT NULL DEFAULT ''")
                self.db.execute("ALTER TABLE jobs ADD COLUMN identity_authorized INTEGER NOT NULL DEFAULT 0")
            if "priority" not in columns:
                self.db.execute("ALTER TABLE jobs ADD COLUMN priority TEXT NOT NULL DEFAULT 'explicit'")
                self.db.execute("ALTER TABLE jobs ADD COLUMN deadline_at REAL")
                self.db.execute("ALTER TABLE jobs ADD COLUMN deadline_span INTEGER")
            self.db.execute("PRAGMA user_version=4")
        priorities.initialize(self)

    @contextmanager
    def transaction(self):
        with self.lock:
            self.db.execute("BEGIN IMMEDIATE")
            try:
                yield
                self.db.execute("COMMIT")
            except BaseException:
                self.db.execute("ROLLBACK")
                raise

    def audit(self, owner, job, event):
        # Deliberately excludes input, output, prompts, provider exceptions and credentials.
        self.db.execute("INSERT INTO audit(at,owner,job,event) VALUES(?,?,?,?)",
                        (time.time(), owner, job, event))
        self.db.execute("DELETE FROM audit WHERE seq <= (SELECT COALESCE(MAX(seq),0)-10000 FROM audit)")

    def submit(self, owner, key, tool, args, policy, verified=False, schedule=None, *, in_transaction=False, priority_request=None, priority_route=None):
        band,span=resolve(policy,schedule)
        logical={"tool":tool.name,"args":args}
        if schedule is not None:logical['schedule']={'priority':band,'deadline_ms':span}
        if priority_request is not None:
            if not verified:raise Fault('app_identity_unverified')
            if self.priority_authority is None:raise Fault('priority_not_configured')
            self.priority_authority.authorize(owner,tool.name,priority_request,priority_route)
            logical['priority_request']=priority_request
            if priority_request['profile_id'] in self.priority_authority.issued_bindings:
                # A v2 tuple is part of the logical operation, even for an
                # internal typed tool whose args contain only its run ID.
                logical['priority_route']={'submit_method':priority_route.submit_method,**priority_route.projection()}
        digest = hashlib.sha256(encode(logical)).hexdigest()
        # Only host extensions already holding transaction() may opt out. RPC
        # callers cannot supply this flag. It permits atomic run/job registration.
        with (nullcontext() if in_transaction else self.transaction()):
            old = self.db.execute("SELECT * FROM jobs WHERE owner=? AND key=?", (owner, key)).fetchone()
            if old:
                if (old["requires_identity"] or tool.requires_identity or not old["tool_contract"]) and not verified:
                    raise Fault("app_identity_unverified")
                if old["digest"] != digest:
                    raise Fault("idempotency_conflict")
                if old['schedule_v1']:
                    if self.priority_authority is None:raise Fault('priority_not_configured')
                    self.priority_authority.check_plan(owner,tool.name,json.loads(old['schedule_v1']))
                return self.project(old)
            if tool.requires_identity and not verified:
                raise Fault("app_identity_unverified")
            count = self.db.execute("SELECT COUNT(*) FROM jobs WHERE owner=? AND state IN ('queued','running','needs_unlock')", (owner,)).fetchone()[0]
            if count >= policy.max_pending:
                raise Fault("queue_budget_exceeded")
            calls = self.db.execute("SELECT calls FROM budget WHERE owner=?", (owner,)).fetchone()
            if policy.max_calls is not None and calls and calls[0] >= policy.max_calls:
                raise Fault("call_budget_exceeded")
            priority_plan = None
            now = time.time()
            if self.priority_authority is not None:
                if not verified:raise Fault('app_identity_unverified')
                if tool.name not in policy.tools:raise Fault('tool_not_authorized')
                request = priority_request or self.priority_authority.legacy_request(owner,tool.name,int(now*1000)+span)
                priority_plan = priorities.plan_submission(self,owner,tool.name,request,int(now*1000),priority_route)
                priority_plan['protocol_optin']=priority_request is not None
            self.db.execute("INSERT INTO budget(owner,calls) VALUES(?,1) ON CONFLICT(owner) DO UPDATE SET calls=calls+1", (owner,))
            job = str(uuid.uuid4())
            self.db.execute("INSERT INTO jobs(id,owner,key,digest,tool,args,idempotent,state,created,updated,requires_identity,permissions,tool_contract,identity_authorized) VALUES(?,?,?,?,?,?,?,'queued',?,?,?,?,?,?)",
                            (job, owner, key, digest, tool.name, encode(args).decode(), tool.idempotent, now, now,
                             tool.requires_identity, encode(tool.permissions).decode(), tool.contract_digest(), verified))
            self.db.execute("UPDATE jobs SET priority=?,deadline_at=?,deadline_span=? WHERE id=?",(band,now+span/1000,span,job))
            if priority_plan is not None:
                self.db.execute('UPDATE jobs SET priority=?,deadline_at=?,schedule_v1=? WHERE id=?',
                    (priority_plan['effective_class'],priority_plan['request']['deadline_at_ms']/1000,encode(priority_plan).decode(),job))
            self.audit(owner, job, "submitted")
            return self.get(owner, job)

    @staticmethod
    def project(row):
        result = {"id": row["id"], "tool": row["tool"], "state": row["state"],
                "attempts": row["attempts"], "result": json.loads(row["result"]) if row["result"] else None,
                "error": row["error"], "updated": row["updated"]}
        if row['schedule_v1'] and json.loads(row['schedule_v1']).get('protocol_optin'):
            plan=json.loads(row['schedule_v1'])
            result['scheduling']=priorities.projection(plan)
        return result

    def row(self, owner, job):
        row = self.db.execute("SELECT * FROM jobs WHERE owner=? AND id=?", (owner, job)).fetchone()
        if not row:
            raise Fault("job_not_found")
        return row

    def get(self, owner, job):
        with self.lock:
            return self.project(self.row(owner, job))

    def access_metadata(self, owner, job):
        with self.lock:
            row = self.db.execute("SELECT tool,requires_identity,permissions,tool_contract FROM jobs WHERE owner=? AND id=?", (owner, job)).fetchone()
            if row is None:
                raise Fault("job_not_found")
            return dict(row)

    def cancel(self, owner, job):
        with self.transaction():
            row = self.row(owner, job)
            if row["state"] not in TERMINAL:
                if row["state"] == "running":
                    # Cancellation requests do not claim that an in-flight side effect stopped.
                    self.db.execute("UPDATE jobs SET cancel=1,updated=? WHERE id=?", (time.time(), job))
                else:
                    self.set_state(job, "cancelled", error="cancelled")
                self.audit(owner, job, "cancel_requested")
            elif row['schedule_v1']:
                self.audit(owner,job,'cancel_after_priority_completion')
            elif self.db.execute("SELECT 1 FROM audit WHERE owner=? AND job=? AND event='fenced_completed' LIMIT 1",
                                 (owner, job)).fetchone():
                # A later request cannot undo an already published completion.
                # Record its actual ordering without changing legacy tools.
                self.audit(owner, job, "cancel_after_fenced_completion")
            return self.get(owner, job)

    def is_cancelled(self, job):
        with self.lock:
            return bool(self.db.execute("SELECT cancel FROM jobs WHERE id=?", (job,)).fetchone()[0])

    def set_state(self, job, state, result=None, error=None, delay=0):
        self.db.execute("UPDATE jobs SET state=?,result=?,error=?,next_at=?,updated=? WHERE id=?",
                        (state, encode(result).decode() if result is not None else None,
                         error, time.time()+delay, time.time(), job))

    @staticmethod
    def _scope_clause(scope):
        """Trusted host work scope, applied before recovery, expiry and claim."""
        if scope is None:
            return "", ()
        if (type(scope) is not frozenset or len(scope) > 32 or any(
                type(pair) is not tuple or len(pair) != 2 or
                any(type(value) is not str or not 1 <= len(value) <= 100 for value in pair)
                for pair in scope)):
            raise Fault("invalid_work_scope")
        pairs = sorted(scope)
        return (" AND (" + " OR ".join("(owner=? AND tool=?)" for _ in pairs) + ")" if pairs
                else " AND 0"), tuple(value for pair in pairs for value in pair)

    def recover(self, tools=None, *, scope=None):
        clause, values = self._scope_clause(scope)
        with self.transaction():
            for row in self.db.execute("SELECT * FROM jobs WHERE state IN ('queued','running','needs_unlock')" + clause, values).fetchall():
                if row['schedule_v1'] or self.priority_authority is not None:
                    # Recovery runs only after Runtime owns its lifetime lock.
                    # Old profiles never silently become new boot authorization.
                    self.set_state(row['id'],'needs_review',error='priority_recovery_requires_new_authorization')
                    self.audit(row['owner'],row['id'],'priority_recovery_held')
                    continue
                current = (tools or {}).get(row["tool"])
                if current is None or not row["tool_contract"] or current.contract_digest() != row["tool_contract"]:
                    self.set_state(row["id"], "needs_review", error="tool_contract_changed")
                    self.audit(row["owner"], row["id"], "recovered_contract_mismatch")
                    continue
                if row["state"] != "running":
                    continue
                if not row["idempotent"]:
                    state = "needs_review"
                elif row["cancel"]:
                    state = "cancelled"
                elif row["attempts"] >= 3:
                    state = "failed"
                else:
                    state = "queued"
                self.set_state(row["id"], state, error="interrupted")
                self.audit(row["owner"], row["id"], "recovered_"+state)
            if scope is None:
                self.db.execute('DELETE FROM resource_leases')
            else:
                self.db.execute('DELETE FROM resource_leases WHERE job IN (SELECT id FROM jobs WHERE 1' + clause + ')', values)

    def claim(self, *, scope=None):
        clause, values = self._scope_clause(scope)
        with self.transaction():
            now=time.time()
            for expired in self.db.execute("SELECT * FROM jobs WHERE state='queued' AND deadline_at IS NOT NULL AND deadline_at<=?" + clause, (now, *values)).fetchall():
                self.set_state(expired['id'],'failed',error='deadline_exceeded')
                self.audit(expired['owner'],expired['id'],'deadline_exceeded')
            candidates=self.db.execute("SELECT * FROM jobs WHERE state='queued' AND next_at<=? AND cancel=0" + clause, (now, *values)).fetchall()
            # Only eligible owners accrue bypasses. Backoff, unlock, cancelled and
            # expired work must not reserve a turn or carry debt into a new queue.
            if scope is None:
                self.db.execute("DELETE FROM scheduler_apps WHERE owner NOT IN (SELECT DISTINCT owner FROM jobs WHERE state='queued' AND next_at<=? AND cancel=0)",(now,))
            dispatch_seq=self.db.execute("SELECT dispatch_seq FROM scheduler_state WHERE singleton=1").fetchone()[0]
            for owner in {r['owner'] for r in candidates}:
                self.db.execute("INSERT OR IGNORE INTO scheduler_apps(owner,waiting_since) VALUES(?,?)",(owner,dispatch_seq))
            waiting_since={r['owner']:r['waiting_since'] for r in self.db.execute("SELECT owner,waiting_since FROM scheduler_apps")}
            if self.priority_authority is not None:
                for legacy in [r for r in candidates if not r['schedule_v1']]:
                    self.set_state(legacy['id'],'needs_review',error='priority_authorization_missing')
                row=priorities.select_profiled(self,[r for r in candidates if r['schedule_v1']],now,dispatch_seq)
            else:
                profiled=[r for r in candidates if r['schedule_v1']]
                for held in profiled:self.set_state(held['id'],'needs_review',error='priority_not_configured')
                row=select([r for r in candidates if not r['schedule_v1']],now,dispatch_seq,waiting_since)
            if row:
                if row['schedule_v1']:
                    priorities.claim_lease(self,row,row['attempts']+1,int(now*1000),dispatch_seq)
                self.db.execute("UPDATE jobs SET state='running',attempts=attempts+1,updated=? WHERE id=?", (time.time(), row["id"]))
                # These updates share the job claim transaction, so a crash cannot
                # erase an unserved app's place or account for a claim twice.
                self.db.execute("UPDATE scheduler_state SET dispatch_seq=dispatch_seq+1 WHERE singleton=1")
                self.db.execute("DELETE FROM scheduler_apps WHERE owner=?",(row['owner'],))
                self.audit(row["owner"], row["id"], "running")
                return dict(self.row(row["owner"], row["id"]))

    def finish(self, row, state, result=None, error=None, delay=0):
        if row.get('schedule_v1'):
            return self.finish_priority(row,state,result,error)
        with self.transaction():
            self.set_state(row["id"], state, result, error, delay)
            self.audit(row["owner"], row["id"], state)

    def finish_priority(self,row,state,result=None,error=None):
        # Freeze observed bytes outside the transaction; encoding may interleave
        # with a real durable cancellation. The decision below sees that request.
        effect=json.loads(encode(result)) if result is not None else None
        with self.transaction():
            current=self.row(row['owner'],row['id'])
            if current['state']!='running' or current['attempts']!=row['attempts']:
                return False
            reason='cancelled' if current['cancel'] else None
            if reason is None:
                try:priorities.check_running(self,row)
                except Fault as exc:reason=exc.code
            if reason is None and state=='succeeded' and self.publication_admission is not None:
                try:self.publication_admission(current['owner'],current['tool'],json.loads(current['args']))
                except Fault as exc:reason=exc.code
            if reason is None and current['deadline_at']<=time.time():reason='deadline_exceeded'
            if reason is not None:
                state='needs_review' if not current['idempotent'] else ('cancelled' if reason=='cancelled' else 'failed')
                if reason in {'priority_identity_binding_changed','priority_identity_binding_unavailable',
                              'priority_route_binding_changed','priority_route_binding_unavailable',
                              'planning_review_not_authorized'}:
                    effect=None
                if effect is not None and not current['idempotent']:
                    effect={'effect':effect,'completion':{'status':'held','reason':reason,'automatic_replay':False}}
                error=reason
            if state in {'queued','needs_unlock'}:
                state='needs_review'
                error=error or 'priority_automatic_replay_held'
            self.set_state(row['id'],state,effect,error)
            self.audit(row['owner'],row['id'],'priority_completed_'+state)
            # The lease remains until Runtime's finally observes adapter return.
            return True

    def finish_fenced(self, row, effect, *, verify, effect_observed_at):
        """Opt-in completion decision serialized with durable cancel/publication.

        The existing transaction uses the process RLock and BEGIN IMMEDIATE.
        A cancel transaction before this decision is observed; a cancel that
        waits for it linearizes after completion. Unfenced finish is unchanged.
        verify is trusted, bounded, read-only completion authority renewal.
        This does not claim rollback or continuous remote/native qualification.
        """
        # Freeze the handler's observation before taking the publication lock.
        # Result encoding itself may interleave with a cancellation request.
        effect = json.loads(encode(effect))
        allowed = {'cancelled', 'expired', 'revoked', 'source_changed', 'unsupported',
                   'binding_mismatch', 'journal_uncertain', 'completion_unverified'}
        with self.transaction():
            current = dict(self.row(row['owner'], row['id']))
            if (current['state'] != 'running' or current['attempts'] != row['attempts']
                    or current['tool_contract'] != row['tool_contract']
                    or current['idempotent'] != 0 or current['requires_identity'] != 1):
                return False  # stale completion cannot overwrite a newer terminal row
            reason = 'cancelled' if current['cancel'] else None
            if reason is None and current['deadline_at'] is not None and current['deadline_at'] <= time.time():
                reason = 'expired'
            if reason is None:
                try:
                    if not callable(verify) or verify() is not None:
                        reason = 'completion_unverified'
                except Exception as error:
                    code = getattr(error, 'code', None)
                    if type(code) is str and code.startswith('nas_upload_'):
                        code = code.removeprefix('nas_upload_')
                    reason = code if type(code) is str and code in allowed else 'completion_unverified'
            # Renew durable flags and deadline AFTER potentially blocking checks,
            # in the SAME transaction as terminal publication; no callback runs
            # between this decision and the database update below.
            current = dict(self.row(row['owner'], row['id']))
            if (current['state'] != 'running' or current['attempts'] != row['attempts']
                    or current['tool_contract'] != row['tool_contract']):
                return False
            decision_at = time.time()
            if current['cancel']:
                reason = 'cancelled'
            elif current['deadline_at'] is not None and current['deadline_at'] <= decision_at:
                reason = 'expired'
            cancel_at = self.db.execute("SELECT MIN(at) FROM audit WHERE owner=? AND job=? AND event='cancel_requested'",
                (row['owner'], row['id'])).fetchone()[0] if current['cancel'] else None
            timing = 'none_before_publication'
            if current['cancel']:
                timing = ('unrecorded_request_time' if cancel_at is None else
                          'after_consumer_return_before_publication' if cancel_at > effect_observed_at else
                          'at_or_before_consumer_return')
            completion = {'protocol': 'store.transaction.v1', 'reason': reason,
                'effect_observed_at': effect_observed_at, 'publication_decided_at': decision_at,
                'cancel_requested_at': cancel_at, 'cancel_timing': timing}
            if reason is None:
                state, error = 'succeeded', None
                result = dict(effect, completion=completion)
            else:
                state, error = 'needs_review', 'completion_' + reason
                result = {'schema_version': 1, 'status': 'needs_review', 'failure': error,
                          'effect': effect, 'completion': completion}
            self.set_state(row['id'], state, result, error)
            self.audit(row['owner'], row['id'], state)
            self.audit(row['owner'], row['id'], 'fenced_completed')
            return True

    def resume(self, owner, job):
        with self.transaction():
            row = self.row(owner, job)
            if row['schedule_v1']:raise Fault('priority_resume_requires_new_authorization')
            if row["state"] != "needs_unlock":
                raise Fault("not_resumable")
            self.set_state(job, "queued")
            self.audit(owner, job, "resume_requested")
            return self.get(owner, job)

    def wake(self, source, target):
        with self.transaction():
            count = self.db.execute("SELECT COUNT(*) FROM wakes WHERE target=?", (target,)).fetchone()[0]
            if count < 64:
                self.db.execute("INSERT INTO wakes(target,source,at) VALUES(?,?,?)", (target, source, time.time()))
            self.audit(source, None, "wake_"+target)

    def poll_wakes(self, target):
        with self.transaction():
            rows = self.db.execute("SELECT seq,source,at FROM wakes WHERE target=?", (target,)).fetchall()
            self.db.execute("DELETE FROM wakes WHERE target=?", (target,))
            return [dict(r) for r in rows]

    def state_counts(self):
        # Only aggregate counters; never select owner, IDs, tool names or payload.
        states = ("queued", "running", "succeeded", "failed", "cancelled", "needs_unlock", "needs_review")
        with self.lock:
            counts = {state: 0 for state in states}
            for row in self.db.execute("SELECT state,COUNT(*) FROM jobs GROUP BY state"):
                if row[0] in counts:
                    counts[row[0]] = row[1]
            return counts

    def close(self):
        with self.lock:
            self.db.close()
