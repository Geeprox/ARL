"""Isolated async launchd-state model; no real launchctl or production writes."""
import importlib.util
import json
import time
import unittest

from deployment.manage import DeploymentError
from tests import test_deployment as fixtures

ROOT = fixtures.ROOT

ASYNC_FAKE = '''#!/usr/bin/python3
import json,sys
from pathlib import Path
root=Path(__file__).parent
with (root/'calls.jsonl').open('a') as log:log.write(json.dumps(sys.argv[1:])+'\\n')
loaded=root/'loaded';pending=root/'unload-polls';cmd=sys.argv[1]
if cmd=='print':
 if (root/'deny-status').exists():
  print('Operation not permitted synthetic-secret /private/fixture',file=sys.stderr);sys.exit(1)
 if pending.exists():
  n=int(pending.read_text())
  if n>0:pending.write_text(str(n-1));sys.exit(0)
  pending.unlink();loaded.unlink(missing_ok=True)
 sys.exit(0 if loaded.exists() else 113)
if cmd=='bootout':
 if (root/'stall-bootout').exists():sys.exit(0)
 if (root/'delay-bootout').exists() and loaded.exists():pending.write_text('3')
 else:loaded.unlink(missing_ok=True)
 sys.exit(0)
if cmd=='bootstrap':
 if (root/'deny-bootstrap').exists():
  print('Bootstrap failed: 13: Permission denied synthetic-secret /private/fixture',file=sys.stderr);sys.exit(13)
 if loaded.exists() or (root/'fail-next-bootstrap').exists():
  (root/'fail-next-bootstrap').unlink(missing_ok=True)
  print('Bootstrap failed: 5: Input/output error synthetic-secret /private/fixture',file=sys.stderr);sys.exit(5)
 loaded.write_text('yes');sys.exit(0)
sys.exit(2)
'''

class LifecycleTests(unittest.TestCase):
    tearDown = fixtures.DeploymentTests.tearDown
    install = fixtures.DeploymentTests.install
    second = fixtures.DeploymentTests.second
    calls = fixtures.DeploymentTests.calls

    def setUp(self):
        fixtures.DeploymentTests.setUp(self)
        self.fake.write_text(ASYNC_FAKE)

    def test_original_missing_wait_reproduces_async_bootstrap_failure(self):
        self.install();(self.root/'delay-bootout').write_text('fixture')
        original=ROOT/'deployment/packages/control-first-four-20260930-candidate/manage.py'
        spec=importlib.util.spec_from_file_location('original_deployment_manager',original)
        module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
        legacy=module.Manager(test_root=self.root,fake_launchctl=self.fake)
        legacy.bootout()
        with self.assertRaisesRegex(module.DeploymentError,'bootstrap_failed'):legacy.bootstrap()
        self.assertTrue((self.root/'loaded').exists())
        self.manager.wait_unloaded();self.manager.bootstrap()
        self.assertGreaterEqual(self.manager.lifecycle_observation['status_polls'],2)
        self.assertTrue(self.manager.lifecycle_observation['service_absent'])

    def test_update_waits_for_absent_label_then_bootstraps_once(self):
        self.install();(self.root/'delay-bootout').write_text('fixture')
        n=sum(c[0]=='bootstrap' for c in self.calls())
        package,manifest=self.second();self.manager.deploy(package,manifest['release'],update=True)
        self.assertEqual(sum(c[0]=='bootstrap' for c in self.calls()),n+1)
        self.assertGreaterEqual(self.manager.lifecycle_observation['status_polls'],4)
        self.assertEqual(self.manager.installation()['current'],manifest['release'])

    def test_failed_update_retains_sanitized_cause_and_async_rollback(self):
        self.install();old=self.manager.installation()
        (self.root/'delay-bootout').write_text('fixture');(self.root/'fail-next-bootstrap').write_text('fixture')
        package,manifest=self.second()
        with self.assertRaisesRegex(DeploymentError,'bootstrap_failed'):self.manager.deploy(package,manifest['release'],update=True)
        self.assertEqual(self.manager.installation(),old);self.assertTrue((self.root/'loaded').exists())
        self.assertEqual(self.manager.launchctl_diagnostic,{'operation':'bootstrap','returncode':5,'code':5,'reason':'io_error'})
        self.assertNotIn('synthetic-secret',json.dumps(self.manager.launchctl_diagnostic))

    def test_unload_wait_has_deadline_without_retry_or_bootstrap(self):
        self.install();(self.root/'stall-bootout').write_text('fixture')
        self.manager.command('bootout',self.manager.target)
        count=sum(c[0]=='bootstrap' for c in self.calls());started=time.monotonic()
        with self.assertRaises(DeploymentError) as error:self.manager.wait_unloaded(timeout=.15)
        self.assertIn(str(error.exception),{'launchd_did_not_unload','launchctl_timeout'})
        self.assertLess(time.monotonic()-started,.65)
        self.assertEqual(sum(c[0]=='bootstrap' for c in self.calls()),count)

    def test_status_permission_failure_is_not_treated_as_absence(self):
        (self.root/'deny-status').write_text('fixture')
        with self.assertRaisesRegex(DeploymentError,'launchctl_status_failed'):self.manager.loaded()
        self.assertEqual(self.manager.launchctl_diagnostic['reason'],'operation_not_permitted')
        self.assertFalse(any(c[0]=='bootstrap' for c in self.calls()))

    def test_bootstrap_permission_diagnostic_has_no_raw_output(self):
        (self.root/'deny-bootstrap').write_text('fixture')
        with self.assertRaisesRegex(DeploymentError,'bootstrap_failed'):self.manager.bootstrap()
        self.assertEqual(self.manager.launchctl_diagnostic,{'operation':'bootstrap','returncode':13,'code':13,'reason':'permission_denied'})
        self.assertNotIn('fixture',json.dumps(self.manager.launchctl_diagnostic))
