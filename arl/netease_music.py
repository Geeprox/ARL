"""Opt-in official ncm-cli playlist tools for an independently approved host.

The default host registers unavailable metadata without authorizing an account.
The CLI, when installed later, owns its own credentials; ARL never reads them.
"""
from __future__ import annotations

import json
import hashlib
import os
import re
import stat
import threading
import subprocess
from pathlib import Path

from .contracts import Fault, Tool, object_schema, string, validate


ENCRYPTED_ID = dict(string(32), pattern=r"[0-9a-fA-F]{32}")
PLAYLIST_ID = ENCRYPTED_ID
PLAYLIST_NAME = string(100)
SEARCH_TERM = string(100)
LIST = "netease.playlist.list.v1"
DESCRIBE = "netease.playlist.describe.v1"
CREATE = "netease.playlist.create.v1"
APPEND = "netease.playlist.append_song.v1"
SEARCH = "netease.song.search.v1"

SCHEMAS = {
    LIST: object_schema(),
    DESCRIBE: object_schema({"playlist_id": PLAYLIST_ID}, ("playlist_id",)),
    CREATE: object_schema({"name": PLAYLIST_NAME}, ("name",)),
    APPEND: object_schema({"playlist_id": PLAYLIST_ID, "song_id": ENCRYPTED_ID},
                          ("playlist_id", "song_id")),
    SEARCH: object_schema({"keyword": SEARCH_TERM}, ("keyword",)),
}

# The official skill publishes `playlist create --playlistName`; the other
# candidates remain inert until the installed CLI confirms every command and
# flag. `commands` and subcommand help remain authoritative.
COMMANDS = {
    LIST: ("playlist", "created", ("--userInput",)),
    DESCRIBE: ("playlist", "get", ("--playlistId", "--userInput")),
    "tracks": ("playlist", "tracks", ("--playlistId", "--userInput")),
    CREATE: ("playlist", "create", ("--playlistName", "--userInput")),
    APPEND: ("playlist", "add", ("--playlistId", "--songIds", "--userInput")),
    SEARCH: ("search", "song", ("--keyword", "--userInput")),
}
INTENTS = {
    LIST: "查看我的歌单", DESCRIBE: "查看歌单", "tracks": "查看歌单歌曲",
    CREATE: "创建歌单", APPEND: "将歌曲加入歌单", SEARCH: "搜索歌曲",
}
_HEX = re.compile(r"[0-9a-fA-F]{32}\Z")
_DECIMAL = re.compile(r"[0-9]{1,20}\Z")


def _text(value, limit=100):
    if (type(value) is not str or not value.strip() or len(value) > limit
            or value.startswith("-") or any(ord(c) < 32 or ord(c) == 127 for c in value)):
        raise Fault("invalid_arguments")
    return value.strip()


def _encrypted(value):
    if type(value) is not str or _HEX.fullmatch(value) is None:
        raise Fault("music_contract_unverified")
    return value.lower()


def _original(value):
    if type(value) is int and value > 0:
        return str(value)
    if type(value) is str and _DECIMAL.fullmatch(value) and int(value) > 0:
        return value
    return None


def _node(raw):
    """Accept only a bounded structured CLI reply, never prose or log output."""
    if type(raw) is not bytes or len(raw) > 65536:
        raise Fault("music_contract_unverified")
    try:
        value = json.loads(raw)
    except (UnicodeError, ValueError):
        raise Fault("music_contract_unverified") from None
    if type(value) is dict:
        code = value.get("code")
        if type(code) is int and code not in (0, 200):
            raise Fault("music_contract_unverified")
        if value.get("success") is False:
            raise Fault("music_contract_unverified")
    for _ in range(2):
        if type(value) is dict and type(value.get("data")) in (dict, list):
            value = value["data"]
        elif type(value) is dict and type(value.get("result")) in (dict, list):
            value = value["result"]
        else:
            break
    if type(value) not in (dict, list):
        raise Fault("music_contract_unverified")
    return value


def _array(value, names):
    if type(value) is list:
        return value
    if type(value) is dict:
        for name in names:
            if type(value.get(name)) is list:
                return value[name]
    raise Fault("music_contract_unverified")


def _playlist(value):
    if type(value) is not dict:
        raise Fault("music_contract_unverified")
    encrypted = _encrypted(value.get("encryptedId", value.get("encrypted_id")))
    name = _text(value.get("name"))
    result = {"playlist_id": encrypted, "name": name}
    original = _original(value.get("originalId", value.get("original_id")))
    if original is not None:
        result["url"] = "https://music.163.com/#/playlist?id=" + original
    count = value.get("trackCount", value.get("track_count"))
    if type(count) is int and 0 <= count <= 100000:
        result["track_count"] = count
    return result


def _song(value):
    if type(value) is not dict:
        raise Fault("music_contract_unverified")
    result = {"song_id": _encrypted(value.get("encryptedId", value.get("encrypted_id"))),
              "name": _text(value.get("name"), 200)}
    original = _original(value.get("originalId", value.get("original_id")))
    if original is not None:
        result["url"] = "https://music.163.com/#/song?id=" + original
    if type(value.get("visible")) is bool:
        result["visible"] = value["visible"]
    return result


class NcmCliTransport:
    """Fixed argv and minimal environment; no shell, login or configuration calls."""

    def __init__(self, executable, *, runner=subprocess.run):
        path = Path(executable)
        if not path.is_absolute():
            raise Fault("music_cli_unavailable")
        try:
            path = path.resolve(strict=True)
            metadata = path.stat()
            if (not stat.S_ISREG(metadata.st_mode) or metadata.st_uid not in (0, os.geteuid())
                    or metadata.st_mode & 0o022):
                raise Fault("music_cli_unavailable")
            self._executable_hash = hashlib.sha256(path.read_bytes()).digest()
        except (OSError, ValueError):
            raise Fault("music_cli_unavailable") from None
        self.executable = str(path)
        self.runner = runner
        self._verified = False

    def _run(self, argv, *, write=False):
        try:
            if hashlib.sha256(Path(self.executable).read_bytes()).digest() != self._executable_hash:
                raise Fault("music_cli_changed")
        except OSError:
            raise Fault("music_cli_changed") from None
        try:
            completed = self.runner([self.executable, *argv], stdout=subprocess.PIPE,
                                    stderr=subprocess.DEVNULL, timeout=12,
                                    env={"PATH": "/usr/bin:/bin:/opt/homebrew/bin", "LANG": "C.UTF-8"})
        except (OSError, subprocess.TimeoutExpired):
            raise Fault("outcome_unknown" if write else "music_cli_unavailable") from None
        raw = completed.stdout
        if type(raw) is not bytes or len(raw) > 65536:
            raise Fault("outcome_unknown" if write else "music_contract_unverified")
        if completed.returncode:
            lower = raw.decode("utf-8", "ignore").lower()
            if any(term in lower for term in ("请先登录", "未登录", "未授权", "unauthorized", "login required")):
                raise Fault("music_login_required")
            if any(term in lower for term in ("api key", "appid", "privatekey", "private key", "未配置")):
                raise Fault("music_app_configuration_required")
            if "请求总量超限" in lower:
                raise Fault("music_quota_exceeded")
            raise Fault("outcome_unknown" if write else "music_cli_unavailable")
        return raw

    def verify_contract(self):
        if self._verified:
            return
        version = self._run(["--version"]).decode("utf-8", "replace").strip()
        if re.search(r"(?<![0-9])0\.1\.7(?![0-9])", version) is None:
            raise Fault("music_contract_unverified")
        tree = self._run(["commands"]).decode("utf-8", "replace")
        for group, command, flags in COMMANDS.values():
            if (re.search(r"\b" + re.escape(group) + r"\b", tree) is None
                    or re.search(r"\b" + re.escape(command) + r"\b", tree) is None):
                raise Fault("music_contract_unverified")
            help_text = self._run([group, command, "--help"]).decode("utf-8", "replace")
            if any(flag not in help_text for flag in flags):
                raise Fault("music_contract_unverified")
        self._verified = True

    def invoke(self, capability, *, before_effect=None, **kwargs):
        self.verify_contract()
        group, command, _ = COMMANDS[capability]
        argv = [group, command]
        if "playlist_id" in kwargs:
            argv += ["--playlistId", kwargs["playlist_id"]]
        if "song_id" in kwargs:
            argv += ["--songIds", kwargs["song_id"]]
        if "name" in kwargs:
            argv += ["--playlistName", kwargs["name"]]
        if "keyword" in kwargs:
            argv += ["--keyword", kwargs["keyword"]]
        argv += ["--userInput", INTENTS[capability]]
        write = capability in (CREATE, APPEND)
        if write:
            if not callable(before_effect):
                raise Fault("permission_denied")
            before_effect()
        raw = self._run(argv, write=write)
        try:
            return _node(raw)
        except Fault:
            raise Fault("outcome_unknown" if write else "music_contract_unverified") from None


class NeteaseMusicAdapter:
    """Typed list/describe/execute seam over the existing ARL Tool registry."""

    def __init__(self, transport=None):
        self.transport = transport
        self._write_lock = threading.Lock()

    def list_capabilities(self):
        return [tool.descriptor() for tool in self.tools()]

    def describe_capability(self, name):
        for tool in self.tools():
            if tool.name == name:
                return tool.descriptor()
        raise Fault("unknown_tool")

    def tools(self):
        return [Tool(name, schema, lambda args, context, n=name: self.execute(n, args, context),
                     idempotent=name not in (CREATE, APPEND),
                     permissions=(("netease_playlist_write", "netease_account") if name in (CREATE, APPEND)
                                  else ("netease_playlist_read", "netease_account")),
                     availability="adapter" if self.transport else "not_configured",
                     description="Official @music163/ncm-cli 0.1.7; CLI configuration, login and account authorization unverified")
                for name, schema in SCHEMAS.items()]

    def _invoke(self, capability, *, context=None, **kwargs):
        if self.transport is None:
            raise Fault("music_cli_unavailable")
        if capability in (CREATE, APPEND):
            return self.transport.invoke(capability, before_effect=context.check_cancelled, **kwargs)
        return self.transport.invoke(capability, **kwargs)

    def _describe(self, playlist_id):
        detail = self._invoke(DESCRIBE, playlist_id=playlist_id)
        if type(detail) is dict and type(detail.get("playlist")) is dict:
            detail = detail["playlist"]
        playlist = _playlist(detail)
        if playlist["playlist_id"] != playlist_id:
            raise Fault("music_contract_unverified")
        tracks = self._invoke("tracks", playlist_id=playlist_id)
        songs = [_song(item) for item in _array(tracks, ("tracks", "songs"))]
        if len(songs) > 1000:
            raise Fault("music_contract_unverified")
        known_count = playlist.get("track_count")
        if type(tracks) is dict:
            count = tracks.get("total", tracks.get("trackCount"))
            if type(count) is int and count >= 0:
                known_count = count if known_count is None else known_count
                if count != known_count:
                    raise Fault("music_contract_unverified")
        return {"playlist": playlist, "songs": songs,
                "complete": known_count is not None and known_count == len(songs)}

    def execute(self, name, args, context):
        if name not in SCHEMAS:
            raise Fault("unknown_tool")
        validate(args, SCHEMAS[name])
        for value in args.values():
            _text(value, 200)
        context.check_cancelled()
        if name == LIST:
            playlists = [_playlist(item) for item in _array(self._invoke(LIST), ("playlists", "list"))]
            if len(playlists) > 100:
                raise Fault("music_contract_unverified")
            return {"playlists": playlists}
        if name == SEARCH:
            songs = [_song(item) for item in _array(self._invoke(SEARCH, keyword=args["keyword"]), ("songs", "list"))]
            if len(songs) > 100:
                raise Fault("music_contract_unverified")
            return {"songs": songs}
        if name == DESCRIBE:
            return self._describe(args["playlist_id"].lower())
        if name == CREATE:
            with self._write_lock:
                context.check_cancelled()
                return self._create(args, context)
        with self._write_lock:
            context.check_cancelled()
            return self._append(args, context)

    def _create(self, args, context):
        created = self._invoke(CREATE, context=context, name=args["name"].strip())
        if type(created) is dict and type(created.get("playlist")) is dict:
            created = created["playlist"]
        try:
            playlist = _playlist(created)
            if playlist["name"] != args["name"].strip():
                raise Fault("outcome_unknown")
            check = self._describe(playlist["playlist_id"])
            if check["playlist"]["name"] != playlist["name"]:
                raise Fault("outcome_unknown")
        except Fault:
            raise Fault("outcome_unknown") from None
        return {"state": "created_verified", **check}

    def _append(self, args, context):
        playlist_id, song_id = args["playlist_id"].lower(), args["song_id"].lower()
        before = self._describe(playlist_id)
        if not before["complete"]:
            raise Fault("playlist_snapshot_incomplete")
        if song_id in {song["song_id"] for song in before["songs"]}:
            return {"state": "already_present", **before}
        # This action is intentionally non-idempotent. On an uncertain reply,
        # read back once; never issue a second add or create automatically.
        context.check_cancelled()
        try:
            self._invoke(APPEND, context=context, playlist_id=playlist_id, song_id=song_id)
        except Fault as exc:
            if exc.code not in {"outcome_unknown", "music_cli_unavailable", "music_contract_unverified"}:
                raise
        try:
            after = self._describe(playlist_id)
            if after["complete"] and song_id in {song["song_id"] for song in after["songs"]}:
                return {"state": "append_verified", **after}
        except Fault:
            pass
        raise Fault("outcome_unknown")
