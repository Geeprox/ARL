"""Offline production build/package entrypoint. Never installs or launches ARL."""
import argparse
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import stat
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
MAIN_ENTITLEMENTS = {'com.apple.security.automation.apple-events': True,
                     'com.apple.security.personal-information.calendars': True}
CALENDAR_FULL_USAGE = '查看日程并在确认后保存修改。'
REMINDERS_FULL_USAGE = '读取提醒事项，并在您确认操作后保存修改。'
CALENDAR_WRITE_USAGE = 'ARL 仅在您确认日程后创建事件，不读取现有日历内容。'
APPLE_EVENTS_USAGE = 'ARL 仅在您主动操作时连接备忘录和信息；访问范围及每次写入内容在应用内清楚显示。'
FINDER_IDENTIFIER = 'local.arl.control.finderactions'
FINDER_RELATIVE_BUNDLE = 'Contents/PlugIns/ARLFinderActions.appex'
FINDER_INPUTS = ['macOS/ARLFinderActions/FinderActionSelection.swift',
                 'macOS/ARLFinderActions/FinderActions.swift',
                 'macOS/ARLFinderActions/Info.plist',
                 'macOS/ARLFinderActions/FinderActions.entitlements',
                 'script/FinderPackageInspector.swift',
                 'tests/FinderActionSelectionTests.swift']
FINDER_ENTITLEMENTS = {'com.apple.security.app-sandbox': True,
                       'com.apple.security.files.user-selected.read-only': True}
BASE_ENV = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'LANG': 'C', 'LC_ALL': 'C',
            'PYTHONDONTWRITEBYTECODE': '1', 'TMPDIR': str(ROOT/'build')}


class BuildError(RuntimeError):
    pass


def require(value, reason):
    if not value:
        raise BuildError(reason)


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def no_links(path):
    for p in (path, *path.parents):
        require(not p.is_symlink(), f'不接受符号链接：{p}')


def regular(path):
    no_links(path)
    require(path.is_file() and stat.S_ISREG(path.stat().st_mode), f'缺少普通文件：{path}')
    return path


def relative(root, rel):
    p = Path(rel)
    require(not p.is_absolute() and '..' not in p.parts and str(p) != '.', f'无效相对路径：{rel}')
    target = root/p
    no_links(target)
    return target


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, f'JSON 重复字段：{key}')
        result[key] = value
    return result


def load(path):
    return json.loads(regular(path).read_bytes(), object_pairs_hook=unique_object)


def save(path, value):
    with path.open('x') as stream:
        json.dump(value, stream, indent=2, ensure_ascii=False, sort_keys=True)
        stream.write('\n')


def tree_inventory(root):
    no_links(root)
    require(root.is_dir(), f'离线资源目录缺失：{root}')
    result = {}
    for p in sorted(root.rglob('*')):
        no_links(p)
        require(p.is_dir() or p.is_file(), f'资源含特殊文件：{p}')
        if p.is_file():
            result[str(p.relative_to(root))] = {'sha256': sha(p), 'mode': stat.S_IMODE(p.stat().st_mode)}
    return result


def capture(argv, seconds=15):
    """Only short read-only preflight tools; no compiler or signing here."""
    try:
        p = subprocess.run(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, env=BASE_ENV, timeout=seconds, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise BuildError(f'依赖检查失败：{argv[0]} ({type(exc).__name__})') from exc
    require(p.returncode == 0, f'依赖检查失败：{argv[0]}：{p.stderr.decode(errors="replace")[-2000:]}')
    return p.stdout.decode().strip()


def run(argv, name, out, env, seconds):
    """Serial trusted build tools, fresh process session, finite timeout and wait."""
    log = out/'logs'/f'{name}.log'
    started = time.monotonic()
    with log.open('xb') as stream:
        child = subprocess.Popen(list(map(str, argv)), stdin=subprocess.DEVNULL,
                                 stdout=stream, stderr=subprocess.STDOUT, env=env,
                                 cwd=ROOT, start_new_session=True, close_fds=True)
        failure = None
        try:
            # Popen.wait owns reaping of this direct child. A timeout/interrupt
            # signals only this build's session while the child is still owned.
            result = child.wait(timeout=seconds)
        except BaseException as exc:
            failure = exc
            if child.returncode is None:
                try:
                    os.killpg(child.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    child.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    try:
                        os.killpg(child.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    child.wait(timeout=5)
            result = child.returncode
    save(out/'logs'/f'{name}.json', {'argv': list(map(str, argv)), 'returncode': result,
         'seconds': round(time.monotonic()-started, 3), 'direct_child_reaped': True,
         'timeout_or_interruption': type(failure).__name__ if failure else None})
    if failure:
        raise BuildError(f'{name} 超时或中断（{type(failure).__name__}）；日志：{log}') from failure
    text = log.read_text(errors='replace')
    require(result == 0, f'{name} 失败（退出码 {result}）；日志：{log}\n{text[-4000:]}')
    return text


def load_packager():
    spec = importlib.util.spec_from_file_location('arl_release_runtime', ROOT/'integrations/service_runtime/package_resources.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def verify_authority(before, signature, executable_hash, info):
    require(before['identifier'] == info['CFBundleIdentifier'] == signature['identifier'], 'authority identifier 不匹配')
    require(before['certificateSHA1'].upper() == signature['certificateSHA1'].upper(), '签名证书与 authority 不匹配')
    require(before['teamOU'] == signature['team'], '签名 Team 与 authority 不匹配')
    require(before['designatedRequirement'] == signature['designatedRequirement'], '签名 designated requirement 与 authority 不匹配')
    entitlements = signature.get('entitlements')
    require(isinstance(entitlements, dict) and set(entitlements) == set(MAIN_ENTITLEMENTS)
            and all(type(v) is bool and v for v in entitlements.values()),
            '正式包必须精确声明 Apple Events 和 Calendar entitlement')
    require(signature['status'] == 'PASS' and signature['entitlementsEmpty'] is False
            and signature['hardenedRuntime'] is True
            and info.get('NSAppleEventsUsageDescription') == APPLE_EVENTS_USAGE
            and info.get('NSCalendarsWriteOnlyAccessUsageDescription') == CALENDAR_WRITE_USAGE
            and info.get('NSCalendarsFullAccessUsageDescription') == CALENDAR_FULL_USAGE
            and info.get('NSRemindersFullAccessUsageDescription') == REMINDERS_FULL_USAGE
            and 'NSCalendarsUsageDescription' not in info, '最终签名条件不符合正式包要求')
    require(signature['executableSHA256'] == executable_hash, '签名检查器与最终 executableSHA256 不匹配')
    after = dict(before)
    after['executableSHA256'] = executable_hash
    require({k for k in before if before[k] != after[k]} <= {'executableSHA256'}, 'authority 存在未允许变更')
    return after


def validate_finder_configuration(info, entitlements):
    required = {'CFBundleDevelopmentRegion','CFBundleExecutable','CFBundleIdentifier',
                'CFBundleName','CFBundleDisplayName','CFBundlePackageType',
                'CFBundleShortVersionString','CFBundleVersion','LSMinimumSystemVersion','NSExtension'}
    require(set(info) == required and info['CFBundleIdentifier'] == FINDER_IDENTIFIER
            and info['CFBundleExecutable'] == 'ARLFinderActions'
            and info['CFBundleName'] == info['CFBundleDisplayName'] == '访达动作'
            and info['CFBundlePackageType'] == 'XPC!'
            and info['NSExtension'] == {'NSExtensionAttributes': {},
                'NSExtensionPointIdentifier': 'com.apple.FinderSync',
                'NSExtensionPrincipalClass': 'ARLFinderActions'}, 'Finder extension metadata 不匹配')
    require(entitlements == FINDER_ENTITLEMENTS
            and all(type(v) is bool for v in entitlements.values()),
            'Finder extension 仅允许沙箱及用户选定文件只读权限')


def preflight(args, root=ROOT):
    require(sys.platform == 'darwin', '正式 ARL 包只能在 macOS 构建')
    require(os.uname().machine == 'arm64', '现有正式构建链仅支持 Apple Silicon / arm64')
    default_recipe=root/'script/release_recipe.json'
    private_recipe=root/'build/local-config/release_recipe.json'
    supplied=getattr(args,'recipe',None)
    recipe_path=Path(supplied).absolute() if supplied else private_recipe if private_recipe.is_file() else default_recipe
    recipe = load(recipe_path)
    product = recipe['product']
    icon_spec = importlib.util.spec_from_file_location('arl_app_icon', root/'script/stage_app_icon.py')
    icon_packager = importlib.util.module_from_spec(icon_spec);icon_spec.loader.exec_module(icon_packager)
    icon_record = icon_packager.preflight()
    helper_spec = importlib.util.spec_from_file_location('arl_reminders_static', root/'integrations/reminders_v3/build_static.py')
    reminders = importlib.util.module_from_spec(helper_spec)
    helper_spec.loader.exec_module(reminders)
    require(recipe['reminders_helper'] == {'linkage':'static','signing_identity':reminders.HELPER_SIGNER,
            'designated_requirement':reminders.HELPER_REQUIREMENT}, '提醒事项静态 helper 身份不匹配')
    require(recipe['schema'] == 1 and product['name'] == 'ARL'
            and product['identifier'] == 'local.arl.control'
            and product['target'] == 'arm64-apple-macos14.0', '生产 recipe 身份不符合 ARL')
    version, build = args.version or product['version'], args.build_number or product['build']
    require(bool(re.fullmatch(r'[0-9]+(?:\.[0-9]+){1,2}', version)), '版本格式应为 0.1.2 或 0.1')
    require(bool(re.fullmatch(r'[0-9]+', build)), 'build number 必须为非负整数')
    groups = recipe['source_groups']
    require(set(groups) == {'ARLCredentialOnboarding', 'ARLCredentialHostCore', 'Control_complete_link'}, '生产编译组不完整')
    all_sources = [r for v in groups.values() for r in v]
    require(len(all_sources) == len(set(all_sources)), '生产输入有重复源码')
    source_hashes = {r:sha(regular(relative(root, r))) for r in all_sources}
    # Explicit pinned leaf reuse avoids implicitly compiling adjacent effect
    # owners/tests. Normal production directories retain full source-set checks.
    leaves = recipe.get('external_leaf_inputs', {})
    require(isinstance(leaves, dict) and set(leaves) <= set(all_sources), '独立复用源码声明无效')
    for rel, pin in leaves.items():
        require(source_hashes[rel] == pin, f'独立复用源码改变，请复核：{rel}')
    for folder in {str(Path(r).parent) for r in all_sources} - {'examples'}:
        actual = {str(p.relative_to(root)) for p in (root/folder).glob('*.swift')}
        expected = {r for r in all_sources if str(Path(r).parent) == folder}
        if expected <= set(leaves):
            continue
        require(actual == expected, f'源码集合改变，请先复核 recipe：{folder}')
    for rel in [recipe['compression_c'], recipe['compression_header'], 'script/ReleasePackageInspector.swift',
                'script/build_release.py', 'script/build_incremental.py', 'script/finalize_build.py', 'script/run_install_management.py', 'integrations/reminders_v3/build_static.py', 'build.sh', 'Build.command', 'integrations/service_runtime/package_resources.py',
                'integrations/service_runtime/netease_bridge.cjs', 'docs/service-connections.json']:
        source_hashes[rel] = sha(regular(relative(root, rel)))
    moments_spec = importlib.util.spec_from_file_location('arl_moments_packager', root/'script/stage_moments_runtime.py')
    moments_packager = importlib.util.module_from_spec(moments_spec); moments_spec.loader.exec_module(moments_packager)
    moments_packager.preflight()
    for rel in moments_packager.inputs(): source_hashes[rel] = sha(regular(relative(root, rel)))
    for rel in icon_packager.source_inputs():
        source_hashes[rel] = sha(regular(relative(root, rel)))
    require(source_hashes['script/ReleasePackageInspector.swift'] == recipe['inspector_source_sha256'], '正式签名检查器源码改变')
    cache_path = relative(root, recipe['cache'])
    require(sha(regular(cache_path)) == recipe['cache_sha256'], '离线 vendor cache 清单 pin 不匹配')
    cache = load(cache_path)
    shell = relative(cache_path.parent, cache['resource_shell'])
    require(cache['schema'] == 1 and tree_inventory(shell) == cache['files'], '离线 vendor 资源被修改、缺失或 mode 改变')
    require(not (shell/'Contents/MacOS/ARL').exists() and not (shell/'Contents/_CodeSignature').exists(), '离线资源壳不能含旧主程序或外层签名')
    packager = load_packager()
    packager.verified_inventory(shell/'Contents/Resources/ServiceRuntime', cache['runtime_inventory_sha256'])
    nas_spec = importlib.util.spec_from_file_location("arl_nas_packager", root/"script/stage_nas_runtime.py")
    nas_packager = importlib.util.module_from_spec(nas_spec)
    nas_spec.loader.exec_module(nas_packager)
    nas_packager.preflight(recipe["nas_runtime_cache_sha256"])
    for rel in nas_packager.source_inputs():
        source_hashes[rel] = sha(regular(relative(root, rel)))
    core_spec = importlib.util.spec_from_file_location("arl_core_packager", root/"script/stage_core_runtime.py")
    core_packager = importlib.util.module_from_spec(core_spec); core_spec.loader.exec_module(core_packager)
    core_private = recipe.get("core_runtime", {}).get("profile") == "local-compatibility"
    for rel in core_packager.inputs(core_private): source_hashes[rel] = sha(regular(relative(root, rel)))
    mio_packager = mio_template = None
    if recipe.get("mio_runtime"):
        mio_spec = importlib.util.spec_from_file_location("arl_mio_packager", root/"script/stage_mio_runtime.py")
        mio_packager = importlib.util.module_from_spec(mio_spec); mio_spec.loader.exec_module(mio_packager)
        reuse = getattr(args, 'verified_mio_reuse', None)
        if reuse is not None:
            base = Path(reuse).absolute(); no_links(base)
            require(root/'build' in base.parents, 'Mio 复用必须来自本仓已验证归档')
            artifact = load(base/'artifact.json'); baseline = load(base/'package/manifest.json')
            require(artifact['status'] == 'PASS' and sha(base/artifact['archive']) == artifact['archive_sha256']
                    and sha(base/'package/manifest.json') == artifact['manifest_sha256'], 'Mio 复用归档改变')
            require(tree_inventory(base/'package/ARL.app') == baseline['bundle_files'], 'Mio 复用签名资源改变')
            mio_template = base/'package/ARL.app/Contents/Library/LoginItems/ARLMioAppleBridge.app'
        else:
            mio_template = mio_packager.preflight(recipe["mio_runtime"], tree_inventory)
        for rel in mio_packager.inputs(): source_hashes[rel] = sha(regular(relative(root, rel)))
    info = plistlib.loads(regular(shell/'Contents/Info.plist').read_bytes())
    require(info['CFBundleName'] == info['CFBundleDisplayName'] == info['CFBundleExecutable'] == 'ARL'
            and info['CFBundleIdentifier'] == 'local.arl.control', '离线资源壳身份不符合正式 ARL')
    internal_authority = shell/'Contents/Resources/CredentialReadOwner/authority.json'
    require(sha(regular(internal_authority)) == info['ARLCredentialReadOwnerAuthoritySHA256'], '公开 owner authority 资源绑定不匹配')
    catalog = load(root/'docs/service-connections.json')
    require(catalog['schema_version'] == 1 and [v['id'] for v in catalog['services']] == ['amap','fliggy','netease','codex'],
            '正式服务 catalog 不完整')
    overlay = recipe.get('read_owner_authority')
    require(type(overlay) is dict and set(overlay) == {'path','sha256'}, '需要固定源码 read-owner 资源')
    read_owner_path = regular(relative(root, overlay['path']))
    require(sha(read_owner_path) == overlay['sha256'], 'read-owner 源码资源 pin 改变')
    read_owner_raw = read_owner_path.read_bytes()
    read_owner = json.loads(read_owner_raw)
    original_read_owner = load(internal_authority)
    require(set(read_owner) == {'schema','executionAllowed','reviewID','owner','mio','capabilities'}
            and read_owner['schema'] == 2 and read_owner['executionAllowed'] is True
            and read_owner['owner'] == original_read_owner['owner'] and read_owner['mio'] == original_read_owner['mio']
            and set(read_owner['capabilities']) == {'travel_read','music_read','music_status','music_playlist_create','music_playlist_append','music_playlist_cover','apple_reminders_task','nas_saved_scope_read','apple_product_v1'}
            and len(read_owner['capabilities']) == 9, 'read-owner 有限能力迁移不匹配')
    import uuid
    require(type(read_owner['reviewID']) is str, 'read-owner reviewID 无效')
    try: uuid.UUID(read_owner['reviewID'])
    except (ValueError, TypeError, AttributeError): raise BuildError('read-owner reviewID 无效') from None
    source_hashes[overlay['path']] = sha(read_owner_path)
    authority_path = relative(root, recipe['authority_template'])
    require(sha(regular(authority_path)) == recipe['authority_template_sha256'], '公开 authority 模板 pin 不匹配；应由 writer 复核迁入')
    authority = load(authority_path)
    require(authority['schema'] == 3 and authority['storageRoute'] == 'local-team-reentry-v1'
            and authority['identifier'] == product['identifier']
            and authority['certificateSHA1'].upper() == recipe['signing_identity']
            and Path(authority['bundlePath']).name == 'ARL.app', '公开 authority 模板身份不匹配')
    # This read enumerates existing signing identities. No certificate/private
    # key is created, exported, unlocked, or replaced by this entrypoint.
    build_only = getattr(args,'build_only',False)
    if not build_only:
        identities = capture(['/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning'])
        require(all(identity in identities.upper() for identity in (recipe['signing_identity'], reminders.HELPER_SIGNER)),
                f'当前环境未检出有效正式签名身份 {recipe["signing_identity"]}；请核实证书或 Keychain 访问条件，不会回退 ad-hoc 或创建证书')
    tools = {name: capture(['/usr/bin/xcrun', '--find', name]) for name in ('swiftc', 'clang', 'ar')}
    sdk = capture(['/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-path'])
    require(all(Path(p).is_file() for p in tools.values()) and Path(sdk).is_dir(), 'Xcode 编译器或 macOS SDK 缺失')
    output = Path(args.output).expanduser().absolute() if args.output else root/'build/releases.noindex'/f'ARL-{version}-{build}'
    no_links(output)
    require(not any(p.name == 'Applications' for p in (output, *output.parents)), '输出不能写入 Applications')
    require((root/'build') in output.parents,
            '构建输出必须位于本项目 build/ 下，禁止外部临时目录')
    require(any(p.name.endswith('.noindex') for p in (output,*output.parents)), 'App 暂存必须位于 .noindex 目录，防止产生搜索重复入口')
    require(not output.exists(), f'输出已存在：{output}；请指定新的 --output，不会覆盖旧产物')
    reminders_plan = reminders.plan(output/'work/reminders', shell/reminders.HELPER_REL, tools['swiftc'], sdk)
    source_hashes.update(reminders_plan['sources'])
    for rel in FINDER_INPUTS:
        source_hashes[rel] = sha(regular(relative(root, rel)))
    finder_info = plistlib.loads((root/'macOS/ARLFinderActions/Info.plist').read_bytes())
    finder_entitlements = plistlib.loads((root/'macOS/ARLFinderActions/FinderActions.entitlements').read_bytes())
    validate_finder_configuration(finder_info, finder_entitlements)
    actual_finder_sources = {str(p.relative_to(root)) for p in (root/'macOS/ARLFinderActions').glob('*.swift')}
    expected_finder_sources = {p for p in FINDER_INPUTS if p.startswith('macOS/') and p.endswith('.swift')}
    require(actual_finder_sources == expected_finder_sources, 'Finder extension 源码集合改变，请先复核')
    finder = {'identifier': FINDER_IDENTIFIER, 'relative_bundle': FINDER_RELATIVE_BUNDLE,
              'info': finder_info,
              'designated_requirement': authority['designatedRequirement'].replace('"local.arl.control"', '"'+FINDER_IDENTIFIER+'"')}
    for tool in ('/usr/bin/codesign','/usr/bin/ditto','/usr/bin/security','/usr/bin/otool'):
        require(Path(tool).is_file() and os.access(tool,os.X_OK),f'构建依赖缺失：{tool}')
    return {'verified_mio_reuse':getattr(args,'verified_mio_reuse',None), 'icon_packager':icon_packager, 'app_icon':icon_record, 'core_packager':core_packager, 'core_private':core_private, 'mio_packager':mio_packager, 'mio_template':mio_template, 'recipe': recipe, 'recipe_path':recipe_path, 'recipe_sha256':sha(recipe_path), 'cache':cache, 'shell':shell,
            'authority':authority, 'authority_path':authority_path, 'read_owner_raw':read_owner_raw, 'source_hashes':source_hashes,
            'version':version, 'build':build, 'output':output, 'tools':tools, 'sdk':sdk, 'packager':packager,'nas_packager':nas_packager,'build_only':build_only,'retain_staging':getattr(args,'retain_staging',False),'reminders':reminders,'reminders_plan':reminders_plan,'finder_extension':finder}


def commands(ctx):
    recipe, out = ctx['recipe'], ctx['output']
    work = out/'work'
    sdk_dir = work/'sdk'
    module_map = '-fmodule-map-file='+str(sdk_dir/'FlyAICompression/module.modulemap')
    target = recipe['product']['target']
    common = [ctx['tools']['swiftc'], '-sdk',ctx['sdk'], '-j','1','-swift-version','6',
              '-suppress-warnings','-target',target,'-module-cache-path',str(ROOT/'build/cache/ModuleCache')]
    steps = [ctx['nas_packager'].document_compile_step(out,ctx['tools']['swiftc'],ctx['sdk'],target), {'name':'compression', 'seconds':30, 'argv':[ctx['tools']['clang'], '-isysroot',ctx['sdk'],
              '-target',target,'-c',str(ROOT/recipe['compression_c']),'-I',str((ROOT/recipe['compression_header']).parent),
              '-o',str(sdk_dir/'FlyAICompression.o')]}]
    for name, seconds in [('ARLCredentialOnboarding',120),('ARLCredentialHostCore',60)]:
        steps.append({'name':name,'seconds':seconds,'argv':common+['-parse-as-library','-whole-module-optimization',
            '-emit-module','-emit-object','-I',str(sdk_dir),'-Xcc',module_map,'-module-name',name,
            '-emit-module-path',str(sdk_dir/(name+'.swiftmodule')),
            *[str(ROOT/r) for r in recipe['source_groups'][name]],'-o',str(sdk_dir/(name+'.o'))]})
    steps.append({'name':'archive_SDK','seconds':15,'argv':[ctx['tools']['ar'],'rcs',str(sdk_dir/'libARLCredentialHostCore.a'),
        *[str(sdk_dir/(n+'.o')) for n in ('ARLCredentialOnboarding','ARLCredentialHostCore','FlyAICompression')]]})
    steps.append({'name':'Control_complete_link','seconds':150,'argv':common+['-I',str(sdk_dir),'-L',str(sdk_dir),
        '-lARLCredentialHostCore','-lz','-Xcc',module_map,
        *[str(ROOT/r) for r in recipe['source_groups']['Control_complete_link']],'-o',str(out/'package/ARL.app/Contents/MacOS/ARL')]})
    steps.append({'name':'PackageInspector','seconds':30,'argv':common+['-parse-as-library',str(ROOT/'script/ReleasePackageInspector.swift'),
        '-o',str(work/'PackageInspector')]})
    steps.extend(ctx['reminders_plan']['steps'])
    if ctx.get('finder_extension'):
        extension = out/'package/ARL.app'/FINDER_RELATIVE_BUNDLE
        steps.append({'name':'Finder_extension','seconds':60,'argv':common+[
            '-parse-as-library','-application-extension','-emit-executable',
            '-module-name','ARLFinderActions','-Xlinker','-e','-Xlinker','_NSExtensionMain',
            '-framework','Foundation','-framework','AppKit','-framework','FinderSync',
            *[str(ROOT/rel) for rel in FINDER_INPUTS if rel.endswith('.swift') and rel.startswith('macOS/')],
            '-o',str(extension/'Contents/MacOS/ARLFinderActions')]})
        steps.append({'name':'FinderInspector','seconds':30,'argv':common+[
            '-parse-as-library',str(ROOT/'script/FinderPackageInspector.swift'),'-o',str(work/'FinderInspector')]})
        steps.append({'name':'Finder_selection_regression_compile','seconds':30,'argv':common+[
            '-parse-as-library',str(ROOT/'macOS/ARLFinderActions/FinderActionSelection.swift'),
            str(ROOT/'tests/FinderActionSelectionTests.swift'),'-o',str(work/'FinderActionSelectionTests')]})
        steps.append({'name':'Finder_selection_regression_run','seconds':15,
            'argv':[str(work/'FinderActionSelectionTests')]})
    if ctx.get('mio_packager'): steps.append(ctx['mio_packager'].compile_step(out, ctx['tools']['swiftc'], ctx['sdk']))
    return steps


def post_build_commands(ctx):
    out = ctx['output']
    app = out/'package/ARL.app'
    rule = ctx['authority']['designatedRequirement']
    archive = out/f'ARL-{ctx["version"]}-{ctx["build"]}-arm64.zip'
    helper = app/ctx['reminders'].HELPER_REL
    result = [
        {'name':'sign_Reminders','seconds':30,'argv':['/usr/bin/codesign','--force','--options','runtime','--timestamp=none',
         '--sign',ctx['reminders'].HELPER_SIGNER,'--identifier','local.arl.remindersbridge',
         '--requirements','=designated => '+ctx['reminders'].HELPER_REQUIREMENT,str(helper)]},
        {'name':'verify_Reminders','seconds':20,'argv':['/usr/bin/codesign','--verify','--strict','--deep',
         '-R','='+ctx['reminders'].HELPER_REQUIREMENT,str(helper)]},
        {'name':'sign_ARL','seconds':30,'argv':['/usr/bin/codesign','--force','--options','runtime','--timestamp=none',
         '--sign',ctx['recipe']['signing_identity'],'--identifier','local.arl.control',
         '--entitlements',str(out/'work/ARL.entitlements.plist'),'--requirements','=designated => '+rule,str(app)]},
        {'name':'inspect_signed_ARL','seconds':20,'argv':[str(out/'work/PackageInspector'),str(app),rule]},
        {'name':'verify_signed_ARL','seconds':30,'argv':['/usr/bin/codesign','--verify','--strict','--deep','--verbose=2',str(app)]},
        {'name':'archive_package','seconds':60,'argv':['/usr/bin/ditto','-c','-k','--sequesterRsrc','--keepParent',str(out/'package'),str(archive)]}]
    result.insert(-1, ctx['nas_packager'].import_probe_command(app))
    if ctx.get('mio_packager'):
        config = ctx['recipe']['mio_runtime']
        nested = app/ctx['mio_packager'].RELATIVE
        mio_steps = [
            {'name':'sign_Mio','seconds':30,'argv':['/usr/bin/codesign','--force','--options','runtime','--timestamp=none',
             '--sign',config['signing_identity'],'--identifier','local.arl.mioapplebridge',
             '--requirements','=designated => '+config['designated_requirement'],str(nested)]},
            {'name':'verify_Mio','seconds':30,'argv':['/usr/bin/codesign','--verify','--strict','--deep',
             '-R','='+config['designated_requirement'],str(nested)]}]
        result[2:2] = mio_steps
    if ctx.get('finder_extension'):
        extension = app/FINDER_RELATIVE_BUNDLE
        requirement = ctx['finder_extension']['designated_requirement']
        finder_steps = [
            {'name':'sign_Finder','seconds':30,'argv':['/usr/bin/codesign','--force','--options','runtime','--timestamp=none',
                '--sign',ctx['recipe']['signing_identity'],'--identifier',FINDER_IDENTIFIER,
                '--entitlements',str(out/'work/Finder.entitlements.plist'),
                '--requirements','=designated => '+requirement,str(extension)]},
            {'name':'inspect_signed_Finder','seconds':20,'argv':[str(out/'work/FinderInspector'),str(extension),requirement]},
            {'name':'verify_signed_Finder','seconds':20,'argv':['/usr/bin/codesign','--verify','--strict','--deep',
                '-R','='+requirement,str(extension)]}]
        result[2:2] = finder_steps # Nested code must be signed before the parent.
    return result



def replace(path, raw):
    mode = stat.S_IMODE(path.stat().st_mode)
    path.chmod(mode | 0o200)
    path.write_bytes(raw)
    path.chmod(mode)


def stage_resources(ctx):
    out, shell = ctx['output'], ctx['shell']
    stage = out/'work/ServiceRuntime'
    shutil.copytree(shell/'Contents/Resources/ServiceRuntime', stage)
    bridge = stage/'Bridge/netease_bridge.cjs'
    replace(bridge, (ROOT/'integrations/service_runtime/netease_bridge.cjs').read_bytes())
    provenance = load(stage/'provenance.json')
    provenance['bridge_sha256'] = sha(bridge)
    replace(stage/'provenance.json', (json.dumps(provenance,indent=2,sort_keys=True)+'\n').encode())
    inventory = load(stage/'inventory.json')
    for rel in ['Bridge/netease_bridge.cjs','provenance.json']:
        p = stage/rel
        inventory[rel] = {'sha256':sha(p), 'bytes':p.stat().st_size, 'mode':stat.S_IMODE(p.stat().st_mode)}
    replace(stage/'inventory.json',(json.dumps(inventory,indent=2,sort_keys=True)+'\n').encode())
    app = out/'package/ARL.app'
    def ignore(directory, names):
        return ['ServiceRuntime'] if Path(directory) == shell/'Contents/Resources' else []
    shutil.copytree(shell, app, ignore=ignore)
    catalog = app/'Contents/Resources/ServiceConnections.json'
    replace(catalog, (ROOT/'docs/service-connections.json').read_bytes())
    info_path = app/'Contents/Info.plist'
    info = plistlib.loads(info_path.read_bytes())
    info.update(CFBundleShortVersionString=ctx['version'], CFBundleVersion=ctx['build'],
                ARLInstallSnapshotLayout=2,
                NSAppleEventsUsageDescription=APPLE_EVENTS_USAGE,
                NSCalendarsWriteOnlyAccessUsageDescription=CALENDAR_WRITE_USAGE,
                NSCalendarsFullAccessUsageDescription=CALENDAR_FULL_USAGE,
                NSRemindersFullAccessUsageDescription=REMINDERS_FULL_USAGE,
                NSBonjourServices=['_smb._tcp'],
                NSLocalNetworkUsageDescription='点击查找网络硬盘时，ARL 查找同一网络内的 SMB 设备；连接仅在您保存设置并主动测试后进行。')
    replace(info_path, plistlib.dumps(info))
    if ctx.get('finder_extension'):
        extension = app/FINDER_RELATIVE_BUNDLE
        require(not extension.exists(), 'Finder extension 输出不能覆盖已有内容')
        (extension/'Contents/MacOS').mkdir(parents=True, mode=0o755)
        finder_info = {**ctx['finder_extension']['info'], 'CFBundleVersion':ctx['build'],
                       'CFBundleShortVersionString':ctx['version']}
        (extension/'Contents/Info.plist').write_bytes(plistlib.dumps(finder_info))
        (out/'work/Finder.entitlements.plist').write_bytes(plistlib.dumps(FINDER_ENTITLEMENTS))
    runtime_record = ctx['packager'].populate(stage, app, sha(stage/'inventory.json'))
    runtime_record["nas"] = ctx["nas_packager"].stage(app,document_worker=ctx["output"]/"work/NASPDFTextExtractor",
        cache_pin=ctx["recipe"]["nas_runtime_cache_sha256"], build_only=ctx.get("build_only",False),
        signing_identity=ctx["recipe"]["signing_identity"])
    if ctx.get('finder_extension'):
        runtime_record['finder_extension'] = {'relative_bundle':FINDER_RELATIVE_BUNDLE,
            'identifier':FINDER_IDENTIFIER,'user_enable_required':True,'system_enable_performed':False}
    runtime_record['core'] = ctx['core_packager'].stage(app, ctx['core_private'])
    if ctx.get('mio_packager'):
        runtime_record['mio'] = ctx['mio_packager'].stage(app, ctx['mio_template'], ctx['build'], ctx['recipe']['mio_runtime'].get('policy_sha256'), verified_template=bool(ctx.get('verified_mio_reuse')))
    # Apply the reviewed source resource only to our staged copy. Both signed
    # bundles carry one exact seal; the immutable vendor shell remains unchanged.
    owner_seal = hashlib.sha256(ctx['read_owner_raw']).hexdigest()
    owner_bundles = [app]
    if ctx.get('mio_packager'): owner_bundles.append(app/'Contents/Library/LoginItems/ARLMioAppleBridge.app')
    for bundle in owner_bundles:
        resource = bundle/'Contents/Resources/CredentialReadOwner/authority.json'
        replace(resource, ctx['read_owner_raw'])
        info_path = bundle/'Contents/Info.plist'
        info = plistlib.loads(info_path.read_bytes()); info['ARLCredentialReadOwnerAuthoritySHA256'] = owner_seal
        if bundle == app and ctx['core_private']: info['ARLCodexServicePolicyVersion'] = 1
        else: info.pop('ARLCodexServicePolicyVersion', None)
        replace(info_path, plistlib.dumps(info))
    require(tree_inventory(shell) == ctx['cache']['files'], '打包过程中 vendor 资源改变')
    # populate verified the copy; this invocation owns the redundant staging tree.
    for directory, _dirs, _files in os.walk(stage):
        Path(directory).chmod(0o700)
    shutil.rmtree(stage)
    moments_spec = importlib.util.spec_from_file_location('arl_moments_packager_stage', ROOT/'script/stage_moments_runtime.py')
    moments_packager = importlib.util.module_from_spec(moments_spec); moments_spec.loader.exec_module(moments_packager)
    runtime_record['moments'] = moments_packager.stage(app, ctx['recipe']['signing_identity'], ctx.get('build_only',False))
    runtime_record['app_icon'] = ctx['icon_packager'].stage(app)
    return app, runtime_record


def assert_inputs(ctx):
    require(all(sha(regular(ROOT/rel)) == pin for rel,pin in ctx['source_hashes'].items()), '构建期间源码或 builder 发生变化')
    require(sha(ctx['recipe_path']) == ctx['recipe_sha256'], '构建期间 recipe 改变')
    require(sha(ROOT/ctx['recipe']['cache']) == ctx['recipe']['cache_sha256'], '构建期间 vendor cache 清单改变')
    require(sha(ctx['authority_path']) == ctx['recipe']['authority_template_sha256'], '构建期间公开 authority 模板改变')
    require(tree_inventory(ctx['shell']) == ctx['cache']['files'], '构建期间 vendor 资源改变')
    if ctx.get('mio_packager'):
        if ctx.get('verified_mio_reuse'):
            base = Path(ctx['verified_mio_reuse'])
            artifact = load(base/'artifact.json'); baseline = load(base/'package/manifest.json')
            require(sha(base/'package/manifest.json') == artifact['manifest_sha256']
                    and tree_inventory(base/'package/ARL.app') == baseline['bundle_files'], 'Mio 复用签名资源改变')
        else:
            ctx['mio_packager'].preflight(ctx['recipe']['mio_runtime'], tree_inventory)


def build(ctx):
    out = ctx['output']
    out.mkdir(parents=True, mode=0o700)
    for rel in ['logs','work/sdk/FlyAICompression','work/Home','work/tmp']:
        (out/rel).mkdir(parents=True, mode=0o700, exist_ok=True)
    cache = ROOT/'build/cache/ModuleCache'
    no_links(cache)
    cache.mkdir(parents=True, exist_ok=True)
    env = {**BASE_ENV, 'HOME':str(out/'work/Home'),'TMPDIR':str(out/'work/tmp'),
           'CLANG_MODULE_CACHE_PATH':str(cache), 'SWIFT_MODULE_CACHE_PATH':str(cache)}
    plan = native_plan(ctx)
    save(out/'native-plan.json',plan)
    success = False
    try:
        for step in commands(ctx):
            if step.get('phase') == 'prestage':
                assert_inputs(ctx)
                run(step['argv'],step['name'],out,env,step['seconds'])
        app, runtime_record = stage_resources(ctx)
        ctx['reminders'].prepare(ctx['reminders_plan'])
        header = str(ROOT/ctx['recipe']['compression_header'])
        (out/'work/sdk/FlyAICompression/module.modulemap').write_text('module FlyAICompression { header "'+header+'" export * }\n')
        for step in commands(ctx):
            if step.get('phase') == 'prestage': continue
            print(f'构建：{step["name"]}',file=sys.stderr,flush=True)
            assert_inputs(ctx)
            run(step['argv'],step['name'],out,env,step['seconds'])
        assert_inputs(ctx)
        helper = Path(ctx['reminders_plan']['app'])/'Contents/MacOS/ARLRemindersBridge'
        dependencies = capture(['/usr/bin/otool','-L',str(helper)],10)
        runtime_record['reminders'] = ctx['reminders'].stage_compiled(ctx['reminders_plan'],app,dependencies)
        if ctx.get('build_only',False):
            save(out/'build-only-manifest.json',{'status':'NATIVE_BUILD_ONLY_PASS',
                 'executableSHA256':sha(app/'Contents/MacOS/ARL'),
                 'source_inputs':ctx['source_hashes'],'recipe_sha256':ctx['recipe_sha256'],
                 'runtime_stage_before_signing':runtime_record,'bundle_files':tree_inventory(app),
                 'app_package_signing_performed':False,'package_identity_authenticated':False,
                 'installed':False,'launched':False,'authority_candidate_generated':False})
            success = True
            print(f'native 构建完成，未进入签名或归档：{app}\n构建记录：{out/"build-only-manifest.json"}')
            return
        before = ctx['authority']
        (out/'work/ARL.entitlements.plist').write_bytes(plistlib.dumps(MAIN_ENTITLEMENTS))
        post = post_build_commands(ctx)
        signature = None
        for step in post[:-1]:
            raw = run(step['argv'],step['name'],out,BASE_ENV,step['seconds'])
            if step['name'] == 'inspect_signed_ARL':signature = json.loads(raw)
        require(signature is not None, '正式签名检查结果缺失')
        info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
        require(info['CFBundleVersion'] == ctx['build'] and info['CFBundleShortVersionString'] == ctx['version'], '包版本不匹配')
        executable_hash = sha(app/'Contents/MacOS/ARL')
        after = verify_authority(before,signature,executable_hash,info)
        save(out/'package/ARL.authority.candidate.json',after)
        require(sha(app/'Contents/Resources/CredentialReadOwner/authority.json') == info['ARLCredentialReadOwnerAuthoritySHA256'], 'owner authority 资源绑定改变')
        assert_inputs(ctx)
        manifest = {'schema':1,'status':'SIGNED_PACKAGE_VERIFIED','product':{'name':'ARL','identifier':'local.arl.control',
             'version':ctx['version'],'build':ctx['build'],'architecture':'arm64'},
             'executableSHA256':executable_hash,'signature':signature,'source_inputs':ctx['source_hashes'],
             'recipe_sha256':ctx['recipe_sha256'],'vendor_cache_sha256':ctx['recipe']['cache_sha256'],
             'runtime_stage_before_signing':runtime_record,'bundle_files':tree_inventory(app),
             'authority_before_sha256':ctx['recipe']['authority_template_sha256'],
             'authority_candidate_sha256':sha(out/'package/ARL.authority.candidate.json'),
             'authority_changed_fields':sorted(k for k in before if before[k] != after[k]),
             'authority_install_target':before['bundlePath'], 'all_other_authority_fields_preserved':True,
             'installed':False,'launched':False,'uploaded':False,'notarized':False,
             'distribution':'Local signed package only; release/notarization approval and notices are separate.'}
        save(out/'package/manifest.json',manifest)
        archive = out/f'ARL-{ctx["version"]}-{ctx["build"]}-arm64.zip'
        run(post[-1]['argv'],post[-1]['name'],out,BASE_ENV,post[-1]['seconds'])
        # Archive bytes and all signed files are stable before success is issued.
        require(tree_inventory(app) == manifest['bundle_files'], '归档期间签名包改变')
        save(out/'artifact.json',{'status':'PASS','archive':archive.name,'archive_sha256':sha(archive),
             'manifest':'package/manifest.json','manifest_sha256':sha(out/'package/manifest.json'),
             'executableSHA256':executable_hash,'installed':False,'launched':False})
        if not ctx.get('retain_staging',False):
            from finalize_build import finalize
            finalize(out)
        success = True
        print(f'构建打包成功：{archive}\n核验 manifest：{out/"package/manifest.json"}')
    finally:
        result = 'BUILD_ONLY_PASS' if ctx.get('build_only',False) else 'PASS'
        save(out/'result.json',{'status':result if success else 'FAILED','installed':False,'launched':False})


def native_plan(ctx):
    return {'schema':1,'workers':1,'status':'PLAN_ONLY_NO_NATIVE_COMMAND_STARTED',
            'output':str(ctx['output']),'version':ctx['version'],'build':ctx['build'],
            'recipe_sha256':ctx['recipe_sha256'],'source_inputs':ctx['source_hashes'],'reminders':ctx['reminders_plan'],
            'vendor_cache_sha256':ctx['recipe']['cache_sha256'],
            'authority_template_sha256':ctx['recipe']['authority_template_sha256'],
            'steps':commands(ctx),'native_step_timeout_total':sum(s['seconds'] for s in commands(ctx)),
            'execution_mode':'NATIVE_BUILD_ONLY' if ctx.get('build_only',False) else 'BUILD_SIGN_PACKAGE',
            'post_build_steps':[] if ctx.get('build_only',False) else post_build_commands(ctx),
            'post_build_timeout_total':0 if ctx.get('build_only',False) else sum(s['seconds'] for s in post_build_commands(ctx)),
            'signing_identity':ctx['recipe']['signing_identity'],'installed':False,'launched':False,
            'signing':'Not performed in build-only mode.' if ctx.get('build_only',False) else 'After compile: hardened runtime, no timestamp network request, exact existing identity; final static Security inspector + strict/deep verify.',
            'authority':'No authority candidate generated in build-only mode.' if ctx.get('build_only',False) else 'Candidate only: final executableSHA256; all other public authority fields must remain unchanged.'}


def main():
    parser = argparse.ArgumentParser(description='离线构建正式 ARL 签名包；默认不安装、不启动、不上传。')
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument('--check',action='store_true',help='只检查本地前置输入、Xcode 和签名条件')
    modes.add_argument('--plan',action='store_true',help='检查后输出 native 构建计划 JSON，不启动编译器')
    parser.add_argument('--recipe',help='用户本机已审的完整配置；默认优先 ignored build/local-config，不修改权限。')
    parser.add_argument('--output',help='新输出目录；默认 build/releases.noindex/ARL-版本-build')
    parser.add_argument('--version',help='显式版本号；默认保留 recipe 版本')
    parser.add_argument('--build-number',help='显式 build number；默认保留 recipe build')
    parser.add_argument('--build-only',action='store_true',help='协调者验证用：只运行 native 编译，不检查 Keychain、不签名、不归档')
    parser.add_argument('--retain-staging',action='store_true',help='仅定向审查：在 .noindex 中暂留 App；验收后必须收尾')
    args = parser.parse_args()
    def terminate(_signum, _frame):
        raise BuildError('收到终止信号')
    signal.signal(signal.SIGTERM,terminate)
    try:
        ctx = preflight(args)
        if args.check:
            print(f'前置检查通过；尚未构建。输出将为：{ctx["output"]}')
        elif args.plan:
            print(json.dumps(native_plan(ctx),indent=2,ensure_ascii=False))
        else:
            # Serialize this entrypoint across output directories. External
            # compiler slots remain the calling coordinator's responsibility.
            (ROOT/'build').mkdir(exist_ok=True)
            with (ROOT/'build/release.lock').open('a') as lock:
                try:
                    fcntl.flock(lock,fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError as exc:
                    raise BuildError('已有 ARL build.sh 构建在运行；本次未启动编译器') from exc
                ctx = preflight(args)
                build(ctx)
        return 0
    except (BuildError,OSError,ValueError,KeyError) as exc:
        print(f'构建失败：{exc}',file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
