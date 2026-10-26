"""Exercise the production SMBReader; only SMB Open/server I/O is synthetic."""
import importlib.util
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'integrations/nas/runtime'))
from homeplane.nas_connection.adapters import Reader, SMBReader, SFTPReader
from homeplane.nas_connection.contracts import relative_path, NASConnectionError
from smbprotocol.open import CreateOptions, ShareAccess, FileAttributes, DirectoryAccessMask, FilePipePrinterAccessMask as Access


class Value:
    def __init__(self, value): self.value = value
    def get_value(self): return self.value


class Server:
    def __init__(self, fail_final=False, deny_traverse=False, name="inside.txt"):
        self.name = name
        self.handles = []
        self.closed = []
        self.swaps = []
        self.outside = False
        self.fail_final = fail_final
        self.deny_traverse = deny_traverse
        self.requests = []

    def swap_ancestor(self):
        # MS-FSA 2.1.5.1.2.2: competing DELETE open shares READ/WRITE/DELETE.
        # Only participating existing access masks can deny that DELETE open;
        # READ_ATTRIBUTES alone must never count as a sharing barrier.
        participating = (Access.FILE_READ_DATA | Access.FILE_EXECUTE | Access.FILE_WRITE_DATA
                         | Access.FILE_APPEND_DATA | Access.DELETE)
        blocked = any(h.connected and h.path == 'allowed' and h.access & participating
                      and not h.share & ShareAccess.FILE_SHARE_DELETE for h in self.handles)
        self.swaps.append(not blocked)
        if not blocked: self.outside = True
        return not blocked


class WireOpen:
    def __init__(self, tree, path):
        self.server, self.path = tree, path.replace('\\', '/')
        self.connected = False
        self.file_attributes = FileAttributes.FILE_ATTRIBUTE_DIRECTORY
        self.file_id = b'fixture-id'
        self.queries = 0

    def create(self, impersonation, access, attributes, share, disposition, options):
        self.access, self.share, self.options = access, share, options
        self.server.requests.append((self.path, access))
        if self.server.deny_traverse and access & DirectoryAccessMask.FILE_TRAVERSE:
            raise PermissionError('synthetic traverse denied')
        if self.path == 'allowed/sub':
            self.server.swap_ancestor()
            if self.server.fail_final: raise OSError('synthetic final open failure')
        self.connected = True
        self.server.handles.append(self)

    def query_directory(self, *args, **kwargs):
        self.server.swap_ancestor()
        if self.server.outside: raise AssertionError('configured root ancestry escaped')
        self.queries += 1
        if self.queries > 1: return []
        return [{k: Value(v) for k, v in {
            'file_name': self.server.name.encode('utf-16-le'), 'file_attributes': 0,
            'end_of_file': 4, 'last_write_time': 0, 'change_time': 0, 'file_id': 7}.items()}]

    def close(self):
        if self.connected:
            self.connected = False
            self.server.closed.append(self.path)


class ReadAncestryTests(unittest.TestCase):
    def reader(self, server):
        reader = SMBReader.__new__(SMBReader)
        Reader.__init__(reader)
        reader.root, reader.tree = 'allowed/sub', server
        reader.connection = reader.session = None
        return reader

    @patch('smbprotocol.open.Open', WireOpen)
    def test_swap_blocked_until_health_final_cleanup(self):
        server = Server()
        self.assertTrue(self.reader(server).health()['readable'])
        self.assertEqual(server.swaps, [False, False])
        self.assertEqual(server.closed, ['allowed/sub', 'allowed'])
        self.assertTrue(all(h.share == ShareAccess.FILE_SHARE_READ for h in server.handles))
        self.assertTrue(all(h.options & CreateOptions.FILE_OPEN_REPARSE_POINT for h in server.handles))
        self.assertEqual(server.handles[0].access,
                         Access.FILE_READ_ATTRIBUTES | DirectoryAccessMask.FILE_TRAVERSE)
        self.assertTrue(server.swap_ancestor())

    @patch('smbprotocol.open.Open', WireOpen)
    def test_paged_cursor_retains_ancestors_until_explicit_close(self):
        server = Server()
        reader = self.reader(server)
        result = reader.list_page('', None, 1)
        self.assertEqual(result['entries'][0]['path'], 'inside.txt')
        self.assertIsNotNone(result['cursor'])
        self.assertFalse(server.swap_ancestor())
        self.assertEqual(server.closed, [])
        reader.close_cursors()
        self.assertEqual(server.closed, ['allowed/sub', 'allowed'])
        self.assertTrue(server.swap_ancestor())

    @patch('smbprotocol.open.Open', WireOpen)
    def test_failed_final_open_releases_verified_ancestors(self):
        server = Server(fail_final=True)
        with self.assertRaises(OSError): self.reader(server).health()
        self.assertEqual(server.swaps, [False])
        self.assertEqual(server.closed, ['allowed'])
        self.assertTrue(server.swap_ancestor())

    @patch('smbprotocol.open.Open', WireOpen)
    def test_traverse_denied_has_no_attributes_only_fallback(self):
        server = Server(deny_traverse=True)
        with self.assertRaises(PermissionError): self.reader(server).health()
        self.assertEqual(server.requests, [('allowed', Access.FILE_READ_ATTRIBUTES | DirectoryAccessMask.FILE_TRAVERSE)])
        self.assertEqual(server.handles, [])

    @patch('smbprotocol.open.Open', WireOpen)
    def test_percent_name_keeps_complete_page_and_ancestry(self):
        server = Server(name='100%完成')
        reader = self.reader(server)
        page = reader.list_page('', None, 128)
        self.assertEqual([e['path'] for e in page['entries']], ['100%完成'])
        self.assertIsNone(page['cursor'])
        self.assertFalse(server.outside)
        self.assertTrue(server.closed)

    @patch('smbprotocol.open.Open', WireOpen)
    def test_encoded_looking_component_is_literal_on_wire(self):
        server = Server()
        reader = self.reader(server)
        opened = reader._open('%2e%2e%2fprivate/100%done', directory=True)
        try:
            self.assertEqual(server.requests[-1][0], 'allowed/sub/%2e%2e%2fprivate/100%done')
            self.assertFalse(server.outside)
        finally:
            opened.close()

    def test_percent_does_not_relax_path_or_size_protection(self):
        for invalid in ['../private', 'allowed/../private', 'a\\b', 'a:b', '/root', 'a//b', 'a/./b', 'a\x00b', 'a' * 256]:
            with self.subTest(path=repr(invalid)), self.assertRaises(NASConnectionError):
                relative_path(invalid)
        self.assertEqual(relative_path('100%done/%2e%2e'), '100%done/%2e%2e')

    def test_sftp_literal_path_and_symlink_guard_remain(self):
        import stat
        from types import SimpleNamespace
        class WireSFTP:
            link = False
            def lstat(self, path): return SimpleNamespace(st_mode=stat.S_IFLNK if self.link else stat.S_IFDIR)
            def normalize(self, path): return path
        reader = SFTPReader.__new__(SFTPReader); reader.sftp = WireSFTP()
        self.assertEqual(reader._path('100%done/%2e%2e'), '/100%done/%2e%2e')
        reader.sftp.link = True
        with self.assertRaises(NASConnectionError): reader._path('100%done')


if __name__ == '__main__': unittest.main()
