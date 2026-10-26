"""Verified local incremental build: reuse unchanged nested components and SDK.
Re-links the changed main executable, stages the core, re-signs/inspects parent.
Never installs, starts a service or weakens any source/signature condition.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import sys
import build_release as b
from finalize_build import staged_release,finalize

ROOT=b.ROOT

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--base',required=True,type=Path);parser.add_argument('--build-number',required=True);parser.add_argument('--recipe',type=Path);parser.add_argument('--retain-staging',action='store_true')
    args=parser.parse_args();ctx=None;success=False;base_scope=None;base_entered=False
    try:
        base=args.base.absolute();b.no_links(base);b.require(ROOT/'build' in base.parents,'增量基线必须来自仓内 build')
        base_scope=staged_release(base);base_scope.__enter__();base_entered=True
        old=b.load(base/'package/manifest.json');artifact=b.load(base/'artifact.json');b.require(artifact['status']=='PASS' and b.sha(base/artifact['archive'])==artifact['archive_sha256'] and b.sha(base/'package/manifest.json')==artifact['manifest_sha256'],'基线回执或归档改变')
        b.require(b.tree_inventory(base/'package/ARL.app')==old['bundle_files'],'基线签名资源改变')
        namespace=argparse.Namespace(version=None,build_number=args.build_number,output=None,build_only=False,recipe=args.recipe,retain_staging=args.retain_staging,verified_mio_reuse=base)
        ctx=b.preflight(namespace);out=ctx['output'];b.require(not out.exists(),'增量输出已存在')
        # SDK, NAS, Mio, reminders, Finder and the inspector stay byte-identical.
        # Parent, CoreRuntime and independently staged Moments code may change.
        stable=set(ctx['recipe']['source_groups']['ARLCredentialOnboarding'])|set(ctx['recipe']['source_groups']['ARLCredentialHostCore'])
        stable|={ctx['recipe']['compression_c'],ctx['recipe']['compression_header'],'script/ReleasePackageInspector.swift'}
        stable|={r for r in ctx['source_hashes'] if r.startswith(('integrations/reminders_v3/','integrations/apple_permissions/','integrations/mio_apple/','integrations/credential_read_owner/','macOS/ARLFinderActions/','vendor/nas/','arl_nas_'))}
        stable |= {r for r in ctx["source_hashes"] if r.startswith("vendor/moments/")}
        # Some credential owner leaf files are also main-only inputs but their
        # changes would affect ownership; this reuse path rejects them.
        b.require(all(old['source_inputs'].get(r)==ctx['source_hashes'][r] for r in stable),'已验证组件源码变化，请改用完整构建')
        out.mkdir(parents=True,mode=0o700)
        for rel in ['logs','work/Home','work/tmp','package']:(out/rel).mkdir(parents=True,mode=0o700)
        shutil.copytree(base/'work/sdk',out/'work/sdk')
        shutil.copy2(base/'work/PackageInspector',out/'work/PackageInspector')
        app=out/'package/ARL.app';shutil.copytree(base/'package/ARL.app',app)
        # Remove only the copied parent seal/CoreRuntime; nested signed images
        # are retained unchanged, then checked against the original inventory.
        for directory in [app/'Contents/_CodeSignature',app/'Contents/Resources/CoreRuntime']:
            for p in directory.rglob('*'):
                if p.is_dir():p.chmod(0o700)
                elif p.is_file():p.chmod(0o600)
            directory.chmod(0o700);shutil.rmtree(directory)
        info_path=app/'Contents/Info.plist';info=plistlib.loads(info_path.read_bytes());info.update(CFBundleVersion=ctx['build'],CFBundleShortVersionString=ctx['version'])
        mode=stat.S_IMODE(info_path.stat().st_mode);info_path.chmod(mode|0o200);info_path.write_bytes(plistlib.dumps(info));info_path.chmod(mode)
        main_changed=old['recipe_sha256']!=ctx['recipe_sha256'] or any(old['source_inputs'].get(r)!=ctx['source_hashes'][r] for r in ctx['recipe']['source_groups']['Control_complete_link'])
        exe=app/'Contents/MacOS/ARL'
        if main_changed:exe.chmod(0o700);exe.unlink()
        moments_changed=any(old['source_inputs'].get(r)!=ctx['source_hashes'][r] for r in ctx['source_hashes'] if r.startswith('integrations/moments/') or r=='script/stage_moments_runtime.py')
        moments_record=old['runtime_stage_before_signing'].get('moments')
        if moments_changed:
            directory=app/'Contents/Resources/MomentsRuntime'
            for p in [directory,*directory.rglob('*')]:p.chmod(0o700 if p.is_dir() else 0o600)
            shutil.rmtree(directory)
            import importlib.util
            spec=importlib.util.spec_from_file_location('incremental_moments',ROOT/'script/stage_moments_runtime.py')
            packager=importlib.util.module_from_spec(spec);spec.loader.exec_module(packager)
            moments_record=packager.stage(app,ctx['recipe']['signing_identity'],False)
        core=ctx['core_packager'].stage(app,ctx['core_private'])
        nas_changed=any(old['source_inputs'].get(r)!=ctx['source_hashes'][r] for r in ctx['source_hashes'] if r.startswith('integrations/nas/runtime/'))
        if nas_changed:
            directory=app/'Contents/Resources/NASRuntime'
            for p in [directory,*directory.rglob('*')]:p.chmod(0o700 if p.is_dir() else 0o600)
            shutil.rmtree(directory)
            nas=ctx['nas_packager'].stage(app,cache_pin=ctx['recipe']['nas_runtime_cache_sha256'],build_only=False,signing_identity=ctx['recipe']['signing_identity'])
            probe=ctx['nas_packager'].import_probe_command(app)
            b.run(probe['argv'],probe['name'],out,b.BASE_ENV,probe['seconds'])
        else:
            nas=ctx['nas_packager'].refresh_staged_permissions(app)
        (out/'work/ARL.entitlements.plist').write_bytes(plistlib.dumps(b.MAIN_ENTITLEMENTS))
        env={**b.BASE_ENV,'HOME':str(out/'work/Home'),'TMPDIR':str(out/'work/tmp')}
        step=next(s for s in b.commands(ctx) if s['name']=='Control_complete_link')
        b.assert_inputs(ctx)
        if main_changed:b.run(step['argv'],step['name'],out,env,step['seconds'])
        post=[s for s in b.post_build_commands(ctx) if s['name'] in {'sign_ARL','inspect_signed_ARL','verify_signed_ARL','archive_package'}]
        for command in post[:-1]:b.run(command['argv'],command['name'],out,b.BASE_ENV,command['seconds'])
        signature=json.loads((out/'logs/inspect_signed_ARL.log').read_text());hash_exe=b.sha(exe)
        after=b.verify_authority(ctx['authority'],signature,hash_exe,plistlib.loads(info_path.read_bytes()))
        b.save(out/'package/ARL.authority.candidate.json',after)
        new_inventory=b.tree_inventory(app)
        retained={k:v for k,v in old['bundle_files'].items() if k.startswith(('Contents/Library/','Contents/PlugIns/','Contents/Resources/NASRuntime/','Contents/Resources/ServiceRuntime/','Contents/Resources/MomentsRuntime/'))}
        for key,row in retained.items():
            if moments_changed and key.startswith('Contents/Resources/MomentsRuntime/'):continue
            if nas_changed and key.startswith('Contents/Resources/NASRuntime/'):continue
            actual=new_inventory.get(key)
            if key in {'Contents/Resources/NASRuntime/inventory.json','Contents/Resources/NASRuntime/provenance.json'}:continue
            expected={**row,'mode':row['mode'] & ~0o022} if key.startswith('Contents/Resources/NASRuntime/') else row
            b.require(actual==expected,'增量期间已验证组件字节改变')
        manifest={**old,'build':ctx['build'],'version':ctx['version'],'executableSHA256':hash_exe,'signature':signature,'source_inputs':ctx['source_hashes'],'recipe_sha256':ctx['recipe_sha256'],'bundle_files':new_inventory,
          'runtime_stage_before_signing':{**old['runtime_stage_before_signing'],'core':core,'nas':nas,'moments':moments_record},'authority_candidate_sha256':b.sha(out/'package/ARL.authority.candidate.json'),'authority_before_sha256':ctx['recipe']['authority_template_sha256'],
          'authority_changed_fields':['executableSHA256'],'all_other_authority_fields_preserved':True,'incremental_base_manifest_sha256':artifact['manifest_sha256'],'unchanged_nested_components_reused':True,'main_relinked':main_changed,'installed':False,'launched':False}
        b.save(out/'package/manifest.json',manifest);b.assert_inputs(ctx)
        archive=out/f'ARL-{ctx["version"]}-{ctx["build"]}-arm64.zip';b.run(post[-1]['argv'],post[-1]['name'],out,env,post[-1]['seconds'])
        b.save(out/'artifact.json',{'status':'PASS','archive':archive.name,'archive_sha256':b.sha(archive),'manifest':'package/manifest.json','manifest_sha256':b.sha(out/'package/manifest.json'),'executableSHA256':hash_exe,'installed':False,'launched':False})
        if not args.retain_staging:finalize(out)
        success=True;print(json.dumps({'status':'PASS','build':ctx['build'],'unchanged_nested_components_reused':True,'main_relinked':main_changed,'installed':False}))
        return 0
    except Exception as error:
        if not isinstance(error,b.BuildError):
            import traceback; traceback.print_exc(limit=4)
        print(str(error) if isinstance(error,b.BuildError) else 'incremental_build_failed',file=sys.stderr);return 1
    finally:
        if base_entered:base_scope.__exit__(*sys.exc_info())
        if ctx and ctx['output'].exists():b.save(ctx['output']/'result.json',{'status':'PASS' if success else 'FAILED','installed':False,'launched':False})
if __name__=='__main__':raise SystemExit(main())
