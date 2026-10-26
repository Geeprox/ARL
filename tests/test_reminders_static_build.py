"""Real static-builder policy/layout regressions; no compiler, signing or EventKit."""
import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('reminders_static', ROOT/'integrations/reminders_v3/build_static.py')
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)


class StaticHelperTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='reminders-build-fixture-', dir=ROOT/'build')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.template = self.root/'template.app'
        (self.template/'Contents').mkdir(parents=True)
        self.info = {'CFBundleIdentifier':'local.arl.remindersbridge', 'CFBundleExecutable':'ARLRemindersBridge',
                     'ARLFirstRemindersPolicyPath':'/synthetic/activation.json',
                     'ARLFirstRemindersPolicySHA256':'a'*64, 'NSRemindersFullAccessUsageDescription':'preserve'}
        (self.template/'Contents/Info.plist').write_bytes(plistlib.dumps(self.info))
        self.plan = r.plan(self.root/'candidate', self.template, '/fake/swiftc', '/fake/sdk')

    def test_plan_is_three_serial_static_steps_with_all_inputs(self):
        self.assertEqual(len(self.plan['steps']),3)
        self.assertIn('integrations/reminders_v3/RemindersTaskStore.swift',self.plan['sources'])
        self.assertIn('macOS/ARLControl/Models/RemindersTask.swift',self.plan['sources'])
        self.assertEqual(self.plan['native_timeout_total'],360)
        for step in self.plan['steps']:
            self.assertEqual(step['argv'][step['argv'].index('-j')+1],'1')
            for forbidden in ['-emit-library','-D','-disable-library-validation']:
                self.assertNotIn(forbidden,step['argv'])
        self.assertEqual(sum(a.endswith('.o') for a in self.plan['steps'][-1]['argv']),2)
        self.assertFalse(Path(self.plan['output']).exists())

    def test_prepare_preserves_every_policy_and_usage_field(self):
        r.prepare(self.plan)
        info = plistlib.loads((Path(self.plan['app'])/'Contents/Info.plist').read_bytes())
        self.assertEqual(info,{**self.info,'ARLRemindersLinkage':'static'})
        self.assertFalse((Path(self.plan['app'])/'Contents/Frameworks').exists())
        self.assertFalse((Path(self.plan['app'])/'Contents/_CodeSignature').exists())

    def test_changed_template_rejected_before_creating_output(self):
        (self.template/'Contents/Info.plist').write_bytes(plistlib.dumps({**self.info,'ARLFirstRemindersPolicySHA256':'b'*64}))
        with self.assertRaisesRegex(ValueError,'template_changed'):r.prepare(self.plan)
        self.assertFalse(Path(self.plan['output']).exists())

    def test_output_scope_symlink_and_existing_path_rejected(self):
        for out in [Path('/private/tmp/ARL-reminders-outside'),self.root]:
            with self.assertRaises(ValueError):r.plan(out,self.template,'/fake/swiftc','/fake/sdk')
        link=self.root/'link';link.symlink_to(self.root, target_is_directory=True)
        with self.assertRaisesRegex(ValueError,'symlink'):r.plan(link/'new',self.template,'/fake/swiftc','/fake/sdk')

    def test_only_system_or_exact_swift_runtime_dependencies(self):
        self.assertEqual(len(r.validate_dependencies('helper:\n /System/Library/Frameworks/EventKit.framework/Versions/A/EventKit (x)\n /usr/lib/libSystem.B.dylib (x)\n @rpath/libswiftCore.dylib (x)')),3)
        for dep in ['@rpath/libARLRemindersCore.dylib','@rpath/libswiftCore.dylib/evil','/private/tmp/unsafe.dylib','']:
            with self.subTest(dep=dep),self.assertRaises(ValueError):r.validate_dependencies('helper:\n'+dep)

    def staged_fixture(self):
        r.prepare(self.plan)
        (Path(self.plan['app'])/'Contents/MacOS/ARLRemindersBridge').write_bytes(b'synthetic never executed')
        app=self.root/'package/ARL.app';target=app/r.HELPER_REL
        (target/'Contents').mkdir(parents=True)
        (target/'Contents/old').write_bytes(b'retain original copied helper')
        return app,target

    def test_staging_retains_template_and_never_changes_cache(self):
        app,target=self.staged_fixture()
        before=(self.template/'Contents/Info.plist').read_bytes()
        receipt=r.stage_compiled(self.plan,app,'helper:\n /usr/lib/libSystem.B.dylib (x)')
        self.assertEqual(receipt['linkage'],'static')
        self.assertFalse(receipt['permission_status_verified'])
        self.assertEqual((self.template/'Contents/Info.plist').read_bytes(),before)
        self.assertTrue((Path(self.plan['output'])/'retained-template.app/Contents/old').is_file())
        self.assertFalse((target/'Contents/old').exists())
        self.assertFalse((target/'Contents/Frameworks').exists())

    def test_unexpected_file_or_modified_policy_stops_before_replacement(self):
        app,target=self.staged_fixture();built=Path(self.plan['app'])
        extra=built/'Contents/extra';extra.write_bytes(b'bad')
        with self.assertRaisesRegex(ValueError,'unsigned_layout'):r.stage_compiled(self.plan,app,'helper:\n /usr/lib/libSystem.B.dylib (x)')
        extra.unlink()
        (built/'Contents/Info.plist').write_bytes(plistlib.dumps({**self.info,'ARLRemindersLinkage':'static','extra':'bad'}))
        with self.assertRaisesRegex(ValueError,'policy_drift'):r.stage_compiled(self.plan,app,'helper:\n /usr/lib/libSystem.B.dylib (x)')
        self.assertTrue((target/'Contents/old').exists())


if __name__ == '__main__':unittest.main()
