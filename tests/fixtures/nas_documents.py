"""Deterministic synthetic documents; no user content or external download."""
from __future__ import annotations
import io
from pathlib import Path
import zipfile

W = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
S = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
P = "http://schemas.openxmlformats.org/presentationml/2006/main"
A = "http://schemas.openxmlformats.org/drawingml/2006/main"
R = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
REL = "http://schemas.openxmlformats.org/package/2006/relationships"


def archive(parts):
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w") as target:
        for name, value in sorted(parts.items()):
            info = zipfile.ZipInfo(name, (2026, 10, 24, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            target.writestr(info, value.encode() if isinstance(value, str) else value)
    return output.getvalue()


def package(parts, main, kind):
    content = {
        "word": "wordprocessingml.document",
        "xl": "spreadsheetml.sheet",
        "ppt": "presentationml.presentation",
    }[kind]
    parts = dict(parts)
    content_types = {
        "word/header": "wordprocessingml.header",
        "xl/worksheets/": "spreadsheetml.worksheet",
        "xl/sharedStrings.xml": "spreadsheetml.sharedStrings",
        "ppt/slides/": "presentationml.slide",
        "ppt/notesSlides/": "presentationml.notesSlide",
    }
    overrides = "".join(
        f'<Override PartName="/{name}" ContentType="application/vnd.openxmlformats-officedocument.{value}+xml"/>'
        for name in parts for prefix, value in content_types.items() if name.startswith(prefix))
    parts["[Content_Types].xml"] = (
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        f'<Override PartName="/{main}" ContentType="application/vnd.openxmlformats-officedocument.{content}.main+xml"/>'
        + overrides + '</Types>')
    parts["_rels/.rels"] = f'<Relationships xmlns="{REL}"><Relationship Id="main" Type="{R}/officeDocument" Target="{main}"/></Relationships>'
    return archive(parts)


def docx(body=None):
    body = body if body is not None else (
        '<w:p><w:r><w:t>ARL DOCX fixture</w:t></w:r></w:p>'
        '<w:p><w:r><w:t>你好</w:t><w:tab/><w:t>世界</w:t><w:br/><w:t>Version: 1</w:t></w:r></w:p>'
        '<w:tbl><w:tr><w:tc><w:p><w:r><w:t>表格：样例</w:t></w:r></w:p></w:tc></w:tr></w:tbl>')
    return package({
        "word/document.xml": f'<w:document xmlns:w="{W}"><w:body>{body}</w:body></w:document>',
        "word/header1.xml": f'<w:hdr xmlns:w="{W}"><w:p><w:r><w:t>HEADER EXCLUDED</w:t></w:r></w:p></w:hdr>',
    }, "word/document.xml", "word")


def xlsx():
    return package({
        "xl/workbook.xml": f'<workbook xmlns="{S}" xmlns:r="{R}"><sheets><sheet name="Fixture" sheetId="2" r:id="second"/><sheet name="隐藏页" state="hidden" sheetId="1" r:id="first"/></sheets></workbook>',
        "xl/_rels/workbook.xml.rels": f'<Relationships xmlns="{REL}"><Relationship Id="first" Type="{R}/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="second" Type="{R}/worksheet" Target="worksheets/sheet2.xml"/></Relationships>',
        "xl/sharedStrings.xml": f'<sst xmlns="{S}"><si><t>ARL XLSX fixture</t></si><si><r><t>你</t></r><r><t>好</t></r></si></sst>',
        "xl/worksheets/sheet1.xml": f'<worksheet xmlns="{S}"><sheetData><row r="1"><c r="A1" t="s"><v>1</v></c></row></sheetData></worksheet>',
        "xl/worksheets/sheet2.xml": f'<worksheet xmlns="{S}"><sheetData><row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="inlineStr"><is><t>原文🙂</t></is></c><c r="C1"><v>12.500</v></c><c r="D1"><f>1+2</f><v>3</v></c><c r="E1"><f>NOW()</f></c></row></sheetData></worksheet>',
    }, "xl/workbook.xml", "xl")


def pptx():
    def slide(text):
        return f'<p:sld xmlns:p="{P}" xmlns:a="{A}"><p:cSld><p:spTree><p:sp><p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:t>{text}</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>'
    return package({
        "ppt/presentation.xml": f'<p:presentation xmlns:p="{P}" xmlns:r="{R}"><p:sldIdLst><p:sldId id="256" r:id="ten"/><p:sldId id="257" r:id="two"/></p:sldIdLst></p:presentation>',
        "ppt/_rels/presentation.xml.rels": f'<Relationships xmlns="{REL}"><Relationship Id="ten" Type="{R}/slide" Target="slides/slide10.xml"/><Relationship Id="two" Type="{R}/slide" Target="slides/slide2.xml"/></Relationships>',
        "ppt/slides/slide10.xml": slide("ARL PPTX fixture 第一张"),
        "ppt/slides/slide2.xml": slide("第二张"),
        "ppt/notesSlides/notesSlide1.xml": f'<p:notes xmlns:p="{P}" xmlns:a="{A}"><a:p><a:r><a:t>NOTES EXCLUDED</a:t></a:r></a:p></p:notes>',
    }, "ppt/presentation.xml", "ppt")


def pdf(*, pages=1, image=False, blank=False):
    font_id = 3 + 2 * pages
    image_id = font_id + 1
    objects = [
        b'<< /Type /Catalog /Pages 2 0 R >>',
        ('<< /Type /Pages /Count ' + str(pages) + ' /Kids [' + ' '.join(f'{3+2*i} 0 R' for i in range(pages)) + '] >>').encode(),
    ]
    for index in range(pages):
        resources = f'/Font << /F1 {font_id} 0 R >>' + (f' /XObject << /Im1 {image_id} 0 R >>' if image else '')
        objects.append(f'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << {resources} >> /Contents {4+2*index} 0 R >>'.encode())
        if image:
            stream = b'q 200 0 0 200 72 400 cm /Im1 Do Q'
        elif blank:
            stream = b''
        else:
            stream = f'BT /F1 12 Tf 72 720 Td (ARL PDF fixture page {index+1}) Tj 0 -18 Td (Version: 1) Tj ET'.encode()
        objects.append(f'<< /Length {len(stream)} >>\nstream\n'.encode() + stream + b'\nendstream')
    objects.append(b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>')
    if image:
        objects.append(b'<< /Type /XObject /Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8 /Length 1 >>\nstream\n\x80\nendstream')
    result = bytearray(b'%PDF-1.4\n')
    offsets = [0]
    for number, value in enumerate(objects, 1):
        offsets.append(len(result))
        result.extend(f'{number} 0 obj\n'.encode() + value + b'\nendobj\n')
    start = len(result)
    result.extend(f'xref\n0 {len(objects)+1}\n0000000000 65535 f \n'.encode())
    for offset in offsets[1:]:
        result.extend(f'{offset:010d} 00000 n \n'.encode())
    result.extend(f'trailer\n<< /Size {len(objects)+1} /Root 1 0 R >>\nstartxref\n{start}\n%%EOF\n'.encode())
    return bytes(result)


def fixtures():
    return {"arl-document-fixture.pdf": pdf(), "arl-document-fixture.docx": docx(),
            "arl-document-fixture.xlsx": xlsx(), "arl-document-fixture.pptx": pptx()}


def write_fixtures(directory):
    directory = Path(directory)
    directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    for name, raw in fixtures().items():
        with (directory / name).open("xb") as output:
            output.write(raw)
