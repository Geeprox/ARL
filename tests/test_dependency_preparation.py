"""No-network extraction, idempotency and interrupted-cache recovery checks."""
import hashlib
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import zipfile
import warnings
from script import install_tunnel as tunnel
from script import prepare_nas_dependencies as nas

class DependencyTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='arl-dependency-');self.root=Path(self.temp.name).resolve()
    def tearDown(self):self.temp.cleanup()
    def zip(self,name='tunnel-client',link=False):
        data=io.BytesIO()
        with zipfile.ZipFile(data,'w') as z:
            entry=zipfile.ZipInfo(name)
            if link:entry.external_attr=(0o120777<<16)
            z.writestr(entry,b'fixture binary never executed')
        return data.getvalue()
    def test_zip_path_escape_symlink_and_duplicate_reject(self):
        for name,link in [('../outside',False),('/absolute',False),('link',True)]:
            p=self.root/'archive.zip';p.write_bytes(self.zip(name,link))
            with self.assertRaises(ValueError):tunnel.safe_extract(p,self.root/'extract')
        data=io.BytesIO()
        with warnings.catch_warnings(),zipfile.ZipFile(data,'w') as z:
            warnings.simplefilter('ignore',UserWarning)
            z.writestr('duplicate',b'a');z.writestr('duplicate',b'b')
        p.write_bytes(data.getvalue())
        with self.assertRaises(ValueError):tunnel.safe_extract(p,self.root/'extract')
        self.assertFalse((self.root.parent/'outside').exists())
    def test_download_hash_gate_and_idempotent_install(self):
        raw=self.zip();info={'version':'v1.2.3','url':'https://github.com/example/fixture','sha256':hashlib.sha256(raw).hexdigest()}
        with patch.object(tunnel,'PREFIX',self.root/'client'),patch.object(tunnel,'fetch',return_value=raw) as fetch:
            with self.assertRaisesRegex(ValueError,'download_hash_mismatch'):tunnel.install({**info,'sha256':'0'*64})
            binary=tunnel.install(info);self.assertTrue(binary.is_file())
            count=fetch.call_count;self.assertEqual(tunnel.install(info),binary);self.assertEqual(fetch.call_count,count)
            (self.root/'client/installation.json').unlink()
            self.assertEqual(tunnel.install(info),binary);self.assertEqual(fetch.call_count,count)
            binary.write_bytes(b'changed')
            with self.assertRaisesRegex(ValueError,'installed_client_changed'):tunnel.installed()
    def test_tar_link_escape_is_not_followed(self):
        data=io.BytesIO()
        with tarfile.open(fileobj=data,mode='w') as t:
            link=tarfile.TarInfo('dir');link.type=tarfile.SYMTYPE;link.linkname='../../outside';t.addfile(link)
            regular=tarfile.TarInfo('dir/value');regular.size=1;t.addfile(regular,io.BytesIO(b'x'))
        path=self.root/'archive.tar';path.write_bytes(data.getvalue())
        with self.assertRaises(ValueError):nas.unpack_tar(path,self.root/'extract')
        self.assertFalse((self.root.parent/'outside/value').exists())
    def test_interrupted_partial_cache_is_recovered_only_if_inventory_matches(self):
        cache=self.root/'cache';(cache/'python').mkdir(parents=True);(cache/'python/bin').write_bytes(b'known')
        receipt={'schema':1,'python':nas.inventory(cache/'python',links=True),'licenses':{}}
        (cache/'PREPARE-RECOVERY.json').write_text(json.dumps(receipt))
        with patch.object(nas,'CACHE',cache):
            self.assertFalse(nas.recovery());self.assertFalse((cache/'python').exists())
            (cache/'python').mkdir();(cache/'python/bin').write_bytes(b'changed')
            (cache/'PREPARE-RECOVERY.json').write_text(json.dumps(receipt))
            with self.assertRaisesRegex(ValueError,'partial_cache_changed'):nas.recovery()
            self.assertTrue((cache/'python/bin').exists())
