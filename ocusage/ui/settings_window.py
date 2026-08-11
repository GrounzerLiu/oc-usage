"""设置窗口：主题（跟随系统/暗色/亮色）、开机自启、关于。"""
from __future__ import annotations

from typing import Optional

from PySide6.QtCore import Property, QEasingCurve, QPropertyAnimation, QRectF, Qt, Signal
from PySide6.QtGui import QColor, QPainter, QPen, QPixmap
from PySide6.QtWidgets import (
    QAbstractButton,
    QApplication,
    QButtonGroup,
    QFrame,
    QHBoxLayout,
    QLabel,
    QPushButton,
    QVBoxLayout,
    QWidget,
)

from ..settings import Settings, autostart_enabled
from .dashboard import ASSETS_DIR, DARK, LIGHT, _build_qss

APP_VERSION = "1.0.0"
GITHUB_URL = "https://github.com/GrounzerLiu/oc-usage"


class _Switch(QAbstractButton):
    """自绘滑块开关：轨道 + 圆形滑块，切换带平滑动画。"""

    def __init__(self, parent: Optional[QWidget] = None):
        super().__init__(parent)
        self.setCheckable(True)
        self.setCursor(Qt.CursorShape.PointingHandCursor)
        self.setFixedSize(46, 24)
        self._pos = 0.0  # 滑块位置 0..1
        self._track_off = "#c8d0df"
        self._track_on = "#4a6cf7"
        self._thumb = "#ffffff"
        self._anim = QPropertyAnimation(self, b"offset", self)
        self._anim.setDuration(140)
        self._anim.setEasingCurve(QEasingCurve.Type.OutCubic)
        self.toggled.connect(self._start_anim)

    def offset(self) -> float:
        return self._pos

    def set_offset(self, value: float) -> None:
        self._pos = max(0.0, min(1.0, float(value)))
        self.update()

    offset = Property(float, offset, set_offset)

    def set_colors(self, track_on: str, track_off: str, thumb: str) -> None:
        self._track_on = track_on
        self._track_off = track_off
        self._thumb = thumb
        self.update()

    def _start_anim(self, checked: bool) -> None:
        self._anim.stop()
        self._anim.setStartValue(self._pos)
        self._anim.setEndValue(1.0 if checked else 0.0)
        self._anim.start()

    def paintEvent(self, event) -> None:
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        w, h = self.width(), self.height()
        # 轨道
        track = QRectF(1, (h - 18) / 2, w - 2, 18)
        on = QColor(self._track_on)
        off = QColor(self._track_off)
        c = QColor(
            round(on.red() * self._pos + off.red() * (1 - self._pos)),
            round(on.green() * self._pos + off.green() * (1 - self._pos)),
            round(on.blue() * self._pos + off.blue() * (1 - self._pos)),
        )
        p.setPen(QPen(c.darker(115), 1))
        p.setBrush(c)
        p.drawRoundedRect(track, 9, 9)
        # 滑块
        pad = 3
        thumb_d = 18
        x = pad + self._pos * (w - 2 * pad - thumb_d)
        p.setPen(QPen(QColor(0, 0, 0, 40), 1))
        p.setBrush(QColor(self._thumb))
        p.drawEllipse(QRectF(x, (h - thumb_d) / 2, thumb_d, thumb_d))
        p.end()


def _extra_qss(t: dict) -> str:
    return f"""
QFrame#group {{
    background: {t['card']};
    border: 1px solid {t['border']};
    border-radius: 12px;
}}
QLabel#groupTitle {{
    font-size: 12px;
    color: {t['sub']};
    letter-spacing: 1px;
    font-weight: 600;
}}
QPushButton#themeBtn {{
    background: {t['card_alt']};
    border: 1px solid {t['border']};
    border-radius: 10px;
    padding: 9px 0;
    color: {t['text']};
    font-size: 13px;
    font-weight: 600;
}}
QPushButton#themeBtn:hover {{ border-color: {t['accent_line']}; }}
QPushButton#themeBtn:checked {{
    background: {t['accent_line']};
    border-color: {t['accent_line']};
    color: {t['btn_text']};
}}
QLabel#switchLabel {{
    color: {t['text']};
    font-size: 13px;
    background: transparent;
}}
QLabel#aboutTitle {{
    font-size: 16px;
    font-weight: bold;
    color: {t['text']};
}}
QLabel#aboutDesc {{
    font-size: 12px;
    color: {t['sub']};
}}
QLabel a:link {{
    color: {t['accent_line']};
    text-decoration: none;
}}
"""


class SettingsWindow(QWidget):
    """设置对话框：主题、开机自启、关于。"""

    theme_changed = Signal(str)  # "system" / "dark" / "light"
    autostart_changed = Signal(bool)

    def __init__(self, settings: Settings, parent: Optional[QWidget] = None):
        super().__init__(parent)
        self.setWindowTitle("设置")
        self.setFixedSize(380, 460)

        self._settings = settings
        self._theme_mode = "system"
        self._scheme_connected = False

        root = QVBoxLayout(self)
        root.setContentsMargins(20, 18, 20, 18)
        root.setSpacing(10)

        # ── 外观：主题 ──
        root.addWidget(self._group_title("外观"))

        theme_card = QFrame()
        theme_card.setObjectName("group")
        theme_row = QHBoxLayout(theme_card)
        theme_row.setContentsMargins(12, 12, 12, 12)
        theme_row.setSpacing(10)

        self._theme_group = QButtonGroup(self)
        self._theme_group.setExclusive(True)
        for mode, label in (
            ("system", "跟随系统"),
            ("light", "亮色"),
            ("dark", "暗色"),
        ):
            btn = QPushButton(label)
            btn.setObjectName("themeBtn")
            btn.setCheckable(True)
            btn.setCursor(Qt.CursorShape.PointingHandCursor)
            self._theme_group.addButton(btn)
            theme_row.addWidget(btn, 1)
        self._theme_group.buttonClicked.connect(self._on_theme_clicked)
        root.addWidget(theme_card)

        # ── 常规：开机自启 ──
        root.addWidget(self._group_title("常规"))

        general_card = QFrame()
        general_card.setObjectName("group")
        general_row = QHBoxLayout(general_card)
        general_row.setContentsMargins(14, 14, 14, 14)

        self._autostart_switch = _Switch()
        self._autostart_switch.setChecked(settings.autostart or autostart_enabled())
        self._autostart_switch.toggled.connect(self._on_autostart_toggled)
        general_row.addWidget(self._autostart_switch)
        general_row.addSpacing(4)
        sw_label = QLabel("开机时自动启动")
        sw_label.setObjectName("switchLabel")
        general_row.addWidget(sw_label)
        general_row.addStretch(1)
        root.addWidget(general_card)

        # ── 关于 ──
        root.addWidget(self._group_title("关于"))

        about_card = QFrame()
        about_card.setObjectName("group")
        about_col = QVBoxLayout(about_card)
        about_col.setContentsMargins(14, 14, 14, 14)
        about_col.setSpacing(6)

        head = QHBoxLayout()
        head.setSpacing(12)
        icon = QLabel()
        pm = QPixmap(str(ASSETS_DIR / "opencode.png"))
        if not pm.isNull():
            pm = pm.scaled(
                40, 40,
                Qt.AspectRatioMode.KeepAspectRatio,
                Qt.TransformationMode.SmoothTransformation,
            )
            icon.setPixmap(pm)
        icon.setFixedSize(40, 40)
        head.addWidget(icon)

        title_col = QVBoxLayout()
        title_col.setSpacing(2)
        title = QLabel(f"OpenCode 用量 v{APP_VERSION}")
        title.setObjectName("aboutTitle")
        title_col.addWidget(title)
        link = QLabel(
            f'<a href="{GITHUB_URL}">GitHub · GrounzerLiu/oc-usage</a>'
        )
        link.setOpenExternalLinks(True)
        link.setCursor(Qt.CursorShape.PointingHandCursor)
        title_col.addWidget(link)
        head.addLayout(title_col)
        head.addStretch(1)
        about_col.addLayout(head)

        desc = QLabel(
            "Windows 托盘常驻，查询 OpenCode Go 订阅用量"
            "（滚动 / 每周 / 每月三层限额）与 Zen 请求级计费明细。\n"
            "数据来自 opencode.ai web console，无官方 API。"
        )
        desc.setObjectName("aboutDesc")
        desc.setWordWrap(True)
        about_col.addWidget(desc)
        root.addWidget(about_card)

        root.addStretch(1)

        self.set_theme_mode(settings.theme)

    @staticmethod
    def _group_title(text: str) -> QLabel:
        lbl = QLabel(text)
        lbl.setObjectName("groupTitle")
        return lbl

    # ── 主题 ──

    def set_theme_mode(self, mode: str) -> None:
        """应用主题模式；同步勾选主题按钮。"""
        self._theme_mode = mode
        if mode == "system":
            app = QApplication.instance()
            if app is not None:
                if not self._scheme_connected:
                    self._scheme_connected = True
                    app.styleHints().colorSchemeChanged.connect(
                        self._on_scheme_changed
                    )
                scheme = app.styleHints().colorScheme()
                self.apply_theme(scheme == Qt.ColorScheme.Dark)
        else:
            self.apply_theme(mode == "dark")
        for btn in self._theme_group.buttons():
            btn.setChecked(btn.text() == {"system": "跟随系统", "light": "亮色", "dark": "暗色"}[mode])

    def apply_theme(self, dark: bool) -> None:
        t = DARK if dark else LIGHT
        self.setStyleSheet(_build_qss(t) + _extra_qss(t))
        self._autostart_switch.set_colors(t["btn"], t["bar_bg"], "#ffffff")

    def _on_scheme_changed(self, scheme) -> None:
        if self._theme_mode == "system":
            self.apply_theme(scheme == Qt.ColorScheme.Dark)

    # ── 交互 ──

    def _on_theme_clicked(self, btn) -> None:
        mode = {"跟随系统": "system", "亮色": "light", "暗色": "dark"}.get(btn.text(), "system")
        self.theme_changed.emit(mode)

    def _on_autostart_toggled(self, checked: bool) -> None:
        self.autostart_changed.emit(bool(checked))
