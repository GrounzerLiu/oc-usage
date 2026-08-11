"""真实网络联调：cookie → go → usage 全链路。"""
import sys

sys.path.insert(0, ".")

from ocusage import client  # noqa: E402

COOKIE = "Fe26.2**8555fd722363508ffe939befc852c6167dc9d4bc96078f7bd69704773bd950c7*zVPTz_sSSA2U43sX2k6TUw*RYi6j_Ono_J--U5ZmRTvyXGLoIqixl3lbMGjv7_XtAF61DhOnqCIflyZ2ZMm3fqBnA6YsGA6IIsbcWloAaRa6mo_jjZhfKNhc969vxmZdHrjhCBAsz0r08HC1T0b590_U1aZP8OJFMMq1A0j8Dq6EJb9kRjhXBBj5vhQj4Rd88bV9lG2A0fhuIa2JVVWCc3OHpDteBclAKiIGviL_Y5e8Nx_cMS2oXBD9rHxAnLyMn1r97tDzVUSWTjKOKGB4yZuh9PCJvJ_RocdGRI6pt9Pvjeqt4QxpNKeTKElQARNlGhczsRTjQ_vVgWNcCMnJtjJ5jDLs4l3RE3txpPgH_AE4g*1816417459073*9fa936ba117e2cc44ee54a4d9ac95bf6e02b8b41794361c7e784c5d485f09917*twYOseAkzBxYqOB71x_UepNa-K99tWLd8hnx5bMPBnM"
WORKSPACE_ID = "wrk_01KW1979J8NW6W8J9NV7SNZX8B"

c = client.OpenCodeClient(COOKIE)

go = c.fetch_go(WORKSPACE_ID)
print("go subscribed:", go.subscribed, "| use_balance:", go.use_balance, "| regions:", go.regions)
for w in (go.rolling, go.weekly, go.monthly):
    if w:
        print(f"  {w.label}: {w.usage_percent}% used, reset in {w.reset_text()}")
print("billing balance:", go.balance, "| payment:", go.payment_method_type)

usage = c.fetch_usage(WORKSPACE_ID)
print("usage records:", len(usage.records), "| total_cost:", usage.total_cost, f"(${usage.total_cost_usd:.4f})")
print("by model:", usage.by_model())
if usage.records:
    r = usage.records[0]
    print("first record:", r.model, r.provider, "tokens:", r.input_tokens, r.output_tokens, r.cache_read_tokens, "cost:", r.cost, "plan:", r.plan)

print("\nLIVE TEST PASSED")
