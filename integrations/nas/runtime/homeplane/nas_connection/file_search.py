"""Candidate scoped recursive filename search and UTF-8 content reader.

Not registered or activated. The owner must inject its existing, live, saved-scope
file_operation and a context validator; neither callback may reconnect/restore a
scope. No paths/credentials/network/publisher are accepted here. This adapter
uses only existing list/read DTOs; the manager remains the SMB authority.
"""
from __future__ import annotations

import base64
import codecs
from collections import deque
from dataclasses import dataclass, field
import hashlib
import json
import re
import time
import unicodedata
import uuid

from .contracts import NASConnectionError, FILE_OUTPUT, file_request, relative_path


@dataclass
class _Scan:
    binding: tuple
    deadline: float
    queue: deque
    pending: deque = field(default_factory=deque)
    seen: set = field(default_factory=set)
    reasons: set = field(default_factory=set)
    pages: int = 0
    scanned: int = 0


def _ref(value):
    return isinstance(value, str) and re.fullmatch('[a-f0-9]{64}', value) is not None


def _invalid():
    raise NASConnectionError('nas_invalid_request')


class ScopedFileReader:
    """One immutable source/epoch; all limits bound both work and saved cursors.

    Search: BFS within known directory references, 4 list calls per reply, 64
    calls/2048 entries/128 directories/depth 8 per scan, 32 results per reply,
    eight single-use cursors at most, absolute 120s scan expiry. No snapshot is
    promised. Read: original bytes plus strict UTF-8 prefix, max 64KiB output
    bytes, using 32KiB manager range reads and its existing cumulative budget.
    """
    def __init__(self, *, source_ref, config_generation, connection_epoch,
                 operation, validate_context, clock=time.monotonic):
        if (not isinstance(source_ref, str) or not re.fullmatch('[A-Za-z0-9_-]{1,96}', source_ref)
                or type(config_generation) is not int or not 1 <= config_generation <= 2**63 - 1
                or not isinstance(connection_epoch, str)
                or not re.fullmatch('[a-f0-9]{32}', connection_epoch)
                or not callable(operation) or not callable(validate_context)):
            _invalid()
        self.fence = (source_ref, config_generation, connection_epoch)
        self.operation, self.validate_context, self.clock = operation, validate_context, clock
        self._cursors = {}
        self._active = False

    async def _validate(self):
        # Explicit True required: absent/unknown permission is not authority.
        if await self.validate_context(*self.fence) is not True:
            raise NASConnectionError('nas_source_changed')

    async def _call(self, request):
        await self._validate()
        result = await self.operation(request)
        await self._validate()
        if (not isinstance(result, dict) or
                tuple(result.get(k) for k in ('source_ref', 'config_generation', 'connection_epoch')) != self.fence
                or result.get('operation') != request['operation']):
            raise NASConnectionError('nas_source_changed')
        return result

    def _enter(self):
        if self._active:
            raise NASConnectionError('nas_busy')
        self._active = True

    async def search_page(self, *, keyword, directory_ref=None, recursive=False, limit=32, cursor=None):
        # Reuse the published keyword/directory/limit validation. Recursive is an
        # explicit candidate option, never a new share/root selector.
        arguments = dict(operation='search', keyword=keyword, limit=limit)
        if directory_ref is not None: arguments['directory_ref'] = directory_ref
        request = file_request(arguments)
        if type(recursive) is not bool or cursor is not None and (
                not isinstance(cursor, str) or not re.fullmatch('[a-f0-9]{32}', cursor)):
            _invalid()
        self._enter()
        try:
            await self._validate()
            now = self.clock()
            self._cursors = {k: v for k, v in self._cursors.items() if v.deadline > now}
            binding = (keyword, directory_ref, recursive, limit)
            if cursor is not None:
                state = self._cursors.pop(cursor, None)
                if state is None or state.binding != binding:
                    raise NASConnectionError('nas_cursor_expired')
            else:
                state = _Scan(binding, now + 120, deque([(directory_ref, 0, None)]), seen={directory_ref})
            match = unicodedata.normalize('NFC', request['keyword']).casefold()
            entries, pages, scanned = [], 0, 0
            while len(entries) < limit:
                if state.pending:
                    if len(json.dumps(entries + [state.pending[0]], ensure_ascii=True).encode()) > FILE_OUTPUT - 16384:
                        break
                    entries.append(state.pending.popleft())
                    continue
                if not state.queue or pages >= 4:
                    break
                if self.clock() >= state.deadline:
                    raise NASConnectionError('nas_cursor_expired')
                directory, depth, provider_cursor = state.queue.popleft()
                arguments = dict(operation='list', limit=32)
                if directory is not None: arguments['directory_ref'] = directory
                if provider_cursor is not None:
                    arguments['cursor'] = provider_cursor
                page = await self._call(arguments)
                rows, next_cursor = page.get('entries'), page.get('next_cursor')
                if (not isinstance(rows, list) or len(rows) > 32
                        or type(page.get('enumeration_complete')) is not bool
                        or next_cursor is not None and (not isinstance(next_cursor, str)
                            or not re.fullmatch('[a-f0-9]{32}', next_cursor))
                        or page['enumeration_complete'] and next_cursor is not None):
                    raise NASConnectionError('nas_transport_failed')
                pages += 1; state.pages += 1
                scanned += len(rows); state.scanned += len(rows)
                if next_cursor is not None:
                    state.queue.appendleft((directory, depth, next_cursor))
                elif page['enumeration_complete'] is not True:
                    state.reasons.add('provider_incomplete')
                for entry in rows:
                    if (not isinstance(entry, dict) or not _ref(entry.get('object_ref'))
                            or not _ref(entry.get('revision')) or entry.get('kind') not in {'file', 'directory'}
                            or type(entry.get('size')) is not int or entry['size'] < 0):
                        raise NASConnectionError('nas_transport_failed')
                    path = relative_path(entry.get('path'))
                    if entry['kind'] == 'file':
                        if match in unicodedata.normalize('NFC', path.rsplit('/', 1)[-1]).casefold():
                            state.pending.append(dict(entry))
                    elif recursive and entry['object_ref'] not in state.seen:
                        state.seen.add(entry['object_ref'])
                        state.queue.append((entry['object_ref'], depth + 1, None))
            await self._validate()
            if self.clock() >= state.deadline:
                raise NASConnectionError('nas_cursor_expired')
            next_cursor = None
            if state.pending or state.queue:
                if self.clock() >= state.deadline:
                    raise NASConnectionError('nas_cursor_expired')
                if len(self._cursors) >= 8:
                    raise NASConnectionError('nas_budget_exceeded')
                next_cursor = uuid.uuid4().hex
                self._cursors[next_cursor] = state
            complete = next_cursor is None and not state.reasons
            return dict(schema_version=1, operation='search', source_ref=self.fence[0],
                        config_generation=self.fence[1], connection_epoch=self.fence[2],
                        directory_ref=directory_ref, keyword=keyword, recursive=recursive,
                        match_mode='nfc_casefold_basename_contains', entries=entries,
                        next_cursor=next_cursor, enumeration_complete=complete, partial=not complete,
                        snapshot_consistent=False, scanned_count=scanned, pages=pages,
                        total_scanned_count=state.scanned, total_pages=state.pages,
                        stopped_reasons=sorted(state.reasons),
                        stopped_reason=None if complete else sorted(state.reasons)[0] if state.reasons
                            else 'result_budget' if state.pending else 'page_budget')
        finally:
            self._active = False

    async def read_complete(self, reference, *, max_bytes=1048576):
        """Exact bounded bytes for document parsing, through unchanged range admission."""
        keys = {'source_ref', 'config_generation', 'connection_epoch', 'object_ref', 'revision', 'size'}
        if (not isinstance(reference, dict) or set(reference) != keys
                or type(max_bytes) is not int or not 1 <= max_bytes <= 32 * 1024 * 1024
                or type(reference.get('size')) is not int or not 0 <= reference['size'] <= max_bytes
                or tuple(reference.get(k) for k in ('source_ref', 'config_generation', 'connection_epoch')) != self.fence):
            _invalid()
        base = {k: v for k, v in reference.items() if k != 'size'}
        file_request(dict(base, operation='read', offset=0, length=1))
        self._enter()
        try:
            await self._validate()
            raw = bytearray(); size = reference['size']; entry = None
            # Empty files still require an exact stat/read/stat via the manager.
            while not raw or len(raw) < min(size, max_bytes):
                offset = len(raw); length = max(1, min(32768, min(size, max_bytes) - offset))
                result = await self._call(dict(base, operation='read', offset=offset, length=length))
                row = result.get('entry')
                if (not isinstance(row, dict) or row.get('object_ref') != base['object_ref']
                        or row.get('revision') != base['revision'] or row.get('size') != size
                        or row.get('kind') != 'file' or entry is not None and row != entry):
                    raise NASConnectionError('nas_revision_changed')
                entry = row
                try:
                    encoded = result['data_base64']; chunk = base64.b64decode(encoded, validate=True)
                    canonical = base64.b64encode(chunk).decode() == encoded
                except (ValueError, KeyError, TypeError):
                    raise NASConnectionError('nas_transport_failed') from None
                end = offset + len(chunk); eof = end == size
                if (not canonical or len(chunk) != min(length, size - offset)
                        or type(result.get('bytes_read')) is not int or result['bytes_read'] != len(chunk)
                        or type(result.get('offset')) is not int or result['offset'] != offset
                        or type(result.get('length')) is not int or result['length'] != length
                        or result.get('eof') is not eof
                        or result.get('next_offset') != (None if eof else end)
                        or not eof and type(result.get('next_offset')) is not int):
                    raise NASConnectionError('nas_transport_failed')
                raw.extend(chunk)
                if eof: break
            await self._validate()
            return bytes(raw), entry
        finally:
            self._active = False

    async def read_utf8(self, reference, *, max_bytes=65536, offset=0):
        """Read one resumable byte range, preserving valid UTF-8 boundaries.

        A prefix is explicit (complete=False). Invalid UTF-8/NUL yields no text,
        retaining the raw bytes for the original binary path. No DOCX/PDF parser
        or content search is implied; no replacement decoding or attachment URL.
        """
        keys = {'source_ref', 'config_generation', 'connection_epoch', 'object_ref', 'revision', 'size'}
        if (not isinstance(reference, dict) or set(reference) != keys
                or type(max_bytes) is not int or not 1 <= max_bytes <= 65536
                or type(reference.get('size')) is not int or not 0 <= reference['size'] <= 2**63 - 1
                or type(offset) is not int or not 0 <= offset <= reference['size']
                or tuple(reference.get(k) for k in ('source_ref', 'config_generation', 'connection_epoch')) != self.fence):
            _invalid()
        base = {k: v for k, v in reference.items() if k != 'size'}
        file_request(dict(base, operation='read', offset=0, length=1))
        start_offset = offset
        self._enter()
        try:
            await self._validate()
            raw = bytearray(); size = reference['size']; entry = None
            # Empty files still require an exact stat/read/stat via the manager.
            while not raw or len(raw) < min(size-start_offset, max_bytes):
                offset = start_offset + len(raw); length = max(1, min(32768, min(size-start_offset, max_bytes) - len(raw)))
                result = await self._call(dict(base, operation='read', offset=offset, length=length))
                row = result.get('entry')
                if (not isinstance(row, dict) or row.get('object_ref') != base['object_ref']
                        or row.get('revision') != base['revision'] or row.get('size') != size
                        or row.get('kind') != 'file' or entry is not None and row != entry):
                    raise NASConnectionError('nas_revision_changed')
                entry = row
                try:
                    encoded = result['data_base64']; chunk = base64.b64decode(encoded, validate=True)
                    canonical = base64.b64encode(chunk).decode() == encoded
                except (ValueError, KeyError, TypeError):
                    raise NASConnectionError('nas_transport_failed') from None
                end = offset + len(chunk); eof = end == size
                if (not canonical or len(chunk) != min(length, size - offset)
                        or type(result.get('bytes_read')) is not int or result['bytes_read'] != len(chunk)
                        or type(result.get('offset')) is not int or result['offset'] != offset
                        or type(result.get('length')) is not int or result['length'] != length
                        or result.get('eof') is not eof
                        or result.get('next_offset') != (None if eof else end)
                        or not eof and type(result.get('next_offset')) is not int):
                    raise NASConnectionError('nas_transport_failed')
                raw.extend(chunk)
                if eof: break
            await self._validate()
            complete = start_offset + len(raw) == size; tail = b''; text = None
            decoder = codecs.getincrementaldecoder('utf-8')('strict')
            try:
                text = decoder.decode(bytes(raw), final=complete)
                tail = decoder.getstate()[0]
                if tail:
                    if not text:
                        raise NASConnectionError('nas_text_page_too_small')
                    del raw[-len(tail):]; tail = b''
                if '\x00' in text: text = None
            except UnicodeDecodeError:
                pass
            result = dict(schema_version=1, operation='read_text', **base, entry=entry, offset=start_offset,
                        size=size, bytes_read=len(raw), data_base64=base64.b64encode(raw).decode(),
                        sha256_of_returned_bytes=hashlib.sha256(raw).hexdigest(),
                        encoding='utf-8' if text is not None else None, text=text,
                        undecoded_tail_base64=base64.b64encode(tail).decode(),
                        complete=complete, truncated=not complete, next_offset=None if complete else start_offset+len(raw),
                        stopped_reason='binary_or_invalid_utf8' if text is None else None if complete else 'text_byte_budget',
                        downloadable_artifact=False, snapshot_consistent=False)
            # Escaped Unicode/control text can exceed the existing result frame
            # even when the raw range is small. Preserve bytes, omit text with
            # an explicit reason; caller can choose a smaller max_bytes.
            if len(json.dumps(result, ensure_ascii=False).encode()) > FILE_OUTPUT - 16384:
                # Shorten this delivery page, preserving a real continuation and
                # valid UTF8. Never replace a usable body with null.
                low, high, fitted = 1, len(raw)-1, None
                while low <= high:
                    count = (low+high)//2
                    page = bytes(raw[:count])
                    try:
                        body = page.decode('utf-8')
                    except UnicodeDecodeError as error:
                        if error.reason != 'unexpected end of data': raise NASConnectionError('nas_transport_failed') from None
                        page = page[:error.start]; body = page.decode('utf-8')
                    candidate = dict(result,bytes_read=len(page),data_base64=base64.b64encode(page).decode(),
                        sha256_of_returned_bytes=hashlib.sha256(page).hexdigest(),text=body,
                        undecoded_tail_base64='',complete=False,truncated=True,next_offset=start_offset+len(page),
                        stopped_reason='text_byte_budget')
                    if page and len(json.dumps(candidate,ensure_ascii=False).encode()) <= FILE_OUTPUT-16384:
                        fitted=candidate;low=count+1
                    else:high=count-1
                if fitted is None:raise NASConnectionError('nas_budget_exceeded')
                result=fitted
            return result
        finally:
            self._active = False
