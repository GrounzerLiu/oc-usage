"""验证登录结果：读取 CookieStore 并抓取数据。"""
import sys

sys.path.insert(0, ".")

from ocusage import client  # noqa: E402
from ocusage.auth import CookieStore  # noqa: E402

cred = CookieStore.load()
if cred is None:
    print("❌ 未找到已保存的凭证")
    sys.exit(1)

cookie, workspace_id = cred
print(f"cookie 已保存: 长度 {len(cookie)}")
print(f"workspace_id: {workspace_id!r}")

if not cookie:
    print("❌ cookie 为空")
    sys.exit(1)

c = client.OpenCodeClient(cookie)

if workspace_id:
    go = c.fetch_go(workspace_id)
    print("\n[Go 套餐]")
    print(f"  已订阅: {go.subscribed} | 余额兜底: {go.use_balance} | 区域: {go.regions}")
    for w in (go.rolling, go.weekly, go.monthly):
        if w:
            print(f"  {w.label}: {w.usage_percent:.0f}% 已用, {w.reset_text()} 后重置")
    print(f"  Zen 余额: ${go.balance}")

    usage = c.fetch_usage(workspace_id)
    print(f"\n[用量明细] {len(usage.records)} 条记录, 总 cost {usage.total_cost} (${usage.total_cost_usd:.4f})")
    for model, cost in sorted(usage.by_model().items(), key=lambda kv: -kv[1]):
        print(f"  {model}: {cost}")

    print("\n✅ 全链路验证通过")
else:
    print("⚠️ workspace_id 为空——登录窗口可能没等到跳转就关闭了")
    print("   数据抓取会失败，需要重新登录")
