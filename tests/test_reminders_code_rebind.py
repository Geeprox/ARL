import copy
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('code_rebind',ROOT/'script/rebind_reminders_helper.py')
b = importlib.util.module_from_spec(spec);spec.loader.exec_module(b)

class CodeBindingTests(unittest.TestCase):
    def setUp(self):
        self.control = {key:'unchanged' for key in b.KEYS}
        self.control.update(schema_version=1,helper_bundle_path=str(b.HELPER),host_home=str(b.HOME_STATE),helper_designated_requirement_sha256='stable',helper_executable_sha256='old')
        self.closure = {'Contents/Info.plist':'info','Contents/MacOS/ARLRemindersBridge':'old','Contents/_CodeSignature/CodeResources':'resources'}
        self.actual = {**self.closure,'Contents/MacOS/ARLRemindersBridge':'new'}
        self.identity = {'helper_bundle_id':'local.arl.remindersbridge','designated_requirement_sha256':'stable','executable_sha256':'new'}

    def test_refresh_only_code_fields_and_preserve_access_policy(self):
        _,raw = b.candidates(self.control,self.closure,self.actual,self.identity)
        changed = b.decode(raw)
        self.assertEqual({key for key in changed if changed[key]!=self.control[key]}, {'helper_executable_sha256','closure_sha256'})
        for key in ('control_requirement','helper_requirement','policy_sha256','host_home'):
            self.assertEqual(changed[key], self.control[key])

    def test_reject_different_stable_identity_or_changed_resources(self):
        with self.assertRaises(AssertionError):b.candidates(self.control,self.closure,self.actual,{**self.identity,'designated_requirement_sha256':'different'})
        with self.assertRaises(AssertionError):b.candidates(self.control,self.closure,{**self.actual,'Contents/Info.plist':'modified'},self.identity)

    def test_reject_missing_or_extra_metadata_without_scope_migration(self):
        bad = copy.deepcopy(self.control);bad['new_scope'] = 'all'
        with self.assertRaises(AssertionError):b.candidates(bad,self.closure,self.actual,self.identity)
        with self.assertRaises(AssertionError):b.candidates(self.control,self.closure,{**self.actual,'unreviewed-file':'x'},self.identity)

if __name__=='__main__':unittest.main()
