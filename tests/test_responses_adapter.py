import io
from unittest import TestCase
from unittest.mock import Mock, patch
from arl.contracts import Fault
from arl.responses_adapter import ResponsesAdapter
from arl.responses_worker import main, URL
from tests.test_research import body, response, MODEL, FINGERPRINT
from arl.contracts import encode

class ResponsesTransportTests(TestCase):
    def test_default_disabled_does_not_touch_credential_or_process(self):
        loader=Mock();adapter=ResponsesAdapter({MODEL:FINGERPRINT},loader)
        with self.assertRaises(Fault) as exc:adapter.complete(body(),{},Mock())
        self.assertEqual(exc.exception.code,'provider_unavailable');loader.assert_not_called()
    def test_worker_fixed_destination_preserves_raw_body_and_response(self):
        raw=body(524288);reply=response(1048576)
        incoming=io.BytesIO(encode({'key':'SYNTHETIC_NOT_A_KEY','timeout':1})+b'\n'+raw);out=io.BytesIO()
        fake=Mock();fake.status=200;fake.headers={'Content-Type':'application/json'};fake.read.return_value=reply
        context=Mock();context.__enter__=Mock(return_value=fake);context.__exit__=Mock(return_value=False)
        opener=Mock();opener.open.return_value=context
        with patch('arl.responses_worker.sys.stdin',Mock(buffer=incoming)),patch('arl.responses_worker.sys.stdout',Mock(buffer=out)),patch('arl.responses_worker.urllib.request.build_opener',return_value=opener):main()
        request=opener.open.call_args.args[0]
        self.assertEqual(request.full_url,URL);self.assertEqual(request.data,raw)
        self.assertEqual(out.getvalue(),b'S'+reply)
    def test_worker_errors_never_export_upstream_body(self):
        from urllib.error import HTTPError
        incoming=io.BytesIO(encode({'key':'SYNTHETIC_NOT_A_KEY','timeout':1})+b'\n'+body());out=io.BytesIO()
        opener=Mock();opener.open.side_effect=HTTPError(URL,401,'SECRET',{},io.BytesIO(b'PRIVATE_CONTENT'))
        with patch('arl.responses_worker.sys.stdin',Mock(buffer=incoming)),patch('arl.responses_worker.sys.stdout',Mock(buffer=out)),patch('arl.responses_worker.urllib.request.build_opener',return_value=opener):main()
        self.assertEqual(out.getvalue(),b'Eprovider_rejected')
    def test_worker_rejects_extra_control_fields_before_network(self):
        incoming=io.BytesIO(encode({'key':'SYNTHETIC_NOT_A_KEY','timeout':1,'url':'http://attacker'})+b'\n'+body());out=io.BytesIO()
        with patch('arl.responses_worker.sys.stdin',Mock(buffer=incoming)),patch('arl.responses_worker.sys.stdout',Mock(buffer=out)),patch('arl.responses_worker.urllib.request.build_opener') as build:main()
        build.assert_not_called();self.assertEqual(out.getvalue(),b'Eprovider_unavailable')
