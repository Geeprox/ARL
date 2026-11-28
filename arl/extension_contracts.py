"""Optional trusted code composition; public defaults have no product grants."""
from .contracts import Fault
from .control import metadata_policies as control_metadata_policies
try:
    import arl.private_compat as compatibility
except ModuleNotFoundError as error:
    if error.name != __package__+'.private_compat':raise
    compatibility=None

def default_policies(local_enabled=False):
    if compatibility:return compatibility.default_policies(local_enabled)
    return metadata_policies()

def metadata_policies():
    return control_metadata_policies(local_status=compatibility is not None)

def managed_app_ids():
    return compatibility.managed_app_ids() if compatibility else frozenset()

RESPONSES_METHODS=compatibility.RESPONSES_METHODS if compatibility else frozenset()
CODEX_METHODS=compatibility.CODEX_METHODS if compatibility else frozenset()
RESEARCH_NAME=compatibility.RESEARCH_NAME if compatibility else None
CODEX_RESEARCH_NAME=compatibility.CODEX_RESEARCH_NAME if compatibility else None
RESEARCH_METHODS=RESPONSES_METHODS | CODEX_METHODS
RESEARCH_NAMES=compatibility.RESEARCH_NAMES if compatibility else frozenset()
CAPTURE_NAME=compatibility.CAPTURE_NAME if compatibility else None
CAPTURE_METHODS=compatibility.CAPTURE_METHODS if compatibility else frozenset()
PLANNING_NAME=compatibility.PLANNING_NAME if compatibility else None

def check_planning_admission(admission):
    if compatibility:return compatibility.check_planning_admission(admission)
    raise Fault('planning_review_not_authorized')
