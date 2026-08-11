"""数据层单测：用真实页面 fixture 验证 SSR 解析。"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from ocusage import client  # noqa: E402

FIXTURES = Path(__file__).parent / "fixtures"


def test_extract_ssr_go():
    html = (FIXTURES / "go.html").read_text(encoding="utf-8")
    data = client._extract_ssr_values(html, ["lite.subscription.get", "billing.get", "go.referral.get"])
    assert data, "应提取到数据"

    sub = client._first_match(data, "lite.subscription.get")
    assert sub and sub.get("mine") is True
    assert sub.get("useBalance") is True
    assert "rollingUsage" in sub and "weeklyUsage" in sub and "monthlyUsage" in sub
    print("go: rollingUsage =", sub["rollingUsage"])


def test_extract_ssr_usage():
    html = (FIXTURES / "usage.html").read_text(encoding="utf-8")
    data = client._extract_ssr_values(html, ["usage.list"])
    raw = client._first_match(data, "usage.list")
    assert isinstance(raw, list) and raw, "usage.list 应为非空列表"
    r = raw[0]
    assert r["model"] and r["cost"] is not None and "inputTokens" in r
    print(f"usage: {len(raw)} 条记录，第一条 = {r['model']} cost={r['cost']} tokens={r['inputTokens']}/{r['outputTokens']}/{r['cacheReadTokens']}")


def test_go_data_model():
    html = (FIXTURES / "go.html").read_text(encoding="utf-8")
    # 用 client 的解析路径（fetch_go 内部逻辑，mock _get）
    class Fake:
        def __init__(self):
            self.cookie = "auth=test"

        def _get(self, path):
            return "https://opencode.ai" + path, html

    c = Fake()
    # 直接调用静态解析
    data = client._extract_ssr_values(html, ["lite.subscription.get", "billing.get", "go.referral.get"])
    sub = client._first_match(data, "lite.subscription.get")
    bill = client._first_match(data, "billing.get")
    assert sub is not None and bill is not None
    print("billing balance =", bill.get("balance"), "| payment =", bill.get("paymentMethodType"))


def test_usage_window_format():
    from ocusage.models import UsageWindow

    w = UsageWindow(label="滚动", usage_percent=1.0, reset_in_sec=15321)
    assert w.reset_text() == "4 小时 15 分钟"
    assert w.remaining_percent == 99.0
    w2 = UsageWindow(label="每月", usage_percent=64, reset_in_sec=1381828)
    assert w2.reset_text() == "15 天 23 小时"
    w3 = UsageWindow(label="x", usage_percent=50, reset_in_sec=42)
    assert w3.reset_text() == "0 分钟"  # <1 分钟向下取整
    print("UsageWindow 格式化 OK")


if __name__ == "__main__":
    test_extract_ssr_go()
    test_extract_ssr_usage()
    test_go_data_model()
    test_usage_window_format()
    print("\nALL PARSE TESTS PASSED")
