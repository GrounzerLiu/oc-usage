# oc-usage — OpenCode 用量托盘工具（Flutter）

Windows 系统托盘常驻，查询 **OpenCode Go** 订阅用量（三层限额：5 小时滚动 / 每周 / 每月）与请求级计费明细。

## 原理

OpenCode 官方没有公开用量 API，用量数据只存在于 web console 页面中。本工具：

1. **登录**：内嵌 WebView2 打开 opencode.ai，登录后从原生 CookieManager 捕获 `auth` cookie，
   DPAPI 加密存入 `%APPDATA%\oc-usage\cookie.bin`（与旧版 Python 工具同路径兼容）
2. **数据获取**：HTTP（dart:io，走系统代理）+ WebView2 仅执行 JS 解析（SSR 提取 / RPC 响应流）
3. **缓存**：SQLite（`%APPDATA%\com.grounzer\oc_usage\oc-usage\cache.db`）—— 请求记录 id 去重增量同步、
   历史月永久缓存、当前月 10 分钟 TTL、Go 限额启动快照

## 运行（开发）

```powershell
cd oc-usage
D:\flutter\bin\flutter.bat run -d windows
```

## 构建与打包

```powershell
D:\flutter\bin\flutter.bat build windows
# 安装器（Inno Setup）
"C:\Program Files\Inno Setup 7\ISCC.exe" install.iss
```

产物：`build\windows\x64\runner\Release\`（约 30MB）、`installer\oc-usage-flutter-setup-1.0.0.exe`（约 11MB）。

## 特性

- 托盘常驻（opencode 图标），5 分钟定时刷新，打开窗口自动更新
- 三层限额环形进度、成本趋势堆叠柱状图（月份切换、悬浮明细）、模型成本占比饼图
- 统计卡片（总请求 / 总 Token / 覆盖天数），悬浮显示完整数字
- 设置：主题（跟随系统 / 亮色 / 暗色）、开机自启、关于
- 单实例运行、`%APPDATA%\com.grounzer\oc_usage\oc-usage\app.log` 日志

## 风险提示

- 依赖 web console 内部页面结构，前端改版可能导致解析失败（`lib/client.dart` 的 key 前缀）
- `cost` 单位官方未公开，按 microUSD 假设换算展示
