
"""The production manager, broker and host; only SMB medium is synthetic."""
from test_nas_runtime_assembly import AssemblyTests, SMB, bootstrap
from unittest.mock import patch
import unittest

class DirectoryTests(AssemblyTests):
    # Do not rerun the inherited old suite in this focused increment.
    async def directory_request(self, path="", cursor=None, **extra):
        return await self.runtime.command(dict(kind="directories", id=2, nonce=self.wire.nonce,
                                              path=path, cursor=cursor, **extra))

    async def test_directory_navigation_and_opaque_inventory(self):
        def listing(reader, path, cursor, limit):
            self.assertEqual(limit,128)
            self.assertIsNone(cursor)
            if path == "":
                return {"entries":[{"path":"child","kind":"directory","revision":"b"*64,"size":0},
                                   {"path":"secret.txt","kind":"file","revision":"c"*64,"size":4}],
                        "cursor":None,"complete":True}
            self.assertEqual(path,"child")
            return {"entries":[],"cursor":None,"complete":True}
        with patch.object(SMB,"list_page",listing):
            await self.runtime.connect(bootstrap())
            page=await self.directory_request()
            self.assertEqual(page,{"path":"","directories":["child"],"next_cursor":None})
            self.assertEqual((await self.directory_request("child"))["directories"],[])
            self.assertEqual(self.wire.lease_count,1)
            self.assertIn("request_reply",self.wire.stages)

    async def test_directory_rejects_escape_unknown_nonce_and_late_revocation(self):
        await self.runtime.connect(bootstrap())
        for path in ["../escape", "/absolute", "unknown", "child/../../escape"]:
            with self.assertRaises(Exception): await self.directory_request(path)
        with self.assertRaises(Exception):
            await self.runtime.command(dict(kind="directories",id=2,nonce="bad",path="",cursor=None))
        SMB.after_list=lambda:setattr(self.wire,"reject","request_reply")
        with self.assertRaises(Exception):await self.directory_request()

    async def test_directory_page_uses_existing_scoped_cursor(self):
        def listing(reader,path,cursor,limit):
            if cursor is None:return {"entries":[],"cursor":"private-transport-cursor","complete":False}
            self.assertEqual(cursor,"private-transport-cursor")
            return {"entries":[{"path":"child","kind":"directory","revision":"b"*64,"size":0}],"cursor":None,"complete":True}
        with patch.object(SMB,"list_page",listing):
            await self.runtime.connect(bootstrap())
            page=await self.directory_request()
            self.assertEqual(len(page["next_cursor"]),32)
            self.assertEqual((await self.directory_request(cursor=page["next_cursor"]))["directories"],["child"])
            with self.assertRaises(Exception):await self.directory_request(cursor=page["next_cursor"])

if __name__ == "__main__":
    suite=unittest.TestSuite(DirectoryTests(n) for n in DirectoryTests.__dict__ if n.startswith("test_directory_"))
    result=unittest.TextTestRunner(verbosity=2).run(suite)
    raise SystemExit(not result.wasSuccessful())
