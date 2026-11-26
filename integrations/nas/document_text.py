"""Text from already verified NAS download bytes; no NAS/network/permission API.

Office extraction uses only the standard library. PDF uses an explicitly supplied
host-owned PDFKit worker, never an executable selected by document/request data.
This component does not register a Mio tool or imply a deployed parser.
"""
from __future__ import annotations

import io
import json
import os
import stat
import tempfile
from html.parser import HTMLParser
from pathlib import Path
import posixpath
import subprocess
import time
import zipfile
import xml.etree.ElementTree as ET

from .attachment_bridge import VerifiedDownloadFile, VerifiedFile, basename, collect_download_file

MAX_TEXT_BYTES = 65536
MAX_UNITS = 128
MAX_RESULT_BYTES = 180224  # Leave room for the authenticated owner envelope.
MAX_DOCUMENT_BYTES = 2**53 - 1  # Exact JSON integer range, matching NAS downloads.
OFFICE_FORMATS = {"docx": "docx", "docm": "docx", "xlsx": "xlsx", "xlsm": "xlsx", "pptx": "pptx", "pptm": "pptx"}
PLAIN_FORMATS = {"txt", "md", "markdown", "csv", "tsv", "log", "json", "jsonl", "xml", "yaml", "yml"}
LEGACY_WORD_FORMATS = {"doc", "rtf", "odt"}
CONVERTED_FORMATS = {"pdf", "html", "htm"} | OFFICE_FORMATS.keys() | LEGACY_WORD_FORMATS
DOCUMENT_FORMATS = PLAIN_FORMATS | CONVERTED_FORMATS


class DocumentFault(ValueError):
    def __init__(self, code):
        self.code = code
        super().__init__(code)


def fail(code):
    raise DocumentFault(code)


def local(tag):
    return tag.rsplit("}", 1)[-1]


def text_runs(node, *, word=False):
    out = []
    pending = [node]
    while pending:
        child = pending.pop()
        name = local(child.tag)
        if child is not node and name == "p":
            continue  # The enclosing document walker visits nested text-box paragraphs separately.
        if name == "t":
            out.append(child.text or "")
        elif word and name == "tab":
            out.append("\t")
        elif name in {"br", "cr"}:
            out.append("\n")
        pending.extend(reversed(list(child)))
    return "".join(out)


class Budget:
    def __init__(self, unit_offset=1, text_offset=0):
        if type(unit_offset) is not int or unit_offset < 1 or type(text_offset) is not int or text_offset < 0:
            fail("invalid_document_cursor")
        self.unit_offset, self.text_offset = unit_offset, text_offset
        self.units = []
        self.remaining = MAX_TEXT_BYTES
        self.reasons = set()
        self.next = None

    def stop(self, index, offset, reason):
        self.next = (index, offset)
        self.reasons.add(reason)
        return False

    def add(self, kind, index, text, **metadata):
        if index < self.unit_offset:
            return True
        offset = self.text_offset if index == self.unit_offset else 0
        encoded = text.encode("utf-8")
        if offset > len(encoded):
            fail("invalid_document_cursor")
        try:
            text = encoded[offset:].decode("utf-8")
        except UnicodeError:
            fail("invalid_document_cursor")
        if len(self.units) >= MAX_UNITS:
            return self.stop(index, offset, "unit_budget")
        separator = int(bool(self.units))
        if self.remaining <= separator and text:
            return self.stop(index, offset, "text_budget")
        self.remaining -= separator
        encoded = text.encode("utf-8")
        page = encoded[:self.remaining].decode("utf-8", errors="ignore")
        accepted = len(page.encode("utf-8"))
        self.remaining -= accepted
        self.units.append(dict(kind=kind, index=index, text_offset=offset, text=page, **metadata))
        if accepted < len(encoded):
            return self.stop(index, offset + accepted, "text_budget")
        return True

    def trim_last(self, accepted):
        unit = self.units[-1]
        self.stop(unit["index"], unit["text_offset"] + accepted, "output_budget")



class OfficeTree(ET.TreeBuilder):
    def doctype(self, name, pubid, system):
        fail("unsupported_xml_declaration")


class Parts:
    def __init__(self, raw):
        try:
            self.zip = zipfile.ZipFile(raw)
            entries = self.zip.infolist()
        except (zipfile.BadZipFile, ValueError):
            fail("invalid_office_package")
        names = [entry.filename for entry in entries]
        try:
            if any(entry.file_size < 0 for entry in entries):
                fail("invalid_office_package")
            if any(entry.flag_bits & 1 for entry in entries):
                fail("encrypted_office_package")
            if len(names) != len(set(names)):
                fail("ambiguous_office_package")
            self.names = set(names)
        except DocumentFault:
            self.zip.close()
            raise

    def close(self):
        self.zip.close()

    def xml(self, name):
        if name not in self.names:
            fail("missing_document_part")
        try:
            with self.zip.open(name) as part:
                return ET.parse(part, parser=ET.XMLParser(target=OfficeTree())).getroot()
        except DocumentFault:
            raise
        except (ValueError, UnicodeError, ET.ParseError, zipfile.BadZipFile, RuntimeError, NotImplementedError, EOFError):
            fail("invalid_document_xml")

    def relationships(self, base, name):
        result = {}
        for row in self.xml(name):
            if local(row.tag) != "Relationship":
                continue
            key = row.get("Id")
            if not key or key in result:
                fail("ambiguous_relationship")
            target = row.get("Target", "")
            if row.get("TargetMode") == "External":
                result[key] = None
                continue
            path = posixpath.normpath(target.lstrip("/") if target.startswith("/") else base + "/" + target)
            result[key] = path if path.startswith(base + "/") and path in self.names else None
        return result


def relationship_id(node):
    return next((value for key, value in node.attrib.items() if key.endswith("}id")), None)


def office(raw, kind, budget):
    if raw.read(8) == bytes.fromhex("d0cf11e0a1b11ae1"):
        fail("encrypted_or_compound_office_unsupported")
    raw.seek(0)
    parts = Parts(raw)
    try:
        if kind == "docx":
            document = parts.xml("word/document.xml")
            if local(document.tag) != "document":
                fail("invalid_document_xml")
            body = next((node for node in document if local(node.tag) == "body"), None)
            if body is None:
                fail("invalid_document_xml")
            for index, paragraph in enumerate((n for n in body.iter() if local(n.tag) == "p"), 1):
                if not budget.add("paragraph", index, text_runs(paragraph, word=True)):
                    break
            return "document_body_text; headers_footnotes_comments_images_excluded"
        if kind == "pptx":
            root = parts.xml("ppt/presentation.xml")
            if local(root.tag) != "presentation":
                fail("invalid_document_xml")
            links = parts.relationships("ppt", "ppt/_rels/presentation.xml.rels")
            for index, slide in enumerate((n for n in root.iter() if local(n.tag) == "sldId"), 1):
                target = links.get(relationship_id(slide))
                if target is None:
                    fail("unavailable_slide_relationship")
                tree = parts.xml(target)
                text = "\n".join(text_runs(n) for n in tree.iter() if local(n.tag) == "p")
                if not budget.add("slide", index, text):
                    break
            return "slide_text_in_presentation_order; notes_images_excluded"
        shared = []
        if "xl/sharedStrings.xml" in parts.names:
            shared = [text_runs(n) for n in parts.xml("xl/sharedStrings.xml") if local(n.tag) == "si"]
        root = parts.xml("xl/workbook.xml")
        if local(root.tag) != "workbook":
            fail("invalid_document_xml")
        links = parts.relationships("xl", "xl/_rels/workbook.xml.rels")
        for index, sheet in enumerate((n for n in root.iter() if local(n.tag) == "sheet"), 1):
            target = links.get(relationship_id(sheet))
            if target is None:
                fail("unavailable_sheet_relationship")
            cells = []
            for cell in parts.xml(target).iter():
                if local(cell.tag) != "c":
                    continue
                values = {local(n.tag): n for n in cell}
                value = values["v"].text or "" if "v" in values else ""
                if cell.get("t") == "s":
                    try:
                        if not value.isdecimal():
                            fail("invalid_shared_string")
                        value = shared[int(value)]
                    except (IndexError, ValueError):
                        fail("invalid_shared_string")
                elif cell.get("t") == "inlineStr":
                    value = text_runs(cell)
                if "f" in values:
                    value = "=" + (values["f"].text or "") + (" [cached: " + value + "]" if value else "")
                cells.append(cell.get("r", "?") + "\t" + value)
            if not budget.add("sheet", index, "\n".join(cells), name=sheet.get("name", ""), hidden=sheet.get("state") in {"hidden", "veryHidden"}):
                break
        return "worksheet_cells_in_workbook_order; raw_scalars_cached_formulas; formulas_not_evaluated"
    finally:
        parts.close()


def pdf(raw, helper, budget):
    if helper is None or not Path(helper).is_absolute() or not Path(helper).is_file():
        fail("pdf_worker_unavailable")
    try:
        response = subprocess.run([str(helper), str(budget.unit_offset), str(budget.text_offset)],
                                  stdin=raw, capture_output=True, timeout=45)
    except subprocess.TimeoutExpired:
        fail("document_parser_timeout")
    except OSError:
        fail("pdf_worker_unavailable")
    if response.returncode or len(response.stdout) > 196608:
        fail("document_parser_failed")
    try:
        result = json.loads(response.stdout)
        if type(result) is not dict or type(result.get("ok")) is not bool:
            fail("invalid_parser_reply")
        if not result["ok"]:
            code = result.get("code")
            fail(code if code in {"invalid_pdf", "encrypted_pdf", "input_budget", "pdf_ocr_failed"} else "document_parser_failed")
        if type(result.get("pages")) is not list or type(result.get("page_count")) is not int:
            fail("invalid_parser_reply")
        previous = budget.unit_offset - 1
        for page in result["pages"]:
            if (type(page) is not dict or set(page) != {"index", "text_offset", "text"}
                    or type(page["index"]) is not int or page["index"] <= previous
                    or type(page["text_offset"]) is not int or page["text_offset"] < 0 or type(page["text"]) is not str):
                fail("invalid_parser_reply")
            budget.units.append(dict(kind="page", **page))
            previous = page["index"]
        if len(budget.units) > MAX_UNITS or len("\n".join(p["text"] for p in budget.units).encode()) > MAX_TEXT_BYTES:
            fail("invalid_parser_reply")
        if result.get("truncated") is True:
            cursor = result.get("next")
            if (type(cursor) is not list or len(cursor) != 2 or any(type(n) is not int for n in cursor)
                    or cursor[0] < budget.unit_offset or cursor[1] < 0):
                fail("invalid_parser_reply")
            budget.stop(*cursor, "pdf_worker_budget")
    except (ValueError, UnicodeError) as error:
        if isinstance(error, DocumentFault):
            raise
        fail("invalid_parser_reply")
    return "pdf_embedded_text_or_local_Vision_OCR; OCR_may_be_inaccurate; annotations_excluded"



class HTMLText(HTMLParser):
    def __init__(self, emit):
        super().__init__(convert_charrefs=True)
        self.emit = emit
        self.hidden = None

    def handle_starttag(self, tag, attrs):
        if not self.hidden and tag in {"script", "style", "template"}:
            self.hidden = tag
        if not self.hidden and tag in {"br", "p", "li", "tr", "div", "h1", "h2", "h3"}:
            self.emit("\n")
        if not self.hidden and tag in {"td", "th"}:
            self.emit("\t")

    def handle_endtag(self, tag):
        if self.hidden == tag:
            self.hidden = None

    def handle_data(self, text):
        if not self.hidden:
            self.emit(text)


def text_encoding(file):
    prefix = file.read(65536)
    file.seek(0)
    if prefix.startswith((b"\xff\xfe\0\0", b"\0\0\xfe\xff")):
        return "utf-32"
    if prefix.startswith((b"\xff\xfe", b"\xfe\xff")):
        return "utf-16"
    try:
        import codecs
        codecs.getincrementaldecoder("utf-8-sig")().decode(prefix)
        return "utf-8-sig"
    except UnicodeError:
        return "gb18030"


def text_lines(file, budget, *, encoding=None):
    reader = io.TextIOWrapper(file, encoding=encoding or text_encoding(file))
    try:
        for index, line in enumerate(reader, 1):
            if "\0" in line:
                fail("invalid_document_text")
            if not budget.add("line", index, line.removesuffix("\n")):
                break
    except UnicodeError:
        fail("invalid_document_text")
    finally:
        reader.detach()


def html(file, budget):
    with tempfile.TemporaryFile() as converted:
        parser=HTMLText(lambda text: converted.write(text.encode("utf-8")))
        reader=io.TextIOWrapper(file, encoding=text_encoding(file))
        try:
            while chunk := reader.read(65536):
                parser.feed(chunk)
            parser.close()
        except UnicodeError:
            fail("invalid_document_text")
        finally:
            reader.detach()
        converted.seek(0)
        text_lines(converted, budget, encoding="utf-8")
    return "html_visible_text; scripts_styles_external_resources_not_loaded"


def legacy_word(file, kind, budget):
    with tempfile.TemporaryFile() as converted:
        try:
            response=subprocess.run(["/usr/bin/textutil","-convert","txt","-format",kind,"-stdin","-stdout",
                                     "-noload","-nostore"], stdin=file, stdout=converted,
                                    stderr=subprocess.DEVNULL, timeout=45)
        except subprocess.TimeoutExpired:
            fail("document_parser_timeout")
        except OSError:
            fail("document_parser_unavailable")
        if response.returncode:
            fail("invalid_document_text")
        converted.seek(0)
        text_lines(converted, budget, encoding="utf-8")
    return "macos_text_conversion; layout_and_embedded_media_excluded"


def bounded_result(artifact, kind, coverage, budget):
    def result():
        return dict(schema_version=1, operation="extract_document_text", format=kind,
                    file_name=artifact.name, source_size=artifact.size, source_sha256=artifact.sha256,
                    state="extracted" if any(unit["text"] for unit in budget.units) else "no_extractable_text",
                    units=budget.units, text="\n".join(unit["text"] for unit in budget.units),
                    complete=not budget.reasons, truncated=bool(budget.reasons),
                    stopped_reasons=sorted(budget.reasons), coverage=coverage,
                    downloadable_artifact=False, unit_offset=budget.unit_offset, text_offset=budget.text_offset,
                    next_unit_offset=budget.next[0] if budget.next else None,
                    next_text_offset=budget.next[1] if budget.next else None)

    def encoded_size():
        return len(json.dumps(result(), ensure_ascii=False, separators=(",", ":")).encode("utf-8"))

    if encoded_size() > MAX_RESULT_BYTES:
        budget.reasons.add("output_budget")
        while budget.units:
            unit = budget.units[-1]
            raw = unit["text"].encode("utf-8")
            unit["text"] = ""
            if encoded_size() > MAX_RESULT_BYTES:
                budget.trim_last(0)
                budget.units.pop()
                continue
            low, high = 0, len(raw)
            while low < high:
                middle = (low + high + 1) // 2
                unit["text"] = raw[:middle].decode("utf-8", errors="ignore")
                if encoded_size() <= MAX_RESULT_BYTES:
                    low = middle
                else:
                    high = middle - 1
            unit["text"] = raw[:low].decode("utf-8", errors="ignore")
            budget.trim_last(len(unit["text"].encode("utf-8")))
            break
    return result()

def extract_document(artifact, *, pdf_helper=None, unit_offset=1, text_offset=0):
    """Parse one immutable VerifiedFile returned by the trusted download bridge.

    pdf_helper is a composition-time trusted path. No request, archive part,
    filename, URL or document content is ever interpreted as a command.
    """
    if type(artifact) is not VerifiedFile:
        fail("verified_file_required")
    artifact.check(max_bytes=MAX_DOCUMENT_BYTES)
    with tempfile.TemporaryFile() as file:
        file.write(artifact.data)
        file.flush()
        return extract_document_file(VerifiedDownloadFile(artifact.name, len(artifact.data), artifact.sha256, file.fileno()),
                                     pdf_helper=pdf_helper, unit_offset=unit_offset, text_offset=text_offset)


def extract_document_file(artifact, *, pdf_helper=None, unit_offset=1, text_offset=0):
    """Parse an exact, already verified seekable spool without copying input to memory."""
    if type(artifact) is not VerifiedDownloadFile:
        fail("verified_file_required")
    basename(artifact.name)
    info = os.fstat(artifact.fd)
    if not stat.S_ISREG(info.st_mode) or info.st_size != artifact.size:
        fail("verified_file_required")
    kind = Path(artifact.name).suffix.lower().lstrip(".")
    if kind not in DOCUMENT_FORMATS:
        fail("unsupported_document_format")
    budget = Budget(unit_offset, text_offset)
    with os.fdopen(os.dup(artifact.fd), "rb") as file:
        file.seek(0)
        if kind == "pdf":
            coverage = pdf(file, pdf_helper, budget)
        elif kind in OFFICE_FORMATS:
            coverage = office(file, OFFICE_FORMATS[kind], budget)
        elif kind in LEGACY_WORD_FORMATS:
            coverage = legacy_word(file, kind, budget)
        elif kind in {"html", "htm"}:
            coverage = html(file, budget)
        else:
            text_lines(file, budget)
            coverage = "decoded_text_lines; data_preserved_as_text"
    return bounded_result(artifact, kind, coverage, budget)


def extract_download(result, *, expected, call, verify, pdf_helper=None, clock=time.monotonic):
    """Host seam: unchanged Mio download validation, then bounded local parsing.

    The trusted host supplies the original live-binding verifier and tool-call
    adapter. No retry, reconnect, NAS write, new scope or publication occurs.
    Revocation while parsing withholds the derived text.
    """
    with collect_download_file(result, expected=expected, call=call, verify=verify, clock=clock) as artifact:
        verify()
        result = extract_document_file(artifact, pdf_helper=pdf_helper)
        verify()
        return result
