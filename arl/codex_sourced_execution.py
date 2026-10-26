"""Versioned, opt-in sourced execution options. No discovery provider IO."""
import json
from . import codex_execution_contract as contract
from .codex_sourced_research import CodexSourcedAdapter, CodexSourcedResearchEngine
from .contracts import Fault, encode
from .research import exact, integer


class CodexExecutionAdapter(CodexSourcedAdapter):
    contract = contract


class CodexExecutionEngine(CodexSourcedResearchEngine):
    contract = contract

    def __init__(self, grants, adapters, *, execution_catalog=None, **kwargs):
        super().__init__(grants, adapters, **kwargs)
        self.execution_catalog = execution_catalog
        self.execution_policies = {}

    def attach(self, store):
        super().attach(store)
        with store.transaction():
            store.db.execute('CREATE TABLE IF NOT EXISTS research_execution_preferences(job TEXT PRIMARY KEY, confirmed TEXT NOT NULL)')

    def catalog(self, owner, policy):
        grant, adapter = self.grant(owner)
        snapshot = (self.execution_catalog(owner) if self.execution_catalog is not None
                    else adapter.text_adapter.execution_catalog_snapshot())
        return contract.catalog(snapshot, owner, policy, grant.models)

    def submit_args(self, p):
        if 'execution_options' not in p:
            return super().submit_args(p)
        integer(p.get('schema_version'), 2, 2)
        contract.options(p['execution_options'])
        legacy = dict(p); legacy.pop('execution_options'); legacy['schema_version'] = 1
        super().submit_args(legacy)

    def dispatch(self, owner, method, p, policy, **kwargs):
        self.execution_policies[owner] = policy
        if method == 'codex.research.capabilities.v1' and p:
            exact(p, {'execution_contract'})
            if p['execution_contract'] != contract.CONTRACT:
                raise Fault('unsupported_execution_contract')
            result = super().capability_result(owner)
            result['execution_options'] = self.catalog(owner, policy)[0]
            return result
        if method == 'codex.research.submit.v1' and 'execution_options' in p:
            self.submit_args(p)
            projected, rows = self.catalog(owner, policy)
            contract.resolve(p['execution_options'], p, projected, rows)
            _, adapter = self.grant(owner, p)
            adapter.preflight(p)  # Local binary/control pins, before queue/budget.
        return super().dispatch(owner, method, p, policy, **kwargs)

    def original_binding(self, run):
        value = super().original_binding(run)
        args = json.loads(run['args'])
        if 'execution_options' in args:
            value['execution_options'] = contract.options(args['execution_options'])
        return value

    def external_admission(self, run):
        args = json.loads(run['args'])
        if 'execution_options' in args:
            policy = self.execution_policies.get(run['owner'])
            if policy is None:
                policy = getattr(self, 'runtime', None).policies[run['owner']]
            projected, rows = self.catalog(run['owner'], policy)
            contract.resolve(args['execution_options'], args, projected, rows)
        return super().external_admission(run)

    def record_native(self, job, event, fields):
        if event == 'native_preferences_ack':
            with self.store.transaction():
                args = json.loads(self.run(job)['args'])
                if 'execution_options' in args:
                    value = contract.preferences(fields, args['execution_options'])
                    previous = self.store.db.execute('SELECT confirmed FROM research_execution_preferences WHERE job=?', (job,)).fetchone()
                    if previous is not None and json.loads(previous['confirmed']) != value:
                        raise Fault('provider_preferences_unverified')
                    self.store.db.execute('INSERT OR IGNORE INTO research_execution_preferences VALUES(?,?)', (job, encode(value).decode()))
            return
        return super().record_native(job, event, fields)

    def receipt(self, run):
        value = super().receipt(run)
        args = json.loads(run['args'])
        if 'execution_options' in args:
            value['schema_version'] = 2
            value['execution_options'] = contract.options(args['execution_options'])
            row = self.store.db.execute('SELECT confirmed FROM research_execution_preferences WHERE job=?', (run['job'],)).fetchone()
            value['execution_preferences'] = json.loads(row['confirmed']) if row else None
        return value

    def validate_response(self, raw, args, run):
        value = super().validate_response(raw, args, run)
        if 'execution_options' in args:
            row = self.store.db.execute('SELECT confirmed FROM research_execution_preferences WHERE job=?', (run['job'],)).fetchone()
            if row is None or value['execution_preferences'] != json.loads(row['confirmed']):
                raise Fault('provider_preferences_unverified')
        return value
