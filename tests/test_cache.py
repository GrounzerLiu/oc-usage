"""缓存机制单元测试：增量截断、历史缓存 TTL、统计聚合。"""
import json
import os
import sys
import tempfile
import unittest
from datetime import datetime, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from ocusage.dbcache import UsageCache, _local_iso
from ocusage.models import HistoryEntry, UsageRecord


def make_record(i: int, minutes_ago: int) -> UsageRecord:
    t = datetime.now() - timedelta(minutes=minutes_ago)
    return UsageRecord(
        id=f"usg_test_{i:08d}",
        time_created=t.strftime("%Y-%m-%dT%H:%M:%S.000Z"),
        model="test-model",
        provider="test",
        input_tokens=1000,
        output_tokens=500,
        reasoning_tokens=100,
        cache_read_tokens=200,
        cost=12345,
        key_id="key_1",
        plan=None,
    )


class FakeClient:
    """模拟服务端：records 按时间倒序分页（每页 50 条）。

    new_count 条"新增"记录（id 从 1000 起）排在最前，
    之后接 total-new_count 条旧记录（id 从 0 起，与已有缓存一致）。
    """

    def __init__(self, total: int, new_count: int = 0):
        new = [make_record(1000 + i, i) for i in range(new_count)]
        old = [make_record(i, new_count + i) for i in range(total - new_count)]
        self.records = new + old
        self.calls: list[int] = []  # 记录被请求的页码

    def fetch_page_records(self, workspace_id: str, page: int) -> list[UsageRecord]:
        self.calls.append(page)
        data = self._eval_server_response(self._rpc_page_raw(workspace_id, page), "x")
        return self._records_from_raw(data)

    def _rpc_page_raw(self, workspace_id: str, page: int) -> str:
        """模拟 RPC 响应文本（sync_full 分批路径使用）。"""
        start = page * 50
        return json.dumps([r.__dict__ for r in self.records[start : start + 50]])

    def _eval_server_response(self, text: str, label: str):
        return json.loads(text)

    def _records_from_raw(self, raw: list) -> list[UsageRecord]:
        return [UsageRecord(**r) for r in raw]

    def fetch_all_usage(self, workspace_id: str, max_pages=800, workers=8):
        out, seen = [], set()
        for p in range(max_pages):
            recs = self.fetch_page_records(workspace_id, p)
            if not recs:
                break
            out.extend(r for r in recs if r.id not in seen)
            seen.update(r.id for r in recs)
        return out


class CacheTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.mkdtemp()
        self.db = UsageCache(Path(tmp) / "cache.db")

    def test_incremental_cutoff(self):
        """核心：增量同步遇到已缓存 id 截断，不重复拉旧页。"""
        # 第一轮：库空 → 全量 250 条（5 页）
        client = FakeClient(250)
        n = self.db.sync_incremental(client, "wrk_x", max_pages=100)
        self.assertEqual(n, 250)
        self.assertEqual(self.db.record_count(), 250)

        # 第二轮：新增 60 条 → 应只拉 page0/1（遇到已知 id 截断）
        client2 = FakeClient(310, new_count=60)
        n2 = self.db.sync_incremental(client2, "wrk_x", max_pages=100)
        self.assertEqual(n2, 60)
        self.assertEqual(self.db.record_count(), 310)
        # 只拉了 page0（前 50 条全新）+ 又拉 page1 直到遇到已知 id
        self.assertLessEqual(len(client2.calls), 3)
        self.assertIn(0, client2.calls)

        # 第三轮：无新增 → 快速路径，只拉 page0 且 0 新增
        client3 = FakeClient(310)
        n3 = self.db.sync_incremental(client3, "wrk_x", max_pages=100)
        self.assertEqual(n3, 0)
        self.assertEqual(client3.calls, [0])

    def test_month_stats(self):
        """SQL 聚合与插入数据一致。"""
        client = FakeClient(50)
        self.db.sync_incremental(client, "wrk_x", max_pages=10)
        stats = self.db.month_stats("wrk_x", datetime.now().year, datetime.now().month)
        self.assertEqual(stats["requests"], 50)
        # token = (1000+500+100+200) * 50
        self.assertEqual(stats["tokens"], 1800 * 50)
        self.assertGreaterEqual(stats["days"], 1)

    def test_history_cache_ttl(self):
        """当前月 TTL 过期重取；历史月永久。"""
        wid = "wrk_x"
        now = datetime.now()
        entries = [HistoryEntry(date="2026-08-01", model="m", total_cost=100, key_id="k")]
        self.db.put_history_cache(wid, now.year, now.month, entries)
        # 刚写入 → 命中
        self.assertIsNotNone(self.db.get_history_cache(wid, now.year, now.month))
        # 历史月 → 永久命中
        self.db.put_history_cache(wid, 2026, 1, entries)
        self.assertIsNotNone(self.db.get_history_cache(wid, 2026, 1))
        # 模拟缓存写入时间过期（直接改 DB）
        with self.db._connect() as conn:
            conn.execute(
                "UPDATE history_cache SET cached_at=? WHERE year=? AND month=?",
                ((datetime.now() - timedelta(hours=2)).isoformat(), now.year, now.month),
            )
        self.assertIsNone(self.db.get_history_cache(wid, now.year, now.month))

    def test_local_iso(self):
        self.assertTrue(_local_iso("2026-08-10T13:25:47.000Z").startswith("2026-08-10T"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
