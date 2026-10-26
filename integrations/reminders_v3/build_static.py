"""Static Reminders helper construction shared by the normal release builder.

This module never signs, installs, launches or queries EventKit. Its template is
an already pinned bundle Info.plist; all policy and usage text are preserved.
"""
from pathlib import Path
import hashlib
import plistlib
import re
import shutil

ROOT = Path(__file__).resolve().parents[2]
HELPER_REL = 'Contents/Library/LoginItems/ARLRemindersBridge.app'
HELPER_SIGNER = '859332B7FFFBBBB33B80C7B78D30C27D2D81583F'
HELPER_REQUIREMENT = 'identifier "local.arl.remindersbridge" and certificate root = H"859332b7fffbbbb33b80c7b78d30c27d2d81583f"'
CORE = ['integrations/reminders_v3/adapter_source/ARLRemindersCore/'+n for n in
        ('Models.swift', 'OperationJournal.swift', 'Service.swift')]
EVENTKIT = ['integrations/reminders_v3/adapter_source/ARLRemindersEventKit/EventKitRepository.swift']
HOST = ['integrations/reminders_v3/'+n for n in ('PermissionBrokerMain.swift',
        'RemindersPermissionIntegration.swift', 'RemindersFirstHost.swift', 'RemindersUpgradeReview.swift', 'RemindersTaskStore.swift', 'RemindersProductRequest.swift', 'RemindersProductHandler.swift')]+[
        'integrations/apple_permissions/NativePermissions.swift',
        'macOS/ARLControl/Services/RemindersNativeSocket.swift',
        'macOS/ARLControl/Models/RemindersFirstSlice.swift',
        'macOS/ARLControl/Models/RemindersTask.swift',
        'macOS/ARLControl/Models/RemindersProductModels.swift']


def require(value, code):
    if not value:
        raise ValueError(code)


def no_links(path):
    require(not any(p.is_symlink() for p in (path, *path.parents)), 'reminders_symlink_refused')


def digest(path):
    no_links(path)
    require(path.is_file(), 'reminders_input_missing')
    return hashlib.sha256(path.read_bytes()).hexdigest()


def plan(output, template, swiftc, sdk):
    out, template = Path(output).absolute(), Path(template).absolute()
    no_links(out)
    require(ROOT/'build' in out.parents and not out.exists(), 'reminders_output_not_new_build_path')
    info_path = template/'Contents/Info.plist'
    pin = digest(info_path)
    info = plistlib.loads(info_path.read_bytes())
    require(info.get('CFBundleIdentifier') == 'local.arl.remindersbridge'
            and info.get('CFBundleExecutable') == 'ARLRemindersBridge', 'reminders_template_identity')
    require(isinstance(info.get('ARLFirstRemindersPolicyPath'), str)
            and info['ARLFirstRemindersPolicyPath'].startswith('/')
            and re.fullmatch('[a-f0-9]{64}', info.get('ARLFirstRemindersPolicySHA256', '')),
            'reminders_sealed_policy_required')
    require(info.get('ARLRemindersLinkage') in (None, 'static'), 'reminders_unknown_linkage')
    work, app = out/'work', out/'ARLRemindersBridge.app'
    common = [str(swiftc), '-sdk', str(sdk), '-j', '1', '-swift-version', '6',
              '-target', 'arm64-apple-macos14.0', '-module-cache-path', str(work/'ModuleCache')]
    steps = []
    for name, sources, seconds in [('ARLRemindersCore', CORE, 120), ('ARLRemindersEventKit', EVENTKIT, 60)]:
        steps.append({'name':name, 'seconds':seconds, 'argv':common+['-parse-as-library',
            '-whole-module-optimization', '-emit-module', '-emit-object', '-module-name', name,
            '-emit-module-path', str(work/(name+'.swiftmodule')), '-I', str(work),
            *[str(ROOT/p) for p in sources], '-o', str(work/(name+'.o'))]})
    steps.append({'name':'Reminders_static_helper', 'seconds':180, 'argv':common+[
        '-parse-as-library', '-I', str(work), *[str(ROOT/p) for p in HOST],
        str(work/'ARLRemindersCore.o'), str(work/'ARLRemindersEventKit.o'),
        '-o', str(app/'Contents/MacOS/ARLRemindersBridge')]})
    return {'schema':1, 'linkage':'static', 'output':str(out), 'app':str(app),
            'template':str(template), 'template_info_sha256':pin,
            'sources':{p:digest(ROOT/p) for p in CORE+EVENTKIT+HOST},
            'steps':steps, 'native_timeout_total':360, 'installed':False, 'launched':False}


def verify_inputs(candidate):
    require(digest(Path(candidate['template'])/'Contents/Info.plist') == candidate['template_info_sha256'],
            'reminders_template_changed')
    require(all(digest(ROOT/p) == pin for p,pin in candidate['sources'].items()), 'reminders_source_changed')


def prepare(candidate):
    verify_inputs(candidate)
    out, app = Path(candidate['output']), Path(candidate['app'])
    no_links(out)
    require(ROOT/'build' in out.parents and app == out/'ARLRemindersBridge.app', 'reminders_stage_path')
    out.mkdir(parents=True, exist_ok=False)
    (out/'work/ModuleCache').mkdir(parents=True)
    (app/'Contents/MacOS').mkdir(parents=True)
    info = plistlib.loads((Path(candidate['template'])/'Contents/Info.plist').read_bytes())
    info['ARLRemindersLinkage'] = 'static'
    (app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))


def validate_dependencies(detail):
    values = [line.strip().split(' (',1)[0] for line in detail.splitlines()[1:] if line.strip()]
    require(values and all(p.startswith(('/System/Library/', '/usr/lib/'))
            or re.fullmatch(r'@rpath/libswift[A-Za-z0-9_]+\.dylib',p) for p in values),
            'reminders_non_system_dynamic_dependency')
    return values


def stage_compiled(candidate, app, dependency_detail):
    verify_inputs(candidate)
    dependencies = validate_dependencies(dependency_detail)
    app, built = Path(app), Path(candidate['app'])
    target = app/HELPER_REL
    no_links(target)
    require(ROOT/'build' in app.parents and app.name == 'ARL.app', 'reminders_stage_not_release')
    expected = {'Contents/Info.plist', 'Contents/MacOS/ARLRemindersBridge'}
    actual = {str(p.relative_to(built)) for p in built.rglob('*') if p.is_file()}
    require(actual == expected and not any(p.is_symlink() for p in built.rglob('*')), 'reminders_unsigned_layout')
    expected_info = plistlib.loads((Path(candidate['template'])/'Contents/Info.plist').read_bytes())
    expected_info['ARLRemindersLinkage'] = 'static'
    require((built/'Contents/Info.plist').read_bytes() == plistlib.dumps(expected_info), 'reminders_policy_drift')
    # Retain the copied historical helper for audit; never touch the pinned cache.
    retained = Path(candidate['output'])/'retained-template.app'
    require(target.is_dir() and not retained.exists(), 'reminders_template_missing')
    target.rename(retained)
    shutil.copytree(built, target)
    return {'linkage':'static', 'template_info_sha256':candidate['template_info_sha256'],
            'unsigned_executable_sha256':digest(target/'Contents/MacOS/ARLRemindersBridge'),
            'dynamic_dependencies':dependencies, 'policy_preserved':True,
            'identity_preserved_requires_final_signing':True, 'permission_status_verified':False,
            'installed':False, 'launched':False}
