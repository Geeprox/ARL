"""Synthetic registered app -> core -> actual signed native Unix receiver."""
import hashlib
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import struct
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from arl.app_connections import AppConnections
from arl.client import Client
from arl.control import AppDescriptor, AppRegistry
from arl.contracts import AppPolicy, Fault, encode
from arl.diagnostics import Diagnostics
from arl.identity import RegisteredPeerVerifier, process_identity
from arl.messages_receive import CAPABILITY, METHODS, MessagesReceive, NativeReceiveTransport
from arl.supervisor import SignedPeerVerifier
from arl.wire import strict_json


def application(home):
    ready=os.open(home/"app-ready",os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600);os.close(ready)
    deadline=time.monotonic()+5
    while not (home/"app-go").exists() and time.monotonic()<deadline:time.sleep(.01)
    assert (home/"app-go").exists()
    client = Client(home, "synthetic.agent")
    assert client.open_app_session("Synthetic receive consumer", [CAPABILITY]) == [CAPABILITY]
    session = client.app_session
    status = client.rpc("messages.receive.status", {"session_id": session})
    scope = status["scope"]["id"].lower()
    first = client.rpc("messages.receive.pull", {"session_id": session, "scope_id": scope})
    assert [row["rowID"] for row in first["batch"]["events"]] == [2]
    assert first["batch"]["events"][0]["text"] == "ARL-TEST signed cross-process receive"
    repeated = client.rpc("messages.receive.pull", {"session_id": session, "scope_id": scope})
    assert repeated["batch"] == first["batch"] and repeated["batch_digest"] == first["batch_digest"]
    try:
        client.rpc("messages.receive.status", {"session_id": session, "consumer_app_id": "forged"})
        raise AssertionError("caller could replace its consumer")
    except Fault as error:
        assert error.code == "messages_receive_invalid_arguments"
    acknowledgment = {"session_id":session,"scope_id":scope,"batch_id":first["batch"]["id"].lower(),"batch_digest":first["batch_digest"]}
    client.rpc("messages.receive.ack", acknowledgment)
    assert client.rpc("messages.receive.pull", {"session_id":session,"scope_id":scope})["batch"] is None
    client.close_app_session()
    try:
        client.rpc("messages.receive.status", {"session_id":session})
        raise AssertionError("closed session still delivered")
    except Fault as error:
        assert error.code == "messages_receive_not_authorized"
    print("PASS actual app handshake, signed native delivery and durable ack", flush=True)


def core(home, requirement, helper):
    transport = NativeReceiveTransport(home, parent_pid=os.getppid(), parent_requirement=requirement, peer_helper=helper)
    policy = AppPolicy(frozenset({CAPABILITY}), methods=METHODS | {"heartbeat"})
    registry = AppRegistry({"synthetic.agent"}, Diagnostics({"synthetic.agent"}))
    registry.register(AppDescriptor("synthetic.agent", "Synthetic", "sf:app"))
    sessions = AppConnections(registry)
    bridge = MessagesReceive(registry, {"synthetic.agent":policy}, transport)
    # Homebrew's bin launcher can exec the framework binary. The fixture host
    # explicitly launches its own already-observed physical interpreter.
    executable = Path(process_identity(os.getpid())["executable"])
    code = subprocess.run(["/usr/bin/codesign", "-d", "--verbose=4", str(executable)], capture_output=True, text=True, check=True)
    found = re.search(r"^CDHash=([a-fA-F0-9]{40,64})$", code.stderr, re.M)
    assert found is not None
    signed = SignedPeerVerifier(helper, {"synthetic.agent":'cdhash H"'+found.group(1)+'"'})
    registered = RegisteredPeerVerifier({"synthetic.agent"})
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(str(home / "runtime.sock")); os.chmod(home / "runtime.sock",0o600); listener.listen(1);listener.settimeout(15)
    child = subprocess.Popen([str(executable),"-B",str(Path(__file__).resolve()),"--app",str(home)], stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    deadline=time.monotonic()+5
    while not (home/"app-ready").exists() and time.monotonic()<deadline:time.sleep(.01)
    assert (home/"app-ready").exists()
    registered.register("synthetic.agent",child.pid,executable)
    go=os.open(home/"app-go",os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600);os.close(go)
    handled = 0
    try:
        while handled < 10:
            try:connection,_ = listener.accept()
            except socket.timeout:
                stdout,stderr=child.communicate(timeout=2)
                raise AssertionError(("app-ended-before-next-request",handled,stdout,stderr))
            with connection:
                connection.settimeout(10)
                raw=connection.makefile("rb").readline(16385)
                request=strict_json(raw)
                try:
                    assert registered(connection,"synthetic.agent") == "synthetic.agent",("peer_registration",handled,child.pid,struct.unpack("i",connection.getsockopt(0,2,4))[0],list(registered.registry))
                    assert signed(connection,"synthetic.agent") == "synthetic.agent"
                    a,b=registered.session_binding(connection,"synthetic.agent"),signed.session_binding(connection,"synthetic.agent")
                    binding=(a[0]+b[0],lambda:a[1]() and b[1]())
                    method=request["method"]
                    if method.startswith("connection."):
                        value=sessions.dispatch("synthetic.agent",method,request["params"],binding,policy)
                    else:
                        value=bridge.dispatch("synthetic.agent",method,request["params"],binding,policy)
                    reply={"protocol":"arl/1","ok":True,"result":value}
                except Fault as error:
                    reply={"protocol":"arl/1","ok":False,"error":{"code":error.code}}
                connection.sendall(encode(reply)+b"\n")
                handled+=1
        stdout,stderr=child.communicate(timeout=10)
        assert child.returncode==0,(stdout,stderr)
        assert "signed native delivery" in stdout
        print(stdout.strip(),flush=True)
    finally:
        listener.close()
        (home/"runtime.sock").unlink(missing_ok=True)
        if child.poll() is None:
            child.kill();child.wait()


if __name__=="__main__":
    if sys.argv[1]=="--app":application(Path(sys.argv[2]))
    else:core(Path(sys.argv[2]),sys.argv[3],Path(sys.argv[4]))
