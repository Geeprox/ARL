"""Focused local-app candidate checks: synthetic transport doubles only.

No production host, real model, held Friday component or original consumer repo
is launched. Run from an environment permitting temporary Unix socket binding.
"""
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
SUITES = [
    'tests.test_codex_contract', 'tests.test_codex_research',
    'tests.test_codex_research_client', 'tests.test_codex_deadline',
    'tests.test_codex_sourced_contract', 'tests.test_codex_sourced_research',
    'tests.test_codex_sourced_client',
    'tests.test_codex_server', 'tests.test_research', 'tests.test_research_client',
    'tests.test_scheduling', 'tests.test_responses_adapter',
]
GENERIC_REGRESSIONS = [
    'test_cancel_and_backoff', 'test_needs_unlock_does_not_pause_other_work',
    'test_pending_queue_budget_and_nonidempotent_unlock_are_safe',
    'test_restored_task_rechecks_capability_policy',
    'test_future_store_version_rejected_without_replacing_data',
    'test_crash_recovery_does_not_replay_uncertain_write',
    'test_disconnect_before_response_is_recoverable',
    'test_persistent_call_budget_and_metadata_only_audit',
]

if __name__ == '__main__':
    if len(sys.argv) != 1: raise SystemExit('This verifier accepts no custom test or provider arguments.')
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE='1')
    tests = SUITES + ['tests.test_runtime.RuntimeTests.' + name for name in GENERIC_REGRESSIONS]
    raise SystemExit(subprocess.call([sys.executable, '-B', '-m', 'unittest', *tests, '-v'], cwd=ROOT, env=env))
