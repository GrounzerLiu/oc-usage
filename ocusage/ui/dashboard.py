"""统计窗口：卡片式布局，亮/暗主题跟随系统，环形进度、图表与明细。"""
from __future__ import annotations

from pathlib import Path
from typing import Optional

from PySide6.QtCharts import (
    QBarCategoryAxis,
    QBarSet,
    QChart,
    QChartView,
    QPieSeries,
    QPieSlice,
    QStackedBarSeries,
    QValueAxis,
)
from PySide6.QtCore import QMargins, QRectF, Qt, QTimer, Signal
from PySide6.QtGui import (
    QBrush,
    QColor,
    QCursor,
    QFont,
    QGradient,
    QLinearGradient,
    QPainter,
    QPainterPath,
    QPen,
    QPixmap,
)
from PySide6.QtWidgets import (
    QApplication,
    QFrame,
    QGraphicsTextItem,
    QGraphicsView,
    QHBoxLayout,
    QLabel,
    QPushButton,
    QVBoxLayout,
    QWidget,
)

from ..models import GoData, UsageData

ASSETS_DIR = Path(__file__).resolve().parent.parent / "assets"

# cost 原始单位 → 美元的换算系数（与网页纵轴一致：totalCost × 1e-8）
COST_TO_USD = 1e-8

# 模型 → 颜色（现代调色板，浅色/深色主题下均清晰）
MODEL_COLORS = {
    "deepseek-v4-flash": "#10b981",  # emerald
    "deepseek-v4-pro": "#8b5cf6",    # violet
    "gpt-5.6-luna": "#3b82f6",       # blue
    "mimo-v2.5": "#06b6d4",          # cyan
}
FALLBACK_COLORS = [
    "#f59e0b", "#ec4899", "#f97316", "#6366f1", "#14b8a6", "#a3a3a3",
]

# 横轴日期标签最小间隔（像素），窗口变窄时按此自动降采样
LABEL_MIN_SPACING_PX = 34

# ── 两套主题（精致配色：蓝→紫主色，卡片柔和阴影） ──

LIGHT = {
    "bg_from": "#f8f9fd",      # 页面背景渐变起点
    "bg_to": "#eef1f9",        # 页面背景渐变终点
    "card": "#ffffff",
    "card_alt": "#f6f8ff",     # 次级/悬停区
    "border": "#e7ebf4",
    "text": "#1b2233",
    "sub": "#6a7490",
    "faint": "#9aa3ba",
    "bar_bg": "#e9edf7",       # 环形轨道
    "btn": "#4a6cf7",          # 主按钮渐变起点（蓝）
    "btn_hover": "#6a8aff",
    "btn_end": "#8b5cf6",      # 主按钮渐变终点（紫）
    "btn_text": "#ffffff",
    "accent_line": "#4a6cf7",  # 区块装饰线
    "ghost_text": "#4a6cf7",   # 次级按钮
    "ghost_border": "#c8d3f8",
    "shadow": (0, 8, 28, 20),
    "shadow_card": (0, 4, 22, 14),
}

DARK = {
    "bg_from": "#0e1118",
    "bg_to": "#121623",
    "card": "#161b28",
    "card_alt": "#1c2233",
    "border": "#272e42",
    "text": "#e8ecf6",
    "sub": "#8e97ad",
    "faint": "#5f6880",
    "bar_bg": "#232a3d",
    "btn": "#4a6cf7",
    "btn_hover": "#5f80ff",
    "btn_end": "#8b5cf6",
    "btn_text": "#ffffff",
    "accent_line": "#6a8cff",
    "ghost_text": "#7aa2ff",
    "ghost_border": "#33406a",
    "shadow": (0, 0, 0, 70),
    "shadow_card": (0, 0, 0, 45),
}

ACCENT = {
    "low": "#2ecc71",    # <50% 绿
    "mid": "#e67e22",    # 50-80% 橙
    "high": "#e74c3c",   # >=80% 红
}


def _accent(pct: float) -> str:
    if pct >= 80:
        return ACCENT["high"]
    if pct >= 50:
        return ACCENT["mid"]
    return ACCENT["low"]


def _readable_label_color(hex_color: str) -> str:
    """按扇区底色亮度选文字色：亮底深字、暗底白字。"""
    c = QColor(hex_color)
    lum = 0.299 * c.red() + 0.587 * c.green() + 0.114 * c.blue()
    return "#1b2233" if lum > 165 else "#ffffff"


def _build_qss(t: dict) -> str:
    return f"""
QWidget {{
    background: qlineargradient(x1:0, y1:0, x2:1, y2:1,
        stop:0 {t['bg_from']}, stop:1 {t['bg_to']});
    color: {t['text']};
    font-family: "Microsoft YaHei UI", "Segoe UI", sans-serif;
    font-size: 13px;
}}
QLabel {{
    background: transparent;
}}
QLabel#winTitle {{
    font-size: 21px;
    font-weight: bold;
    color: {t['text']};
}}
QLabel#winSubtitle {{
    font-size: 12px;
    color: {t['sub']};
}}
QLabel#status {{
    font-size: 12px;
    color: {t['sub']};
    background: {t['card']};
    border: 1px solid {t['border']};
    border-radius: 14px;
    padding: 4px 12px;
}}
QFrame#card {{
    background: {t['card']};
    border: 1px solid {t['border']};
    border-radius: 16px;
}}
QLabel#cardTitle {{
    font-size: 12px;
    color: {t['sub']};
    letter-spacing: 1px;
    font-weight: 600;
}}
QLabel#statNum {{
    font-size: 26px;
    font-weight: bold;
    color: {t['text']};
}}
QLabel#cardReset {{
    font-size: 11px;
    color: {t['faint']};
}}
QLabel#sectionTitle {{
    font-size: 14px;
    font-weight: bold;
    color: {t['text']};
    padding-left: 10px;
    border-left: 3px solid {t['accent_line']};
    border-top-left-radius: 2px;
    border-bottom-left-radius: 2px;
}}
QLabel#costSummary {{
    font-size: 12px;
    color: {t['sub']};
}}
QPushButton#refreshBtn {{
    background: qlineargradient(x1:0, y1:0, x2:1, y2:0,
        stop:0 {t['btn']}, stop:1 {t['btn_end']});
    color: {t['btn_text']};
    border: none;
    border-radius: 9px;
    padding: 7px 20px;
    font-size: 12px;
    font-weight: bold;
}}
QPushButton#refreshBtn:hover {{ background: qlineargradient(x1:0, y1:0, x2:1, y2:0,
    stop:0 {t['btn_hover']}, stop:1 {t['btn_end']}); }}
QPushButton#refreshBtn:pressed {{ background: {t['btn']}; }}
QPushButton#ghostBtn {{
    background: transparent;
    border: 1px solid {t['ghost_border']};
    border-radius: 9px;
    padding: 6px 18px;
    color: {t['ghost_text']};
    font-size: 12px;
    font-weight: 600;
}}
QPushButton#ghostBtn:hover {{ background: {t['card_alt']}; border-color: {t['accent_line']}; }}
QPushButton#ghostBtn:pressed {{ background: {t['bar_bg']}; }}
QPushButton#monthBtn {{
    background: {t['card']};
    border: 1px solid {t['border']};
    border-radius: 8px;
    padding: 4px 12px;
    color: {t['text']};
    font-size: 12px;
}}
QPushButton#monthBtn:hover {{ background: {t['card_alt']}; border-color: {t['accent_line']}; color: {t['accent_line']}; }}
QPushButton#monthBtn:pressed {{ background: {t['bar_bg']}; }}
QLabel#monthLabel {{
    color: {t['text']};
    font-size: 13px;
    font-weight: bold;
}}
QLabel#note {{
    color: {t['faint']};
}}
"""


def _apply_card_shadow(widget: QFrame, dark: bool) -> None:
    """卡片阴影：亮色柔和投影，暗色轻描边。"""
    from PySide6.QtWidgets import QGraphicsDropShadowEffect

    eff = QGraphicsDropShadowEffect(widget)
    if dark:
        eff.setBlurRadius(20)
        eff.setOffset(0, 4)
        eff.setColor(QColor(0, 0, 0, 80))
    else:
        eff.setBlurRadius(26)
        eff.setOffset(0, 6)
        eff.setColor(QColor(42, 58, 110, 24))
    widget.setGraphicsEffect(eff)


def _ring_icon(size: int = 44) -> QPixmap:
    """蓝→紫渐变圆角方块 + 白色百分号（窗口头部与应用图标同风格）。"""
    pm = QPixmap(size, size)
    pm.fill(Qt.GlobalColor.transparent)
    p = QPainter(pm)
    p.setRenderHint(QPainter.RenderHint.Antialiasing)
    grad = QLinearGradient(0, 0, size, size)
    grad.setColorAt(0, QColor("#4a6cf7"))
    grad.setColorAt(1, QColor("#8b5cf6"))
    p.setBrush(QBrush(grad))
    p.setPen(Qt.PenStyle.NoPen)
    p.drawRoundedRect(1, 1, size - 2, size - 2, size * 0.28, size * 0.28)
    p.setPen(QColor("white"))
    f = p.font()
    f.setBold(True)
    f.setPixelSize(int(size * 0.46))
    p.setFont(f)
    p.drawText(pm.rect(), Qt.AlignmentFlag.AlignCenter, "%")
    p.end()
    return pm


class _RingProgress(QWidget):
    """圆形进度环：轨道 + 按用量着色的弧 + 居中百分比。"""

    def __init__(self, parent: Optional[QWidget] = None):
        super().__init__(parent)
        self._pct = 0.0
        self._color = "#2ecc71"
        self._track = "#e9edf7"
        self.setMinimumSize(104, 104)

    def set_value(self, pct: float, color: str, track: str) -> None:
        self._pct = max(0.0, min(100.0, pct))
        self._color = color
        self._track = track
        self.update()

    def paintEvent(self, event) -> None:
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        side = min(self.width(), self.height())
        pen_w = max(8.0, side * 0.082)
        rect = self.rect()
        rect = rect.adjusted(
            int((self.width() - side) / 2 + pen_w / 2),
            int((self.height() - side) / 2 + pen_w / 2),
            -int((self.width() - side) / 2 + pen_w / 2),
            -int((self.height() - side) / 2 + pen_w / 2),
        )
        track_pen = QPen(QColor(self._track))
        track_pen.setWidthF(pen_w)
        p.setPen(track_pen)
        p.drawEllipse(rect)

        arc_pen = QPen(QColor(self._color))
        arc_pen.setWidthF(pen_w)
        arc_pen.setCapStyle(Qt.PenCapStyle.RoundCap)
        p.setPen(arc_pen)
        span = int(-360 * 16 * self._pct / 100.0)
        p.drawArc(rect, 90 * 16, span)

        p.setPen(QColor(self._color))
        f = p.font()
        f.setBold(True)
        f.setPixelSize(27)
        p.setFont(f)
        p.drawText(
            QRectF(self.rect()), Qt.AlignmentFlag.AlignCenter, f"{self._pct:.0f}%"
        )
        p.end()


class _LimitCard(QFrame):
    """一张限额卡片：名称 + 环形进度 + 重置倒计时。"""

    def __init__(self, label: str, parent: Optional[QWidget] = None):
        super().__init__(parent)
        self.setObjectName("card")
        self.setMinimumWidth(168)

        layout = QVBoxLayout(self)
        layout.setContentsMargins(14, 12, 14, 14)
        layout.setSpacing(6)

        title = QLabel(label)
        title.setObjectName("cardTitle")
        title.setAlignment(Qt.AlignmentFlag.AlignCenter)
        layout.addWidget(title)

        self._ring = _RingProgress()
        layout.addWidget(self._ring, 1)

        self._reset = QLabel("")
        self._reset.setObjectName("cardReset")
        self._reset.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self._reset.setWordWrap(True)
        layout.addWidget(self._reset)

        self._last_pct = 0.0
        self._last_reset = "—"
        self._bar_bg = "#e9edf7"

    def set_value(self, percent: float, reset_text: str) -> None:
        self._last_pct = max(0.0, min(100.0, percent))
        self._last_reset = reset_text
        self._apply()

    def set_bar_bg(self, color: str) -> None:
        self._bar_bg = color
        self._apply()

    def _apply(self) -> None:
        pct = self._last_pct
        color = _accent(pct)
        self._ring.set_value(pct, color, self._bar_bg)
        if self._last_reset != "—":
            self._reset.setText(f"剩余 {100 - pct:.0f}% · {self._last_reset}后重置")
        else:
            self._reset.setText("—")


class _StatCard(QFrame):
    """数据卡片：小标签 + 大数字 + 副注；悬浮显示完整数值（不自动消失）。"""

    def __init__(self, label: str, parent: Optional[QWidget] = None):
        super().__init__(parent)
        self.setObjectName("card")
        layout = QVBoxLayout(self)
        layout.setContentsMargins(16, 12, 16, 12)
        layout.setSpacing(4)

        cap = QLabel(label)
        cap.setObjectName("cardTitle")
        layout.addWidget(cap)

        self._num = QLabel("—")
        self._num.setObjectName("statNum")
        layout.addWidget(self._num)

        self._sub = QLabel("")
        self._sub.setObjectName("cardReset")
        layout.addWidget(self._sub)

        self._tip_text = ""
        # 顶层悬浮提示：无边框、不拦截鼠标（避免抢 hover 导致闪烁）
        self._tip = QLabel("", None)
        self._tip.setWindowFlags(
            Qt.WindowType.ToolTip | Qt.WindowType.FramelessWindowHint
        )
        self._tip.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents)
        self._tip.setStyleSheet(
            "background:#2b303c; color:#ffffff; border: 1px solid #4a6cf7;"
            " border-radius:6px; padding:4px 10px; font-size:12px;"
        )
        self._tip.hide()
        self.setMouseTracking(True)

    def set_value(self, num: str, sub: str = "", tip_text: str = "") -> None:
        self._num.setText(num)
        self._sub.setText(sub)
        self._tip_text = tip_text
        if not tip_text:
            self._tip.hide()

    def _show_tip(self, gpos) -> None:
        self._tip.setText(self._tip_text)
        self._tip.adjustSize()
        x = gpos.x() + 14
        y = gpos.y() + 16
        screen = QApplication.screenAt(gpos)
        if screen is not None:
            geo = screen.availableGeometry()
            x = min(x, geo.right() - self._tip.width() - 4)
            y = min(y, geo.bottom() - self._tip.height() - 4)
        self._tip.move(x, y)
        self._tip.show()

    def enterEvent(self, event) -> None:
        if self._tip_text:
            self._show_tip(event.globalPosition().toPoint())
        super().enterEvent(event)

    def mouseMoveEvent(self, event) -> None:
        if self._tip_text and self._tip.isVisible():
            self._show_tip(event.globalPosition().toPoint())
        super().mouseMoveEvent(event)

    def leaveEvent(self, event) -> None:
        self._tip.hide()
        super().leaveEvent(event)


class _Callout(QGraphicsTextItem):
    """柱子悬浮提示框：圆角卡片样式，跟随鼠标移动，不会自动消失。"""

    def __init__(self, chart):
        super().__init__(chart)
        self.setZValue(100)
        self.setTextInteractionFlags(Qt.TextInteractionFlag.NoTextInteraction)
        # 关键：不接收鼠标/悬停事件，否则 tooltip 会抢占柱子的 hover
        # 状态，导致 hover 来回切换 → 闪烁
        self.setAcceptedMouseButtons(Qt.MouseButton.NoButton)
        self.setAcceptHoverEvents(False)
        self.setFont(QFont("Microsoft YaHei UI", 9))
        self._bg = "#161b28"
        self._border = "#6a8cff"
        self._line0 = ""
        self._line1 = ""
        self.hide()

    def set_theme(self, t: dict) -> None:
        self._bg = t["card"]
        self._border = t["accent_line"]
        self.setDefaultTextColor(QColor(t["text"]))
        self.update()

    def boundingRect(self) -> QRectF:
        """覆盖背景 padding，确保 view 的脏区包含整个提示框（否则移动/隐藏留残影）。"""
        r = super().boundingRect()
        return r.adjusted(-8, -6, 8, 6)

    def set_content(self, line0: str, line1: str) -> None:
        self.prepareGeometryChange()
        self._line0, self._line1 = line0, line1
        self.setPlainText(f"{line0}\n{line1}")
        self.adjustSize()

    def paint(self, painter, option, widget) -> None:
        painter.save()
        path = QPainterPath()
        path.addRoundedRect(self.boundingRect(), 6, 6)
        painter.fillPath(path, QBrush(QColor(self._bg)))
        painter.setPen(QPen(QColor(self._border), 1))
        painter.drawPath(path)
        painter.restore()
        super().paint(painter, option, widget)


class _ChartView(QChartView):
    """图表视图：自定义绘制横轴日期标签（按柱子位置精确对齐，随宽度降采样）。

    QBarCategoryAxis 不允许重复类别、不支持标签跳过（重复类别会被 Qt 丢弃
    导致柱子错位），因此禁用默认标签，改在 drawForeground 里按 plotArea
    均分位置自绘，并只画间隔的日期。
    """

    def __init__(self, chart, parent=None):
        super().__init__(chart, parent)
        self._days: list[int] = []
        self._label_color = "#8e97ad"
        self._callout: Optional[_Callout] = None
        # 全视口重绘，杜绝自定义 item 绘制残留
        self.setViewportUpdateMode(QGraphicsView.ViewportUpdateMode.FullViewportUpdate)

    def set_days(self, days: list[int]) -> None:
        self._days = days
        self.update()

    def set_label_color(self, color: str) -> None:
        self._label_color = color
        self.update()

    def mouseMoveEvent(self, event) -> None:
        super().mouseMoveEvent(event)
        c = self._callout
        if c is None or not c.isVisible():
            return
        # 跟随鼠标（右上偏移），并防止越出视图
        x = event.pos().x() + 14
        y = event.pos().y() - 18
        w = c.boundingRect().width() + 20
        h = c.boundingRect().height() + 12
        x = min(x, self.width() - w - 2)
        y = max(y, 4)
        c.setPos(x, y)

    def drawForeground(self, painter, rect) -> None:
        super().drawForeground(painter, rect)
        days = self._days
        if not days:
            return
        plot = self.chart().plotArea()
        n = len(days)
        w = plot.width()
        if n <= 0 or w <= 0:
            return
        step = max(
            1, (n * LABEL_MIN_SPACING_PX + int(w) - 1) // int(w)
        )
        painter.save()
        font = QFont("Microsoft YaHei UI")
        font.setPointSize(8)
        painter.setFont(font)
        painter.setPen(QColor(self._label_color))
        for i, d in enumerate(days):
            if i % step != 0:
                continue
            x = plot.left() + (i + 0.5) * w / n
            r = QRectF(x - 60, plot.bottom() + 8, 120, 18)
            painter.drawText(
                r, Qt.AlignmentFlag.AlignHCenter | Qt.AlignmentFlag.AlignTop, f"{d}日"
            )
        painter.restore()


def _fmt_tokens(n: float) -> str:
    """大数中文格式：2.35亿 / 5678万 / 890。"""
    if n >= 1e8:
        return f"{n / 1e8:.2f}亿"
    if n >= 1e4:
        return f"{n / 1e4:.2f}万"
    return f"{n:.0f}"


def _clear_layout(layout) -> None:
    """递归清空布局（含子布局），供列表重建时释放旧行。"""
    while layout.count():
        item = layout.takeAt(0)
        w = item.widget()
        if w is not None:
            w.deleteLater()
        elif item.layout() is not None:
            _clear_layout(item.layout())


class DashboardWindow(QWidget):
    """点击托盘后显示的统计窗口。"""

    refresh_requested = Signal()
    all_stats_requested = Signal()
    settings_requested = Signal()
    month_changed = Signal(int, int)  # year, month（1-based）

    def __init__(self, parent: Optional[QWidget] = None):
        super().__init__(parent)
        self.setWindowTitle("OpenCode 用量")
        self.resize(780, 950)

        self._dark = False
        self._theme = LIGHT

        root = QVBoxLayout(self)
        root.setContentsMargins(20, 16, 20, 16)
        root.setSpacing(12)

        # ── 头部：图标 + 标题 + 状态 + 刷新/全量按钮 ──
        header = QHBoxLayout()
        header.setSpacing(12)

        icon_label = QLabel()
        icon_pm = QPixmap(str(ASSETS_DIR / "opencode.png"))
        if icon_pm.isNull():
            icon_pm = _ring_icon(44)
        else:
            icon_pm = icon_pm.scaled(
                44, 44,
                Qt.AspectRatioMode.KeepAspectRatio,
                Qt.TransformationMode.SmoothTransformation,
            )
        icon_label.setPixmap(icon_pm)
        icon_label.setFixedSize(44, 44)
        header.addWidget(icon_label)

        title_col = QVBoxLayout()
        title_col.setSpacing(2)
        title = QLabel("OpenCode 用量")
        title.setObjectName("winTitle")
        title_col.addWidget(title)
        self._sub_status = QLabel("")
        self._sub_status.setObjectName("winSubtitle")
        title_col.addWidget(self._sub_status)
        header.addLayout(title_col)

        header.addStretch(1)

        self._status = QLabel("")
        self._status.setObjectName("status")
        header.addWidget(self._status)

        self._all_btn = QPushButton("全量统计")
        self._all_btn.setObjectName("ghostBtn")
        self._all_btn.setCursor(Qt.CursorShape.PointingHandCursor)
        self._all_btn.clicked.connect(self.all_stats_requested.emit)
        header.addWidget(self._all_btn)

        self._settings_btn = QPushButton("⚙ 设置")
        self._settings_btn.setObjectName("ghostBtn")
        self._settings_btn.setCursor(Qt.CursorShape.PointingHandCursor)
        self._settings_btn.clicked.connect(self.settings_requested.emit)
        header.addWidget(self._settings_btn)

        self._refresh_btn = QPushButton("刷新")
        self._refresh_btn.setObjectName("refreshBtn")
        self._refresh_btn.setCursor(Qt.CursorShape.PointingHandCursor)
        self._refresh_btn.clicked.connect(self.refresh_requested.emit)
        header.addWidget(self._refresh_btn)
        root.addLayout(header)

        # ── 三层限额卡片（环形进度） ──
        cards = QHBoxLayout()
        cards.setSpacing(14)
        self._cards: dict[str, _LimitCard] = {}
        for key, label in [("rolling", "滚动用量"), ("weekly", "每周用量"), ("monthly", "每月用量")]:
            card = _LimitCard(label)
            _apply_card_shadow(card, False)
            cards.addWidget(card, 1)
            self._cards[key] = card
        root.addLayout(cards)

        # ── 成本柱状图（按天×模型堆叠，与网页「成本」区块一致） ──
        chart_header = QHBoxLayout()
        chart_title = QLabel("成本趋势")
        chart_title.setObjectName("sectionTitle")
        chart_header.addWidget(chart_title)
        chart_header.addStretch(1)

        self._month_prev_btn = QPushButton("◀")
        self._month_prev_btn.setObjectName("monthBtn")
        self._month_prev_btn.setCursor(Qt.CursorShape.PointingHandCursor)
        self._month_prev_btn.clicked.connect(lambda: self._shift_month(-1))
        chart_header.addWidget(self._month_prev_btn)

        self._month_label = QLabel("")
        self._month_label.setObjectName("monthLabel")
        self._month_label.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self._month_label.setMinimumWidth(90)
        chart_header.addWidget(self._month_label)

        self._month_next_btn = QPushButton("▶")
        self._month_next_btn.setObjectName("monthBtn")
        self._month_next_btn.setCursor(Qt.CursorShape.PointingHandCursor)
        self._month_next_btn.clicked.connect(lambda: self._shift_month(1))
        chart_header.addWidget(self._month_next_btn)
        root.addLayout(chart_header)

        # 当前查看月份（1-based）
        import datetime as _dt

        _now = _dt.datetime.now()
        self._view_year = _now.year
        self._view_month = _now.month
        self._update_month_label()

        self._chart = QChart()
        self._chart.setBackgroundVisible(False)
        self._chart.legend().setVisible(True)
        self._chart.legend().setAlignment(Qt.AlignmentFlag.AlignBottom)
        self._chart.setMargins(QMargins(6, 8, 6, 30))  # 底部留白给自绘日期标签
        self._chart_view = _ChartView(self._chart)
        self._chart_view.setRenderHint(QPainter.RenderHint.Antialiasing)
        self._chart_view.setMinimumHeight(230)
        self._chart_view.setStyleSheet("background: transparent; border: none;")
        self._callout = _Callout(self._chart)
        self._chart_view._callout = self._callout
        self._hide_timer = QTimer(self)
        self._hide_timer.setSingleShot(True)
        self._hide_timer.setInterval(150)
        self._hide_timer.timeout.connect(self._callout.hide)
        self._x_axis = None
        self._sorted_days: list[int] = []
        root.addWidget(self._chart_view)

        # ── 饼图 + 模型明细列表（横向排布，充分利用宽度） ──
        pie_header = QHBoxLayout()
        pie_title = QLabel("模型成本占比")
        pie_title.setObjectName("sectionTitle")
        pie_header.addWidget(pie_title)
        pie_header.addStretch(1)
        root.addLayout(pie_header)

        pie_card = QFrame()
        pie_card.setObjectName("card")
        pie_row = QHBoxLayout(pie_card)
        pie_row.setContentsMargins(14, 10, 14, 10)
        pie_row.setSpacing(16)

        self._pie_chart = QChart()
        self._pie_chart.setBackgroundVisible(False)
        self._pie_chart.legend().setVisible(False)  # 名称/颜色在右侧列表，图例占用横向空间
        self._pie_chart.setMargins(QMargins(14, 14, 14, 14))  # 引线/标签留白，避免被裁切
        self._pie_view = QChartView(self._pie_chart)
        self._pie_view.setRenderHint(QPainter.RenderHint.Antialiasing)
        self._pie_view.setFixedSize(224, 204)
        self._pie_view.setStyleSheet("background: transparent; border: none;")
        pie_row.addWidget(self._pie_view)

        # 右侧：模型明细列表（色点 + 名称 + 占比 + 金额）
        self._cost_list = QVBoxLayout()
        self._cost_list.setSpacing(4)
        pie_row.addLayout(self._cost_list, 1)
        root.addWidget(pie_card)
        self._last_model_costs: list = []

        # ── 用量统计（总请求 / 总 Token / 覆盖天数） ──
        stats_header = QHBoxLayout()
        stats_title = QLabel("用量统计")
        stats_title.setObjectName("sectionTitle")
        stats_header.addWidget(stats_title)
        stats_header.addStretch(1)
        root.addLayout(stats_header)

        stats_row = QHBoxLayout()
        stats_row.setSpacing(14)
        self._stat_req = _StatCard("总请求")
        self._stat_tok = _StatCard("总 Token")
        self._stat_days = _StatCard("覆盖天数")
        for card in (self._stat_req, self._stat_tok, self._stat_days):
            _apply_card_shadow(card, False)
            stats_row.addWidget(card, 1)
        root.addLayout(stats_row)

        # ── 主题（默认跟随系统，可由设置切换） ──
        self._theme_mode = "system"
        self._scheme_connected = False
        self.set_theme_mode("system")

    # ── 主题 ──

    def set_theme_mode(self, mode: str) -> None:
        """主题模式：system 跟随系统，dark/light 固定。"""
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

    def apply_theme(self, dark: bool) -> None:
        self._dark = dark
        self._theme = DARK if dark else LIGHT
        t = self._theme
        self.setStyleSheet(_build_qss(t))
        self._sub_status.setStyleSheet(f"color: {t['sub']}; font-size: 12px;")
        title = self.findChild(QLabel, "winTitle")
        if title is not None:
            title.setStyleSheet(f"font-size: 21px; font-weight: bold; color: {t['text']};")
        self._status.setStyleSheet(
            f"color: {t['sub']}; font-size: 12px; background: {t['card']};"
            f" border: 1px solid {t['border']}; border-radius: 14px; padding: 4px 12px;"
        )
        self._chart_view.set_label_color(t["faint"])
        self._callout.set_theme(t)
        for card in self._cards.values():
            card.set_bar_bg(t["bar_bg"])
        if self._last_model_costs:
            self._rebuild_cost_list(self._last_model_costs)
        self._apply_chart_theme()
        self._apply_pie_theme()

    def _on_scheme_changed(self, scheme) -> None:
        self.apply_theme(scheme == Qt.ColorScheme.Dark)

    @property
    def is_dark(self) -> bool:
        return self._dark

    # ── 数据更新 ──

    def show_go(self, go: Optional[GoData]) -> None:
        if go is None:
            return
        self._sub_status.setText("已订阅 OpenCode Go" if go.subscribed else "未订阅 OpenCode Go")

        for key, w in (
            ("rolling", go.rolling),
            ("weekly", go.weekly),
            ("monthly", go.monthly),
        ):
            card = self._cards[key]
            if w is None:
                card.set_value(0, "—")
            else:
                card.set_value(w.usage_percent, w.reset_text())

    def show_usage(self, usage: Optional[UsageData]) -> None:
        """保留接口（用量明细不再展示，仅存最近数据供统计参考）。"""
        if usage is None:
            return
        self._last_usage = usage

    def _shift_month(self, delta: int) -> None:
        """切换上一月/下一月。"""
        m = self._view_month + delta
        y = self._view_year
        if m < 1:
            m, y = 12, y - 1
        elif m > 12:
            m, y = 1, y + 1
        self._view_year, self._view_month = y, m
        self._update_month_label()
        self.month_changed.emit(y, m)

    def _update_month_label(self) -> None:
        self._month_label.setText(f"{self._view_year}年{self._view_month}月")

    def show_history(self, history: list) -> None:
        """更新成本柱状图 + 汇总文本（按查看月份）。"""
        self._build_cost_chart(history)
        if not history:
            return
        total = sum(h.total_cost for h in history)
        lines = [
            f"【使用历史 · 本月 {len(history)} 条 · 合计 {total:,} credits"
            f"（≈ ${total * COST_TO_USD:.2f}）】",
            f"{'日期':<12}{'模型':<24}{'成本':>14}",
        ]
        for h in history:
            lines.append(f"{h.date:<12}{h.model:<24}{h.total_cost:>14,}")
        self._history_lines = lines

    def show_cost_share(self, model_costs: list) -> None:
        """成本占比（全部数据）：饼图（左）+ 模型明细列表（右）。

        model_costs: [(model, cost原始单位)] 降序。
        """
        self._last_model_costs = list(model_costs)
        # 清空旧系列（移除 series 后图例项自动消失）
        for s in list(self._pie_chart.series()):
            self._pie_chart.removeSeries(s)

        self._rebuild_cost_list(model_costs)
        if not model_costs:
            return

        total = sum(c for _, c in model_costs)
        pie = QPieSeries()
        for i, (model, cost) in enumerate(model_costs):
            color = MODEL_COLORS.get(model, FALLBACK_COLORS[i % len(FALLBACK_COLORS)])
            pct = cost / total * 100 if total else 0
            sl = pie.append(model, cost)
            sl.setColor(QColor(color))
            # QtCharts 外部引线标签超宽会被强制省略号截断（已知缺陷），
            # 因此改用扇区内部标签：>12% 显示、小扇区不显示（信息在右侧列表）
            if pct >= 12:
                sl.setLabelVisible(True)
                sl.setLabel(f"{pct:.0f}%")
                sl.setLabelPosition(QPieSlice.LabelPosition.LabelInsideHorizontal)
                sl.setLabelBrush(QColor(_readable_label_color(color)))
                f = self._axis_font()
                f.setBold(True)
                f.setPointSize(9)
                sl.setLabelFont(f)
            else:
                sl.setLabelVisible(False)
        self._pie_chart.addSeries(pie)
        self._apply_pie_theme()

    def _rebuild_cost_list(self, model_costs: list) -> None:
        """右侧明细列表：色点 + 模型名 + 占比 + 金额 + 总计行。"""
        t = self._theme
        # 清空旧行
        while self._cost_list.count():
            item = self._cost_list.takeAt(0)
            w = item.widget()
            if w is not None:
                w.deleteLater()
            elif item.layout() is not None:
                _clear_layout(item.layout())

        if not model_costs:
            empty = QLabel("（无数据，等待同步）")
            empty.setStyleSheet(f"color: {t['faint']}; font-size: 12px;")
            self._cost_list.addWidget(empty)
            return

        total = sum(c for _, c in model_costs)
        for i, (model, cost) in enumerate(model_costs):
            color = MODEL_COLORS.get(model, FALLBACK_COLORS[i % len(FALLBACK_COLORS)])
            pct = cost / total * 100 if total else 0
            row = QHBoxLayout()
            row.setSpacing(8)
            dot = QLabel()
            dot.setFixedSize(12, 12)
            dot.setStyleSheet(f"background: {color}; border-radius: 6px;")
            row.addWidget(dot)
            name = QLabel(model)
            name.setStyleSheet(f"color: {t['text']}; font-size: 12px; font-weight: 600;")
            row.addWidget(name)
            row.addStretch(1)
            pct_label = QLabel(f"{pct:.1f}%")
            pct_label.setStyleSheet(f"color: {t['sub']}; font-size: 12px;")
            row.addWidget(pct_label)
            amt = QLabel(f"${cost * COST_TO_USD:.2f}")
            amt.setAlignment(Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignVCenter)
            amt.setMinimumWidth(64)
            amt.setStyleSheet(f"color: {t['text']}; font-size: 12px; font-weight: 600;")
            row.addWidget(amt)
            self._cost_list.addLayout(row)

        # 分隔线 + 总计行
        sep = QFrame()
        sep.setFixedHeight(1)
        sep.setStyleSheet(f"background: {t['border']};")
        self._cost_list.addWidget(sep)

        total_row = QHBoxLayout()
        total_row.setSpacing(8)
        total_cap = QLabel("总计")
        total_cap.setStyleSheet(f"color: {t['sub']}; font-size: 12px;")
        total_row.addWidget(total_cap)
        total_row.addStretch(1)
        total_amt = QLabel(f"${total * COST_TO_USD:.2f}")
        total_amt.setAlignment(Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignVCenter)
        total_amt.setMinimumWidth(64)
        total_amt.setStyleSheet(
            f"color: {t['accent_line']}; font-size: 14px; font-weight: bold;"
        )
        total_row.addWidget(total_amt)
        self._cost_list.addLayout(total_row)
        self._cost_list.addStretch(1)

    def show_stats(self, stats: dict) -> None:
        """显示用量统计（全部数据）：总请求 / 总 Token / 覆盖天数。"""
        if not stats or not stats.get("requests"):
            self._stat_req.set_value("—")
            self._stat_tok.set_value("—")
            self._stat_days.set_value("—")
            return
        req = stats.get("requests", 0)
        tokens = stats.get("tokens", 0)
        days = stats.get("days", 0)
        avg_req = req / days if days else 0
        avg_tok = tokens / days if days else 0
        self._stat_req.set_value(
            f"{req:,}", f"日均 {avg_req:,.1f} 次", f"总请求：{req:,} 次"
        )
        self._stat_tok.set_value(
            _fmt_tokens(tokens),
            f"日均 {_fmt_tokens(avg_tok)}",
            f"总 Token：{tokens:,}",
        )
        self._stat_days.set_value(str(days), "有请求记录的日子", f"覆盖 {days} 天")

    def _apply_pie_theme(self) -> None:
        """饼图标签颜色在创建时已按扇区底色选定（亮/暗主题通用），无需重设。"""

    def _build_cost_chart(self, history: list) -> None:
        """构建按天×模型的堆叠柱状图（美元，与网页一致）。

        标准用法：QBarCategoryAxis 类别 = 实际有数据的日期，柱子与类别一一对应。
        """
        days: dict[int, dict[str, float]] = {}
        for h in history:
            day = int(h.date[8:10]) if len(h.date) >= 10 else 0
            if day <= 0:
                continue
            days.setdefault(day, {})
            days[day][h.model] = days[day].get(h.model, 0) + h.total_cost * COST_TO_USD

        models: list[str] = []
        for d in days.values():
            for m in d:
                if m not in models:
                    models.append(m)

        # 清空旧图表：先删系列再删轴（removeAllSeries 不会移除轴，否则每次刷新累积多对轴）
        self._chart.removeAllSeries()
        for ax in list(self._chart.axes()):
            self._chart.removeAxis(ax)
        if not days or not models:
            self._chart.setTitle("暂无成本数据")
            self._chart.setTitleBrush(QColor(self._theme["sub"]))
            self._apply_chart_theme()
            return
        self._chart.setTitle("")
        self._x_axis = None

        sorted_days = sorted(days.keys())
        self._sorted_days = sorted_days

        series = QStackedBarSeries()
        for i, model in enumerate(models):
            bset = QBarSet(model)
            for day in sorted_days:
                bset.append(days[day].get(model, 0.0))
            color = MODEL_COLORS.get(model, FALLBACK_COLORS[i % len(FALLBACK_COLORS)])
            bset.setColor(QColor(color))
            bset.setPen(QPen(QColor(self._theme["card"]), 1))
            series.append(bset)
        series.setBarWidth(0.55)
        series.hovered.connect(self._on_bar_hovered)
        self._chart.addSeries(series)

        # X 轴：类别 = 实际有数据的日期（标准用法，类别与柱子 index 一一对应）。
        # 标签由 _ChartView.drawForeground 自绘（轴默认标签禁用，避免省略/错位）
        axis_x = QBarCategoryAxis()
        axis_x.append([f"{d}日" for d in sorted_days])
        axis_x.setLabelsVisible(False)
        axis_x.setLabelsFont(self._axis_font())
        self._chart.addAxis(axis_x, Qt.AlignmentFlag.AlignBottom)
        series.attachAxis(axis_x)
        self._x_axis = axis_x
        self._chart_view.set_days(sorted_days)

        max_usd = max(sum(d.values()) for d in days.values())
        axis_y = QValueAxis()
        axis_y.setRange(0, max(1.0, max_usd * 1.15))
        axis_y.setLabelFormat("$%.2f")
        axis_y.setLabelsFont(self._axis_font())
        axis_y.setTickCount(6)
        self._chart.addAxis(axis_y, Qt.AlignmentFlag.AlignLeft)
        series.attachAxis(axis_y)

        self._apply_chart_theme()

    def _on_bar_hovered(self, status: bool, index: int, barset) -> None:
        """柱子悬浮提示：日期 · 模型 · 金额 · 当日占比（Callout 不自动消失）。"""
        if not status or index < 0 or index >= len(self._sorted_days):
            # 延迟隐藏：避免柱段边界微动导致的闪烁
            self._hide_timer.start()
            return
        self._hide_timer.stop()
        day = self._sorted_days[index]
        model = barset.label()
        value = barset.at(index)
        line0 = f"{day}日 · {model}"
        line1 = f"${value:.2f}"
        total = 0.0
        for s in self._chart.series():
            for bs in s.barSets():
                total += bs.at(index)
        if total > 0:
            line1 += f"（占当日 {value / total * 100:.0f}%）"
        self._callout.set_content(line0, line1)
        pos = self._chart_view.mapFromGlobal(QCursor.pos())
        self._callout.setPos(pos.x() + 14, pos.y() - 18)
        self._callout.show()

    def _apply_chart_theme(self) -> None:
        """图表颜色跟随亮/暗主题。"""
        t = self._theme
        for axis in self._chart.axes():
            axis.setLineVisible(False)  # 现代风格：无轴线
            axis.setLabelsColor(QColor(t["faint"]))
            if isinstance(axis, QValueAxis):
                axis.setGridLineVisible(True)
                axis.setGridLineColor(QColor(t["border"]))  # 网格线淡化
            elif isinstance(axis, QBarCategoryAxis):
                axis.setGridLineVisible(False)
        self._chart.legend().setLabelColor(QColor(t["sub"]))
        self._chart.legend().setFont(self._axis_font())
        self._chart_view.setStyleSheet(
            f"background: {t['card']}; border: 1px solid {t['border']};"
            " border-radius: 12px;"
        )

    def _axis_font(self):
        from PySide6.QtGui import QFont

        # 显式指定中文字体，避免 QtCharts 默认字体无中文回退导致标签不渲染
        f = QFont("Microsoft YaHei UI")
        f.setPointSize(8)
        return f

    def set_status(self, text: str) -> None:
        self._status.setText(text)
