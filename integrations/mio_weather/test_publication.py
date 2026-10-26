"""Candidate gateway uses only private temporary source and synthetic transports."""
import contextlib
import hashlib
import importlib.util
import io
import json
import shutil
import subprocess
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch

import cli


class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.base = Path(self.temp.name)
        self.src = Path(__file__).resolve().parent
        server_dir = self.base/'service/tunnel-experiment/travel-draft'; server_dir.mkdir(parents=True)
        weather_dir = self.base/'service/amap/weather'; weather_dir.mkdir(parents=True)
        shutil.copy(self.src/'tool.json', weather_dir/'tool.json')
        self.before = server_dir/'before.py'; self.after = server_dir/'server.py'
        shutil.copy(self.src/'server.before.py', self.before); shutil.copy(self.src/'server.weather.py', self.after)
        def load(path, name):
            spec = importlib.util.spec_from_file_location(name, path); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m
        self.old, self.new = load(self.before, 'old_gateway'), load(self.after, 'new_gateway')

    def tearDown(self): self.temp.cleanup()

    def test_existing_13_full_descriptors_unchanged(self):
        self.assertEqual(len(self.old.TOOLS), 13); self.assertEqual(len(self.new.TOOLS), 14)
        self.assertEqual(self.old.TOOLS, self.new.TOOLS[:13])
        self.assertEqual(self.new.TOOLS[-1]['name'], 'mio_maps_weather')

    def test_actual_isolated_stdio_discovery(self):
        req = {'jsonrpc':'2.0','id':1,'method':'tools/list','params':{}}
        proc = subprocess.run(['/usr/bin/python3','-I',str(self.after)],input=json.dumps(req)+'\n',
            capture_output=True,text=True,timeout=2)
        self.assertEqual(proc.returncode, 0)
        reply = json.loads(proc.stdout); self.assertEqual(len(reply['result']['tools']), 14)

    def test_weather_dispatch_fixed_cli_and_bounds(self):
        envelope = {'content':[{'type':'text','text':'{"schema_version":1}'}], 'isError':False}
        def run(argv, **kwargs):
            self.assertEqual(argv, ['/usr/bin/python3','-I',str(self.base.resolve()/'service/amap/weather/cli.py')])
            self.assertEqual(json.loads(kwargs['input']), {'adcode':'310101','mode':'forecast'})
            self.assertEqual(kwargs['timeout'], 8); self.assertEqual(kwargs['stderr'], subprocess.DEVNULL)
            return types.SimpleNamespace(returncode=0,stdout=json.dumps(envelope))
        with patch.object(self.new.subprocess, 'run', side_effect=run):
            self.assertEqual(self.new.call('mio_maps_weather', {'adcode':'310101','mode':'forecast'}), envelope)

    def test_invalid_weather_rejected_before_execution(self):
        with patch.object(self.new.subprocess, 'run') as run:
            for args in [{'adcode':'Shanghai'}, {'adcode':'310101','mode':'hourly'}, {'adcode':'310101','key':'fake'}]:
                with self.assertRaises(self.new.InvalidArguments): self.new.call('mio_maps_weather',args)
            run.assert_not_called()

    def test_ping_is_unchanged_no_runner(self):
        with patch.object(self.new.subprocess, 'run') as run:
            self.assertEqual(self.new.call('mio_tunnel_ping',{}), self.old.call('mio_tunnel_ping',{}))
            run.assert_not_called()

    def test_deadline_is_sanitized(self):
        with patch.object(self.new.subprocess, 'run', side_effect=subprocess.TimeoutExpired('secret-command',8)):
            result = self.new.call('mio_maps_weather', {'adcode':'310101'})
        self.assertTrue(result['isError']); self.assertNotIn('secret-command',json.dumps(result))

    def test_existing_key_reader_only_synthetic_fixture(self):
        path = self.base/'fixture.json'; path.write_text('{"AMAP_MAPS_API_KEY":"fixture_only_not_a_real_key"}'); path.chmod(0o600)
        with patch.object(cli,'KEY_FILE',path):
            self.assertEqual(cli.existing_amap_key(), 'fixture_only_not_a_real_key')
            path.chmod(0o644)
            with self.assertRaises(cli.WeatherFault): cli.existing_amap_key()

    def test_cli_invalid_input_never_reads_key(self):
        output = io.StringIO()
        with patch.object(cli.sys, 'stdin', types.SimpleNamespace(buffer=io.BytesIO(b'{"adcode":"Shanghai"}'))), \
             patch.object(cli,'existing_amap_key') as key, contextlib.redirect_stdout(output):
            self.assertEqual(cli.main(),0); key.assert_not_called()
        self.assertTrue(json.loads(output.getvalue())['isError'])


if __name__ == '__main__': unittest.main()
