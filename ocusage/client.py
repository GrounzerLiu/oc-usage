"""opencode.ai 数据获取。

数据来源：
- GET /workspace/{id}/go    → SSR 内联：lite.subscription.get / billing.get / go.referral.get / workspaces[]
- GET /workspace/{id}/usage → SSR 内联：usage.list（最近一页请求级明细）
- POST /_server RPC        → 按天×模型聚合历史 / 请求记录分页（网页同源接口）

SSR 内联数据用 QJSEngine 执行页面内联 <script>，再从 _$HY.r[key].v 取出数据。
RPC 的 X-Server-Id 是 SolidStart 构建时生成的哈希，每次前端发版都会变化，
因此实现自动发现（从页面 JS bundle 提取 createServerReference id）+ 本地缓存 +
调用失败（404/500）时自动重新发现并重试。
"""
from __future__ import annotations

import json
import os
import re
import threading
import urllib.error
import urllib.request
from pathlib import Path
from typing import Optional

from PySide6.QtCore import QCoreApplication
from PySide6.QtQml import QJSEngine

from .models import GoData, HistoryEntry, UsageData, UsageRecord, UsageWindow, Workspace

# QJSEngine 线程亲和：每个线程独立引擎（线程局部）
_ENGINE_LOCAL = threading.local()

BASE_URL = "https://opencode.ai"
USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36"
)

WORKSPACE_RE = re.compile(r"/workspace/(wrk_[A-Za-z0-9]+)")

# server function id 的初始已知值（2026-08 抓取）；失效时自动重新发现
KNOWN_SERVER_IDS = {
    "history": "15702f3a12ff8bff357f8c2aa154a17e65b746d5f6b96adc9002c86ee0c15205",
    "page": "bfd684bfc2e4eed05cd0b518f5e4eafd3f3376e3938abb9e536e7c03df831e5c",
}
SERVER_IDS_FILE = (
    Path(os.environ.get("APPDATA", str(Path.home()))) / "oc-usage" / "server_ids.json"
)
USAGE_PAGE_SIZE = 50

# JS bundle 里 server reference 的形态：createServerReference("<64-hex>")
SERVER_REF_RE = re.compile(r'createServerReference\("([0-9a-f]{64})"\)')
BUNDLE_JS_RE = re.compile(r"/_build/assets/[A-Za-z0-9_.-]+\.js")

# QJSEngine 要求存在 QCoreApplication 实例；主程序里已有 QApplication 时不会重复创建
_APP_REF = None


def _ensure_qapp() -> None:
    global _APP_REF
    if QCoreApplication.instance() is None:
        _APP_REF = QCoreApplication([])


class ClientError(Exception):
    """数据获取/解析错误（消息可直接展示给用户）。"""


def _extract_inline_scripts(html: str) -> list[str]:
    """提取页面内联 <script>（不带 src 的）。"""
    return re.findall(r"<script(?![^>]*\bsrc=)[^>]*>(.*?)</script>", html, re.S)


def _extract_ssr_values(html: str, key_prefixes: list[str]) -> dict[str, object]:
    """执行 SSR 内联脚本，提取 _$HY.r 中 key 前缀匹配的已 resolve 数据。"""
    _ensure_qapp()
    scripts = _extract_inline_scripts(html)
    if not scripts:
        raise ClientError("页面没有内联数据（可能未登录或页面结构变化）")

    engine = QJSEngine()
    # 垫出浏览器全局对象：页面脚本依赖 window/self/document，以及
    # SolidStart 序列化用到的隐式全局 $R / _$HY（QJSEngine 严格模式下需预声明）
    engine.evaluate(
        "var window = {};"
        "var self = window;"
        "var document = { addEventListener: function(){}, removeEventListener: function(){} };"
        "var $R = []; window.$R = $R;"
        "var _$HY = { events: [], completed: new WeakSet(), r: {}, fe: function(){} };"
    )
    for s in scripts:
        r = engine.evaluate(s)
        if r.isError():
            # 单个脚本失败不致命（可能有条件逻辑），记录后继续
            pass

    prefixes_js = json.dumps(key_prefixes)
    code = f"""(function() {{
        var out = {{}};
        for (var k in _$HY.r) {{
            for (var i = 0; i < {prefixes_js}.length; i++) {{
                if (k.indexOf({prefixes_js}[i]) === 0) {{
                    var v = _$HY.r[k];
                    // SSR 序列化中 _$HY.r[key] 是已 resolve 的 Promise 对象，
                    // 页面代码 resolve 时写入 r.p.v=d（即该对象的 .v 属性）
                    out[k] = (v && v.v !== undefined) ? v.v : (v && v.p && v.p.v);
                }}
            }}
        }}
        return JSON.stringify(out);
    }})()"""
    res = engine.evaluate(code)
    if res.isError():
        raise ClientError(f"SSR 数据解析失败：{res.toString()}")
    data = json.loads(res.toString())
    if not data:
        raise ClientError("SSR 数据为空（可能未登录或页面结构变化）")
    return data


def _first_match(data: dict[str, object], prefix: str) -> Optional[object]:
    for k, v in data.items():
        if k.startswith(prefix):
            return v
    return None


class OpenCodeClient:
    """携带 auth cookie 的 opencode.ai 客户端。"""

    def __init__(self, cookie_value: str):
        """cookie_value 为 auth cookie 的值（不含 'auth=' 前缀）。"""
        self.cookie = f"auth={cookie_value}"

    # ── HTTP ──

    def _get(self, path: str) -> tuple[str, str]:
        """GET 页面，返回 (final_url, html)。urllib 自动跟随重定向。"""
        req = urllib.request.Request(
            BASE_URL + path,
            headers={
                "Cookie": self.cookie,
                "User-Agent": USER_AGENT,
                "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                "Accept-Language": "zh-CN,zh;q=0.9",
            },
        )
        try:
            with urllib.request.urlopen(req, timeout=20) as resp:
                final_url = resp.geturl()
                if resp.status == 401:
                    raise ClientError("登录已过期，请重新登录")
                return final_url, resp.read().decode("utf-8", errors="replace")
        except urllib.error.HTTPError as e:
            if e.code in (401, 403):
                raise ClientError("登录已过期，请重新登录")
            raise ClientError(f"请求失败：HTTP {e.code}")
        except urllib.error.URLError as e:
            raise ClientError(f"网络错误：{e.reason}")
        except TimeoutError:
            raise ClientError("请求超时")

    # ── 数据接口 ──

    @staticmethod
    def workspaces_from_html(html: str) -> list[Workspace]:
        """从任意 workspace 页面的 SSR 数据提取 workspace 列表（备用）。"""
        data = _extract_ssr_values(html, ["workspaces[]"])
        ws = _first_match(data, "workspaces[]")
        if isinstance(ws, list) and ws:
            return [Workspace(id=w["id"], name=w.get("name", ""), slug=w.get("slug")) for w in ws]
        return []

    def fetch_go(self, workspace_id: str) -> GoData:
        """解析 /workspace/{id}/go 页面：Go 三层限额 + billing + referral。"""
        _, html = self._get(f"/workspace/{workspace_id}/go")
        data = _extract_ssr_values(
            html,
            ["lite.subscription.get", "billing.get", "go.referral.get"],
        )

        go = GoData()

        sub = _first_match(data, "lite.subscription.get")
        if isinstance(sub, dict):
            go.subscribed = bool(sub.get("mine"))
            go.use_balance = bool(sub.get("useBalance"))
            go.regions = [str(r) for r in (sub.get("region") or [])]

            def window(label: str, raw: object) -> Optional[UsageWindow]:
                if not isinstance(raw, dict):
                    return None
                return UsageWindow(
                    label=label,
                    usage_percent=float(raw.get("usagePercent", 0)),
                    reset_in_sec=int(raw.get("resetInSec", 0)),
                    status=str(raw.get("status", "ok")),
                )

            go.rolling = window("滚动", sub.get("rollingUsage"))
            go.weekly = window("每周", sub.get("weeklyUsage"))
            go.monthly = window("每月", sub.get("monthlyUsage"))

        bill = _first_match(data, "billing.get")
        if isinstance(bill, dict):
            go.balance = bill.get("balance")
            go.payment_method_type = bill.get("paymentMethodType")
            go.monthly_limit = bill.get("monthlyLimit")
            go.monthly_usage = bill.get("monthlyUsage")

        ref = _first_match(data, "go.referral.get")
        if isinstance(ref, dict):
            go.referral_code = ref.get("referralCode")
            go.referral_available_amount = ref.get("rewardAmount")

        return go

    def fetch_usage(self, workspace_id: str) -> UsageData:
        """解析 /workspace/{id}/usage 页面：最近一页请求级明细。"""
        _, html = self._get(f"/workspace/{workspace_id}/usage")
        data = _extract_ssr_values(html, ["usage.list"])
        raw = _first_match(data, "usage.list")
        records = self._records_from_raw(raw) if isinstance(raw, list) else []
        return UsageData(records=records)

    @staticmethod
    def _records_from_raw(raw: list) -> list[UsageRecord]:
        """把 usage.list / 分页 RPC 的原始记录转成 UsageRecord。"""
        records: list[UsageRecord] = []
        for r in raw:
            if not isinstance(r, dict):
                continue
            enr = r.get("enrichment") or {}
            records.append(
                UsageRecord(
                    id=str(r.get("id", "")),
                    time_created=str(r.get("timeCreated", "")),
                    model=str(r.get("model", "")),
                    provider=str(r.get("provider", "")),
                    input_tokens=int(r.get("inputTokens") or 0),
                    output_tokens=int(r.get("outputTokens") or 0),
                    reasoning_tokens=int(r.get("reasoningTokens") or 0),
                    cache_read_tokens=int(r.get("cacheReadTokens") or 0),
                    cost=int(r.get("cost") or 0),
                    key_id=str(r.get("keyID", "")),
                    plan=enr.get("plan"),
                )
            )
        return records

    def _resolve_id(self, workspace_id: str, kind: str) -> Optional[str]:
        """取 server function id：本地缓存 > 已知初始值。"""
        cache = self._load_id_cache()
        key = f"{kind}:{workspace_id}"
        if key in cache:
            return cache[key]
        return KNOWN_SERVER_IDS.get(kind)

    def _rpc_call(self, kind: str, body: dict, workspace_id: str, label: str) -> str:
        """POST /_server RPC（按 kind 解析 id）。404/500（前端改版导致 id 失效）时自动重新发现并重试一次。"""
        server_id = self._resolve_id(workspace_id, kind)
        if not server_id:
            server_id = self._discover_server_id(workspace_id, kind)
        if not server_id:
            raise ClientError(f"{label}失败：无法定位服务函数（前端可能已改版）")
        try:
            return self._rpc_raw(server_id, body, workspace_id, label)
        except ClientError as e:
            if "HTTP 404" in str(e) or "HTTP 500" in str(e):
                new_id = self._discover_server_id(workspace_id, kind)
                if new_id:
                    return self._rpc_raw(new_id, body, workspace_id, label)
            raise

    def _rpc_raw(self, server_id: str, body: dict, workspace_id: str, label: str) -> str:
        """POST /_server RPC（网络错误自动重试 3 次，退避 1s/3s）。"""
        import time

        req = urllib.request.Request(
            BASE_URL + "/_server",
            data=json.dumps(body).encode("utf-8"),
            headers={
                "Cookie": self.cookie,
                "Content-Type": "application/json",
                "X-Server-Id": server_id,
                "X-Server-Instance": "server-fn:0",
                "Origin": BASE_URL,
                "Referer": f"{BASE_URL}/workspace/{workspace_id}/usage",
                "User-Agent": USER_AGENT,
                "Accept": "*/*",
            },
        )
        last_err: Optional[Exception] = None
        for attempt in range(3):
            try:
                with urllib.request.urlopen(req, timeout=20) as resp:
                    return resp.read().decode("utf-8", errors="replace")
            except urllib.error.HTTPError as e:
                if e.code in (401, 403):
                    raise ClientError("登录已过期，请重新登录")
                if e.code == 500 and attempt < 2:
                    # 服务端瞬时错误：退避后重试
                    time.sleep(1 + attempt * 2)
                    last_err = e
                    continue
                raise ClientError(f"{label}失败：HTTP {e.code}（前端可能已改版）")
            except urllib.error.URLError as e:
                if attempt < 2:
                    time.sleep(1 + attempt * 2)
                    last_err = e
                    continue
                raise ClientError(f"网络错误：{e.reason}")
        raise ClientError(f"{label}失败：{last_err}")

    def _rpc_page_raw(self, workspace_id: str, page: int) -> str:
        """分页 RPC 的 HTTP 层（供并发拉取；QJSEngine 解析须在主线程）。"""
        body = {
            "t": {
                "t": 9,
                "i": 0,
                "l": 2,
                "a": [
                    {"t": 1, "s": workspace_id},
                    {"t": 0, "s": page},
                ],
                "o": 0,
            },
            "f": 31,
            "m": [],
        }
        server_id = self._resolve_id(workspace_id, "page")
        return self._rpc_raw(server_id, body, workspace_id, "请求记录获取")

    # ── server function id 自动发现 ──

    @staticmethod
    def _load_id_cache() -> dict:
        try:
            return json.loads(SERVER_IDS_FILE.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return {}

    @staticmethod
    def _save_id_cache(cache: dict) -> None:
        try:
            SERVER_IDS_FILE.parent.mkdir(parents=True, exist_ok=True)
            SERVER_IDS_FILE.write_text(json.dumps(cache, indent=2), encoding="utf-8")
        except OSError:
            pass

    def _discover_server_id(self, workspace_id: str, kind: str) -> Optional[str]:
        """从 usage 页面的 JS bundle 提取并试调 server function id（历史聚合/分页）。"""
        cache = self._load_id_cache()
        key = f"{kind}:{workspace_id}"
        if key in cache:
            return cache[key]

        # 1. 抓 usage 页面，取所有 JS bundle URL（文件名带 hash，每次部署都变，必须现取）
        _, html = self._get(f"/workspace/{workspace_id}/usage")
        bundle_urls = set(BUNDLE_JS_RE.findall(html))

        # 2. 下载 bundle，收集 createServerReference id
        candidates: set[str] = set()
        for u in bundle_urls:
            try:
                req = urllib.request.Request(BASE_URL + u, headers={"User-Agent": USER_AGENT})
                with urllib.request.urlopen(req, timeout=15) as resp:
                    js = resp.read().decode("utf-8", errors="replace")
                candidates.update(SERVER_REF_RE.findall(js))
            except Exception:
                continue

        # 3. 逐个试调：响应结构匹配即为所需 id（SolidStart 序列化键名不带引号）
        for cid in candidates:
            try:
                body = self._probe_body(kind, workspace_id)
                text = self._rpc_raw(cid, body, workspace_id, "函数探测")
                if kind == "history" and "usage:" in text and "totalCost" in text:
                    cache[key] = cid
                    self._save_id_cache(cache)
                    return cid
                if kind == "page" and '"usg_' in text:
                    cache[key] = cid
                    self._save_id_cache(cache)
                    return cid
            except Exception:
                continue
        return None

    @staticmethod
    def _probe_body(kind: str, workspace_id: str) -> dict:
        if kind == "history":
            import datetime

            now = datetime.datetime.now()
            return {
                "t": {"t": 9, "i": 0, "l": 4, "a": [
                    {"t": 1, "s": workspace_id},
                    {"t": 0, "s": now.year},
                    {"t": 0, "s": now.month - 1},
                    {"t": 1, "s": "+08:00"},
                ], "o": 0},
                "f": 31,
                "m": [],
            }
        return {
            "t": {"t": 9, "i": 0, "l": 2, "a": [
                {"t": 1, "s": workspace_id},
                {"t": 0, "s": 0},
            ], "o": 0},
            "f": 31,
            "m": [],
        }

    @staticmethod
    def _eval_server_response(text: str, label: str):
        """执行 SolidStart RPC 响应流，返回 self.$R["server-fn:0"][0]。"""
        # 响应为 SolidStart 序列化流：((self.$R=... )["server-fn:0"]=[],($R=>$R[0]={...})(...))
        # 其中的裸 $R 是浏览器页面脚本创建的隐式全局，这里垫 self.$R 与 $R 指向同一对象
        # QJSEngine 有线程亲和：每个线程使用自己的引擎（线程局部）
        engine = getattr(_ENGINE_LOCAL, "engine", None)
        if engine is None:
            _ensure_qapp()
            engine = QJSEngine()
            engine.evaluate("var self = { $R: [] }; var $R = self.$R;")
            _ENGINE_LOCAL.engine = engine
        # 重置 $R，避免上次解析的残留数据串扰（$R 重新绑定到新数组）
        engine.evaluate("self.$R = []; $R = self.$R;")
        res = engine.evaluate(text)
        if res.isError():
            raise ClientError(f"{label}解析失败：{res.toString()}")
        out = engine.evaluate('JSON.stringify(self.$R["server-fn:0"][0])')
        if out.isError():
            raise ClientError(f"{label}解析失败：{out.toString()}")
        return json.loads(out.toString())

    def fetch_usage_history(
        self, workspace_id: str, year: int, month: int
    ) -> list[HistoryEntry]:
        """按天×模型的聚合历史（与网页「成本」区块一致）。

        走 SolidStart 内部 RPC（POST /_server）。month 为 0-based（7 = 8 月）。
        """
        body = {
            "t": {
                "t": 9,
                "i": 0,
                "l": 4,
                "a": [
                    {"t": 1, "s": workspace_id},
                    {"t": 0, "s": year},
                    {"t": 0, "s": month},
                    {"t": 1, "s": "+08:00"},
                ],
                "o": 0,
            },
            "f": 31,
            "m": [],
        }
        text = self._rpc_call("history", body, workspace_id, "用量历史获取")
        data = self._eval_server_response(text, "用量历史")
        entries: list[HistoryEntry] = []
        for e in data.get("usage") or []:
            entries.append(
                HistoryEntry(
                    date=e.get("date", ""),
                    model=e.get("model", ""),
                    total_cost=int(e.get("totalCost") or 0),
                    key_id=e.get("keyId", ""),
                    plan=e.get("plan"),
                )
            )
        return entries

    def fetch_page_records(self, workspace_id: str, page: int) -> list[UsageRecord]:
        """拉取一页请求记录（50 条，按时间倒序）。"""
        text = self._rpc_page_raw(workspace_id, page)
        data = self._eval_server_response(text, "请求记录")
        return self._records_from_raw(data) if isinstance(data, list) else []

    def fetch_all_usage(
        self, workspace_id: str, max_pages: int = 800, workers: int = 4
    ) -> list[UsageRecord]:
        """并发分页拉取请求记录（每页 50 条，按页号并发请求后连续拼接）。

        服务端分页按 offset 连续返回；拉完所有页后从第 0 页起连续累加，
        遇到不足一页（末尾）即停止，自动丢弃越界页。
        """
        from concurrent.futures import ThreadPoolExecutor, as_completed

        results: dict[int, list[UsageRecord]] = {}

        def fetch_page(page: int) -> tuple[int, list[UsageRecord]]:
            # 只做 HTTP（并发）；QJSEngine 非线程安全，解析放主线程串行
            return page, self.fetch_page_records(workspace_id, page)

        with ThreadPoolExecutor(max_workers=workers) as pool:
            futures = [pool.submit(fetch_page, p) for p in range(max_pages)]
            for fut in as_completed(futures):
                page, records = fut.result()
                results[page] = records

        # 主线程串行拼接，从第 0 页起连续，遇到不足一页即停（末尾）
        all_records: list[UsageRecord] = []
        seen: set[str] = set()
        for page in range(max_pages):
            records = results.get(page)
            if records is None:
                break
            if not records:
                break
            fresh = [r for r in records if r.id not in seen]
            all_records.extend(fresh)
            seen.update(r.id for r in records)
            if len(records) < USAGE_PAGE_SIZE:
                break
        return all_records
