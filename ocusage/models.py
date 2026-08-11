"""数据模型与格式化工具。"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Optional


# ── Go 套餐三层限额 ──


@dataclass
class UsageWindow:
    """Go 套餐的一个滚动限额窗口（5 小时 / 每周 / 每月）。"""

    label: str  # "rolling" / "weekly" / "monthly"
    usage_percent: float  # 已用百分比 0-100
    reset_in_sec: int  # 距重置秒数
    status: str = "ok"

    @property
    def remaining_percent(self) -> float:
        return max(0.0, 100.0 - self.usage_percent)

    def reset_text(self) -> str:
        """把秒数格式化为 'X 小时 Y 分钟' / 'X 天 Y 小时'。"""
        s = max(0, int(self.reset_in_sec))
        days, rem = divmod(s, 86400)
        hours, rem = divmod(rem, 3600)
        minutes = rem // 60
        if days > 0:
            return f"{days} 天 {hours} 小时"
        if hours > 0:
            return f"{hours} 小时 {minutes} 分钟"
        return f"{minutes} 分钟"


# ── Go 页面聚合数据 ──


@dataclass
class GoData:
    """/workspace/{id}/go 页面 SSR 数据的总和。"""

    subscribed: bool = False
    use_balance: bool = False
    regions: list[str] = field(default_factory=list)
    rolling: Optional[UsageWindow] = None
    weekly: Optional[UsageWindow] = None
    monthly: Optional[UsageWindow] = None
    # billing
    balance: Optional[float] = None  # USD
    payment_method_type: Optional[str] = None
    monthly_limit: Optional[float] = None
    monthly_usage: Optional[float] = None
    # referral
    referral_code: Optional[str] = None
    referral_available_amount: Optional[int] = None  # 分（cents）

    def summary_lines(self) -> list[str]:
        """给托盘 tooltip / 窗口用的简短文本行。"""
        lines = []
        if self.subscribed:
            for w in (self.rolling, self.weekly, self.monthly):
                if w:
                    lines.append(
                        f"{w.label}：已用 {w.usage_percent:.0f}%"
                        f"（剩 {w.remaining_percent:.0f}%，{w.reset_text()} 后重置）"
                    )
        else:
            lines.append("未订阅 Go")
        return lines


# ── usage 页面请求级明细 ──


@dataclass
class UsageRecord:
    """一次 API 请求的计费用量。"""

    id: str
    time_created: str  # ISO
    model: str
    provider: str
    input_tokens: int
    output_tokens: int
    reasoning_tokens: int
    cache_read_tokens: int
    cost: int  # 原始单位（接口未公开，按 microUSD 假设展示）
    key_id: str
    plan: Optional[str] = None

    @property
    def cost_usd(self) -> float:
        return self.cost / 1_000_000

    @property
    def total_tokens(self) -> int:
        return self.input_tokens + self.output_tokens + self.reasoning_tokens + self.cache_read_tokens


@dataclass
class UsageData:
    """/workspace/{id}/usage 页面 SSR 数据。"""

    records: list[UsageRecord] = field(default_factory=list)

    @property
    def total_cost(self) -> int:
        return sum(r.cost for r in self.records)

    @property
    def total_cost_usd(self) -> float:
        return self.total_cost / 1_000_000

    def by_model(self) -> dict[str, int]:
        out: dict[str, int] = {}
        for r in self.records:
            out[r.model] = out.get(r.model, 0) + r.cost
        return out


@dataclass
class HistoryEntry:
    """按天×模型的聚合历史（_server RPC，与网页「成本」区块一致）。"""

    date: str  # YYYY-MM-DD
    model: str
    total_cost: int  # 原始单位（credits，与网页一致）
    key_id: str
    plan: Optional[str] = None


def compute_month_stats(records: list[UsageRecord], year: int, month: int) -> dict:
    """统计某月请求记录：总 token、总请求数、覆盖天数。

    records 为全量请求记录；month 为 1-based。返回
    {"requests": n, "tokens": n, "days": n}。
    """
    prefix = f"{year:04d}-{month:02d}"
    filtered = [r for r in records if r.time_created.startswith(prefix)]
    days = len({r.time_created[:10] for r in filtered})
    tokens = sum(r.total_tokens for r in filtered)
    return {"requests": len(filtered), "tokens": tokens, "days": days}


# ── workspace ──


@dataclass
class Workspace:
    id: str
    name: str
    slug: Optional[str] = None
