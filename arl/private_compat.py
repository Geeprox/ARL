"""Local compatibility composition. Excluded from public source distributions.
No RPC/config loader enables this adapter; existing grants and typed APIs stay exact.
"""
from .contracts import AppPolicy, Fault
from .travel import TravelAdapter
from .research import METHODS as RESPONSES_METHODS, NAME as RESEARCH_NAME
from .codex_research import METHODS as CODEX_METHODS, NAME as CODEX_RESEARCH_NAME
from .tisra_capture_runtime import NAME as CAPTURE_NAME
from .friday_planning import NAME as FRIDAY_PLANNING_NAME
from .tisra_capture_uploads import METHODS as CAPTURE_METHODS
from .service_deployment.portal import ServicePortal, METHODS as SERVICE_PORTAL_METHODS
RESEARCH_METHODS = RESPONSES_METHODS | CODEX_METHODS
RESEARCH_NAMES = frozenset({RESEARCH_NAME, CODEX_RESEARCH_NAME, 'tisra.codex.research.v2', 'tisra.codex.rerank.v1'})


def default_policies(local_enabled=False):
    common = frozenset({"runtime.ping", "runtime.info", "text.sha256", "model.complete"})
    mock = frozenset({"mock"})
    return {
        "settings": AppPolicy(frozenset(), frozenset(), max_tokens=0, max_pending=0, max_calls=0,
                              methods=frozenset({"health", "ready", "overview", "settings.snapshot", "settings.logs", "settings.logs_export", "settings.logs.v3", "settings.modules_snapshot"}), public_metadata=True),
        "tisra": AppPolicy(common | {"apple.calendar.list", "apple.reminders.list"},
                           mock | ({"ollama"} if local_enabled else set())),
        "friday": AppPolicy(common, mock | ({"ollama"} if local_enabled else set())),
        "mio": AppPolicy(common - {"model.complete"} | frozenset(t["name"] for t in TravelAdapter().descriptors)),
    }


def check_planning_admission(admission):
    from .friday_profile import PlanningAdmission
    if type(admission) is not PlanningAdmission:
        raise Fault('planning_review_not_authorized')

def metadata_policies():
    from .compat_host import metadata_policies as legacy
    return legacy()

def managed_app_ids():
    return frozenset(default_policies())-{'settings'}

DEFAULT_APP="tisra"

PLANNING_NAME=FRIDAY_PLANNING_NAME
