#!/usr/bin/env python3
"""Offline exact-username contact remarks and referenced-person projection.

Reads an explicit plaintext contact snapshot, or authenticates/decrypts an
explicit contact.db using its existing saved raw key. Never invokes WeChat,
wx-cli, process access or network. Full contact results are private; enrich_*
adds only already-referenced persons' display metadata to an archive copy.
"""
from __future__ import annotations

import argparse
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import sys
import tempfile

import local_sns_snapshot as snapshot_codec


FORMAT = "moments-contact-names-private-v1"
PRIVATE_ROOT = Path(__file__).resolve().parents[2] / "work/contacts/private"


class ContactNamesError(ValueError):
    """Stable errors must not contain keys, contact values or source paths."""


def _name(value):
    return value if isinstance(value, str) and value.strip() else None


def _mapping(mapping):
    if isinstance(mapping, dict) and mapping.get("format") == FORMAT:
        mapping = mapping.get("contacts")
    if not isinstance(mapping, dict):
        raise ContactNamesError("contact_mapping_not_object")
    return mapping


def load_saved_contact_key(keys_file):
    """Select one explicit contact.db key; never derive or expose its value."""
    try:
        values = json.loads(Path(keys_file).read_text(encoding="utf-8"))
        if not isinstance(values, dict):
            raise ContactNamesError("saved_key_mapping_invalid")
        selected = [item for name, item in values.items()
                    if isinstance(name, str) and Path(name).name.lower() == "contact.db"]
        if len(selected) != 1:
            raise ContactNamesError("saved_contact_key_not_unique")
        encoded = selected[0].get("enc_key") if isinstance(selected[0], dict) else None
        if not isinstance(encoded, str) or len(encoded) != 64:
            raise ContactNamesError("saved_contact_key_not_32_bytes")
        value = bytes.fromhex(encoded)
        if len(value) != 32:
            raise ContactNamesError("saved_contact_key_not_32_bytes")
        return value
    except (OSError, UnicodeError, ValueError) as error:
        if isinstance(error, ContactNamesError):
            raise
        raise ContactNamesError("saved_contact_key_unreadable_or_invalid") from None


def read_contact_names(contacts_db):
    """Read only the proven contact(username,remark,nick_name) columns.

    The input is a quiescent plaintext snapshot; immutable mode never creates
    SQLite journals or opens the source WeChat database for SQLite writes.
    Aliases, encrypted usernames, display-name similarity and chat-room names
    are never identity keys. Conflicting exact usernames are withheld.
    """
    path = Path(contacts_db).resolve()
    if not path.is_file():
        raise ContactNamesError("contact_snapshot_missing")
    try:
        connection = sqlite3.connect(path.as_uri() + "?mode=ro&immutable=1", uri=True)
        try:
            if connection.execute("PRAGMA integrity_check").fetchall() != [("ok",)]:
                raise ContactNamesError("contact_snapshot_integrity_failed")
            schema = connection.execute('PRAGMA table_info("contact")').fetchall()
            columns = {row[1] for row in schema}
            if not {"username", "remark", "nick_name"}.issubset(columns):
                raise ContactNamesError("contact_snapshot_schema_unsupported")
            rows = connection.execute('SELECT username,remark,nick_name FROM "contact"')
            contacts, conflicts = {}, set()
            total, skipped = 0, 0
            for username, remark, nickname in rows:
                total += 1
                if not isinstance(username, str) or not username or username != username.strip():
                    skipped += 1
                    continue
                if remark is not None and not isinstance(remark, str):
                    raise ContactNamesError("contact_remark_not_text")
                if nickname is not None and not isinstance(nickname, str):
                    raise ContactNamesError("contact_nickname_not_text")
                item = {"remark": _name(remark), "nickname": _name(nickname)}
                if username in conflicts:
                    continue
                if username in contacts and contacts[username] != item:
                    contacts.pop(username)
                    conflicts.add(username)
                else:
                    contacts[username] = item
            return {"format": FORMAT,
                    "source": {"file_name": path.name, "schema": "contact(username,remark,nick_name)",
                               "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                               "sqlite_integrity_check": "ok", "read_only": True},
                    "summary": {"source_rows": total, "mapped_usernames": len(contacts),
                                "nonempty_remarks": sum(item["remark"] is not None for item in contacts.values()),
                                "conflicting_usernames_withheld": len(conflicts),
                                "invalid_usernames_skipped": skipped},
                    "contacts": contacts}
        finally:
            connection.close()
    except sqlite3.Error:
        raise ContactNamesError("contact_snapshot_read_failed") from None


def snapshot_contact_database(source, keys_file, output):
    """Reuse authenticated SQLCipher/WAL primitives without changing SNS checks."""
    source, keys_file, output = (Path(value).resolve() for value in (source, keys_file, output))
    if source.name.lower() != "contact.db":
        raise ContactNamesError("explicit_contact_database_required")
    if output in (source, Path(str(source) + "-wal"), Path(str(source) + "-shm"), keys_file):
        raise ContactNamesError("contact_output_must_not_replace_input")
    key = load_saved_contact_key(keys_file)
    database, wal, stable = snapshot_codec.capture(source)
    plaintext, crypto = snapshot_codec.reconstruct(database, wal, key)
    output.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor, name = tempfile.mkstemp(prefix=".verified-contact-", dir=output.parent)
    candidate = Path(name)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(plaintext)
            stream.flush()
            os.fsync(stream.fileno())
        # Contact validation is intentionally separate from validate_snapshot,
        # which must continue requiring SnsTimeLine for SNS exports.
        mapping = read_contact_names(candidate)
        if (snapshot_codec._path_identity(source) != tuple(stable["database_stat"])
                or snapshot_codec._path_identity(Path(str(source) + "-wal")) !=
                (tuple(stable["wal_stat"]) if stable["wal_stat"] else None)):
            raise ContactNamesError("contact_source_changed_before_publish")
        os.replace(candidate, output)
        mapping["source"]["file_name"] = output.name
        mapping["source"].update({"encrypted_source_file_name": source.name,
                                 "encrypted_source_sha256": hashlib.sha256(database).hexdigest(),
                                 "key_scope": "one_saved_contact_raw_key_not_exported",
                                 "source_write_performed": False, "network_used": False,
                                 "source_stability": stable, "crypto": crypto})
        return mapping
    finally:
        if candidate.exists():
            candidate.unlink()


def _identity(username, contacts, *, original_nickname=None):
    # Dictionary lookup is exact/case-sensitive. Never fall back to nickname,
    # alias, substring, lowercased username or a hash guessed from a nickname.
    record = contacts.get(username) if isinstance(username, str) else None
    record = record if isinstance(record, dict) else {}
    remark, contact_nickname = _name(record.get("remark")), _name(record.get("nickname"))
    for value, source in ((remark, "contact_remark"), (_name(original_nickname), "original_nickname"),
                          (contact_nickname, "contact_nickname"), (_name(username), "username")):
        if value is not None:
            return value, source, remark, contact_nickname
    return None, "not_available", remark, contact_nickname


def enrich_person(item, mapping):
    """Return a copy; preserve original nickname and append referenced names."""
    if not isinstance(item, dict):
        raise ContactNamesError("person_not_object")
    contacts = _mapping(mapping)
    result = copy.deepcopy(item)
    name, source, remark, nickname = _identity(item.get("username"), contacts,
                                               original_nickname=item.get("nickname"))
    result.update(remark=remark, contact_nickname=nickname,
                  display_name=name, display_name_source=source)
    reference = item.get("ref_username")
    if isinstance(reference, str) and reference:
        name, source, _, _ = _identity(reference, contacts)
        result.update(ref_display_name=name, ref_display_name_source=source)
    else:
        # Previously-enriched copies must not retain a stale reference name.
        result.pop("ref_display_name", None)
        result.pop("ref_display_name_source", None)
    return result


def enrich_document(document, mapping):
    """Project only referenced people in current posts and retained revisions.

    Supports local moments.json's likes/comments.items and independent archive
    fields' list form. Never publishes the complete contact mapping.
    """
    contacts = _mapping(mapping)
    result = copy.deepcopy(document)

    def enrich_post(post):
        if not isinstance(post, dict):
            return
        for kind in ("likes", "comments"):
            value = post.get(kind)
            if isinstance(value, dict) and isinstance(value.get("items"), list):
                value["items"] = [enrich_person(person, contacts) for person in value["items"]]
            elif isinstance(value, list):
                post[kind] = [enrich_person(person, contacts) for person in value]

    for post in result.get("posts", []):
        enrich_post(post)
    for change in result.get("changes", []):
        enrich_post(change.get("snapshot"))
    for obj in result.get("objects", []):
        enrich_post(obj.get("fields"))
    for revision in result.get("revisions", []):
        enrich_post(revision.get("observation", {}).get("fields"))
    return result


def contact_usage_summary(document, mapping):
    """Count current referenced people only; no names or full mapping emitted.

    Retained changes/revisions are intentionally excluded from usage totals to
    avoid counting the same observed interaction multiple times.
    """
    contacts = _mapping(mapping)
    posts = document.get("posts")
    if not isinstance(posts, list):
        posts = [obj.get("fields", {}) for obj in document.get("objects", [])]
    users, references = set(), set()
    result = {"matching": "exact_case_sensitive_username_only", "posts": len(posts),
              "reference_records": 0, "reference_exact_contact_matches": 0,
              "reference_remark_display_records": 0}
    for kind in ("likes", "comments"):
        counts = {"person_records": 0, "exact_contact_matches": 0, "remark_display_records": 0}
        for post in posts:
            value = post.get(kind)
            items = value.get("items") if isinstance(value, dict) else value
            for person in items if isinstance(items, list) else []:
                username = person.get("username")
                if isinstance(username, str) and username:
                    users.add(username)
                counts["person_records"] += 1
                counts["exact_contact_matches"] += isinstance(username, str) and username in contacts
                counts["remark_display_records"] += _identity(username, contacts)[1] == "contact_remark"
                reference = person.get("ref_username")
                if isinstance(reference, str) and reference:
                    references.add(reference)
                    result["reference_records"] += 1
                    result["reference_exact_contact_matches"] += reference in contacts
                    result["reference_remark_display_records"] += _identity(reference, contacts)[1] == "contact_remark"
        result[kind] = counts
    result.update(unique_person_usernames=len(users),
                  unique_exact_contact_matches=sum(username in contacts for username in users),
                  unique_remarked_people=sum(_identity(username, contacts)[1] == "contact_remark" for username in users),
                  unique_reference_usernames=len(references))
    return result


def _private_output(path):
    path = Path(path).resolve()
    if not path.is_relative_to(PRIVATE_ROOT.resolve()):
        raise ContactNamesError("contact_output_requires_work_contacts_private")
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(path.parent, 0o700)
    return path


def _crypto_runtime():
    if importlib.util.find_spec("cryptography") is not None:
        return
    raise ContactNamesError("existing_cryptography_runtime_required")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    inputs = parser.add_mutually_exclusive_group(required=True)
    inputs.add_argument("--contacts-db", type=Path, help="explicit quiescent plaintext snapshot")
    inputs.add_argument("--source", type=Path, help="explicit encrypted contact.db")
    parser.add_argument("--keys-file", type=Path)
    parser.add_argument("--snapshot-output", type=Path, default=PRIVATE_ROOT / "contact.sqlite3")
    parser.add_argument("--output", type=Path, default=PRIVATE_ROOT / "contact-names.json")
    args = parser.parse_args(argv)
    if bool(args.source) != bool(args.keys_file):
        parser.error("--keys-file is required only with --source")
    try:
        output = _private_output(args.output)
        if args.source:
            protected = {args.source.resolve(), args.keys_file.resolve(),
                         Path(str(args.source.resolve()) + "-wal"), Path(str(args.source.resolve()) + "-shm")}
            snapshot_output = _private_output(args.snapshot_output)
            if output in protected or output == snapshot_output:
                raise ContactNamesError("contact_output_must_not_replace_input")
            _crypto_runtime()
            mapping = snapshot_contact_database(args.source, args.keys_file, snapshot_output)
        else:
            if output == args.contacts_db.resolve():
                raise ContactNamesError("contact_output_must_not_replace_input")
            mapping = read_contact_names(args.contacts_db)
        snapshot_codec._private_write(output, (json.dumps(mapping, ensure_ascii=False, indent=2) + "\n").encode())
        print(json.dumps({"status": "ok", **mapping["summary"], "network_used": False,
                          "source_write_performed": False}))
        return 0
    except (ContactNamesError, snapshot_codec.SnapshotError, OSError, ValueError) as error:
        code = str(error) if isinstance(error, (ContactNamesError, snapshot_codec.SnapshotError)) else "contact_local_io_error"
        print(json.dumps({"status": "failed", "error_code": code, "network_used": False,
                          "source_write_performed": False}))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
