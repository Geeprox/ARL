"""Document parsing within the existing live NAS read session; no new authority."""
import json
from pathlib import Path
import tempfile

from homeplane.nas_connection.contracts import NASConnectionError, file_request
from integrations.nas.attachment_bridge import VerifiedDownloadFile, BridgeFault, basename
from integrations.nas.document_text import DOCUMENT_FORMATS, DocumentFault, extract_document_file, MAX_DOCUMENT_BYTES

FIELDS = {"operation","source_ref","config_generation","connection_epoch","object_ref","revision","size","name"}


def request(value):
    if (type(value) is not dict or not FIELDS.issubset(value) or set(value) - FIELDS - {"unit_offset","text_offset"} or value["operation"] != "read_document"
            or type(value["size"]) is not int or not 0 <= value["size"] <= MAX_DOCUMENT_BYTES):
        raise NASConnectionError("nas_invalid_request")
    if any(type(value.get(k, default)) is not int or value.get(k, default) < default for k, default in (("unit_offset",1),("text_offset",0))):
        raise NASConnectionError("nas_invalid_request")
    try:
        basename(value["name"])
    except (BridgeFault, KeyError):
        raise NASConnectionError("nas_invalid_request") from None
    raw = {k: value[k] for k in ("source_ref","config_generation","connection_epoch","object_ref","revision")}
    file_request(dict(raw, operation="read", offset=0, length=1))
    return dict(value)


def failure(code):
    return dict(schema_version=1, operation="read_document", state="failed",
                error={"code":code}, automatic_replay=False)


def fit_frame(value):
    # Text was already paged against UTF8 JSON before this identity envelope.
    if len(json.dumps(value, ensure_ascii=False).encode()) > 196608:
        raise NASConnectionError("nas_budget_exceeded")
    return value


async def execute(host, value, validate):
    value = request(value)
    reference = {k:value[k] for k in FIELDS - {"operation","name"}}
    if Path(value["name"]).suffix.lower().lstrip(".") not in DOCUMENT_FORMATS:
        return failure("unsupported_document_format")
    manager = host.connection.manager
    if Path(manager._path(reference["object_ref"])).name != value["name"]:
        return failure("nas_name_mismatch")
    helper = getattr(host, "document_pdf_helper",
                     Path(__file__).resolve().parent.parent / "Tools/NASPDFTextExtractor")
    with tempfile.TemporaryFile(prefix="arl-nas-document-") as file:
        entry, sha256 = await manager.spool_file(reference, file)
        await validate()
        try:
            result = extract_document_file(VerifiedDownloadFile(value["name"], value["size"], sha256, file.fileno()),
                                           pdf_helper=helper, unit_offset=value.get("unit_offset",1),
                                           text_offset=value.get("text_offset",0))
        except (DocumentFault, BridgeFault) as error:
            await validate()
            return failure(error.code)
    await validate()
    result.update(operation="read_document", source_ref=value["source_ref"],
                  config_generation=value["config_generation"], connection_epoch=value["connection_epoch"],
                  object_ref=value["object_ref"], revision=value["revision"], entry=entry,
                  snapshot_consistent=False,
                  location=manager._file_envelope("read_document",
                    (value["config_generation"],value["connection_epoch"]))["location"])
    return fit_frame(result)
