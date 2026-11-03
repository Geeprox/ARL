"""Real owned-child crash recovery in a temporary fixture; no installed app or accounts."""
from pathlib import Path
import subprocess
import sys
import shutil
import plistlib
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('xcrun'), 'macOS Swift process lifecycle required')
class BundledRuntimeWatchdogTests(unittest.TestCase):
    def test_owned_child_crashes_recover_without_replaying_business_or_restarting_siblings(self):
        (ROOT/'build').mkdir(exist_ok=True)
        # Match the installed app's canonical path boundary; Foundation may
        # normalize /private/var to /var differently from Python realpath.
        with tempfile.TemporaryDirectory(prefix='arl-watchdog-check-', suffix='.noindex', dir=ROOT/'build') as temporary:
            output = Path(temporary).resolve()
            app = output/'Fixture.app'
            (app/'Contents/MacOS').mkdir(parents=True)
            resources = app/'Contents/Resources'; resources.mkdir()
            binary = app/'Contents/MacOS/checks'
            (app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'local.arl.watchdog-fixture','CFBundleExecutable':'checks','CFBundlePackageType':'APPL'}))
            for source, name in [('/bin/sleep','sleep'),('/usr/bin/true','true')]:
                shutil.copyfile(source,resources/name)
                (resources/name).chmod(0o755)
            # Same-file extension exposes the actual private ensure/launch path;
            # the production source is copied verbatim, without replacements.
            owner = output/'BundledRuntimeOwner.swift'
            owner.write_text((ROOT/'macOS/ARLControl/Services/BundledRuntimeOwner.swift').read_text()+'''\nextension BundledRuntimeOwner {
    func ensureFixtureChild(key: String, executable: URL, arguments: [String]) throws {
        do { try ensureChild(key, executable: executable, arguments: arguments) }
        catch {
            FileHandle.standardError.write(Data(("fixture launch failure: " + String(describing:error) + " bundle=" + Bundle.main.bundleURL.path + " executable=" + executable.path + "\\n").utf8))
            throw error
        }
    }
}
''')
            sources = ['integrations/runtime_logging/ConnectionLog.swift',
                       'macOS/ARLControl/Services/BundledRuntimeOwner.swift',
                       'tests/BundledOwnerLifecycleTests.swift']
            built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-j', '1',
                '-D', 'ARL_LIFECYCLE_TEST', '-parse-as-library', '-module-cache-path', str(output/'cache'),
                *[str(owner) if name.endswith('/BundledRuntimeOwner.swift') else str(ROOT/name) for name in sources], '-o', str(binary)], capture_output=True, text=True, timeout=90)
            self.assertEqual(built.returncode, 0, built.stdout+built.stderr)
            result = subprocess.run([str(binary),str(resources/'sleep'),str(resources/'true')], capture_output=True, text=True, timeout=25)
            self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
            self.assertIn('real SIGKILL recovery', result.stdout)
            self.assertIn('unexpected zero exit restarts', result.stdout)
            self.assertIn('overlapping recovery/exit', result.stdout)

if __name__ == '__main__': unittest.main()
