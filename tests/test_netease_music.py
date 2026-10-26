"""Offline official CLI contract and playlist effect tests. No account or network."""
import json
import subprocess
import unittest
from types import SimpleNamespace

from arl.contracts import Fault
from arl.netease_music import (APPEND, CREATE, DESCRIBE, LIST, SEARCH,
                               NcmCliTransport, NeteaseMusicAdapter)
from arl.service import default_policies


P = "a" * 32
S1 = "b" * 32
S2 = "c" * 32


class Context:
    def check_cancelled(self):
        pass


class FakeOfficialCli:
    def __init__(self):
        self.tracks = [S1]
        self.name = "测试歌单"
        self.calls = []
        self.add_calls = self.create_calls = 0
        self.add_timeout = False
        self.add_timeout_before_effect = False
        self.create_unknown = False
        self.create_malformed = False
        self.on_help = None
        self.incomplete = False
        self.bad_help = False
        self.login_required = False

    def __call__(self, argv, **options):
        self.calls.append(tuple(argv[1:]))
        assert options["env"] == {"PATH": "/usr/bin:/bin:/opt/homebrew/bin", "LANG": "C.UTF-8"}
        assert options["stderr"] == subprocess.DEVNULL
        cmd = argv[1:]
        if cmd == ["--version"]:
            return self.reply("0.1.7")
        if cmd == ["commands"]:
            return self.reply("playlist created get tracks create add search song")
        if cmd[-1] == "--help":
            if self.on_help:
                self.on_help()
            if self.bad_help and cmd[:2] == ["playlist", "add"]:
                return self.reply("--playlistId --userInput")
            return self.reply("--playlistId --playlistName --songIds --keyword --userInput")
        if self.login_required:
            return self.reply("请先登录 hidden-private-key", code=1)
        if cmd[:2] == ["playlist", "created"]:
            return self.reply({"playlists": [self.playlist()]})
        if cmd[:2] == ["playlist", "get"]:
            return self.reply({"playlist": self.playlist()})
        if cmd[:2] == ["playlist", "tracks"]:
            return self.reply({"tracks": [self.song(song_id) for song_id in self.tracks],
                               "total": len(self.tracks) + int(self.incomplete)})
        if cmd[:2] == ["playlist", "create"]:
            self.create_calls += 1
            self.name = cmd[cmd.index("--playlistName") + 1]
            if self.create_malformed:
                return self.reply("malformed private-output")
            if self.create_unknown:
                return self.reply({"unexpected": "no identifier"})
            return self.reply({"playlist": self.playlist()})
        if cmd[:2] == ["playlist", "add"]:
            self.add_calls += 1
            if self.add_timeout_before_effect:
                raise subprocess.TimeoutExpired(argv, options["timeout"])
            song_id = cmd[cmd.index("--songIds") + 1]
            self.tracks.append(song_id)
            if self.add_timeout:
                raise subprocess.TimeoutExpired(argv, options["timeout"])
            return self.reply({"ok": True})
        if cmd[:2] == ["search", "song"]:
            return self.reply({"songs": [self.song(S2)]})
        raise AssertionError(cmd)

    def playlist(self):
        return {"encryptedId": P, "originalId": 123, "name": self.name,
                "trackCount": len(self.tracks) + int(self.incomplete)}

    @staticmethod
    def song(song_id):
        return {"encryptedId": song_id, "originalId": 456, "name": "测试歌曲", "visible": True}

    @staticmethod
    def reply(value, code=0):
        output = value if type(value) is str else json.dumps(value, ensure_ascii=False)
        return SimpleNamespace(returncode=code, stdout=output.encode())


class NeteaseMusicTests(unittest.TestCase):
    def adapter(self, fake):
        return NeteaseMusicAdapter(NcmCliTransport("/usr/bin/true", runner=fake))

    def test_unconfigured_and_not_authorized_by_default(self):
        adapter = NeteaseMusicAdapter()
        self.assertEqual(len(adapter.list_capabilities()), 5)
        self.assertEqual(adapter.describe_capability(APPEND)["availability"], "not_configured")
        self.assertFalse(adapter.describe_capability(APPEND)["idempotent"])
        self.assertNotIn(APPEND, default_policies()["mio"].tools)
        with self.assertRaises(Fault) as caught:
            adapter.execute(LIST, {}, Context())
        self.assertEqual(caught.exception.code, "music_cli_unavailable")

    def test_read_create_dedupe_append_and_readback(self):
        fake = FakeOfficialCli()
        adapter = self.adapter(fake)
        self.assertEqual(adapter.execute(LIST, {}, Context())["playlists"][0]["url"],
                         "https://music.163.com/#/playlist?id=123")
        self.assertEqual(adapter.execute(SEARCH, {"keyword": "测试"}, Context())["songs"][0]["song_id"], S2)
        self.assertTrue(adapter.execute(DESCRIBE, {"playlist_id": P}, Context())["complete"])
        self.assertEqual(adapter.execute(CREATE, {"name": "新歌单"}, Context())["state"], "created_verified")
        self.assertEqual(adapter.execute(APPEND, {"playlist_id": P, "song_id": S1}, Context())["state"], "already_present")
        self.assertEqual(fake.add_calls, 0)
        result = adapter.execute(APPEND, {"playlist_id": P, "song_id": S2}, Context())
        self.assertEqual(result["state"], "append_verified")
        self.assertEqual(len(result["songs"]), 2)
        self.assertEqual(fake.add_calls, 1)
        self.assertEqual(adapter.execute(APPEND, {"playlist_id": P, "song_id": S2}, Context())["state"], "already_present")
        self.assertEqual(fake.add_calls, 1)
        for call in fake.calls:
            if "--userInput" in call:
                self.assertLessEqual(len(call[call.index("--userInput") + 1]), 8)

    def test_unknown_create_is_never_retried(self):
        fake = FakeOfficialCli()
        fake.create_unknown = True
        with self.assertRaises(Fault) as caught:
            self.adapter(fake).execute(CREATE, {"name": "新歌单"}, Context())
        self.assertEqual(caught.exception.code, "outcome_unknown")
        self.assertEqual(fake.create_calls, 1)

    def test_malformed_write_reply_does_not_report_safe_failure_or_repeat(self):
        fake = FakeOfficialCli()
        fake.create_malformed = True
        with self.assertRaises(Fault) as caught:
            self.adapter(fake).execute(CREATE, {"name": "新歌单"}, Context())
        self.assertEqual(caught.exception.code, "outcome_unknown")
        self.assertEqual(fake.create_calls, 1)
        self.assertNotIn("private-output", str(caught.exception))

    def test_deadline_after_contract_probe_prevents_first_effect(self):
        class ExpiringContext:
            expired = False
            def check_cancelled(self):
                if self.expired:
                    raise Fault("deadline_exceeded")
        fake = FakeOfficialCli()
        context = ExpiringContext()
        fake.on_help = lambda: setattr(context, "expired", True)
        with self.assertRaises(Fault) as caught:
            self.adapter(fake).execute(CREATE, {"name": "新歌单"}, context)
        self.assertEqual(caught.exception.code, "deadline_exceeded")
        self.assertEqual(fake.create_calls, 0)
        self.assertFalse(any(call[:2] == ("playlist", "create") and "--userInput" in call for call in fake.calls))

    def test_unknown_add_reads_back_once_and_does_not_repeat(self):
        fake = FakeOfficialCli()
        fake.add_timeout = True
        result = self.adapter(fake).execute(APPEND, {"playlist_id": P, "song_id": S2}, Context())
        self.assertEqual(result["state"], "append_verified")
        self.assertEqual(fake.add_calls, 1)

    def test_unknown_add_without_readback_proof_stays_unknown(self):
        fake = FakeOfficialCli()
        fake.add_timeout_before_effect = True
        with self.assertRaises(Fault) as caught:
            self.adapter(fake).execute(APPEND, {"playlist_id": P, "song_id": S2}, Context())
        self.assertEqual(caught.exception.code, "outcome_unknown")
        self.assertEqual(fake.add_calls, 1)

    def test_incomplete_snapshot_and_numeric_song_id_block_effect(self):
        fake = FakeOfficialCli()
        adapter = self.adapter(fake)
        with self.assertRaises(Fault) as caught:
            adapter.execute(APPEND, {"playlist_id": P, "song_id": "456"}, Context())
        self.assertEqual(caught.exception.code, "invalid_arguments")
        self.assertEqual(fake.calls, [])
        fake.incomplete = True
        with self.assertRaises(Fault) as caught:
            adapter.execute(APPEND, {"playlist_id": P, "song_id": S2}, Context())
        self.assertEqual(caught.exception.code, "playlist_snapshot_incomplete")
        self.assertEqual(fake.add_calls, 0)

    def test_contract_and_login_fail_closed_without_leaking_output(self):
        fake = FakeOfficialCli()
        fake.bad_help = True
        with self.assertRaises(Fault) as caught:
            self.adapter(fake).execute(LIST, {}, Context())
        self.assertEqual(caught.exception.code, "music_contract_unverified")
        self.assertFalse(any(call[:2] == ("playlist", "created") and "--userInput" in call for call in fake.calls))
        fake.bad_help = False
        fake.login_required = True
        with self.assertRaises(Fault) as caught:
            self.adapter(fake).execute(LIST, {}, Context())
        self.assertEqual(caught.exception.code, "music_login_required")
        self.assertNotIn("hidden-private-key", str(caught.exception))
        self.assertFalse(any(call[:2] == ("login", "--background") for call in fake.calls))


if __name__ == "__main__":
    unittest.main()
