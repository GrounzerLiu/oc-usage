"""系统托盘图标。"""
from __future__ import annotations

from pathlib import Path
from typing import Callable, Optional

from PySide6.QtCore import QObject, Signal
from PySide6.QtGui import QAction, QIcon
from PySide6.QtWidgets import QMenu, QSystemTrayIcon

ASSETS_DIR = Path(__file__).resolve().parent.parent / "assets"


class TrayIcon(QObject):
    """托盘图标：悬停显示用量摘要，点击打开统计窗口，右键菜单刷新/登录/退出。"""

    open_requested = Signal()
    refresh_requested = Signal()
    relogin_requested = Signal()
    quit_requested = Signal()

    def __init__(self, parent: Optional[QObject] = None):
        super().__init__(parent)
        self._tray = QSystemTrayIcon(self)
        self._tray.setIcon(self._make_icon())
        self._tray.setToolTip("OpenCode 用量")

        menu = QMenu()
        self._action_open = QAction("打开统计", menu)
        self._action_refresh = QAction("立即刷新", menu)
        self._action_relogin = QAction("重新登录…", menu)
        self._action_quit = QAction("退出", menu)
        menu.addAction(self._action_open)
        menu.addAction(self._action_refresh)
        menu.addSeparator()
        menu.addAction(self._action_relogin)
        menu.addAction(self._action_quit)
        self._tray.setContextMenu(menu)

        self._tray.activated.connect(self._on_activated)
        self._action_open.triggered.connect(self.open_requested.emit)
        self._action_refresh.triggered.connect(self.refresh_requested.emit)
        self._action_relogin.triggered.connect(self.relogin_requested.emit)
        self._action_quit.triggered.connect(self.quit_requested.emit)

    # ── 对外接口 ──

    def show(self) -> None:
        self._tray.show()

    def hide(self) -> None:
        self._tray.hide()

    def set_summary(self, lines: list[str], status: str = "") -> None:
        """更新托盘 tooltip。lines 为数据行，status 为状态前缀（如 '刷新中…'）。"""
        parts = ([status] if status else []) + lines
        self._tray.setToolTip("OpenCode 用量\n" + "\n".join(parts) if parts else "OpenCode 用量")

    def set_error(self, message: str) -> None:
        self._tray.setToolTip(f"OpenCode 用量\n❌ {message}")

    # ── 内部 ──

    def _on_activated(self, reason: QSystemTrayIcon.ActivationReason) -> None:
        # 单击/双击打开统计窗口
        if reason in (QSystemTrayIcon.ActivationReason.Trigger, QSystemTrayIcon.ActivationReason.DoubleClick):
            self.open_requested.emit()

    def _make_icon(self) -> QIcon:
        """使用 opencode 官网图标；资源缺失时回退到程序化生成的图标。"""
        png = ASSETS_DIR / "opencode.png"
        if png.exists():
            return QIcon(str(png))
        from PySide6.QtCore import QRectF, Qt
        from PySide6.QtGui import QColor, QPainter, QPixmap

        pm = QPixmap(64, 64)
        pm.fill(Qt.GlobalColor.transparent)
        p = QPainter(pm)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        p.setBrush(QColor("#1f6feb"))
        p.setPen(Qt.PenStyle.NoPen)
        p.drawRoundedRect(QRectF(2, 2, 60, 60), 12, 12)
        p.setPen(QColor("white"))
        font = p.font()
        font.setBold(True)
        font.setPixelSize(30)
        p.setFont(font)
        p.drawText(pm.rect(), Qt.AlignmentFlag.AlignCenter, "%")
        p.end()
        return QIcon(pm)
