"""dbcache 与 client 的集成冒烟测试（真实网络，需已登录）。"""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from ocusage.auth import CookieStore
from ocusage.client import OpenCodeClient
from ocusage.dbcache import UsageCache


@unittest.skipUnless(CookieStore.load(), "需要已登录的 cookie")
class IntegrationTest(unittest.TestCase):
    def test_incremental_roundtrip(self):
        cookie, wid = CookieStore.load()
        c = OpenCodeClient(cookie)
        db = UsageCache()
        n = db.sync_incremental(c, wid, max_pages=4)
        self.assertGreaterEqual(n, 0)
        # 立即再同步：应走快速路径，新增极少
        n2 = db.sync_incremental(c, wid, max_pages=4)
        self.assertLessEqual(n2, 10)
        stats = db.month_stats(wid, 2026, 8)
        self.assertGreater(stats["requests"], 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
