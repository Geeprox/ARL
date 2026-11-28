"""Versioned application task methods and scenario declarations."""
import re

from .codex_execution_options import PACKAGE_IDS
from .contracts import Fault
from .scheduling import BANDS

TASK_SUBMIT = 'application.tasks.submit.v1'
TASK_GET = 'application.tasks.get.v1'
TASK_CANCEL = 'application.tasks.cancel.v1'
TASK_METHODS = frozenset({TASK_SUBMIT, TASK_GET, TASK_CANCEL})

MAX_TASK_DEADLINE_MS = 180_000
_REQUIRED_FIELDS = frozenset({'id', 'name', 'task_kind', 'priority', 'package_id'})
_ALLOWED_FIELDS = _REQUIRED_FIELDS | {'deadline_ms', 'max_output_bytes'}


def validate_scenarios(value):
    """Validate and fill scenario defaults for both SDK construction and admission."""
    if type(value) is not list or len(value) > 32:
        raise Fault('invalid_application_scenarios')
    scenarios = []
    seen = set()
    for row in value:
        if type(row) is not dict or not _REQUIRED_FIELDS <= row.keys() <= _ALLOWED_FIELDS:
            raise Fault('invalid_application_scenarios')
        item = dict(row, deadline_ms=row.get('deadline_ms', MAX_TASK_DEADLINE_MS),
                    max_output_bytes=row.get('max_output_bytes', 4096))
        if (type(item['id']) is not str or re.fullmatch(r'[A-Za-z0-9_.-]{1,64}', item['id']) is None
                or item['id'] in seen
                or type(item['name']) is not str or not 1 <= len(item['name']) <= 100
                or any(ord(char) < 32 for char in item['name'])
                or type(item['task_kind']) is not str
                or re.fullmatch(r'[A-Za-z0-9_.-]{1,100}', item['task_kind']) is None
                or type(item['priority']) is not str or item['priority'] not in BANDS
                or type(item['package_id']) is not str or item['package_id'] not in PACKAGE_IDS
                or type(item['deadline_ms']) is not int or not 1000 <= item['deadline_ms'] <= MAX_TASK_DEADLINE_MS
                or type(item['max_output_bytes']) is not int or not 128 <= item['max_output_bytes'] <= 32768):
            raise Fault('invalid_application_scenarios')
        seen.add(item['id'])
        scenarios.append(item)
    return scenarios
