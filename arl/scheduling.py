"""Server-authorized priority with persistent, bounded app fairness.

The store supplies a durable dispatch counter and each eligible owner's first
unserved dispatch. Priority may bypass an owner only a bounded number of times;
overdue owners are then served in waiting order. Running work is nonpreemptible.
"""
from .contracts import Fault
BANDS={'background':0,'explicit':1,'interactive':2}
AGING_SECONDS=30
MAX_PRIORITY_BYPASSES=8

def resolve(policy,requested=None):
    requested={} if requested is None else requested
    if type(requested) is not dict or set(requested)-{'priority','deadline_ms'}:raise Fault('invalid_arguments')
    band=requested.get('priority',policy.default_priority)
    span=requested.get('deadline_ms',policy.max_deadline_ms)
    if type(band)!=str or band not in BANDS or band not in policy.priority_bands:raise Fault('priority_not_authorized')
    if type(span)!=int or not 1<=span<=policy.max_deadline_ms:raise Fault('deadline_not_authorized')
    return band,span

def order(row,now):
    rank=BANDS.get(row['priority'],0)
    age=max(0,now-row['created'])
    return (-min(2,rank+int(age//AGING_SECONDS)),row['created'],row['id'])


def select(candidates, now, dispatch_seq, waiting_since):
    """Select one app head, preserving priority/aging/FIFO within each app.

    After MAX_PRIORITY_BYPASSES claims by other apps, an eligible app joins the
    overdue FIFO. An app that starts waiting later cannot overtake that FIFO,
    including an interactive app. With N eligible apps including itself, its
    next claim follows at most MAX_PRIORITY_BYPASSES + N - 1 other-app claims.
    """
    heads={}
    for row in candidates:
        owner=row['owner']
        if owner not in heads or order(row,now)<order(heads[owner],now):
            heads[owner]=row
    if not heads:
        return None
    overdue=[row for owner,row in heads.items()
             if dispatch_seq-waiting_since[owner]>=MAX_PRIORITY_BYPASSES]
    if overdue:
        return min(overdue,key=lambda row:(waiting_since[row['owner']],order(row,now)))
    return min(heads.values(),key=lambda row:order(row,now))
