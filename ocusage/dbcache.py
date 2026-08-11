"""用量数据本地缓存（SQLite）。

设计原则：历史数据不可变 —— 请求记录每条以 id 去重增量入库，
按月×模型的历史聚合当前月 10 分钟 TTL、历史月永久有效。

DB 结构（%APPDATA%\\oc-usage\\cache.db）：
  records       全部请求记录（id 主键，time_local 索引用于聚合）
  history_cache 按月×模型的聚合历史（workspace,year,month 唯一）
  meta          键值元数据
"""
from __future__ import annotations

import json
import sqlite3
import threading
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Callable, Optional

from .client import ClientError, OpenCodeClient, UsageRecord
from .models import HistoryEntry

HISTORY_TTL_SEC = 10 * 60  # 当前月聚合缓存 10 分钟


def _local_iso(utc_iso: str) -> str:
    """UTC ISO 时间转本地时区 ISO（用于按天/月聚合）。"""
    try:
        dt = datetime.fromisoformat(utc_iso.replace("Z", "+00:00"))
        return dt.astimezone().isoformat(timespec="seconds")
    except ValueError:
        return utc_iso


class UsageCache:
    """请求记录与历史聚合的 SQLite 缓存。线程安全（每操作独立连接）。"""

    def __init__(self, db_path: Optional[Path] = None):
        self.db_path = db_path or Path.home() / "AppData" / "Roaming" / "oc-usage" / "cache.db"
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.Lock()
        self._init_db()

    # ── 基础 ──────────────────────────────────────────────

    def _connect(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self.db_path, timeout=30)
        conn.execute("PRAGMA journal_mode=WAL")
        return conn

    def _init_db(self) -> None:
        with self._connect() as conn:
            conn.execute(
                """CREATE TABLE IF NOT EXISTS records (
                    id TEXT PRIMARY KEY,
                    time_created TEXT NOT NULL,
                    time_local TEXT NOT NULL,
                    model TEXT NOT NULL,
                    provider TEXT NOT NULL DEFAULT '',
                    input_tokens INTEGER NOT NULL DEFAULT 0,
                    output_tokens INTEGER NOT NULL DEFAULT 0,
                    reasoning_tokens INTEGER NOT NULL DEFAULT 0,
                    cache_read_tokens INTEGER NOT NULL DEFAULT 0,
                    cost INTEGER NOT NULL DEFAULT 0,
                    key_id TEXT NOT NULL DEFAULT '',
                    plan TEXT
                )"""
            )
            conn.execute("CREATE INDEX IF NOT EXISTS idx_records_local ON records(time_local)")
            conn.execute(
                """CREATE TABLE IF NOT EXISTS history_cache (
                    workspace TEXT NOT NULL,
                    year INTEGER NOT NULL,
                    month INTEGER NOT NULL,
                    payload TEXT NOT NULL,
                    cached_at TEXT NOT NULL,
                    PRIMARY KEY (workspace, year, month)
                )"""
            )
            conn.execute(
                """CREATE TABLE IF NOT EXISTS meta (
                    k TEXT PRIMARY KEY, v TEXT
                )"""
            )

    # ── 请求记录：增量同步 ─────────────────────────────────

    def known_ids(self, workspace_id: str, limit: int = 200_000) -> set[str]:
        """已缓存记录 id 集合（增量判定用）。"""
        with self._connect() as conn:
            rows = conn.execute(
                "SELECT id FROM records WHERE id LIKE ?", (f"usg_%",)
            ).fetchall()
        return {r[0] for r in rows}

    def _insert_records(self, records: list[UsageRecord]) -> int:
        """INSERT OR IGNORE，返回新增条数。"""
        if not records:
            return 0
        now = datetime.now().isoformat(timespec="seconds")
        with self._connect() as conn:
            cur = conn.executemany(
                """INSERT OR IGNORE INTO records
                   (id, time_created, time_local, model, provider,
                    input_tokens, output_tokens, reasoning_tokens, cache_read_tokens,
                    cost, key_id, plan)
                   VALUES (?,?,?,?,?,?,?,?,?,?,?,?)""",
                [
                    (
                        r.id,
                        r.time_created,
                        _local_iso(r.time_created),
                        r.model,
                        r.provider,
                        r.input_tokens,
                        r.output_tokens,
                        r.reasoning_tokens,
                        r.cache_read_tokens,
                        r.cost,
                        r.key_id,
                        r.plan,
                    )
                    for r in records
                ],
            )
            conn.execute(
                "INSERT OR REPLACE INTO meta(k,v) VALUES('last_sync_at',?)", (now,)
            )
        return cur.rowcount

    def sync_incremental(
        self,
        client: OpenCodeClient,
        workspace_id: str,
        max_pages: int = 800,
        progress: Optional[Callable[[int, int], None]] = None,
    ) -> int:
        """增量同步：从最新一页顺序拉取，遇到已缓存 id 即截断停止。

        首次（库空）自动切换为并发全量。返回新增条数。
        """
        known = self.known_ids(workspace_id)

        # 快速路径：最新一条已入库 → 完全同步
        newest = client.fetch_page_records(workspace_id, 0)
        if newest and newest[0].id in known:
            # 仍把缺的（同页内更早的）补齐
            new = [r for r in newest if r.id not in known]
            return self._insert_records(new)

        if not known:
            return self.sync_full(client, workspace_id, max_pages=max_pages, progress=progress)

        # 顺序增量：每页找第一个已缓存 id，其前段为新记录
        total_new = 0
        page = 0
        while page < max_pages:
            records = client.fetch_page_records(workspace_id, page)
            if not records:
                break
            cut = None
            for j, r in enumerate(records):
                if r.id in known:
                    cut = j
                    break
            if cut is not None:
                total_new += self._insert_records(records[:cut])
                break
            total_new += self._insert_records(records)
            known.update(r.id for r in records)
            page += 1
            if len(records) < 50:
                break
        return total_new

    def sync_full(
        self,
        client: OpenCodeClient,
        workspace_id: str,
        max_pages: int = 800,
        workers: int = 4,
        progress: Optional[Callable[[int, Optional[int]], None]] = None,
    ) -> int:
        """并发全量重建：清空后分批拉取入库（每批 20 页，边拉边存）。

        网络错误在 _rpc_raw 内重试；单批失败即中止（已入库批次保留）。
        """
        from concurrent.futures import ThreadPoolExecutor, as_completed

        with self._connect() as conn:
            conn.execute("DELETE FROM records")

        total = 0
        page = 0
        while page < max_pages:
            batch_end = min(page + 20, max_pages)
            results: dict[int, str] = {}
            with ThreadPoolExecutor(max_workers=workers) as pool:
                futures = {
                    pool.submit(client._rpc_page_raw, workspace_id, p): p
                    for p in range(page, batch_end)
                }
                for fut in as_completed(futures):
                    p = futures[fut]
                    results[p] = fut.result()

            # 主线程串行解析 + 入库（QJSEngine 线程亲和）
            batch_records: list[UsageRecord] = []
            for p in range(page, batch_end):
                text = results.get(p)
                if text is None:
                    break
                data = client._eval_server_response(text, "请求记录")
                recs = (
                    client._records_from_raw(data) if isinstance(data, list) else []
                )
                if not recs:
                    break  # 末尾页
                batch_records.extend(recs)
            total += self._insert_records(batch_records)
            page += 20
            if progress:
                progress(total, None)
            if len(batch_records) < 20 * 50:
                break  # 最后一页不足一页
        if progress:
            progress(total, total)
        return total

    def record_count(self) -> int:
        with self._connect() as conn:
            return conn.execute("SELECT COUNT(*) FROM records").fetchone()[0]

    # ── 统计：SQL 直接聚合（秒级） ─────────────────────────

    def all_stats(self) -> dict:
        """全量统计：总请求数、总 token、覆盖天数（全部历史数据）。"""
        with self._connect() as conn:
            row = conn.execute(
                """SELECT COUNT(*),
                          COALESCE(SUM(input_tokens+output_tokens+reasoning_tokens+cache_read_tokens), 0),
                          COUNT(DISTINCT substr(time_local, 1, 10))
                   FROM records"""
            ).fetchone()
        return {
            "requests": int(row[0]),
            "tokens": int(row[1]),
            "days": int(row[2]),
        }

    def all_model_costs(self) -> list[tuple[str, int]]:
        """全量按模型的成本分布（原始单位，降序）。"""
        with self._connect() as conn:
            rows = conn.execute(
                "SELECT model, SUM(cost) FROM records GROUP BY model ORDER BY 2 DESC"
            ).fetchall()
        return [(m, int(c)) for m, c in rows]

    def month_stats(self, workspace_id: str, year: int, month: int) -> dict:
        """某月统计：总请求数、总 token、覆盖天数。month 为 1-based。"""
        prefix = f"{year:04d}-{month:02d}"
        with self._connect() as conn:
            row = conn.execute(
                """SELECT COUNT(*),
                          COALESCE(SUM(input_tokens+output_tokens+reasoning_tokens+cache_read_tokens), 0),
                          COUNT(DISTINCT substr(time_local, 1, 10))
                   FROM records WHERE time_local LIKE ?""",
                (prefix + "%",),
            ).fetchone()
        return {
            "requests": int(row[0]),
            "tokens": int(row[1]),
            "days": int(row[2]),
        }

    def month_history(
        self, workspace_id: str, year: int, month: int
    ) -> list[HistoryEntry]:
        """某月按天×模型的聚合（来自 records 表）。month 为 1-based。"""
        prefix = f"{year:04d}-{month:02d}"
        with self._connect() as conn:
            rows = conn.execute(
                """SELECT substr(time_local, 1, 10), model,
                          SUM(cost), COALESCE(MAX(key_id), '')
                   FROM records WHERE time_local LIKE ?
                   GROUP BY substr(time_local, 1, 10), model
                   ORDER BY 1, 2""",
                (prefix + "%",),
            ).fetchall()
        return [
            HistoryEntry(
                date=date, model=model, total_cost=int(cost), key_id=key_id, plan=None
            )
            for date, model, cost, key_id in rows
        ]

    # ── 历史聚合 RPC 结果缓存 ──────────────────────────────

    def get_history_cache(
        self, workspace_id: str, year: int, month: int
    ) -> Optional[list[HistoryEntry]]:
        """取缓存的历史聚合；已过期（当前月超过 TTL / 缓存晚于今天）返回 None。"""
        with self._connect() as conn:
            row = conn.execute(
                "SELECT payload, cached_at FROM history_cache WHERE workspace=? AND year=? AND month=?",
                (workspace_id, year, month),
            ).fetchone()
        if row is None:
            return None
        payload, cached_at = row
        cached_dt = datetime.fromisoformat(cached_at)
        now = datetime.now()
        # 历史月：永久有效
        if (year, month) < (now.year, now.month):
            return [HistoryEntry(**e) for e in json.loads(payload)]
        # 当前月：缓存不超过 TTL 且是今天写入的才有效
        if cached_dt.date() == now.date() and (now - cached_dt) < timedelta(
            seconds=HISTORY_TTL_SEC
        ):
            return [HistoryEntry(**e) for e in json.loads(payload)]
        return None

    def put_history_cache(
        self, workspace_id: str, year: int, month: int, entries: list[HistoryEntry]
    ) -> None:
        with self._connect() as conn:
            conn.execute(
                """INSERT OR REPLACE INTO history_cache(workspace, year, month, payload, cached_at)
                   VALUES (?,?,?,?,?)""",
                (
                    workspace_id,
                    year,
                    month,
                    json.dumps([e.__dict__ for e in entries], ensure_ascii=False),
                    datetime.now().isoformat(timespec="seconds"),
                ),
            )

    # ── 元数据 ─────────────────────────────────────────────

    def last_sync_at(self) -> Optional[str]:
        with self._connect() as conn:
            row = conn.execute("SELECT v FROM meta WHERE k='last_sync_at'").fetchone()
        return row[0] if row else None

    def clear(self) -> None:
        with self._connect() as conn:
            conn.execute("DELETE FROM records")
            conn.execute("DELETE FROM history_cache")
