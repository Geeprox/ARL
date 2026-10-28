"""Production composition: metadata only, no task grants, inference or enrollment.

Future product composition is host code, never a caller-selected JSON profile.
The installed entry uses this fixed composition and a fixed account state home.
"""
from __future__ import annotations

import argparse
import fcntl
import json
import os
import pwd
import re
import signal
import stat
import threading
import time
from pathlib import Path

from . import VERSION
from .contracts import AppPolicy, Fault
from .lifecycle import private_home
from .service import Runtime


def account_home():
    return Path(pwd.getpwuid(os.geteuid()).pw_dir)


def state_home():
    return account_home()/"Library/Application Support/ARL"


def metadata_policies():
    return {"settings": AppPolicy(frozenset(), frozenset(), 0, 0, 0,
        methods=frozenset({"health", "ready", "overview", "settings.snapshot", "settings.logs", "settings.logs_export", "settings.logs.v3", "settings.modules_snapshot", "codex.service.status.v1", "settings.app_icon.v1"}), public_metadata=True),
        **{app: AppPolicy(frozenset(), frozenset(), 0, 0, 0, methods=frozenset())
           for app in ("tisra", "friday", "mio")}}


class PeerComposition:
    """Trusted in-process composition; default rejects every task-app identity.

    Approved product host code can supply SignedPeerVerifier and a controlled
    supervisor's peer_verifier. That still requires explicit AppPolicy grants;
    verifier acceptance alone never opens tools. Installed metadata profile
    passes no verifiers and exposes no config/registration RPC or env switch.
    """
    def __init__(self, verifiers=()):
        self.verifiers = tuple(verifiers)

    def __call__(self, connection, app):
        for verifier in self.verifiers:
            try:
                accepted = verifier(connection, app)
            except Exception:
                continue
            if accepted == app:
                return accepted
        return None

    def session_binding(self, connection, app):
        for verifier in self.verifiers:
            if verifier(connection, app) == app:
                binder = getattr(verifier, 'session_binding', None)
                if binder is not None:
                    return binder(connection, app)
        raise Fault('app_identity_unverified')


class MetadataLog:
    """Bounded 64 KiB private log, fixed machine fields, no exception messages."""
    def __init__(self, home):
        self.path = home/"host.log"

    def event(self, event, code=None):
        if event not in {"starting", "ready", "stopped", "disabled", "error"}:
            raise ValueError("unknown_log_event")
        record = {"at": int(time.time()), "event": event, "version": VERSION}
        if code and re.fullmatch(r"[a-z_]{1,80}", code):
            record["code"] = code
        raw = (json.dumps(record, sort_keys=True)+"\n").encode()
        fd = os.open(str(self.path), os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
                raise Fault("unsafe_log")
            fcntl.flock(fd, fcntl.LOCK_EX)
            if os.fstat(fd).st_size + len(raw) > 65536:
                os.ftruncate(fd, 0)
            os.lseek(fd, 0, os.SEEK_END)
            os.write(fd, raw)
        finally:
            os.close(fd)


class CodexCallerPeer:
    """Reuse the existing signed peer and registered kernel-process verifier."""
    def __init__(self, caller, registered, signed):
        from .identity import RegisteredPeerVerifier
        from .supervisor import SignedPeerVerifier
        if (type(registered) is not RegisteredPeerVerifier or type(signed) is not SignedPeerVerifier or
                caller not in registered.app_ids or caller not in signed.requirements):
            raise Fault('codex_caller_unverified')
        self.caller, self.registered, self.signed = caller, registered, signed

    def __call__(self, connection, app):
        if app == self.caller and self.registered(connection, app) == app and self.signed(connection, app) == app:
            return app
        return None

    def session_binding(self, connection, app):
        if self(connection, app) != app:raise Fault('app_identity_unverified')
        a, current_a = self.registered.session_binding(connection, app)
        b, current_b = self.signed.session_binding(connection, app)
        import hashlib
        return hashlib.sha256((a+b).encode()).hexdigest(), lambda: current_a() and current_b()


def compose_codex_service(home, *, service, peer_verifier, isolated=False, service_portal=None, formal_tisra_peer=None):
    """Trusted in-process seam. Production requires both existing peer verifiers.

    No default activation, grant loader or caller-selected configuration. The
    existing native owner supplies the reviewed scope and current parent peer.
    """
    from .codex_server import CodexService
    from .identity import RegisteredPeerVerifier
    if (type(service) is not CodexService or service.runtime is not None or not service.current() or
            (type(peer_verifier) is not CodexCallerPeer and not (
                isolated is True and type(peer_verifier) is RegisteredPeerVerifier)) or
            (isolated is not True and service.adapter.test_command is not None) or
            (isolated is True and Path(home).resolve() == state_home().resolve())):
        raise Fault('codex_service_not_admitted')
    if (type(peer_verifier) is CodexCallerPeer and peer_verifier.caller != service.caller or
            type(peer_verifier) is RegisteredPeerVerifier and service.caller not in peer_verifier.app_ids):
        raise Fault('codex_caller_unverified')
    from .formal_peer import available_formal_tisra_peer, FormalTisraPeer
    if formal_tisra_peer is None and not isolated:
        formal_tisra_peer = available_formal_tisra_peer()
    if formal_tisra_peer is not None and type(formal_tisra_peer) is not FormalTisraPeer:
        raise Fault('app_identity_unverified')
    policies = metadata_policies()
    if formal_tisra_peer is not None:policies['tisra'] = application_metadata_policy()
    if service.caller in policies:raise Fault('codex_caller_conflict')
    policies[service.caller] = AppPolicy(frozenset({service.name}), frozenset(), 0, 1, service.max_calls,
        methods=frozenset({'health','ready','capabilities','submit','get','cancel','heartbeat'}),
        max_deadline_ms=30000)
    runtime = Runtime(home, policies=policies, providers={}, local_enabled=False,
        extra_tools=[service.tool()], identity_verifier=PeerComposition((peer_verifier,) + ((formal_tisra_peer,) if formal_tisra_peer is not None else ())),
        execute_jobs=True, codex_service=service, admission=service.admit,
        work_scope=frozenset({(service.caller, service.name)}), service_portal=service_portal,
        application_catalog=(lambda app: service.status().get('execution_catalog')) if formal_tisra_peer is not None else None)
    service.runtime = runtime
    from .control import AppDescriptor
    runtime.control.apps.register(AppDescriptor(service.caller, 'ARL Codex', 'sf:cpu',
        capabilities=('codex.text.plan.v1',)))
    if formal_tisra_peer is not None:
        runtime.control.apps.register(AppDescriptor('tisra', 'Tisra', 'sf:text.book.closed'))
    return runtime


def application_metadata_policy():
    """Discovery/registration only: zero tools, providers, queue slots or calls."""
    from .application_models import METHODS
    return AppPolicy(frozenset(), frozenset(), 0, 0, 0,
        methods=METHODS | {'health','ready','capabilities','heartbeat'},
        priority_bands=frozenset({'background','explicit','interactive'}))


CODEX_CONFIGURATION = 'codex-service-v1.json'

def _codex_file(path, limit, *, private=False):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        info = os.fstat(fd)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or
                info.st_mode & (0o077 if private else 0o022) or not 1 <= info.st_size <= limit):
            raise Fault('codex_configuration_unsafe')
        raw = os.read(fd, limit + 1)
        if len(raw) != info.st_size:raise Fault('codex_configuration_unsafe')
        return raw
    finally:os.close(fd)


def read_codex_configuration(home):
    """Stable scope data from the existing native owner; no login or grant UI."""
    import hashlib
    from .wire import strict_json
    try:raw = _codex_file(Path(home)/CODEX_CONFIGURATION, 4096, private=True)
    except FileNotFoundError:return None, None
    except OSError:raise Fault('codex_configuration_unsafe') from None
    try:
        value = strict_json(raw)
        fields = {'schema_version','caller','provider','model','reasoning_effort','service_tier',
            'scope_generation','max_calls','max_output_bytes','core_manifest_sha256',
            'caller_requirement','explicit_submission_only'}
        if (type(value) is not dict or set(value) != fields or
                type(value['schema_version']) is not int or value['schema_version'] not in (1, 2) or
                value['caller'] != 'arl-control' or value['provider'] != 'codex_app_server' or
                value['reasoning_effort'] != 'xhigh' or value['service_tier'] != 'default' or
                value['explicit_submission_only'] is not True or
                type(value['model']) is not str or re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._/-]{0,149}',value['model']) is None or
                not (type(value['max_calls']) is int and 1 <= value['max_calls'] <= 1000 or value['schema_version'] == 2 and value['max_calls'] is None) or
                type(value['max_output_bytes']) is not int or not 128 <= value['max_output_bytes'] <= 32768 or
                type(value['core_manifest_sha256']) is not str or re.fullmatch(r'[a-f0-9]{64}',value['core_manifest_sha256']) is None or
                type(value['caller_requirement']) is not str or not 1 <= len(value['caller_requirement']) <= 512 or
                type(value['scope_generation']) is not str):
            raise ValueError('configuration')
        import uuid
        if str(uuid.UUID(value['scope_generation'])) != value['scope_generation']:raise ValueError('generation')
        return value, hashlib.sha256(raw).hexdigest()
    except (ValueError, TypeError, KeyError, Fault):raise Fault('codex_configuration_invalid') from None


def build_codex_activation(home):
    """Consume the owner's fixed scope only inside the existing signed ARL bundle.

    Current upstream binary/version is preflighted, never compared with a stale
    schema hash. The manifest pin below binds our own reviewed packaged code.
    """
    import hashlib
    import plistlib
    import subprocess
    from .codex_server import CodexService, CodexTextAdapter
    from .identity import RegisteredPeerVerifier, process_identity
    from .supervisor import SignedPeerVerifier
    try:
        config, seal = read_codex_configuration(home)
        if config is None:return None, None, 'not_configured'
        code = Path(__file__).resolve().parents[1]
        app = code.parents[3]
        if app.suffix != '.app' or code != app/'Contents/Resources/CoreRuntime/code':
            raise Fault('codex_native_owner_unavailable')
        manifest_path = code.parent/'manifest.json'
        manifest_raw = _codex_file(manifest_path, 1024*1024)
        if hashlib.sha256(manifest_raw).hexdigest() != config['core_manifest_sha256']:
            raise Fault('codex_package_binding_changed')
        manifest = json.loads(manifest_raw)
        helper = code/'build/PeerSignatureHelper'
        helper_pin = manifest['files']['code/build/PeerSignatureHelper']
        if hashlib.sha256(_codex_file(helper, 16*1024*1024)).hexdigest() != helper_pin:
            raise Fault('codex_package_binding_changed')
        info = plistlib.loads(_codex_file(app/'Contents/Info.plist', 1024*1024))
        name = info['CFBundleExecutable']
        if type(name) is not str or re.fullmatch(r'[A-Za-z0-9_.-]{1,100}', name) is None:
            raise Fault('codex_native_owner_unavailable')
        executable = (app/'Contents/MacOS'/name).resolve(strict=True)
        pid = os.getppid()
        identity = process_identity(pid)
        if identity['uid'] != os.geteuid() or identity['executable'] != str(executable):
            raise Fault('codex_native_owner_unavailable')
        verified = subprocess.run(['/usr/bin/codesign','--verify','--strict','--deep',str(app)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5,
            env={'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','LANG':'C','LC_ALL':'C'})
        if verified.returncode != 0:raise Fault('codex_native_signature_unverified')
        registered = RegisteredPeerVerifier({config['caller']})
        registered.register(config['caller'], pid, executable)
        lease = registered.capture_registration(config['caller'], pid)
        signed = SignedPeerVerifier(helper, {config['caller']:config['caller_requirement']})
        def current_scope():
            _, current_seal = read_codex_configuration(home)
            return (current_seal == seal and
                hashlib.sha256(_codex_file(manifest_path,1024*1024)).hexdigest() == config['core_manifest_sha256'] and
                hashlib.sha256(_codex_file(helper,16*1024*1024)).hexdigest() == helper_pin)
        service = CodexService(CodexTextAdapter(enabled=True), caller=config['caller'], model=config['model'],
            reasoning_effort=config['reasoning_effort'], service_tier=config['service_tier'],
            scope_generation=config['scope_generation'], max_calls=config['max_calls'],
            max_output_bytes=config['max_output_bytes'], authorization_current=current_scope, peer_current=lease.is_current,
            allow_model_selection=True)
        return service, CodexCallerPeer(config['caller'], registered, signed), 'configured'
    except Fault as error:return None, None, error.code
    except (OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError):
        return None, None, 'codex_configuration_unavailable'

def make_runtime(home, *, capture_attachment=None, service_portal=None, formal_tisra_peer=None,
                 research_activation=None, codex_service=None, codex_peer=None, codex_isolated=False):
    if codex_service is not None:
        if capture_attachment is not None or research_activation is not None:
            raise Fault('codex_service_composition_conflict')
        return compose_codex_service(home, service=codex_service, peer_verifier=codex_peer,
            isolated=codex_isolated, service_portal=service_portal, formal_tisra_peer=formal_tisra_peer)

    if capture_attachment is not None:
        if service_portal is not None or formal_tisra_peer is not None or research_activation is not None:
            raise Fault('service_portal_composition_conflict')
        from .tisra_capture_host import CaptureHostAttachment
        if type(capture_attachment) is not CaptureHostAttachment:
            raise Fault('capture_host_unconfigured')
        return capture_attachment.make_runtime(home)
    if research_activation is not None:
        if formal_tisra_peer is not None:
            raise Fault('research_host_composition_conflict')
        from .formal_research_host import compose_formal_research
        return compose_formal_research(home, research_activation, service_portal=service_portal)
    # No replay/mutation of historical pending tasks in the metadata-only host.
    policies = metadata_policies()
    if formal_tisra_peer is not None:
        from .formal_peer import FormalTisraPeer
        if type(formal_tisra_peer) is not FormalTisraPeer:raise Fault('app_identity_unverified')
        policies['tisra'] = application_metadata_policy()
    runtime = Runtime(home, policies=policies, local_enabled=False,
                   identity_verifier=PeerComposition((formal_tisra_peer,) if formal_tisra_peer is not None else ()), execute_jobs=False,
                   service_portal=service_portal,
                   # An explicitly empty canonical-source snapshot permits metadata/icon
                   # handshake without a model cache; it never invents rows or
                   # starts a provider to satisfy discovery.
                   application_catalog=(lambda app: {'schema_version':1,
                       'source':'app_server_model_list','selection_enabled':False,
                       'models':[],'current':{}}) if formal_tisra_peer is not None else None)
    if formal_tisra_peer is not None:
        from .control import AppDescriptor
        runtime.control.apps.register(AppDescriptor('tisra', 'Tisra', 'sf:text.book.closed'))
    return runtime


def run(home, *, capture_attachment=None, service_portal=None, formal_tisra_peer=None,
        research_activation=None, codex_service=None, codex_peer=None, codex_isolated=False,
        codex_configuration_state='not_configured'):
    log = None
    runtime = None
    finished = threading.Event()
    try:
        home = private_home(home)
        log = MetadataLog(home)
        runtime = make_runtime(home, capture_attachment=capture_attachment, service_portal=service_portal,
                               formal_tisra_peer=formal_tisra_peer,
                               research_activation=research_activation, codex_service=codex_service,
                               codex_peer=codex_peer, codex_isolated=codex_isolated)
        runtime.codex_configuration_state = codex_configuration_state
        log.event("starting")
        def stop(signum, frame):
            threading.Thread(target=runtime.shutdown, daemon=True).start()
        signal.signal(signal.SIGTERM, stop)
        signal.signal(signal.SIGINT, stop)
        def monitor():
            announced = False
            probing = False
            next_probe = 0.0
            def preflight():
                nonlocal probing, next_probe
                try:
                    if codex_service is not None:
                        codex_service.preflight()
                    elif research_activation.admission.current() and not runtime.stopping.is_set():
                        runtime.priority_producer.probe_native('tisra', research_activation.model)
                        runtime.research_preflight_at = time.monotonic()
                except Exception:
                    pass  # Public status remains model_preflight_pending.
                finally:
                    next_probe = time.monotonic() + 45
                    probing = False
            while not finished.wait(0.2):
                if (home/"disabled").exists():
                    log.event("disabled")
                    runtime.shutdown()
                    return
                if research_activation is not None and not research_activation.admission.current():
                    log.event("disabled", "research_consent_revoked")
                    runtime.shutdown()
                    return
                if runtime.ready.is_set() and not announced:
                    log.event("ready")
                    announced = True
                if (research_activation is not None or codex_service is not None) and runtime.ready.is_set() and not probing and time.monotonic() >= next_probe:
                    if research_activation is not None:
                        try:
                            research_activation.registered_peer.registration_subject('tisra')
                        except Fault:
                            continue
                    probing = True
                    threading.Thread(target=preflight, daemon=True).start()
        watcher = threading.Thread(target=monitor, daemon=True)
        watcher.start()
        runtime.run()
        log.event("stopped")
        return 0
    except Fault as exc:
        if log:
            try: log.event("disabled" if exc.code == "user_disabled" else "error", exc.code)
            except Exception: pass
        # SuccessfulExit=false KeepAlive must not respawn an intentional stop or
        # duplicate owner, including disabled encountered at the next login.
        return 0 if exc.code in {"user_disabled", "already_running"} else 1
    except Exception:
        if log:
            try: log.event("error", "host_startup_failed")
            except Exception: pass
        return 1  # Never print a traceback, argv, environment or handler message.
    finally:
        finished.set()
        if capture_attachment is not None:
            capture_attachment.close()


def main():
    parser = argparse.ArgumentParser(description="ARL local production host")
    parser.add_argument("--isolated-test", action="store_true")
    parser.add_argument("--home", type=Path)
    args = parser.parse_args()
    if args.home is not None and not args.isolated_test:
        parser.error("home override requires an explicit isolated test")
    home = args.home if args.isolated_test and args.home is not None else state_home()
    codex_service, codex_peer, codex_state = build_codex_activation(home)
    if codex_state != 'not_configured':
        # An invalid independent scope never falls back to a different caller.
        return run(home, codex_service=codex_service, codex_peer=codex_peer,
                   codex_configuration_state=codex_state)
    from .tisra_capture_profiles import attachment_for_profiles
    from .formal_peer import available_formal_tisra_peer
    from .research_product import build_activation
    capture_attachment = attachment_for_profiles()
    if not capture_attachment.enabled:
        capture_attachment = None
    home = args.home if args.isolated_test and args.home is not None else state_home()
    activation, _ = build_activation(home) if capture_attachment is None else (None, 'capture_profile_active')
    return run(home,
               capture_attachment=capture_attachment,
               formal_tisra_peer=available_formal_tisra_peer() if capture_attachment is None and activation is None else None,
               research_activation=activation)


if __name__ == "__main__":
    raise SystemExit(main())
