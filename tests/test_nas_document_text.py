"""Local real-format samples and PDFKit; no NAS, TCC, user document or model call."""
from __future__ import annotations
from copy import deepcopy
import hashlib
import io
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import warnings
import zipfile

from integrations.nas import document_text as document
from integrations.nas.attachment_bridge import VerifiedFile, BridgeFault, DOWNLOAD_KEYS
from tests.fixtures import nas_documents as sample

ROOT = Path(__file__).resolve().parents[1]
AUDIT = ROOT / "build/audit/nas-document-text-20261024.noindex"


def artifact(name, raw):
    return VerifiedFile(name, raw, hashlib.sha256(raw).hexdigest())



def mcp_reply(value):
    return dict(content=[dict(type="text", text=json.dumps(value, ensure_ascii=False))],
                structuredContent=deepcopy(value), isError=False)


def download_manifest(raw, name):
    return dict(schema_version=1, operation="download",
        operation_id="1faf7a95-3247-4d30-bc67-233bc839358f", source_ref="synthetic",
        config_generation=1, connection_epoch="e" * 32, transfer_ref="f" * 64,
        object_ref="a" * 64, revision="b" * 64, name=name, size=len(raw),
        sha256=hashlib.sha256(raw).hexdigest(), expires_in_seconds=120,
        complete=True, direction="download", downloadable_artifact=False,
        delivery_code="platform_file_publisher_required")


class DownloadReplyFixture:
    def __init__(self, raw):
        self.raw = raw
        self.calls = []

    def __call__(self, tool, arguments):
        import base64
        assert tool == "mio_nas_transfer_read"
        self.calls.append(deepcopy(arguments))
        raw = self.raw[arguments["offset"]:arguments["offset"] + arguments["length"]]
        end = arguments["offset"] + len(raw)
        return mcp_reply(dict(arguments, schema_version=1, operation="transfer_read",
            bytes_read=len(raw), data_base64=base64.b64encode(raw).decode(),
            chunk_sha256=hashlib.sha256(raw).hexdigest(), eof=end == len(self.raw),
            next_offset=None if end == len(self.raw) else end,
            downloadable_artifact=False, delivery_code="platform_file_publisher_required"))

class OfficeChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        AUDIT.mkdir(mode=0o700, parents=True, exist_ok=True)

    def fault(self, code, function):
        with self.assertRaises(document.DocumentFault) as caught:
            function()
        self.assertEqual(caught.exception.code, code)

    def test_docx_unicode_table_breaks_and_explicit_coverage(self):
        raw = sample.docx()
        result = document.extract_document(artifact("fixture.docx", raw))
        self.assertEqual(result["text"], "ARL DOCX fixture\n你好\t世界\nVersion: 1\n表格：样例")
        self.assertNotIn("HEADER EXCLUDED", result["text"])
        self.assertEqual(result["source_sha256"], hashlib.sha256(raw).hexdigest())
        self.assertTrue(result["complete"])
        self.assertIn("headers_footnotes_comments_images_excluded", result["coverage"])


    @unittest.skipUnless(shutil.which("textutil"), "native macOS textutil")
    def test_independent_native_docx_conversion(self):
        expected = "ARL native DOCX fixture\n你好，原文🙂\nVersion: 1"
        with tempfile.TemporaryDirectory(dir=AUDIT) as temporary:
            home = Path(temporary)
            source = home / "synthetic.txt"
            target = home / "native.docx"
            source.write_text(expected, encoding="utf-8")
            converted = subprocess.run(["textutil", "-convert", "docx", "-inputencoding", "UTF-8",
                "-output", str(target), str(source)], capture_output=True, timeout=15)
            self.assertEqual(converted.returncode, 0)
            result = document.extract_document(artifact(target.name, target.read_bytes()))
            self.assertEqual(result["text"], expected)
            self.assertTrue(result["complete"])

    def test_xlsx_original_workbook_order_shared_inline_hidden_and_cached_formulas(self):
        result = document.extract_document(artifact("fixture.xlsx", sample.xlsx()))
        self.assertEqual([unit["name"] for unit in result["units"]], ["Fixture", "隐藏页"])
        self.assertTrue(result["units"][1]["hidden"])
        self.assertEqual(result["units"][0]["text"],
            "A1\tARL XLSX fixture\nB1\t原文🙂\nC1\t12.500\nD1\t=1+2 [cached: 3]\nE1\t=NOW()")
        self.assertEqual(result["units"][1]["text"], "A1\t你好")
        self.assertIn("formulas_not_evaluated", result["coverage"])

    def test_pptx_relationship_order_and_notes_are_excluded(self):
        result = document.extract_document(artifact("fixture.pptx", sample.pptx()))
        self.assertEqual(result["text"], "ARL PPTX fixture 第一张\n第二张")
        self.assertNotIn("NOTES EXCLUDED", result["text"])
        self.assertEqual([unit["index"] for unit in result["units"]], [1, 2])

    def test_legacy_formats_and_unknown_extensions_are_explicit(self):
        for name in ["fixture.doc", "fixture.xls", "fixture.ppt", "fixture.zip", "fixture.docm"]:
            self.fault("unsupported_document_format",
                lambda: document.extract_document(artifact(name, b"synthetic")))

    def test_compound_office_boundary_does_not_attempt_decryption(self):
        raw = bytes.fromhex("d0cf11e0a1b11ae1") + bytes(128)
        self.fault("encrypted_or_compound_office_unsupported",
            lambda: document.extract_document(artifact("fixture.docx", raw)))

    def test_invalid_zip_missing_part_and_bad_xml(self):
        for raw, code in [(b"not a zip", "invalid_office_package"),
                          (sample.archive({"other.xml": "<x/>"}), "missing_document_part"),
                          (sample.archive({"word/document.xml": "<bad>"}), "invalid_document_xml"),
                          (sample.archive({"word/document.xml": "<other/>"}), "invalid_document_xml")]:
            self.fault(code, lambda: document.extract_document(artifact("fixture.docx", raw)))

    def test_xml_entity_and_external_sheet_relationship_never_fetch(self):
        entity = '<!DOCTYPE document [<!ENTITY bomb "external">]><document/>'
        self.fault("unsupported_xml_declaration", lambda: document.extract_document(
            artifact("fixture.docx", sample.archive({"word/document.xml": entity}))))
        with zipfile.ZipFile(io.BytesIO(sample.xlsx())) as original:
            parts = {name: original.read(name) for name in original.namelist()}
        parts["xl/_rels/workbook.xml.rels"] = (
            f'<Relationships xmlns="{sample.REL}"><Relationship Id="second" Target="https://invalid.example/x" TargetMode="External"/></Relationships>')
        self.fault("unavailable_sheet_relationship", lambda: document.extract_document(
            artifact("fixture.xlsx", sample.archive(parts))))

    def test_long_paragraph_and_many_units_have_lossless_continuation(self):
        text = "中😀" * 18000
        raw = sample.docx("<w:p><w:r><w:t>"+text+"</w:t></w:r></w:p>" + "<w:p><w:r><w:t>end</w:t></w:r></w:p>"*140)
        item = artifact("fixture.docx", raw)
        cursor=(1,0); parts={};seen=set()
        while True:
            self.assertNotIn(cursor,seen);seen.add(cursor)
            result=document.extract_document(item,unit_offset=cursor[0],text_offset=cursor[1])
            for unit in result["units"]:
                self.assertEqual(len(parts.get(unit["index"],"").encode()),unit["text_offset"])
                parts[unit["index"]]=parts.get(unit["index"],"")+unit["text"]
            if result["complete"]:break
            cursor=(result["next_unit_offset"],result["next_text_offset"])
        self.assertEqual(parts[1],text);self.assertEqual(len(parts),141)

    def test_duplicate_parts_and_expansion_budget(self):
        out = io.BytesIO()
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with zipfile.ZipFile(out, "w") as archive:
                archive.writestr("word/document.xml", "<x/>")
                archive.writestr("word/document.xml", "<x/>")
        self.fault("ambiguous_office_package", lambda: document.extract_document(artifact("fixture.docx", out.getvalue())))
        large = sample.archive({"word/document.xml": b"x" * (document.MAX_XML_BYTES + 1)})
        self.fault("office_part_memory_budget", lambda: document.extract_document(artifact("fixture.docx", large)))

    @unittest.skipUnless(shutil.which("zip"), "system zip needed for a real encrypted ZIP fixture")
    def test_real_password_encrypted_zip_is_refused(self):
        with tempfile.TemporaryDirectory(dir=AUDIT) as temporary:
            home = Path(temporary)
            (home / "word").mkdir()
            (home / "word/document.xml").write_text("<document/>")
            subprocess.run(["zip", "-q", "-P", "SYNTHETIC-FIXTURE", "encrypted.docx", "word/document.xml"],
                           cwd=home, check=True, capture_output=True)
            self.fault("encrypted_office_package", lambda: document.extract_document(
                artifact("encrypted.docx", (home / "encrypted.docx").read_bytes())))

    def test_utf8_budget_is_explicit_without_replacement_characters(self):
        text = "🙂" * 20000
        raw = sample.docx(f"<w:p><w:r><w:t>{text}</w:t></w:r></w:p>")
        result = document.extract_document(artifact("fixture.docx", raw))
        self.assertTrue(result["truncated"])
        self.assertIn("text_budget", result["stopped_reasons"])
        self.assertNotIn("\ufffd", result["text"])
        self.assertEqual(result["text"], text[:document.MAX_TEXT_BYTES // 4])


    def test_json_escape_output_budget_remains_explicit(self):
        text = ('"' + "\\") * 32000
        raw = sample.docx(f"<w:p><w:r><w:t>{text}</w:t></w:r></w:p>")
        result = document.extract_document(artifact("fixture.docx", raw))
        encoded = json.dumps(result, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.assertLessEqual(len(encoded), document.MAX_RESULT_BYTES)
        self.assertIn("output_budget", result["stopped_reasons"])
        self.assertTrue(result["truncated"])
        self.assertTrue(text.startswith(result["text"]))


    def test_text_box_paragraph_is_not_duplicated(self):
        body = "<w:p><w:r><w:t>Main</w:t><w:txbxContent><w:p><w:r><w:t>Box</w:t></w:r></w:p></w:txbxContent></w:r></w:p>"
        result = document.extract_document(artifact("fixture.docx", sample.docx(body)))
        self.assertEqual(result["text"], "Main\nBox")

    def test_text_budget_counts_paragraph_separators(self):
        body = ("<w:p><w:r><w:t>" + "x" * 32768 + "</w:t></w:r></w:p>") * 2
        result = document.extract_document(artifact("fixture.docx", sample.docx(body)))
        self.assertEqual(len(result["text"].encode("utf-8")), document.MAX_TEXT_BYTES)
        self.assertTrue(result["truncated"])

    def test_unit_budget_is_explicit(self):
        raw = sample.docx("<w:p><w:r><w:t>x</w:t></w:r></w:p>" * (document.MAX_UNITS + 1))
        result = document.extract_document(artifact("fixture.docx", raw))
        self.assertEqual(len(result["units"]), document.MAX_UNITS)
        self.assertTrue(result["truncated"])
        self.assertIn("unit_budget", result["stopped_reasons"])

    def test_unverified_or_changed_bytes_never_parse(self):
        self.fault("verified_file_required", lambda: document.extract_document({"name": "fixture.docx"}))
        with self.assertRaises(BridgeFault):
            document.extract_document(VerifiedFile("fixture.docx", sample.docx(), "0" * 64))
        self.fault("pdf_worker_unavailable", lambda: document.extract_document(artifact("fixture.pdf", sample.pdf())))

    def test_download_bridge_to_actual_docx_parser(self):
        raw = sample.docx()
        original = download_manifest(raw, "fixture.docx")
        calls = DownloadReplyFixture(raw)
        checks = []
        result = document.extract_download(mcp_reply(original), expected={k: original[k] for k in DOWNLOAD_KEYS},
            call=calls, verify=lambda: checks.append(True))
        self.assertIn("你好\t世界", result["text"])
        self.assertEqual(result["source_sha256"], hashlib.sha256(raw).hexdigest())
        self.assertEqual(len(calls.calls), 1)
        self.assertFalse(result["downloadable_artifact"])
        self.assertGreater(len(checks), 2)

    def test_revocation_during_parsing_withholds_result_without_retry(self):
        raw = sample.docx()
        original = download_manifest(raw, "fixture.docx")
        calls = DownloadReplyFixture(raw)
        revoked = False
        def verify():
            if revoked:
                raise BridgeFault("owner_revoked")
        original_extract = document.extract_document
        def revoke_after_actual_parse(*args, **kwargs):
            nonlocal revoked
            value = original_extract(*args, **kwargs)
            revoked = True
            return value
        with patch.object(document, "extract_document", side_effect=revoke_after_actual_parse):
            with self.assertRaises(BridgeFault) as caught:
                document.extract_download(mcp_reply(original), expected={k: original[k] for k in DOWNLOAD_KEYS},
                    call=calls, verify=verify)
        self.assertEqual(caught.exception.code, "owner_revoked")
        self.assertEqual(len(calls.calls), 1)


@unittest.skipUnless(sys.platform == "darwin", "real macOS PDFKit")
class PDFKitChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        AUDIT.mkdir(mode=0o700, parents=True, exist_ok=True)
        cls.temporary = tempfile.TemporaryDirectory(prefix="pdfkit-", dir=AUDIT)
        cls.home = Path(cls.temporary.name)
        cls.helper = cls.home / "NASPDFTextExtractor"
        cls.protector = cls.home / "NASPDFProtectionFixture"
        base = ["xcrun", "swiftc", "-j", "1", "-swift-version", "6", "-parse-as-library",
                "-module-cache-path", str(cls.home / "ModuleCache")]
        for source, target in [(ROOT / "integrations/nas/native/NASPDFTextExtractor.swift", cls.helper),
                               (ROOT / "tests/fixtures/NASPDFProtectionFixture.swift", cls.protector)]:
            compiled = subprocess.run(base + [str(source), "-o", str(target)], capture_output=True, text=True, timeout=120)
            if compiled.returncode:
                raise RuntimeError(compiled.stderr)

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def extract(self, raw):
        return document.extract_document(artifact("fixture.pdf", raw), pdf_helper=self.helper)

    def test_actual_pdfkit_extracts_text_and_page_order(self):
        result = self.extract(sample.pdf(pages=2))
        self.assertIn("ARL PDF fixture page 1", result["units"][0]["text"])
        self.assertIn("Version: 1", result["text"])
        self.assertIn("ARL PDF fixture page 2", result["units"][1]["text"])
        self.assertTrue(result["complete"])
        self.assertEqual(result["format"], "pdf")

    def test_scanned_image_only_and_blank_pdf_return_no_text_without_ocr(self):
        for raw in [sample.pdf(image=True), sample.pdf(blank=True)]:
            result = self.extract(raw)
            self.assertEqual(result["state"], "no_extractable_text")
            self.assertEqual(result["text"], "")
            self.assertIn("no_OCR", result["coverage"])

    def test_actual_pdfkit_password_protected_pdf_is_refused(self):
        protected = subprocess.run([str(self.protector)], input=sample.pdf(), capture_output=True, timeout=15)
        self.assertEqual(protected.returncode, 0, protected.stderr)
        with self.assertRaises(document.DocumentFault) as caught:
            self.extract(protected.stdout)
        self.assertEqual(caught.exception.code, "encrypted_pdf")

    def test_invalid_pdf_and_worker_input_limit(self):
        with self.assertRaises(document.DocumentFault) as caught:
            self.extract(b"invalid PDF")
        self.assertEqual(caught.exception.code, "invalid_pdf")
        response = subprocess.run([str(self.helper)], input=b"x" * (document.MAX_DOCUMENT_BYTES + 1), capture_output=True, timeout=10)
        self.assertEqual(json.loads(response.stdout), {"ok": False, "code": "input_budget"})

    def test_real_pdf_page_budget_is_explicit(self):
        result = self.extract(sample.pdf(pages=129))
        self.assertEqual(len(result["units"]), 128)
        self.assertTrue(result["truncated"])
        self.assertIn("pdf_worker_budget", result["stopped_reasons"])


if __name__ == "__main__":
    unittest.main()
