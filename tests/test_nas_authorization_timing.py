"""Pure bounded timing aggregation/reader; no NAS dependency or connection."""
import json
import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch

from integrations.nas import diagnostics
from integrations.nas.runtime.nas_authorization_timing import (
    FILENAME,MAX_COUNT,MAX_RECORD,ReadonlyAuthorizationTimings,readonly_operation,
)


class AuthorizationTimingTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.root=Path(self.temp.name).resolve();self.root.chmod(0o700)
        self.timings=ReadonlyAuthorizationTimings(root=self.root,clock=lambda:1000)

    def tearDown(self):self.temp.cleanup()
    def saved(self):return json.loads((self.root/FILENAME).read_bytes())
    def record(self):return diagnostics.snapshot(root=self.root,now=1001)['records'][FILENAME]

    def test_actual_sdk_files_list_and_legacy_list_have_the_same_readonly_window(self):
        # NASRuntimeClient.fileOperation uses kind=files and NASFileRequest's
        # normalized operation=list. readDirectory uses the legacy kind=list.
        frames=[{'kind':'connect','config':{'host':'SECRET_ENDPOINT'}},
                {'kind':'list','id':2,'nonce':'SECRET_NONCE'},
                {'kind':'files','id':3,'nonce':'SECRET_NONCE','request':{'operation':'list','limit':20}}]
        self.assertEqual([readonly_operation(frame) for frame in frames],['connect','list','list'])
        for frame in frames:
            self.timings.begin(readonly_operation(frame));self.timings.add('request',200_000_000,'ok')
            self.assertTrue(self.timings.finish())
        self.assertEqual(self.saved()['stages'][0]['count'],3)
        self.assertNotIn('SECRET',json.dumps(self.saved()))

    def test_every_other_file_or_write_operation_is_excluded(self):
        frames=[{'kind':'files','request':{'operation':op}} for op in
            ['read','read_text','read_document','search','search_recursive','download','transfer_read','upload_new','cleanup']]
        frames += [{'kind':kind,'request':{'operation':'list'}} for kind in
            ['acceptance','upload_new','directories','status','server_connect','stop']]
        frames += [None,[],{}, {'kind':'files','request':None},{'kind':'files','request':{'operation':True}}]
        for frame in frames:
            with self.subTest(frame=frame):
                self.assertIsNone(readonly_operation(frame))
                self.timings.begin(readonly_operation(frame));self.timings.add('request',1000,'ok')
                self.assertFalse(self.timings.finish())
        self.assertFalse((self.root/FILENAME).exists())

    def test_fixed_private_record_roundtrip_is_timestamped_not_server_health(self):
        self.timings.begin('connect');self.timings.add('lease',25_000_000,'ok')
        self.assertFalse((self.root/FILENAME).exists());self.assertTrue(self.timings.finish())
        row=self.saved()['stages'][0]
        self.assertEqual(row['min_microseconds'],25000);self.assertEqual(row['outcomes']['ok'],1)
        self.assertEqual(stat.S_IMODE((self.root/FILENAME).stat().st_mode),0o600)
        result=diagnostics.snapshot(root=self.root,now=1001)
        self.assertTrue(result['records'][FILENAME]['fresh']);self.assertEqual(result['current_server_health'],'not_probed')
        self.assertFalse(diagnostics.snapshot(root=self.root,now=1301)['records'][FILENAME]['fresh'])

    def test_finite_count_duration_and_recent_sample_budgets_are_explicit(self):
        self.timings.begin('list')
        for _ in range(MAX_COUNT+1):self.timings.add('request',123000,'ok')
        self.assertTrue(self.timings.finish());value=self.saved();row=value['stages'][0]
        self.assertTrue(value['truncated']);self.assertEqual(row['count'],MAX_COUNT)
        self.assertEqual(len(row['recent_microseconds']),16);self.assertLess((self.root/FILENAME).stat().st_size,MAX_RECORD)
        self.assertEqual(self.record()['state'],'available')

    def test_invalid_input_never_becomes_an_arbitrary_stage_or_record_field(self):
        self.timings.begin('list')
        for stage,duration,outcome in [('SECRET_STAGE',1000,'ok'),('request',True,'ok'),('request',1000,'SECRET_ERROR')]:
            self.timings.add(stage,duration,outcome)
        self.assertFalse(self.timings.finish())
        self.timings.begin('list');self.timings.add('request',200_000_000_000,'ok');self.assertTrue(self.timings.finish())
        self.assertTrue(self.saved()['truncated']);self.assertEqual(self.record()['state'],'available')

    def test_recording_failure_never_creates_a_directory_or_retries_on_other_operations(self):
        absent=self.root/'missing';recorder=ReadonlyAuthorizationTimings(root=absent)
        recorder.begin('list');recorder.add('request',1000,'ok');self.assertFalse(recorder.finish());self.assertFalse(absent.exists())
        self.timings.begin('list');self.timings.add('request',1000,'ok')
        with patch('integrations.nas.runtime.nas_authorization_timing.os.write',side_effect=OSError('SECRET')) as write:
            self.assertFalse(self.timings.finish());self.timings.begin('files');self.assertFalse(self.timings.finish())
            self.assertEqual(write.call_count,1)
        self.assertEqual(list(self.root.iterdir()),[])

    def test_symlink_hardlink_and_nonprivate_record_are_refused(self):
        target=self.root/'unrelated';target.write_text('KEEP');path=self.root/FILENAME;path.symlink_to(target)
        self.timings.begin('list');self.timings.add('request',1000,'ok');self.assertFalse(self.timings.finish())
        self.assertEqual(target.read_text(),'KEEP');path.unlink()
        self.timings.begin('list');self.assertTrue(self.timings.finish())
        os.link(path,self.root/'alias');self.assertEqual(self.record(),{'state':'untrusted'})
        (self.root/'alias').unlink();path.chmod(0o400);self.assertEqual(self.record(),{'state':'untrusted'})

    def test_reader_rejects_extra_fields_bad_aggregates_or_secret_values(self):
        from copy import deepcopy
        self.timings.begin('connect');self.timings.add('reserve',200000000,'ok');self.timings.finish();valid=self.saved()
        changes=[lambda value:value.update(scope={'SECRET':True}),
            lambda value:value['stages'][0].update(stage='SECRET'),
            lambda value:value['stages'][0].update(count=True),
            lambda value:value['stages'][0]['outcomes'].update(ok=2),
            lambda value:value['stages'][0].update(recent_microseconds=[-1])]
        for change in changes:
            value=deepcopy(valid);change(value);(self.root/FILENAME).write_text(json.dumps(value))
            result=self.record();self.assertEqual(result,{'state':'invalid'});self.assertNotIn('SECRET',json.dumps(result))


if __name__=='__main__':unittest.main()
