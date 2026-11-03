"""Current AppConnections/registration/policy remain the receive authority."""
import unittest
from dataclasses import replace

from arl.app_connections import AppConnections
from arl.control import AppDescriptor, AppRegistry
from arl.contracts import AppPolicy, Fault
from arl.diagnostics import Diagnostics
from arl.messages_receive import CAPABILITY, METHODS, MessagesReceive, build_native_receive_transport


class Transport:
    def __init__(self):
        self.calls = []
        self.during = None

    def call(self, method, params, consumer, recheck):
        recheck()
        self.calls.append((method, params, consumer))
        if self.during:
            self.during()
        recheck()
        return {"synthetic_body": "ARL-TEST only"}


class MessagesReceiveBridgeTests(unittest.TestCase):
    def setUp(self):
        self.now, self.alive = 1000, True
        self.app = "synthetic.agent"
        self.registry = AppRegistry({self.app}, Diagnostics({self.app}), clock=lambda:self.now, monotonic=lambda:self.now)
        self.registry.register(AppDescriptor(self.app, "Synthetic", "sf:app"))
        self.policy = AppPolicy(frozenset({CAPABILITY}), methods=METHODS | {"heartbeat"})
        self.policies = {self.app: self.policy}
        self.binding = ("a" * 64, lambda:self.alive)
        self.connections = AppConnections(self.registry)
        opened = self.connections.dispatch(self.app, "connection.open", {"client_nonce":"b"*64,"name":"Synthetic","icon_ref":"sf:app","version":"1","capabilities":[CAPABILITY]}, self.binding, self.policy)
        self.connections.dispatch(self.app,"connection.confirm", {key:opened[key] for key in ("session_id","challenge")},self.binding,self.policy)
        self.session = opened["session_id"]
        self.transport = Transport()
        self.bridge = MessagesReceive(self.registry,self.policies,self.transport)

    def call(self, extra=None, binding=None, method="messages.receive.status"):
        return self.bridge.dispatch(self.app,method,{"session_id":self.session,**(extra or {})},binding or self.binding,self.policy)

    def test_consumer_fields_are_derived_from_actual_confirmed_session(self):
        self.assertEqual(self.call(),{"synthetic_body":"ARL-TEST only"})
        method, params, consumer = self.transport.calls[0]
        self.assertEqual(params,{})
        self.assertEqual(consumer,{"app_id":self.app,"session_id":self.session,"registration_generation":"a"*64})

    def test_untrusted_scope_or_consumer_fields_never_reach_native(self):
        for extra in ({"app_id":"other"},{"consumer_app_id":"other"},{"path":"/private"},{"scope_id":"x"},{"grant":True}):
            with self.subTest(extra=extra),self.assertRaises(Fault): self.call(extra)
        self.assertEqual(self.transport.calls,[])

    def test_same_uid_or_app_name_is_not_a_binding(self):
        for binding in (("c"*64,lambda:True),("a"*64,lambda:False)):
            with self.assertRaises(Fault): self.call(binding=binding)
        self.assertEqual(self.transport.calls,[])

    def test_scope_and_ack_are_only_payload_selectors_not_authority(self):
        params={"scope_id":"11111111-1111-4111-8111-111111111111"}
        self.call(params,method="messages.receive.pull")
        self.assertEqual(self.transport.calls[-1][1],params)
        params.update(batch_id="22222222-2222-4222-8222-222222222222",batch_digest="d"*64)
        self.call(params,method="messages.receive.ack")
        self.assertEqual(self.transport.calls[-1][1],params)

    def test_policy_removal_during_native_read_suppresses_result(self):
        self.transport.during=lambda:self.policies.update({self.app:replace(self.policy,tools=frozenset())})
        with self.assertRaises(Fault): self.call()

    def test_registration_replacement_during_native_read_suppresses_result(self):
        self.transport.during=lambda:self.registry.register(AppDescriptor(self.app,"Replacement","sf:app"))
        with self.assertRaises(Fault): self.call()

    def test_expired_session_or_dead_registered_process_is_rejected(self):
        self.now+=30001
        with self.assertRaises(Fault):self.call()
        self.assertEqual(self.transport.calls,[])

    def test_revoke_after_admission_suppresses_result(self):
        self.transport.during=lambda:self.registry.revoke(self.app)
        with self.assertRaises(Fault):self.call()

    def test_source_checkout_does_not_configure_a_native_or_model_grant(self):
        transport,state=build_native_receive_transport("/not-a-real-owner")
        self.assertIsNone(transport)
        self.assertEqual(state,"not_packaged")


if __name__ == "__main__":unittest.main()
