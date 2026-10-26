"""Isolated registered-consumer demo: fixed inert tools, no production state.
No model, Apple data, account, launchd or tunnel is accessed.
"""
import os
import tempfile
import threading
from pathlib import Path
from arl.client import Client
from arl.contracts import AppPolicy
from arl.control import AppDescriptor
from arl.identity import RegisteredPeerVerifier, process_identity
from arl.service import Runtime

def main():
    with tempfile.TemporaryDirectory(prefix="arl-demo-") as directory:
        home=Path(directory);peer=RegisteredPeerVerifier({"sample_app"})
        peer.register("sample_app",os.getpid(),process_identity(os.getpid())["executable"])
        runtime=Runtime(home,policies={"sample_app":AppPolicy(frozenset({"runtime.ping","text.sha256"}))},identity_verifier=peer)
        runtime.control.apps.register(AppDescriptor("sample_app","Host placeholder","sf:app"))
        worker=threading.Thread(target=runtime.run);worker.start()
        client=Client(home,"sample_app")
        try:
            client.connect()
            print("Negotiated tools:",client.open_app_session("示例应用",("runtime.ping","text.sha256")))
            job=client.submit("text.sha256",{"text":"ARL foundation"},"demo-1")
            print("Verified tool result:",client.wait(job["id"])["state"])
            client.close_app_session()
        finally:runtime.shutdown();worker.join(10)
if __name__=="__main__":main()
