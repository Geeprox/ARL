"""Actual native discovery and Notes read boundaries; synthetic events only."""
from pathlib import Path
import json
import platform
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]

@unittest.skipUnless(sys.platform=='darwin' and shutil.which('xcrun'),'macOS Swift required')
class NativeApplicationRegressionTests(unittest.TestCase):
    def compile_run(self,sources,*,flags=(),fixture=False,sdk=False):
        with tempfile.TemporaryDirectory(prefix='arl-native-boundaries-') as directory:
            root=Path(directory).resolve();binary=root/'checks'
            if sdk:
                recipe=json.loads((ROOT/'script/release_recipe.json').read_text())
                header=ROOT/recipe['compression_header']
                module=root/'FlyAICompression';module.mkdir()
                modulemap=module/'module.modulemap'
                modulemap.write_text('module FlyAICompression { header "'+str(header)+'" export * }\n')
                target=platform.machine()+'-apple-macos14.0'
                result=subprocess.run(['xcrun','clang','-target',target,'-c',str(ROOT/recipe['compression_c']),
                    '-I',str(header.parent),'-o',str(root/'FlyAICompression.o')],capture_output=True,text=True,timeout=60)
                self.assertEqual(result.returncode,0,result.stderr[-8000:])
                sources=[*recipe['source_groups']['ARLCredentialOnboarding'],*sources]
                flags=[*flags,'-target',target,'-Xcc','-fmodule-map-file='+str(modulemap),
                    str(root/'FlyAICompression.o'),'-lz','-lsqlite3']
            result=subprocess.run(['xcrun','swiftc','-swift-version','6','-j','1','-parse-as-library',
                '-module-cache-path',str(root/'cache'),*flags,*[str(ROOT/p) for p in sources],'-o',str(binary)],
                capture_output=True,text=True,timeout=240 if sdk else 120)
            self.assertEqual(result.returncode,0,result.stderr[-8000:])
            result=subprocess.run([str(binary),*([str(root/'fixture')] if fixture else [])],capture_output=True,text=True,timeout=30)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr[-6000:])
    def test_discovery_aliases_deduplicate_without_merging_unrelated_devices(self):
        self.compile_run(['macOS/ARLControl/Views/EditorialStyle.swift',
            'macOS/ARLControl/NASSettings/NASAddressInput.swift',
            'macOS/ARLControl/NASSettings/NASDiscovery.swift','macOS/ARLControl/NASSettings/NASDiscoverySection.swift',
            'tests/NASDiscoveryRefreshTests.swift'],flags=['-D','NAS_DISCOVERY_FIXTURE'])
    def test_notes_read_all_and_write_scope_guards(self):
        self.compile_run(['macOS/ARLControl/Services/AppleDirectEvents.swift',
            'macOS/ARLControl/Services/AppleDirectJournal.swift','macOS/ARLControl/Models/AppleConnectionState.swift',
            'macOS/ARLControl/Services/AppleStatusCoordinator.swift','macOS/ARLControl/Models/NotesDirectModels.swift',
            'macOS/ARLControl/Services/NotesDirectBackend.swift','tests/NotesDirectTests.swift'],fixture=True)
    def test_archive_recovery_preserves_unknown_foreign_revoked_and_busy_mounts(self):
        self.compile_run(['tests/NASArchiveRecoveryTests.swift'],sdk=True)

if __name__=='__main__':unittest.main()
