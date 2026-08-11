"""GUI 冒烟测试（offscreen）：托盘、窗口、DPAPI、登录窗口创建。"""
import os
import sys

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
sys.path.insert(0, ".")

from PySide6.QtWidgets import QApplication  # noqa: E402

from ocusage.auth import COOKIE_FILE, CookieStore, LoginWindow  # noqa: E402
from ocusage.ui.dashboard import DashboardWindow  # noqa: E402
from ocusage.ui.tray import TrayIcon  # noqa: E402

app = QApplication([])

# 1. 托盘
tray = TrayIcon()
tray.show()
tray.set_summary(["滚动：2% 已用", "每周：3% 已用"], status="刷新中…")
print("1. tray OK")

# 2. 统计窗口
win = DashboardWindow()
win.set_status("测试")
win.show_go(None)
print("2. dashboard OK")

# 3. DPAPI 存取 round-trip
test_cookie = "Fe26.2**test" * 10
CookieStore.save(test_cookie, "wrk_01KW_TEST")
loaded = CookieStore.load()
assert loaded == (test_cookie, "wrk_01KW_TEST"), loaded
print("3. DPAPI round-trip OK ->", loaded[1])
CookieStore.clear()
assert CookieStore.load() is None
print("4. CookieStore clear OK")

# 5. 登录窗口创建（不加载页面，避免网络依赖）
login = LoginWindow()
print("5. login window create OK")

print("\nSMOKE TEST PASSED")
