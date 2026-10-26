"""Emit actual private-host results for Swift owner/Mio integration; synthetic transport only."""
import asyncio
import json
from tests.test_nas_document_host import DocumentHostTests
from tests.fixtures import nas_documents

async def cases():
    rows = []
    for kind in ("pdf", "docx", "xlsx", "pptx"):
        test = DocumentHostTests()
        await test.asyncSetUp()
        try:
            args, result = await test.check_format(kind)
            rows.append(dict(format=kind, arguments={k:v for k,v in args.items() if k != "operation"},
                             wire=args, reply=result))
        finally:
            await test.asyncTearDown()
    test = DocumentHostTests()
    await test.asyncSetUp()
    try:
        args = await test.prepare(b"invalid PDF", "fixture.pdf")
        result = await test.call(args)
        rows.append(dict(format="invalid_pdf", arguments={k:v for k,v in args.items() if k != "operation"},
                         wire=args, reply=result))
    finally:
        await test.asyncTearDown()
    return rows

if __name__ == "__main__":
    print(json.dumps(asyncio.run(cases()), ensure_ascii=False, sort_keys=True))
