"""Real private host/manager/parser chain; only SMB transport and authority fixtures are synthetic."""
import asyncio
import base64
import hashlib
import io
import json
from pathlib import Path
import time
import unittest
from unittest.mock import patch
import zipfile

from tests import test_nas_reader_host as fixture
from tests.fixtures import nas_documents as samples
from tests.test_nas_document_text import PDFKitChecks
from homeplane.nas_connection.contracts import NASConnectionError

ROOT = Path(__file__).resolve().parents[1]


class DocumentHostTests(unittest.IsolatedAsyncioTestCase):
    @classmethod
    def setUpClass(cls):
        PDFKitChecks.setUpClass()
    @classmethod
    def tearDownClass(cls):
        PDFKitChecks.tearDownClass()

    args = fixture.HostReaderTests.args
    call = fixture.HostReaderTests.call

    async def asyncSetUp(self):
        await fixture.HostReaderTests.asyncSetUp(self)
        self.host.document_pdf_helper = PDFKitChecks.helper


    async def asyncTearDown(self):
        await fixture.HostReaderTests.asyncTearDown(self)

    async def prepare(self, raw, filename):
        self.raw = raw
        found = await self.call(self.args())
        entry = found["entries"][0]
        self.transport_calls.clear()
        return self.args("read_document", name=filename,
                         **{key:entry[key] for key in ("object_ref","revision","size")})

    async def check_format(self, kind):
        raw = samples.fixtures()["arl-document-fixture." + kind]
        args = await self.prepare(raw, "arl-document-fixture." + kind)
        result = await self.call(args)
        self.assertIn({"pdf":"ARL PDF fixture", "docx":"ARL DOCX fixture", "xlsx":"你好", "pptx":"ARL PPTX fixture"}[kind], result["text"])
        self.assertEqual(result["format"], kind)
        self.assertEqual(result["source_sha256"], hashlib.sha256(raw).hexdigest())
        self.assertEqual(result["source_size"], len(raw))
        self.assertEqual(result["entry"]["revision"], args["revision"])
        self.assertEqual(result["connection_epoch"], args["connection_epoch"])
        self.assertEqual(result["operation"], "read_document")
        self.assertTrue(result["complete"])
        self.assertFalse(result["downloadable_artifact"])
        self.assertEqual(self.transport_calls, ["stat","read","stat"])
        self.assertEqual(self.manager._file_bytes, len(raw))
        return args, result

    async def test_actual_host_pdf(self): await self.check_format("pdf")
    async def test_actual_host_docx(self): await self.check_format("docx")
    async def test_actual_host_xlsx(self): await self.check_format("xlsx")
    async def test_actual_host_pptx(self): await self.check_format("pptx")

    async def test_revision_changed_never_parses_or_reads(self):
        args = await self.prepare(samples.docx(), "fixture.docx")
        args["revision"] = "f" * 64
        with self.assertRaises(NASConnectionError):
            await self.call(args)
        self.assertNotIn("read", self.transport_calls)

    async def test_scope_fence_changed_never_reads(self):
        args = await self.prepare(samples.docx(), "fixture.docx")
        args["connection_epoch"] = "f" * 32
        with self.assertRaises(NASConnectionError):
            await self.call(args)
        self.assertEqual(self.transport_calls, [])

    async def test_revocation_during_real_parser_withholds_text(self):
        import nas_document_host
        args = await self.prepare(samples.docx(), "fixture.docx")
        actual = nas_document_host.extract_document
        def revoke(*a, **kw):
            value = actual(*a, **kw)
            self.host.authority.revoked = True
            return value
        with patch.object(nas_document_host, "extract_document", side_effect=revoke):
            with self.assertRaises(NASConnectionError) as caught:
                await self.call(args)
        self.assertEqual(caught.exception.code, "nas_source_changed")

    async def test_actual_parse_failure_preserves_error_and_live_session(self):
        args = await self.prepare(b"invalid PDF", "fixture.pdf")
        result = await self.call(args)
        self.assertEqual(result["state"], "failed")
        self.assertEqual(result["error"]["code"], "invalid_pdf")
        self.assertFalse(result["automatic_replay"])
        self.assertEqual(self.manager._state, "online")

    async def test_unsupported_extension_is_not_a_range_read(self):
        args = await self.prepare(b"legacy binary", "fixture.doc")
        result = await self.call(args)
        self.assertEqual(result["error"]["code"], "unsupported_document_format")
        self.assertEqual(self.transport_calls, [])

    async def test_multichunk_uses_original_cumulative_budget(self):
        output = io.BytesIO()
        with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_STORED) as target:
            with zipfile.ZipFile(io.BytesIO(samples.docx())) as source:
                for name in source.namelist(): target.writestr(name, source.read(name))
            target.writestr("synthetic-unused.bin", bytes(range(256)) * 512)
        raw = output.getvalue()
        result = await self.call(await self.prepare(raw, "fixture.docx"))
        self.assertEqual(result["state"], "extracted")
        self.assertEqual(self.manager._file_bytes, len(raw))
        self.assertEqual(self.transport_calls.count("read"), (len(raw) + 32767) // 32768)

    async def test_private_frame_budget_remains_explicit(self):
        raw = samples.docx("<w:p><w:r><w:t>" + "中" * 30000 + "</w:t></w:r></w:p>")
        result = await self.call(await self.prepare(raw, "fixture.docx"))
        self.assertTrue(result["truncated"])
        self.assertIn("text_budget", result["stopped_reasons"])
        self.assertEqual(result["next_unit_offset"],1)
        self.assertGreater(result["next_text_offset"],0)
        self.assertLessEqual(len(json.dumps(result,ensure_ascii=False).encode()), 196608)
        self.assertTrue(("中" * 30000).startswith(result["text"]))

    async def test_original_authority_deadline_still_fences_parser(self):
        import nas_document_host
        args = await self.prepare(samples.docx(), "fixture.docx")
        actual = nas_document_host.extract_document
        def expire(*a, **kw):
            result = actual(*a, **kw)
            self.host.authority.deadline = time.monotonic() - 1
            return result
        with patch.object(nas_document_host, "extract_document", side_effect=expire):
            with self.assertRaises(NASConnectionError):
                await self.call(args)


if __name__ == "__main__":
    unittest.main()
