"""Isolated build-driver regressions. No native compiler, keys or app launch."""
import argparse
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import stat
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('build_release',ROOT/'script/build_release.py')
b = importlib.util.module_from_spec(spec)
spec.loader.exec_module(b)


class ReleaseTests(unittest.TestCase):
    def test_relative_path_rejects_escape_and_symlink(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            for rel in ['../escape','/absolute']:
                with self.assertRaises(b.BuildError):b.relative(root,rel)
            (root/'link').symlink_to('/tmp')
            with self.assertRaises(b.BuildError):b.relative(root,'link/file')

    def test_inventory_detects_mode_and_content_change(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            p = root/'resource';p.write_bytes(b'original');p.chmod(0o444)
            before = b.tree_inventory(root)
            p.chmod(0o644)
            self.assertNotEqual(before,b.tree_inventory(root))
            p.write_bytes(b'different');p.chmod(0o444)
            self.assertNotEqual(before,b.tree_inventory(root))

    def test_binding_updates_only_executable_sha(self):
        before = {'schema':3,'identifier':'local.arl.control','certificateSHA1':'A'*40,'teamOU':'TEAM',
                  'designatedRequirement':'exact rule','executableSHA256':'old','executionAllowed':False,
                  'bundlePath':'/original/ARL.app','validationPurposes':['keep']}
        signature = {'status':'PASS','identifier':'local.arl.control','certificateSHA1':'a'*40,'team':'TEAM',
                     'designatedRequirement':'exact rule','executableSHA256':'new','entitlementsEmpty':False,'entitlements':dict(b.MAIN_ENTITLEMENTS),'hardenedRuntime':True}
        after = b.verify_authority(before,signature,'new',{'CFBundleIdentifier':'local.arl.control','NSAppleEventsUsageDescription':b.APPLE_EVENTS_USAGE,'NSCalendarsWriteOnlyAccessUsageDescription':b.CALENDAR_WRITE_USAGE,'NSCalendarsFullAccessUsageDescription':b.CALENDAR_FULL_USAGE,'NSRemindersFullAccessUsageDescription':b.REMINDERS_FULL_USAGE})
        self.assertEqual({k for k in before if before[k]!=after[k]},{'executableSHA256'})
        self.assertFalse(after['executionAllowed'])
        with self.assertRaises(b.BuildError):
            b.verify_authority(before,signature,'new',{'CFBundleIdentifier':'local.arl.control','NSAppleEventsUsageDescription':b.APPLE_EVENTS_USAGE})
        for key,wrong in [('certificateSHA1','B'*40),('team','other'),('designatedRequirement','wrong'),
                          ('executableSHA256','stale'),('entitlementsEmpty',True),('hardenedRuntime',False)]:
            with self.subTest(key=key),self.assertRaises(b.BuildError):
                b.verify_authority(before,{**signature,key:wrong},'new',{'CFBundleIdentifier':'local.arl.control','NSAppleEventsUsageDescription':b.APPLE_EVENTS_USAGE,'NSCalendarsWriteOnlyAccessUsageDescription':b.CALENDAR_WRITE_USAGE,'NSCalendarsFullAccessUsageDescription':b.CALENDAR_FULL_USAGE,'NSRemindersFullAccessUsageDescription':b.REMINDERS_FULL_USAGE})

    def test_calendar_purpose_requires_exact_explicit_full_access_declaration(self):
        before = {'identifier':'local.arl.control','certificateSHA1':'A'*40,'teamOU':'TEAM',
                  'designatedRequirement':'exact rule','executableSHA256':'old'}
        signature = {'status':'PASS','identifier':'local.arl.control','certificateSHA1':'A'*40,'team':'TEAM',
                     'designatedRequirement':'exact rule','executableSHA256':'new','entitlementsEmpty':False,
                     'hardenedRuntime':True,'entitlements':dict(b.MAIN_ENTITLEMENTS)}
        info = {'CFBundleIdentifier':'local.arl.control','NSAppleEventsUsageDescription':b.APPLE_EVENTS_USAGE,
                'NSCalendarsWriteOnlyAccessUsageDescription':b.CALENDAR_WRITE_USAGE,'NSCalendarsFullAccessUsageDescription':b.CALENDAR_FULL_USAGE,'NSRemindersFullAccessUsageDescription':b.REMINDERS_FULL_USAGE}
        for key in ['NSCalendarsFullAccessUsageDescription','NSCalendarsUsageDescription']:
            with self.subTest(key=key),self.assertRaises(b.BuildError):
                b.verify_authority(before,signature,'new',{**info,key:'unexpected broader purpose'})

    def test_reminders_purpose_matches_actual_outer_application_subject(self):
        before = {'identifier':'local.arl.control','certificateSHA1':'A'*40,'teamOU':'TEAM',
                  'designatedRequirement':'exact rule','executableSHA256':'old'}
        signature = {'status':'PASS','identifier':'local.arl.control','certificateSHA1':'A'*40,'team':'TEAM',
                     'designatedRequirement':'exact rule','executableSHA256':'new','entitlementsEmpty':False,
                     'hardenedRuntime':True,'entitlements':dict(b.MAIN_ENTITLEMENTS)}
        info = {'CFBundleIdentifier':'local.arl.control','NSAppleEventsUsageDescription':b.APPLE_EVENTS_USAGE,
                'NSCalendarsWriteOnlyAccessUsageDescription':b.CALENDAR_WRITE_USAGE,
                'NSCalendarsFullAccessUsageDescription':b.CALENDAR_FULL_USAGE,
                'NSRemindersFullAccessUsageDescription':b.REMINDERS_FULL_USAGE}
        self.assertEqual(b.verify_authority(before,signature,'new',info)['executableSHA256'],'new')
        for value in [None, '', 1, 'unexpected purpose']:
            invalid = dict(info)
            if value is None: invalid.pop('NSRemindersFullAccessUsageDescription')
            else: invalid['NSRemindersFullAccessUsageDescription'] = value
            with self.subTest(value=value),self.assertRaises(b.BuildError):
                b.verify_authority(before,signature,'new',invalid)

    def test_authority_rejects_extra_missing_false_and_integer_entitlements(self):
        before = {'identifier':'local.arl.control','certificateSHA1':'A'*40,'teamOU':'TEAM',
                  'designatedRequirement':'exact rule','executableSHA256':'old'}
        signature = {'status':'PASS','identifier':'local.arl.control','certificateSHA1':'A'*40,'team':'TEAM',
                     'designatedRequirement':'exact rule','executableSHA256':'new','entitlementsEmpty':False,'hardenedRuntime':True}
        invalid = [{}, {'com.apple.security.automation.apple-events':True},
                   {'com.apple.security.personal-information.calendars':True},
                   {**b.MAIN_ENTITLEMENTS,'com.apple.security.cs.disable-library-validation':True}]
        for key in b.MAIN_ENTITLEMENTS:
            invalid.extend([{**b.MAIN_ENTITLEMENTS,key:False},{**b.MAIN_ENTITLEMENTS,key:1}])
        for values in invalid:
            with self.subTest(values=values),self.assertRaises(b.BuildError):
                b.verify_authority(before,{**signature,'entitlements':values},'new',
                                   {'CFBundleIdentifier':'local.arl.control','NSAppleEventsUsageDescription':b.APPLE_EVENTS_USAGE,'NSCalendarsWriteOnlyAccessUsageDescription':b.CALENDAR_WRITE_USAGE,'NSCalendarsFullAccessUsageDescription':b.CALENDAR_FULL_USAGE,'NSRemindersFullAccessUsageDescription':b.REMINDERS_FULL_USAGE})

    def test_run_nonzero_and_timeout_are_failures_with_wait_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory).resolve();(out/'logs').mkdir()
            with self.assertRaises(b.BuildError):
                b.run([sys.executable,'-c','raise SystemExit(7)'],'failure',out,b.BASE_ENV,2)
            receipt = b.load(out/'logs/failure.json')
            self.assertEqual(receipt['returncode'],7)
            self.assertTrue(receipt['direct_child_reaped'])
            with self.assertRaises(b.BuildError):
                b.run([sys.executable,'-c','import time;time.sleep(30)'],'timeout',out,b.BASE_ENV,0.1)
            receipt = b.load(out/'logs/timeout.json')
            self.assertEqual(receipt['timeout_or_interruption'],'TimeoutExpired')
            self.assertTrue(receipt['direct_child_reaped'])

    def test_plan_does_not_run_native(self):
        ctx = {'recipe':{'product':{'target':'arm64-apple-macos14.0'},'compression_c':'c/file.c',
                         'compression_header':'c/file.h','source_groups':{'ARLCredentialOnboarding':['sdk1.swift'],
                         'ARLCredentialHostCore':['sdk2.swift'],'Control_complete_link':['app.swift']},
                         'cache_sha256':'cache','authority_template_sha256':'authority','signing_identity':'identity'},
               'output':Path('/tmp/review-output'),'tools':{'clang':'/fake/clang','swiftc':'/fake/swiftc','ar':'/fake/ar'},
               'sdk':'/fake/SDK','version':'0.1.2','build':'13','recipe_sha256':'recipe','source_hashes':{},
               'authority':{'designatedRequirement':'fixture rule'}}
        helper_spec = importlib.util.spec_from_file_location('reminders_static_fixture',ROOT/'integrations/reminders_v3/build_static.py')
        helper = importlib.util.module_from_spec(helper_spec);helper_spec.loader.exec_module(helper)
        ctx['reminders'] = helper
        nas_spec = importlib.util.spec_from_file_location('nas_packager_fixture',ROOT/'script/stage_nas_runtime.py')
        nas = importlib.util.module_from_spec(nas_spec);nas_spec.loader.exec_module(nas)
        ctx['nas_packager'] = nas
        ctx['reminders_plan'] = {'steps':[{'name':'reminders_'+str(i),'seconds':120,'argv':['/fake/swiftc','-j','1']} for i in range(3)]}
        with patch.object(b,'run',side_effect=AssertionError('native started')):
            plan = b.native_plan(ctx)
        self.assertEqual(plan['workers'],1)
        nas_probe = next(s for s in plan['post_build_steps'] if s['name']=='verify_NAS_packaged_imports')
        self.assertIn('-I',nas_probe['argv']);self.assertIn('-B',nas_probe['argv'])
        self.assertEqual(nas_probe['seconds'],15)
        self.assertEqual(len(plan['steps']),10)
        self.assertEqual([s['name'] for s in plan['post_build_steps'][:2]],['sign_Reminders','verify_Reminders'])
        arl_sign = next(s['argv'] for s in plan['post_build_steps'] if s['name']=='sign_ARL')
        self.assertEqual(arl_sign[arl_sign.index('--entitlements')+1],str(ctx['output']/'work/ARL.entitlements.plist'))
        self.assertIn('--options',plan['post_build_steps'][0]['argv'])
        self.assertIn('runtime',plan['post_build_steps'][0]['argv'])
        self.assertNotIn('--entitlements',plan['post_build_steps'][0]['argv'])
        verify = plan['post_build_steps'][1]['argv']
        self.assertEqual(verify[verify.index('-R')+1], '=' + helper.HELPER_REQUIREMENT)
        ctx['build_only'] = True
        compile_plan = b.native_plan(ctx)
        self.assertEqual(compile_plan['post_build_steps'],[])
        self.assertEqual(compile_plan['post_build_timeout_total'],0)
        for step in plan['steps']:
            self.assertNotIn('-D',step['argv'])
            self.assertNotIn('-disable-sandbox',step['argv'])
            if step['argv'][0]=='/fake/swiftc':
                self.assertEqual(step['argv'][step['argv'].index('-j')+1],'1')

    def test_failed_build_cannot_emit_pass_manifest(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory).resolve()/'output'
            ctx = {'output':out}
            with patch.object(b,'native_plan',return_value={'synthetic':True}), patch.object(b,'commands',return_value=[]), \
                 patch.object(b,'stage_resources',side_effect=b.BuildError('fixture resource failure')):
                with self.assertRaises(b.BuildError):b.build(ctx)
            self.assertEqual(b.load(out/'result.json')['status'],'FAILED')
            self.assertFalse((out/'artifact.json').exists())
            self.assertFalse((out/'package/manifest.json').exists())

    def test_missing_identity_blocks_before_any_native_command(self):
        args = argparse.Namespace(recipe=str(ROOT/'script/release_recipe.json'),version=None,build_number=None,output=None)
        with patch.object(b,'capture',return_value='0 valid identities found'), \
             patch.object(b,'run',side_effect=AssertionError('native started')):
            with self.assertRaisesRegex(b.BuildError,'签名身份'):
                b.preflight(args)

    def test_build_only_preflight_does_not_enumerate_keychain(self):
        args = argparse.Namespace(recipe=str(ROOT/'script/release_recipe.json'),version=None,build_number=None,output=None,build_only=True)
        def fixture_capture(argv,seconds=15):
            self.assertNotEqual(argv[0],'/usr/bin/security')
            if argv[:2] == ['/usr/bin/xcrun','--find']:return '/usr/bin/true'
            if argv[:2] == ['/usr/bin/xcrun','--sdk']:return '/System/Library'
            raise AssertionError(argv)
        with patch.object(b,'capture',side_effect=fixture_capture), \
             patch.object(b,'run',side_effect=AssertionError('native started')):
            ctx = b.preflight(args)
        self.assertTrue(ctx['build_only'])

    def test_output_rejects_external_directory(self):
        args = argparse.Namespace(recipe=str(ROOT/'script/release_recipe.json'),version=None,build_number=None,output=str(ROOT.parent/'ARL-external-test-output'),build_only=True)
        def fixture_capture(argv,seconds=15):
            if argv[:2] == ['/usr/bin/xcrun','--find']:return '/usr/bin/true'
            if argv[:2] == ['/usr/bin/xcrun','--sdk']:return '/System/Library'
            raise AssertionError(argv)
        with patch.object(b,'capture',side_effect=fixture_capture):
            with self.assertRaisesRegex(b.BuildError,'本项目 build'):
                b.preflight(args)

    def test_real_offline_resources_are_rebound_without_changing_helper_or_vendor(self):
        recipe = b.load(ROOT/'script/release_recipe.json')
        descriptor = b.load(ROOT/recipe['cache'])
        shell = ROOT/recipe['cache'];shell = shell.parent/descriptor['resource_shell']
        before = b.tree_inventory(shell)
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory).resolve()
            # The existing NAS staging has its own regression suite. Keep this test
            # offline/unsigned while exercising the real common resource copy.
            from types import SimpleNamespace
            ctx = {'output':out,'shell':shell,'cache':descriptor,'version':'0.1.2','build':'13','packager':b.load_packager(),
                   'build_only':True,'recipe':recipe,'nas_packager':SimpleNamespace(stage=lambda *a,**k:{'synthetic_nas_stage':True}),
                   'icon_packager':SimpleNamespace(stage=lambda *a,**k:{'synthetic_icon_stage':True})}
            core_spec = importlib.util.spec_from_file_location('fixture_core_packager',ROOT/'script/stage_core_runtime.py')
            core = importlib.util.module_from_spec(core_spec);core_spec.loader.exec_module(core)
            ctx.update(core_packager=core,core_private=False,read_owner_raw=(ROOT/recipe['read_owner_authority']['path']).read_bytes())
            app,record = b.stage_resources(ctx)
            info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
            self.assertEqual(info['NSAppleEventsUsageDescription'],b.APPLE_EVENTS_USAGE)
            runtime = app/'Contents/Resources/ServiceRuntime'
            self.assertEqual(info['ARLServiceRuntimeManifestSHA256'],b.sha(runtime/'inventory.json'))
            self.assertEqual(record['bridge_sha256'],b.sha(ROOT/'integrations/service_runtime/netease_bridge.cjs'))
            self.assertEqual((app/'Contents/Resources/ServiceConnections.json').read_bytes(),(ROOT/'docs/service-connections.json').read_bytes())
            for rel,meta in before.items():
                if rel == 'Contents/Resources/CredentialReadOwner/authority.json':
                    self.assertEqual((app/rel).read_bytes(),ctx['read_owner_raw'])
                elif rel.startswith('Contents/Library/') or rel.startswith('Contents/Resources/CredentialReadOwner/'):
                    self.assertEqual(b.sha(app/rel),meta['sha256'],rel)
            self.assertFalse((app/'Contents/MacOS/ARL').exists())
            self.assertFalse((app/'Contents/_CodeSignature').exists())
            self.assertFalse((out/'work/ServiceRuntime').exists())
            self.assertEqual(b.tree_inventory(shell),before)


if __name__=='__main__':unittest.main()
