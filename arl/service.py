from __future__ import annotations

import json
import os
import socket
import socketserver
import threading
import time

from . import PROTOCOL, VERSION
from .capabilities import AppleAdapter, build_tools
from .contracts import AppPolicy, Cancelled, Fault, encode, object_schema, string, validate
from .control import ControlPlane
from .app_connections import AppConnections, METHODS as CONNECTION_METHODS
from .application_models import ApplicationModels, METHODS as APPLICATION_METHODS
from .diagnostics import CODES, log_schema, log_v3_schema
from .lifecycle import InstanceLock, peer_uid, private_home
from .overview import overview
from .runtime_description import RuntimeDescription
from .modules import MioMetadata
from .providers import Router
from .storage import Store
from . import priority as priorities
from .travel import TravelAdapter
from .wake import WakeRegistry
from .extension_contracts import (default_policies, RESPONSES_METHODS, CODEX_METHODS,
    RESEARCH_NAME, CODEX_RESEARCH_NAME, RESEARCH_METHODS, RESEARCH_NAMES,
    CAPTURE_NAME, CAPTURE_METHODS, PLANNING_NAME, check_planning_admission)
from .service_deployment.portal import ServicePortal, METHODS as SERVICE_PORTAL_METHODS

MAX_FRAME = 16384
METHODS = {
    "runtime.describe": object_schema(), "health": object_schema(), "ready": object_schema(), "capabilities": object_schema(),
    "providers": object_schema(), "overview": object_schema(), "codex.service.status.v1": object_schema(),
    "settings.modules_snapshot": object_schema(), "settings.snapshot": object_schema(),
    "settings.app_icon.v1": object_schema({"app_id":string(64), "sha256":string(64)}, ["app_id","sha256"]), "settings.logs": log_schema(),
    "settings.logs_export": log_schema(export=True), "settings.logs.v3": log_v3_schema(), "heartbeat": object_schema(),
    "submit": object_schema({"tool": string(100), "args": {"type": "object", "properties": {}},
                              "key": string(128)}, ["tool", "args", "key"]),
    "submit_scheduled": object_schema(),
    "get": object_schema({"id": string(40)}, ["id"]),
    "cancel": object_schema({"id": string(40)}, ["id"]),
    "resume": object_schema({"id": string(40)}, ["id"]),
    "wake": object_schema({"target": string(64)}, ["target"]),
    "poll_wakes": object_schema(), "stop": object_schema(),
}
METHODS.update(SERVICE_PORTAL_METHODS)
METHODS.update({m:object_schema() for m in CONNECTION_METHODS | APPLICATION_METHODS})




class JobContext:
    def __init__(self, runtime, row):
        self.runtime, self.row = runtime, row
        self.owner = row["owner"]
        route = runtime.codex_service
        if route is not None and row["tool"] == route.name:
            self.native_observer = lambda event, **fields: route.observe(row["id"], event, **fields)
        self.deadline = time.monotonic()+max(0,row["deadline_at"]-time.time()) if row.get("deadline_at") is not None else None
        if row.get('schedule_v1'):
            with runtime.store.lock:
                lease=runtime.store.db.execute('SELECT expected_return_ms FROM resource_leases WHERE job=? AND attempt=?',
                    (row['id'],row['attempts'])).fetchone()
            if lease is not None:
                bounded=time.monotonic()+max(0,lease[0]/1000-time.time())
                self.deadline=bounded if self.deadline is None else min(self.deadline,bounded)

    def check_cancelled(self):
        priorities.check_running(self.runtime.store,self.row)
        route = self.runtime.codex_service
        if route is not None and self.row["tool"] == route.name:
            route.admit(self.owner, self.row["tool"], json.loads(self.row["args"]))
        if self.row['tool']==PLANNING_NAME and self.runtime.admission is not None:
            self.runtime.admission(self.owner,self.row['tool'],json.loads(self.row['args']))
        if self.runtime.stopping.is_set() or self.runtime.store.is_cancelled(self.row["id"]):
            raise Cancelled()
        if self.deadline is not None and time.monotonic() >= self.deadline:
            raise Fault("deadline_exceeded")

    def remaining(self,maximum=60):
        self.check_cancelled()
        return min(maximum,max(0.001,self.deadline-time.monotonic())) if self.deadline is not None else maximum


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = False
    block_on_close = True

    def __init__(self, *args, **kwargs):
        self.admission = threading.BoundedSemaphore(32)
        super().__init__(*args, **kwargs)

    def process_request(self, request, client_address):
        if not self.admission.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except BaseException:
            self.admission.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.admission.release()


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        self.request.settimeout(5)
        runtime = self.server.runtime
        try:
            if peer_uid(self.request) != os.geteuid():
                raise Fault("peer_not_authorized")
            deadline, raw = time.monotonic()+5, bytearray()
            while b"\n" not in raw:
                remaining = deadline-time.monotonic()
                if remaining <= 0:
                    raise Fault("rpc_deadline_exceeded")
                self.request.settimeout(remaining)
                chunk = self.request.recv(min(4096, MAX_FRAME+1-len(raw)))
                if not chunk:
                    raise Fault("invalid_frame")
                raw.extend(chunk)
                if len(raw) > MAX_FRAME:
                    raise Fault("invalid_frame")
            if not raw.endswith(b"\n") or raw.count(b"\n") != 1:
                raise Fault("invalid_frame")
            request = json.loads(raw)
            if type(request) is dict and request.get('method') in set(SERVICE_PORTAL_METHODS) | CONNECTION_METHODS | APPLICATION_METHODS | {'settings.app_icon.v1'}:
                from .service_deployment.validation import strict_json as service_portal_json
                request = service_portal_json(bytes(raw))
            if type(request) is dict and request.get('method') in RESEARCH_METHODS | CAPTURE_METHODS:
                from .wire import strict_json
                request = strict_json(bytes(raw))
            runtime = self.server.runtime
            verified = runtime.identity_verifier(self.request, request.get("app")) if runtime.identity_verifier and type(request) is dict else None
            binding = None
            if verified is not None and request.get('method') in CONNECTION_METHODS | APPLICATION_METHODS:
                binder = getattr(runtime.identity_verifier, 'session_binding', None)
                if binder is None: raise Fault('app_identity_unverified')
                binding = binder(self.request, verified)
            result = runtime.dispatch(request, verified_app=verified, peer_binding=binding)
            response = {"protocol": PROTOCOL, "ok": True, "result": result}
        except Fault as exc:
            response = {"protocol": PROTOCOL, "ok": False, "error": {"code": exc.code}}
        except socket.timeout:
            response = {"protocol": PROTOCOL, "ok": False, "error": {"code": "rpc_deadline_exceeded"}}
        except (ValueError, TypeError, KeyError):
            response = {"protocol": PROTOCOL, "ok": False, "error": {"code": "invalid_request"}}
        except Exception:
            response = {"protocol": PROTOCOL, "ok": False, "error": {"code": "internal_error"}}
        if response.get('ok') is False:
            code = response['error']['code']
            code = ('identity_unverified' if code in {'app_identity_unverified','peer_not_authorized'} else
                    'invalid_request' if code in {'invalid_frame','rpc_deadline_exceeded','unsupported_protocol'} else
                    'invalid_arguments' if code in {'invalid_cursor','log_session_changed'} else code if code in CODES else 'internal_error')
            runtime.control.diagnostics.emit('rpc_rejected',code=code,level='warning')
        try:
            encoded = encode(response)+b"\n"
            # Research frames include the envelope in their 64KiB limit. Legacy
            # settings snapshots keep their existing transport behavior.
            if isinstance(locals().get('request'), dict) and request.get('method') in RESEARCH_METHODS and len(encoded) > 65536:
                encoded = encode({'protocol':PROTOCOL,'ok':False,'error':{'code':'response_frame_too_large'}})+b'\n'
            if isinstance(locals().get('request'), dict) and request.get('method') in CAPTURE_METHODS | APPLICATION_METHODS | {'settings.app_icon.v1'} and len(encoded) > MAX_FRAME:
                encoded = encode({'protocol':PROTOCOL,'ok':False,'error':{'code':'response_frame_too_large'}})+b'\n'
            self.wfile.write(encoded)
        except OSError:
            pass  # A response lost to disconnect can be recovered using the original key.


class Runtime:
    def __init__(self, home, *, start_delay=0, local_enabled=False, policies=None,
                 extra_tools=(), apple=None, travel=None, wake_callbacks=None, providers=None,
                 identity_verifier=None, shutdown_grace=35, execute_jobs=True, resources=None, modules=None, admission=None, research=None, codex_research=None, capture=None, host_attachment=None, service_portal=None, priority_authority=None, codex_service=None, work_scope=None, application_catalog=None):
        self.home = private_home(home)
        Store._scope_clause(work_scope)
        self.work_scope = work_scope
        self.codex_service = codex_service
        self.start_delay = start_delay
        self.description = RuntimeDescription()
        self.local_enabled = local_enabled
        if service_portal is not None and type(service_portal) is not ServicePortal:
            raise Fault('invalid_service_portal_composition')
        self.service_portal = service_portal if service_portal is not None else ServicePortal()
        self.policies = self.service_portal.policies(policies or default_policies(local_enabled))
        self.router = Router(self.policies, local_enabled, providers)
        self.apple = apple or AppleAdapter()
        self.tools = build_tools(self.router, self.apple, travel or TravelAdapter())
        self.tools.update({t.name: t for t in extra_tools})
        self.research = research
        self.codex_research_name = codex_research.name if codex_research is not None else CODEX_RESEARCH_NAME
        self.research_engines = {engine.name: engine for engine in (research, codex_research) if engine is not None}
        for engine in self.research_engines.values():
            self.tools[engine.name] = engine.tool
        self.capture = capture
        self.host_attachment = host_attachment
        if capture is not None:
            capture.bind_runtime(self)
            self.tools[capture.name] = capture.tool
        self.wake_callbacks = wake_callbacks
        self.stopping = threading.Event()
        self.ready = threading.Event()
        self.job_signal = threading.Event()
        self.server = self.store = self.instance = None
        self.worker = None
        self.workers = []
        if priority_authority is not None and type(priority_authority) is not priorities.PriorityAuthority:
            raise Fault('priority_invalid_host_policy')
        self.priority_authority=priority_authority
        self.priority_producer=None
        self.closed = threading.Event()
        # No insecure fallback: production composition must install a peer verifier.
        # A verified identity is passed by Handler, never taken from JSON.
        self.identity_verifier = identity_verifier
        self.shutdown_grace = shutdown_grace
        self.execute_jobs = execute_jobs
        self.admission = admission
        self.control = ControlPlane(self,resources=resources)
        self.app_connections = AppConnections(self.control.apps)
        if application_catalog is not None and not callable(application_catalog):
            raise Fault("invalid_application_models_composition")
        self.application_models = (ApplicationModels(self.control.apps, self.policies, application_catalog)
                                   if application_catalog is not None else None)
        self.service_portal.bind_runtime(self)
        self.modules = modules if modules is not None else MioMetadata()

    @property
    def admission(self):
        return self._admission

    @admission.setter
    def admission(self, value):
        # Host review replacement and Store publication share the Store lock.
        # Publication holds it through commit, so the current check cannot
        # race a different review into force before the result is durable.
        store=getattr(self,'store',None)
        if store is None:self._admission=value
        else:
            with store.lock:self._admission=value

    def bind_priority(self):
        if self.priority_authority is not None:
            if self.identity_verifier is None:raise Fault('app_identity_unverified')
            self.priority_authority.bind(self.store,self.policies)

    def sensitive(self, tool):
        return tool.requires_identity

    def check_publication_admission(self, owner, tool, args):
        """Check the current host review inside Store's publication transaction."""
        admission=self.admission
        if tool==PLANNING_NAME:
            # A removed/replaced admission must not let a completed old review
            # publish through the object that existed when Store was created.
            check_planning_admission(admission)
        if admission is not None:
            admission(owner,tool,args)

    def dispatch(self, request, verified_app=None, peer_binding=None):
        if type(request) is not dict or set(request) != {"protocol", "app", "method", "params"}:
            raise Fault("invalid_request")
        if request["protocol"] != PROTOCOL:
            raise Fault("unsupported_protocol")
        owner, method, params = request["app"], request["method"], request["params"]
        if type(owner) is not str:
            raise Fault("unknown_app")
        unknown_profile_app=(owner not in self.policies and method in {'priority.negotiate.v1','priority.negotiate.v2'}
                             and verified_app==owner and self.identity_verifier is not None and self.priority_authority is not None)
        if owner not in self.policies and not unknown_profile_app:raise Fault('unknown_app')
        if type(method) is not str or method not in METHODS and method not in RESEARCH_METHODS and method not in CAPTURE_METHODS and method not in priorities.METHODS:
            raise Fault("unknown_method")
        if method in CAPTURE_METHODS and self.capture is None:
            raise Fault('unknown_method')
        policy = self.policies[owner] if not unknown_profile_app else AppPolicy(frozenset(),methods=frozenset({'priority.negotiate.v1','priority.negotiate.v2'}))
        # Explicit public metadata exception, never an identity grant. Even a host
        # policy cannot use this flag to exempt arbitrary tools or task methods.
        public_read = (owner == "settings" and policy.public_metadata and
                       method in {"runtime.describe", "health", "ready", "overview", "settings.snapshot", "settings.logs", "settings.logs_export", "settings.logs.v3", "settings.modules_snapshot", "codex.service.status.v1", "settings.app_icon.v1", *SERVICE_PORTAL_METHODS} and verified_app is None)
        if self.identity_verifier is not None and verified_app != owner and not public_read:
            raise Fault("app_identity_unverified")
        priority_allowed=(method in {'priority.negotiate.v1','priority.negotiate.v2'} or method=='priority.submit.v1' and 'submit' in policy.methods)
        connection_allowed = method in CONNECTION_METHODS and 'heartbeat' in policy.methods
        describe_allowed = method == 'runtime.describe' and 'health' in policy.methods
        if method not in policy.methods and not connection_allowed and not describe_allowed and not (self.priority_authority is not None and priority_allowed):
            raise Fault("method_not_authorized")
        if method in CONNECTION_METHODS:
            if verified_app != owner or self.identity_verifier is None:
                raise Fault('app_identity_unverified')
            return self.app_connections.dispatch(owner, method, params, peer_binding, policy)
        if method in APPLICATION_METHODS:
            if verified_app != owner or self.identity_verifier is None or peer_binding is None:
                raise Fault('app_identity_unverified')
            if self.application_models is None:
                raise Fault('application_models_not_configured')
            return self.application_models.dispatch(owner, method, params, peer_binding)
        if method in priorities.METHODS:
            if verified_app!=owner or self.identity_verifier is None:raise Fault('app_identity_unverified')
            if self.priority_authority is None or self.store is None:raise Fault('priority_not_configured')
            if type(params) is not dict:raise Fault('priority_invalid_arguments')
            if method in {'priority.negotiate.v1','priority.negotiate.v2'}:
                if set(params)!={'requested_profile'}:raise Fault('priority_invalid_arguments')
                with self.store.lock:
                    negotiate=self.priority_authority.negotiate_v2 if method=='priority.negotiate.v2' else self.priority_authority.negotiate
                    return negotiate(owner,verified_app,params['requested_profile'])
            if set(params)!={'tool','args','key','scheduling'}:raise Fault('priority_invalid_arguments')
            priorities.validate_request(params['scheduling'])
            validate(params['tool'],string(100));validate(params['key'],string(128))
            if type(params['args']) is not dict:raise Fault('invalid_arguments')
        elif method in CAPTURE_METHODS:
            if verified_app != owner:
                raise Fault('app_identity_unverified')
            if type(params) is not dict:
                raise Fault('capture_invalid_arguments')
        elif method in RESEARCH_METHODS:
            research_engine = self.research_engines.get(self.codex_research_name if method in CODEX_METHODS else RESEARCH_NAME)
            if research_engine is None:
                raise Fault('unknown_method')
            if verified_app != owner:
                raise Fault('app_identity_unverified')
            if type(params) is not dict:
                raise Fault('invalid_arguments')
        elif method in {"submit","submit_scheduled"}:
            if method=="submit_scheduled" and verified_app!=owner:raise Fault("app_identity_unverified")
            expected={"tool","args","key","priority","deadline_ms"} if method=="submit_scheduled" else {"tool","args","key"}
            if type(params) is not dict or set(params) != expected:
                raise Fault("invalid_arguments")
            validate(params["tool"], string(100))
            validate(params["key"], string(128))
            if type(params["args"]) is not dict:
                raise Fault("invalid_arguments")
        else:
            validate(params, METHODS[method])
        if method == 'heartbeat':
            if verified_app != owner:
                raise Fault('app_identity_unverified')
            if not self.control.apps.observe_verified(owner):
                raise Fault('method_not_authorized')
            return {'schema_version':2,'accepted':True,'checked_at_ms':self.control.clock(),'stale_after_ms':30000}
        if verified_app == owner:
            self.control.apps.observe_verified(owner)
        if method in SERVICE_PORTAL_METHODS:
            if owner != 'settings':
                raise Fault('method_not_authorized')
            return self.service_portal.dispatch(method, params)
        if method == 'settings.modules_snapshot':
            return self.modules.snapshot()
        if method == 'settings.snapshot':
            return self.control.snapshot()
        if method == 'settings.app_icon.v1':
            if owner != 'settings':raise Fault('method_not_authorized')
            if self.application_models is None:raise Fault('application_icon_unavailable')
            return self.application_models.read_icon(params['app_id'], params['sha256'])
        if method in {'settings.logs','settings.logs_export'}:
            return self.control.diagnostics.query(params,export=method == 'settings.logs_export')
        if method == 'settings.logs.v3':
            return self.control.diagnostics.query_v3(params)
        if method == "runtime.describe":
            return self.description.snapshot(self.ready.is_set() and not self.stopping.is_set(),
                application_models=self.application_models is not None)
        if method == "health":
            return {"live": not self.stopping.is_set(), "ready": self.ready.is_set(),
                    "version": VERSION, "pid": os.getpid(), "ui_required": False}
        if method == "ready":
            if not self.ready.is_set():
                raise Fault("not_ready")
            return {"ready": True, "version": VERSION}
        if method == "overview":
            return overview(self)
        if method == "codex.service.status.v1":
            return self.codex_service.status() if self.codex_service is not None else {"schema_version": 1, "state": "not_configured",
                "reason": getattr(self, "codex_configuration_state", "not_configured")}
        if method == "stop":
            # Stop wins even while the service is initializing.
            fd = os.open(str(self.home/"disabled"), os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600)
            try:
                os.fsync(fd)
            finally:
                os.close(fd)
            self.stopping.set()
            self.job_signal.set()
            threading.Thread(target=self.server.shutdown, daemon=True).start()
            return {"disabled": True, "bootstrap_allowed": False}
        if not self.ready.is_set() or self.stopping.is_set():
            raise Fault("not_ready")
        if method in CAPTURE_METHODS:
            result = self.capture.dispatch(owner, method, params, policy, verified_app=verified_app)
            self.job_signal.set()
            return result
        if method in RESEARCH_METHODS:
            result = research_engine.dispatch(owner, method, params, policy)
            self.job_signal.set()
            return result
        if method == "capabilities":
            descriptors=[t.descriptor() for t in self.tools.values() if t.name in self.policies[owner].tools]
            if self.priority_producer is not None:
                for descriptor in descriptors:
                    if self.priority_producer.planner_required(owner,descriptor['name']):
                        descriptor['priority_required']=True
            return {"version": 1, "protocol": PROTOCOL, "tools": descriptors, "local_inference_enabled": self.local_enabled,
                    "identity_boundary": "registered_kernel_peer" if self.identity_verifier else "same_os_uid; app IDs are local client declarations"}
        if method == "providers":
            return self.router.discover()
        if method in {"submit","submit_scheduled","priority.submit.v1"}:
            name = params["tool"]
            if name in RESEARCH_NAMES:
                raise Fault('typed_research_method_required')
            if name == CAPTURE_NAME:
                raise Fault('typed_capture_method_required')
            if name not in self.tools:
                raise Fault("unknown_tool")
            if name not in self.policies[owner].tools:
                raise Fault("tool_not_authorized")
            tool = self.tools[name]
            if self.sensitive(tool) and verified_app != owner:
                raise Fault("app_identity_unverified")
            validate(params["args"], tool.schema)
            if name == "apple.calendar.create.v1":
                from .calendar_write import checked
                checked(params["args"])
                if params["key"] != params["args"]["operation_id"]:
                    raise Fault("operation_key_mismatch")
            if name == "model.complete":
                self.router.check(owner, params["args"])
            if self.admission is not None:
                self.admission(owner, name, params["args"])
            if self.priority_producer is not None and name in {'model.complete',PLANNING_NAME}:
                if method=='submit_scheduled' or method=='submit' and name==PLANNING_NAME and self.priority_producer.planner_required(owner,name):
                    raise Fault('priority_route_binding_unavailable')
                if method=='priority.submit.v1' and params['scheduling']['profile_id'] not in self.priority_authority.issued_bindings:
                    raise Fault('priority_route_binding_unavailable')
            route=None
            if method=='priority.submit.v1':
                args=params['args']
                if name=='model.complete':
                    route=priorities.RouteContext(method,args['provider'],args['model'])
                elif name==PLANNING_NAME:
                    route=priorities.RouteContext(method,'codex_app_server',args['model'])
                else:
                    route=priorities.RouteContext(method)
            if method=='submit' and name=='model.complete' and self.priority_producer is not None:
                # Serialize the host-generated deadline, existing-key lookup and
                # durable submit. The caller supplied only its original args/key.
                with self.store.lock:
                    request,route=self.priority_producer.auto_generic_request(owner,params['args'],params['key'])
                    job=self.store.submit(owner,params['key'],tool,params['args'],self.policies[owner],
                        verified=verified_app==owner,priority_request=request,priority_route=route)
            else:
                job = self.store.submit(owner, params["key"], tool, params["args"], self.policies[owner], verified=verified_app == owner,
                    schedule={"priority":params["priority"],"deadline_ms":params["deadline_ms"]} if method=="submit_scheduled" else None,
                    priority_request=params.get('scheduling'),priority_route=route)
            self.job_signal.set()
            return job
        if method in {"get", "cancel", "resume"}:
            current = self.store.access_metadata(owner, params["id"])
            if current['tool'] in RESEARCH_NAMES:
                raise Fault('typed_research_method_required')
            if current['tool'] == CAPTURE_NAME:
                raise Fault('typed_capture_method_required')
            tool = self.tools.get(current["tool"])
            if (current["requires_identity"] or not current["tool_contract"] or tool is None or self.sensitive(tool)) and verified_app != owner:
                raise Fault("app_identity_unverified")
            result = getattr(self.store, method)(owner, params["id"])
            if self.codex_service is not None and current["tool"] == self.codex_service.name:
                result["progress"] = self.codex_service.progress(result)
            self.job_signal.set()
            return result
        if method == "wake":
            return self.wakes.wake(owner, params["target"])
        if method == "poll_wakes":
            return self.store.poll_wakes(owner)

    def work(self):
        while not self.stopping.is_set():
            row = self.store.claim(scope=self.work_scope) if self.work_scope is not None else self.store.claim()
            if not row:
                self.job_signal.wait(0.1)
                self.job_signal.clear()
                continue
            tool = self.tools.get(row["tool"])
            research_engine = (self.capture if self.capture is not None and row['tool'] == CAPTURE_NAME
                               else self.research_engines.get(row["tool"]))
            started = False
            replayable = bool(tool and row["idempotent"] and tool.idempotent and
                              row["tool_contract"] == tool.contract_digest())
            try:
                # Recheck restored work against current capability and model policy.
                if tool is None or tool.name not in self.policies[row["owner"]].tools:
                    raise Fault("tool_not_authorized")
                if row["tool_contract"] != tool.contract_digest():
                    raise Fault("tool_contract_changed")
                if (row["requires_identity"] or self.sensitive(tool)) and (
                        self.identity_verifier is None or not row["identity_authorized"]):
                    raise Fault("app_identity_unverified")
                args = json.loads(row["args"])
                validate(args, tool.schema)
                if self.admission is not None:
                    self.admission(row["owner"], row["tool"], args)
                context = JobContext(self, row)
                context.check_cancelled()
                started = True
                result = tool.handler(args, context)
                effect_observed_at = time.time() if tool.completion_fence is not None else None
                if research_engine is not None:
                    context.check_cancelled()
                    research_engine.complete(row, result)
                    continue
                if len(encode(result)) > 65536:
                    raise Fault("result_too_large")
                if tool.completion_fence is not None:
                    self.store.finish_fenced(row, result,
                        verify=lambda: tool.completion_fence(result, context),
                        effect_observed_at=effect_observed_at)
                    if self.codex_service is not None and row["tool"] == self.codex_service.name:
                        self.codex_service.note_publication(self.store.get(row["owner"], row["id"]))
                    continue
                if tool.idempotent:
                    context.check_cancelled()
                # A completed non-idempotent action remains succeeded even if cancel arrived late.
                self.store.finish(row, "succeeded", result)
            except Cancelled:
                if self.codex_service is not None and row["tool"] == self.codex_service.name:
                    self.codex_service.finish_failure(self.store, row, "cancelled")
                    continue
                if research_engine is not None:
                    research_engine.complete(row, error='cancelled')
                    continue
                state = "cancelled" if replayable or not started else "needs_review"
                if self.stopping.is_set() and not row["cancel"]:
                    state = "queued" if replayable else ("needs_review" if started else "cancelled")
                self.store.finish(row, state, error="cancelled_or_interrupted")
            except Fault as exc:
                if self.codex_service is not None and row["tool"] == self.codex_service.name:
                    self.codex_service.finish_failure(self.store, row, exc.code)
                    continue
                if research_engine is not None:
                    research_engine.complete(row, error=exc.code)
                    continue
                if started and not replayable:
                    self.store.finish(row, "needs_review", error=exc.code)
                elif exc.code == "tool_contract_changed":
                    self.store.finish(row, "needs_review", error=exc.code)
                elif exc.code == "needs_unlock":
                    # A write handler may already have affected the external system.
                    # Only idempotent reads enter the resumable unlock state.
                    self.store.finish(row, "needs_unlock", error=exc.code)
                elif exc.code in {"transient", "provider_unavailable"} and replayable and row["attempts"] < 3:
                    self.store.finish(row, "queued", error=exc.code, delay=0.1 * 2**row["attempts"])
                else:
                    self.store.finish(row, "failed", error=exc.code)
            except Exception:
                if self.codex_service is not None and row["tool"] == self.codex_service.name:
                    self.codex_service.finish_failure(self.store, row, "provider_error")
                    continue
                if research_engine is not None:
                    research_engine.complete(row, error='research_provider_error')
                    continue
                # Unknown exceptions in writes may follow an external effect; never auto replay.
                self.store.finish(row, "needs_review" if started and not replayable else "failed", error="tool_error")
            finally:
                if row.get('schedule_v1'):
                    priorities.release_lease(self.store,row)

    def run(self):
        os.umask(0o077)
        self.instance = InstanceLock(self.home)
        try:
            if (self.home/"disabled").exists():
                raise Fault("user_disabled")
            self.control.start()
            sock = self.home/"runtime.sock"
            if sock.exists():
                sock.unlink()  # Only the lifetime-lock owner removes a stale endpoint.
            self.store = Store(self.home/"state.sqlite")
            self.store.publication_admission=self.check_publication_admission
            self.bind_priority()
            if self.host_attachment is not None:
                self.host_attachment.start(self)
            for engine in self.research_engines.values():
                engine.attach(self.store)
            if self.capture is not None:
                self.capture.attach(self.store)
            self.wakes = WakeRegistry(self.store, self.policies, self.wake_callbacks)
            self.server = Server(str(sock), Handler)
            self.server.runtime = self
            os.chmod(sock, 0o600)
            # Bind early for live/not-ready discovery. Recovery precedes ready.
            def initialize():
                if self.stopping.wait(self.start_delay):
                    return
                if self.execute_jobs:
                    if self.work_scope is None:
                        self.store.recover(self.tools)
                    else:
                        self.store.recover(self.tools, scope=self.work_scope)
                    for engine in self.research_engines.values():
                        if hasattr(engine, 'recover'): engine.recover()
                    if self.capture is not None:
                        self.capture.recover()
                    count=self.priority_authority.worker_count if self.priority_authority is not None else 1
                    self.workers=[threading.Thread(target=self.work,daemon=True) for _ in range(count)]
                    self.worker=self.workers[0]
                    for worker in self.workers:worker.start()
                self.ready.set()
                self.control.diagnostics.emit('runtime_ready')
            startup = threading.Thread(target=initialize, daemon=True)
            startup.start()
            if not self.stopping.is_set():
                self.server.serve_forever(poll_interval=0.05)
            startup.join(5)
        finally:
            self.control.diagnostics.emit('runtime_stopping')
            self.control.close()
            self.service_portal.close()
            self.stopping.set()
            self.ready.clear()
            self.job_signal.set()
            if self.codex_service is not None:
                self.codex_service.close()
            if self.host_attachment is not None:
                self.host_attachment.begin_shutdown()
            for worker in (self.workers or ([self.worker] if self.worker else [])):
                worker.join(self.shutdown_grace)
                # An embedded host can contain a buggy non-cooperative adapter.
                # Keep the DB/socket/instance lock owned until it actually exits;
                # never announce closed or allow a second owner while it is alive.
                if worker.is_alive():
                    worker.join()
            if self.server:
                self.server.server_close()
            if self.store:
                self.store.close()
            endpoint = self.home/"runtime.sock"
            if endpoint.exists():
                endpoint.unlink()
            self.instance.close()
            if self.host_attachment is not None:
                self.host_attachment.close(runtime_finished=self)
            self.closed.set()

    def shutdown(self):
        self.stopping.set()
        self.job_signal.set()
        if self.server:
            self.server.shutdown()
