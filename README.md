# oc-usage — OpenCode 用量托盘工具

Windows 系统托盘常驻，查询 **OpenCode Go** 订阅用量（三层限额：5 小时滚动 / 每周 / 每月）与 Zen 请求级计费明细。

## 原理

OpenCode 官方没有公开用量 API（[issue #10448](https://github.com/sst/opencode/issues/10448) 仍挂着），
用量数据只存在于 web console 的页面中。本工具：

1. 内嵌 **QtWebEngine** 打开 `https://opencode.ai/console/login`，登录后自动捕获 `auth` cookie（iron-session，有效期约一年）
2. cookie 用 **Windows DPAPI** 加密存入 `%APPDATA%\oc-usage\cookie.bin`
3. 请求页面并用 **QJSEngine** 执行 SSR 内联脚本，从 `_$HY.r` 提取数据（无需调用内部 RPC，前端改版容错性最好）：
   - `GET /workspace/{id}/go` → 三层限额、余额、邀请奖励
   - `GET /workspace/{id}/usage` → 请求级明细（模型、token、cost）

## 运行

```powershell
cd oc-usage
.venv\Scripts\python.exe main.py
```

首次运行会弹出登录窗口（Google 或邮箱验证码），登录后自动开始显示。

托盘菜单：打开统计 / 立即刷新 / 重新登录 / 退出。

## 测试

```powershell
.venv\Scripts\python.exe tests\test_parse.py
```

## 风险提示

- 依赖 web console 内部页面结构，opencode 前端改版可能导致解析失败（届时更新 `ocusage/client.py` 的 key 前缀即可）
- `cost` 单位官方未公开，按 microUSD 假设换算展示
