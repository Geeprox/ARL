"""Product-owned, time-limited Tisra Research approval for the production host.

No approval is shipped. The file is a local user action, not an RPC or environment
switch. Reading it neither contacts Codex nor registers a process.
"""
from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
import time
import uuid

from .codex_server import CodexTextAdapter, DEFAULT_BINARY
from .codex_sourced_research import NAME
from .contracts import Fault
from .formal_peer import available_formal_tisra_peer
from .formal_research_host import FormalResearchActivation
from .identity import RegisteredPeerVerifier
from .priority import AppProfilePolicy, ResourcePolicy, TaskPolicy
from .priority_host import PriorityHostConfig

FILENAME = 'tisra-research-consent-v1.json'
TTL_MS = 3_600_000
FIELDS = frozenset({'schema_version', 'subject', 'tool', 'task_kind', 'provider',
                    'model', 'consent_id', 'issued_at_ms', 'expires_at_ms',
                    'explicit_tisra_submission_only', 'no_cost_hard_cap_accepted'})


@dataclass(frozen=True)
class ResearchConsent:
    model: str
    consent_id: str
    issued_at_ms: int
    expires_at_ms: int
    sha256: str

    def current(self, home, *, now_ms=None):
        consent, state = read_consent(home, now_ms=now_ms)
        return state == 'approved' and consent == self


def _unique_pairs(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError('duplicate key')
        value[key] = item
    return value


def read_consent(home, *, now_ms=None):
    """Return a narrow public state; malformed or unsafe files grant nothing."""
    path = Path(home) / FILENAME
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except FileNotFoundError:
        return None, 'needs_user_authorization'
    except OSError:
        return None, 'consent_unreadable'
    try:
        info = os.fstat(fd)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or
                info.st_mode & 0o077 or not 1 <= info.st_size <= 4096):
            return None, 'consent_unsafe'
        raw = os.read(fd, 4097)
        if len(raw) != info.st_size:
            return None, 'consent_unsafe'
    finally:
        os.close(fd)
    try:
        value = json.loads(raw, object_pairs_hook=_unique_pairs)
        if type(value) is not dict or set(value) != FIELDS:
            raise ValueError('fields')
        if (type(value['schema_version']) is not int or value['schema_version'] != 1 or
                value['subject'] != 'tisra' or value['tool'] != NAME or
                value['task_kind'] != 'model.inference' or
                value['provider'] != 'codex_app_server' or
                value['explicit_tisra_submission_only'] is not True or
                value['no_cost_hard_cap_accepted'] is not True):
            raise ValueError('scope')
        model = value['model']
        if type(model) is not str or re.fullmatch(r'[A-Za-z0-9._/-]{1,150}', model) is None:
            raise ValueError('model')
        identifier = value['consent_id']
        if type(identifier) is not str or str(uuid.UUID(identifier)) != identifier:
            raise ValueError('id')
        issued, expires = value['issued_at_ms'], value['expires_at_ms']
        if (type(issued) is not int or type(expires) is not int or
                not 0 < issued < expires <= issued + TTL_MS):
            raise ValueError('ttl')
        now = int(time.time() * 1000) if now_ms is None else now_ms
        if type(now) is not int:
            raise ValueError('time')
        if now < issued:
            return None, 'consent_not_yet_valid'
        if now >= expires:
            return None, 'consent_expired'
        return ResearchConsent(model, identifier, issued, expires,
                               hashlib.sha256(raw).hexdigest()), 'approved'
    except (UnicodeError, ValueError, KeyError, TypeError, OverflowError):
        return None, 'consent_invalid'


class ResearchAdmission:
    """Recheck the exact grant on every publication and external execution."""
    def __init__(self, home, consent):
        self.home, self.consent = Path(home), consent

    def current(self):
        return self.consent.current(self.home)

    def __call__(self, owner, tool, args):
        if not self.current():
            raise Fault('research_review_not_authorized')
        selected = None
        if type(args) is dict and args.get('schema_version') == 2:
            from .codex_execution_contract import options
            try:selected = options(args.get('execution_options'))
            except Fault:raise Fault('research_review_not_authorized') from None
        if (owner != 'tisra' or tool != NAME or type(args) is not dict or
                args.get('provider') != 'codex_app_server' or
                args.get('model') != self.consent.model or
                (selected is not None and selected['priority'] != args.get('priority')) or
                (args.get('priority') != 'explicit' and not (
                    selected is not None and selected['priority'] == args.get('priority') and
                    type(args.get('priority')) is str and args['priority'] in {'background', 'interactive'})) or
                args.get('max_output_tokens', object()) is not None or
                type(args.get('max_output_bytes')) is not int or
                not 128 <= args['max_output_bytes'] <= 32768 or
                type(args.get('deadline_ms')) is not int or
                not 1 <= args['deadline_ms'] <= 30000 or
                type(args.get('request')) is not dict or
                type(args['request'].get('byte_count')) is not int or
                not 1 <= args['request']['byte_count'] <= 8192 or
                type(args.get('descriptor')) is not dict or
                type(args['descriptor'].get('byte_count')) is not int or
                not 1 <= args['descriptor']['byte_count'] <= 32768):
            raise Fault('research_review_not_authorized')


def build_activation(home):
    """Production entry consumer: return activation only after a current grant."""
    consent, state = read_consent(home)
    if consent is None:
        return None, state
    peer = available_formal_tisra_peer()
    if peer is None:
        return None, 'pinned_tisra_unavailable'
    try:
        adapter = CodexTextAdapter(DEFAULT_BINARY, enabled=True)
        registry = RegisteredPeerVerifier({'tisra'})
        priority = PriorityHostConfig(
            (ResourcePolicy('model', slots=1, realtime_reserved=0,
                            background_start_limit_ms=30000),),
            (TaskPolicy(NAME, 'model.inference', 'model',
                        owners=frozenset({'tisra'}), maximum_class='interactive',
                        estimate_floor_ms=100, execution_budget_ms=25000),),
            {'tisra': AppProfilePolicy(frozenset({'background', 'interactive'}),
                                       max_deadline_ms=30000)}, 60000)
        return FormalResearchActivation(peer, registry, adapter, consent.model,
             consent.consent_id, priority, ResearchAdmission(home, consent),
             consent.consent_id), 'awaiting_tisra_connection'
    except (OSError, Fault, ValueError):
        return None, 'codex_binary_unavailable'


def status(home, *, fallback=None):
    _, state = read_consent(home)
    if state == 'approved':
        state = fallback or 'host_restart_required'
    actions = {
        'needs_user_authorization': 'Review the Tisra Research scope and grant one hour of access to the existing Codex account, then restart ARL.',
        'host_restart_required': 'Restart ARL to consume this approval, then open Tisra.',
        'awaiting_tisra_connection': 'Open the exact installed Tisra app to establish its signed local connection.',
        'pinned_tisra_unavailable': 'Restore the exact reviewed Tisra app and signature helper before restarting ARL.',
        'codex_binary_unavailable': 'Restore the exact installed Codex CLI before restarting ARL.',
        'capture_profile_active': 'Use a reviewed product composition for both profiles before enabling Research.',
        'consent_expired': 'Review the scope and issue a fresh one-hour approval.',
        'consent_not_yet_valid': 'Check the system clock, then issue a fresh approval.',
        'consent_unsafe': 'Remove the unsafe approval file and issue a fresh one.',
        'consent_unreadable': 'Remove the unreadable approval file and issue a fresh one.',
        'consent_invalid': 'Remove the invalid approval file and issue a fresh one.',
    }
    return {'state': state, 'action': actions.get(state, 'Review the Research configuration.')}


def grant(home, model, *, confirmed=False, now_ms=None):
    """One explicit local operation; never called by the production host."""
    if not confirmed or type(model) is not str or re.fullmatch(r'[A-Za-z0-9._/-]{1,150}', model) is None:
        raise Fault('research_consent_not_confirmed')
    now = int(time.time() * 1000) if now_ms is None else now_ms
    if type(now) is not int or now <= 0:
        raise Fault('research_consent_invalid')
    value = {'schema_version': 1, 'subject': 'tisra', 'tool': NAME,
             'task_kind': 'model.inference', 'provider': 'codex_app_server',
             'model': model, 'consent_id': str(uuid.uuid4()),
             'issued_at_ms': now, 'expires_at_ms': now + TTL_MS,
             'explicit_tisra_submission_only': True,
             'no_cost_hard_cap_accepted': True}
    raw = (json.dumps(value, sort_keys=True, separators=(',', ':')) + '\n').encode()
    path = Path(home) / FILENAME
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    except FileExistsError:
        raise Fault('research_consent_exists') from None
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(raw)
            stream.flush()
            os.fsync(stream.fileno())
    except BaseException:
        path.unlink(missing_ok=True)
        raise
    return value['expires_at_ms']


def revoke(home):
    """Delete only this approval. The running host observes removal and stops."""
    (Path(home) / FILENAME).unlink(missing_ok=True)


def main(argv=None):
    import argparse
    from .host import state_home
    from .lifecycle import private_home
    parser = argparse.ArgumentParser(description='Local Tisra Research authorization')
    parser.add_argument('command', choices=('status', 'grant', 'revoke'))
    parser.add_argument('--model', help='Exact existing Codex model for grant')
    args = parser.parse_args(argv)
    home = private_home(state_home())
    if args.command == 'status':
        from .client import Client
        activation, fallback = build_activation(home)
        visible = status(home, fallback='host_restart_required' if activation is not None else fallback)
        if activation is not None:
            try:
                snapshot = Client(home, 'settings').rpc('settings.snapshot')
                apps = snapshot.get('apps', ())
                app = next((row for row in apps if type(row) is dict and row.get('id') == 'tisra'), {})
                if (snapshot.get('runtime', {}).get('task_execution_enabled') is True and
                        NAME in app.get('authorized_tools', ())):
                    visible = {'state': 'awaiting_tisra_connection' if app.get('authentication') != 'verified' else 'host_composed',
                               'action': 'Open Tisra and run its typed model/route preflight before explicit submission.'}
            except (Fault, KeyError, TypeError, ValueError):
                pass
        print(json.dumps(visible, sort_keys=True))
        return 0
    if args.command == 'revoke':
        revoke(home)
        print(json.dumps({'state': 'revoked', 'action': 'ARL will stop the Research host.'}))
        return 0
    if args.model is None:
        parser.error('--model is required for grant')
    print('Authorize Tisra only: explicitly submitted Research text and selected source excerpts may be sent to the existing Codex account for one hour. One provider turn per request; 8 KiB input, 32 KiB generated text, 256 KiB envelope, 30 seconds. No token or cost hard cap. Delete consent to revoke future work. Type AUTHORIZE TISRA RESEARCH to continue:', file=sys.stderr)
    if sys.stdin.readline().strip() != 'AUTHORIZE TISRA RESEARCH':
        print(json.dumps({'state': 'not_granted'}))
        return 1
    try:
        expires = grant(home, args.model, confirmed=True)
    except Fault as exc:
        print(json.dumps({'error': exc.code}), file=sys.stderr)
        return 1
    print(json.dumps({'state': 'approved', 'expires_at_ms': expires,
                      'action': 'Restart ARL and open Tisra; the model check remains pending.'}))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
