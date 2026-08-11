"""入口：托盘常驻 + 登录 + 后台刷新。"""
from __future__ import annotations

import sys
import threading
from typing import Optional

from PySide6.QtCore import QObject, QTimer, Signal
from PySide6.QtWidgets import QApplication, QMessageBox

from ocusage import client
from ocusage.auth import CookieStore, LoginWindow
from ocusage.dbcache import UsageCache
from ocusage.models import GoData, HistoryEntry, UsageData
from ocusage.settings import Settings, set_autostart
from ocusage.ui.dashboard import DashboardWindow
from ocusage.ui.settings_window import SettingsWindow
from ocusage.ui.tray import TrayIcon

REFRESH_INTERVAL_MS = 5 * 60 * 1000  # 5 分钟自动刷新


class AppController(QObject):
    """串联：cookie → 数据抓取 → 托盘/窗口。"""

    go_loaded = Signal(object)  # GoData
    history_loaded = Signal(object)  # list[HistoryEntry]
    all_loaded = Signal(int)  # 缓存同步完成（新增条数）
    all_failed = Signal(str)
    stats_ready = Signal(dict)  # 用量统计（全部数据）
    cost_share_ready = Signal(object)  # 成本占比（全部数据）[(model, cost)]
    data_error = Signal(str)

    def __init__(self, app: QApplication):
        super().__init__(app)
        self._app = app
        cred = CookieStore.load()
        self._cookie: Optional[str] = cred[0] if cred else None
        self._workspace_id: Optional[str] = cred[1] if cred else None

        self.tray = TrayIcon(self)
        self.window = DashboardWindow()
        self._db = UsageCache()
        self._settings = Settings()
        self._settings_window: Optional[SettingsWindow] = None
        self.window.set_theme_mode(self._settings.theme)

        # 信号路由
        self.tray.open_requested.connect(self._show_window)
        self.tray.refresh_requested.connect(self.refresh)
        self.tray.relogin_requested.connect(self._start_login)
        self.tray.settings_requested.connect(self._show_settings)
        self.tray.quit_requested.connect(app.quit)
        self.window.refresh_requested.connect(self.refresh)
        self.window.all_stats_requested.connect(self.fetch_all)
        self.window.settings_requested.connect(self._show_settings)
        self.window.month_changed.connect(self.on_month_changed)
        self.go_loaded.connect(self._on_go_loaded)
        self.history_loaded.connect(self._on_history_loaded)
        self.all_loaded.connect(self._on_all_loaded)
        self.all_failed.connect(self._on_all_failed)
        self.stats_ready.connect(self._on_stats_ready)
        self.cost_share_ready.connect(self._on_cost_share_ready)
        self.data_error.connect(self._on_data_error)

        # 当前查看的月份（1-based，柱状图历史）
        import datetime as _dt

        _now = _dt.datetime.now()
        self._view_year = _now.year
        self._view_month = _now.month

        # 后台抓取线程
        self._fetch_thread: Optional[threading.Thread] = None
        self._history_thread: Optional[threading.Thread] = None
        self._sync_thread: Optional[threading.Thread] = None
        self._lock = threading.Lock()
        self._latest_go: Optional[GoData] = None
        self._latest_history: list[HistoryEntry] = []

        # 定时刷新
        self._timer = QTimer(self)
        self._timer.setInterval(REFRESH_INTERVAL_MS)
        self._timer.timeout.connect(self.refresh)

    # ── 启动 ──

    def start(self) -> None:
        self.tray.show()
        if self._cookie and self._workspace_id:
            self.refresh()
            self._timer.start()
        else:
            self.tray.set_error("未登录，点击托盘菜单「重新登录」")
            self._start_login()

    # ── 登录 ──

    def _start_login(self) -> None:
        self._login_window = LoginWindow()
        self._login_window.login_succeeded.connect(self._on_login_ok)
        self._login_window.cancelled.connect(self._on_login_cancel)
        self._login_window.show()
        self._login_window.raise_()
        self._login_window.activateWindow()

    def _on_login_ok(self, cookie: str, workspace_id: str) -> None:
        self._cookie = cookie
        if workspace_id:
            self._workspace_id = workspace_id
        if not self._workspace_id:
            self.tray.set_error("登录成功但未获取到 workspace，请重试")
            return
        self.tray.set_summary([], status="登录成功，正在获取数据…")
        self.refresh()
        self._timer.start()

    def _on_login_cancel(self) -> None:
        self.tray.set_error("未登录")

    # ── 刷新 ──

    def refresh(self) -> None:
        if not self._cookie:
            self._start_login()
            return
        self.window.set_status("刷新中…")
        with self._lock:
            if self._fetch_thread and self._fetch_thread.is_alive():
                return  # 已有刷新在进行
            self._fetch_thread = threading.Thread(target=self._fetch_worker, daemon=True)
            self._fetch_thread.start()

    def fetch_all(self, force: bool = False) -> None:
        """同步请求记录缓存并输出统计卡片（force=全量重建，否则增量）。

        「全量统计」按钮与统计卡片共用此流程；统计结果来自 SQLite 聚合（秒级）。
        DB 已有数据时先出快照，同时后台增量同步补齐新记录。
        """
        if not self._cookie or not self._workspace_id:
            self._start_login()
            return
        wid = self._workspace_id

        # DB 已有数据且非强制 → 先出统计快照（历史数据不变，秒出）
        if not force:
            stats = self._db.all_stats()
            if stats["requests"] > 0:
                self.stats_ready.emit(stats)
                self.cost_share_ready.emit(self._db.all_model_costs())

        self._sync_async(force=force)

    def _sync_async(self, force: bool) -> None:
        """后台同步线程：增量（默认）或全量重建（force）。"""
        with self._lock:
            if self._sync_thread and self._sync_thread.is_alive():
                return
            self.window.set_status(
                "正在全量重建缓存…" if force else "正在同步请求记录…"
            )

            def worker():
                try:
                    c = client.OpenCodeClient(self._cookie)
                    if force:
                        n = self._db.sync_full(c, self._workspace_id)
                    else:
                        n = self._db.sync_incremental(c, self._workspace_id)
                    stats = self._db.all_stats()
                    self.stats_ready.emit(stats)
                    self.cost_share_ready.emit(self._db.all_model_costs())
                    self.all_loaded.emit(n)
                except client.ClientError as e:
                    self.all_failed.emit(str(e))
                except Exception as e:  # noqa: BLE001
                    self.all_failed.emit(f"内部错误：{e}")

            self._sync_thread = threading.Thread(target=worker, daemon=True)
            self._sync_thread.start()

    def _history_with_cache(
        self, c: client.OpenCodeClient, wid: str, year: int, month: int
    ) -> list[HistoryEntry]:
        """历史聚合：缓存命中直接返回（当前月 10 分钟 TTL、历史月永久）。"""
        cached = self._db.get_history_cache(wid, year, month)
        if cached is not None:
            return cached
        try:
            entries = c.fetch_usage_history(wid, year, month - 1)
        except client.ClientError:
            return []
        self._db.put_history_cache(wid, year, month, entries)
        return entries

    def _on_all_loaded(self, n: int) -> None:
        self.window.set_status(f"缓存已同步 · 新增 {n} 条 · {self._now_text()}")

    def _on_stats_ready(self, stats: dict) -> None:
        self.window.show_stats(stats)
        self.window.set_status(f"上次刷新 {self._now_text()}")

    def _on_cost_share_ready(self, costs: list) -> None:
        self.window.show_cost_share(costs)

    def _on_all_failed(self, message: str) -> None:
        self.window.set_status(f"全量统计失败：{message}")
        self.tray.set_error(message)

    def on_month_changed(self, year: int, month: int) -> None:
        """切换月份：后台拉取该月历史聚合并更新柱状图。"""
        self._view_year, self._view_month = year, month
        self.window.set_status(f"加载 {year}年{month}月…")
        if not self._cookie or not self._workspace_id:
            return

        def worker():
            try:
                c = client.OpenCodeClient(self._cookie)
                entries = self._history_with_cache(c, self._workspace_id, year, month)
                self.history_loaded.emit(entries)
                self.window.set_status(f"上次刷新 {self._now_text()}")
            except client.ClientError as e:
                self.data_error.emit(str(e))
            except Exception as e:  # noqa: BLE001
                self.data_error.emit(f"内部错误：{e}")

        self._history_thread = threading.Thread(target=worker, daemon=True)
        self._history_thread.start()

    def _fetch_worker(self) -> None:
        """后台线程：抓取 go 窗口数据 + 历史聚合（带缓存）。"""
        try:
            if not self._cookie or not self._workspace_id:
                self.data_error.emit("缺少登录凭证")
                return
            c = client.OpenCodeClient(self._cookie)
            wid = self._workspace_id
            go = c.fetch_go(wid)
            # 拉取当前查看月份的历史（带缓存，保持柱状图不跳回当月）
            history = self._history_with_cache(c, wid, self._view_year, self._view_month)
            self.go_loaded.emit(go)
            self.history_loaded.emit(history)
        except client.ClientError as e:
            self.data_error.emit(str(e))
        except Exception as e:  # noqa: BLE001
            self.data_error.emit(f"内部错误：{e}")

    # ── 数据落地 ──

    def _on_go_loaded(self, go: GoData) -> None:
        self._latest_go = go
        self.tray.set_summary(go.summary_lines())
        self.window.show_go(go)
        self.window.set_status(f"上次刷新 {self._now_text()}")

    def _on_history_loaded(self, history: list[HistoryEntry]) -> None:
        self._latest_history = history
        self.window.show_history(history)
        self.window.set_status(f"上次刷新 {self._now_text()}")

    def _on_data_error(self, message: str) -> None:
        self.tray.set_error(message)
        if message.startswith("登录已过期"):
            self._start_login()

    # ── 设置 ──

    def _show_settings(self) -> None:
        if self._settings_window is None:
            self._settings_window = SettingsWindow(self._settings)
            self._settings_window.theme_changed.connect(self._on_theme_changed)
            self._settings_window.autostart_changed.connect(self._on_autostart_changed)
        self._settings_window.set_theme_mode(self._settings.theme)
        self._settings_window.show()
        self._settings_window.raise_()
        self._settings_window.activateWindow()

    def _on_theme_changed(self, mode: str) -> None:
        self._settings.theme = mode
        self._settings.save()
        self.window.set_theme_mode(mode)
        if self._settings_window is not None:
            self._settings_window.set_theme_mode(mode)

    def _on_autostart_changed(self, enabled: bool) -> None:
        self._settings.autostart = enabled
        self._settings.save()
        try:
            set_autostart(enabled)
        except Exception as e:  # noqa: BLE001
            self.tray.set_error(f"开机自启设置失败：{e}")

    # ── 窗口 ──

    def _show_window(self) -> None:
        if self._latest_go is not None:
            self.window.show_go(self._latest_go)
        if self._latest_history:
            self.window.show_history(self._latest_history)
        self.fetch_all()  # 统计快照 + 后台增量同步
        if self._latest_go is None:
            self.window.set_status("数据尚未获取，点击「刷新」")
        else:
            self.window.set_status(f"上次刷新 {self._now_text()}")
        self.window.show()
        self.window.raise_()
        self.window.activateWindow()

    @staticmethod
    def _now_text() -> str:
        import datetime

        return datetime.datetime.now().strftime("%H:%M:%S")


def main() -> int:
    import argparse

    parser = argparse.ArgumentParser(description="OpenCode 用量托盘工具")
    parser.add_argument(
        "--workspace",
        help="workspace id（wrk_...），跳过登录窗口自动提取，直接使用",
    )
    args = parser.parse_args()

    app = QApplication(sys.argv)
    app.setApplicationName("ocusage")
    app.setQuitOnLastWindowClosed(False)  # 托盘常驻，关窗口不退出

    controller = AppController(app)
    if args.workspace:
        controller._workspace_id = args.workspace
    controller.start()
    return app.exec()


if __name__ == "__main__":
    sys.exit(main())
