"""Finder release boundary regressions; never compile, sign, enable or launch."""
import copy
import importlib.util
from pathlib import Path
import plistlib
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('finder_build_fixture', ROOT/'script/build_release.py')
b = importlib.util.module_from_spec(spec)
spec.loader.exec_module(b)

class FinderPackageTests(unittest.TestCase):
    def setUp(self):
        self.info = plistlib.loads((ROOT/'macOS/ARLFinderActions/Info.plist').read_bytes())
        self.entitlements = plistlib.loads((ROOT/'macOS/ARLFinderActions/FinderActions.entitlements').read_bytes())

    def test_rejects_permission_expansion_and_non_boolean_values(self):
        b.validate_finder_configuration(self.info, self.entitlements)
        cases = [{}, {**self.entitlements, 'com.apple.security.automation.apple-events': True},
                 {**self.entitlements, 'com.apple.security.files.user-selected.read-write': True},
                 {**self.entitlements, 'com.apple.security.app-sandbox': False},
                 {**self.entitlements, 'com.apple.security.app-sandbox': 1}]
        for candidate in cases:
            with self.subTest(candidate=candidate), self.assertRaises(b.BuildError):
                b.validate_finder_configuration(self.info, candidate)

    def test_rejects_different_extension_point_principal_or_extra_metadata(self):
        for field, value in [('NSExtensionPointIdentifier', 'other.extension'),
                             ('NSExtensionPrincipalClass', 'UnexpectedPrincipal')]:
            info = copy.deepcopy(self.info)
            info['NSExtension'][field] = value
            with self.assertRaises(b.BuildError): b.validate_finder_configuration(info, self.entitlements)
        for field, value in [('CFBundleIdentifier','different.identity'),
                             ('NSAppleEventsUsageDescription','unexpected automation')]:
            with self.assertRaises(b.BuildError):
                b.validate_finder_configuration({**self.info, field:value}, self.entitlements)

    def test_nested_signing_precedes_parent_with_exact_host_entitlements(self):
        ctx = {'output':ROOT/'build/finder-plan-fixture',
               'recipe':{'signing_identity':'exact existing identity'},
               'version':'0.1.2','build':'51',
               'authority':{'designatedRequirement':'exact parent requirement'},
               'reminders':type('ReminderFixture', (), {'HELPER_REL':'Contents/Library/fixture.app',
                            'HELPER_SIGNER':'helper identity','HELPER_REQUIREMENT':'exact helper requirement'}),
               'finder_extension':{'designated_requirement':'exact finder requirement'},
               'nas_packager':type('NASFixture', (), {'import_probe_command':staticmethod(
                   lambda app:{'name':'NAS_fixture_import','argv':['synthetic-import-probe'], 'seconds':1})})}
        steps = b.post_build_commands(ctx)
        names = [step['name'] for step in steps]
        self.assertLess(names.index('sign_Finder'), names.index('sign_ARL'))
        self.assertLess(names.index('inspect_signed_Finder'), names.index('sign_ARL'))
        finder = next(step['argv'] for step in steps if step['name']=='sign_Finder')
        self.assertEqual(finder[finder.index('--sign')+1], 'exact existing identity')
        self.assertEqual(finder[finder.index('--requirements')+1], '=designated => exact finder requirement')
        self.assertEqual(finder[finder.index('--entitlements')+1], str(ctx['output']/'work/Finder.entitlements.plist'))
        arl = next(step['argv'] for step in steps if step['name']=='sign_ARL')
        self.assertEqual(arl[arl.index('--entitlements')+1], str(ctx['output']/'work/ARL.entitlements.plist'))
        self.assertEqual(b.MAIN_ENTITLEMENTS, {'com.apple.security.automation.apple-events':True,
                                                   'com.apple.security.personal-information.calendars':True})
        self.assertFalse(any('pluginkit' in str(arg) or 'launchctl' in str(arg) for step in steps for arg in step['argv']))

if __name__=='__main__': unittest.main()
