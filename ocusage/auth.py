"""登录与凭证管理。

- LoginWindow：内嵌 QtWebEngine 打开 opencode.ai 登录页，用户登录后自动捕获 auth cookie
- CookieStore：DPAPI 加密存储 cookie 到 %APPDATA%/oc-usage/cookie.bin
"""
from __future__ import annotations

import ctypes
import ctypes.wintypes as wintypes
import os
import re
import time
from pathlib import Path
from typing import Optional

from PySide6.QtCore import QTimer, QUrl, Signal
from PySide6.QtWebEngineCore import QWebEngineCookieStore, QWebEngineProfile
from PySide6.QtWebEngineWidgets import QWebEngineView
from PySide6.QtWidgets import QLabel, QPushButton, QVBoxLayout, QWidget

LOGIN_URL = "https://opencode.ai/auth/authorize"  # 主站 OpenAuth 登录（GitHub/Google），登录后自动跳转 /workspace/{id}
AUTH_COOKIE_NAME = "auth"
COOKIE_DIR = Path(os.environ.get("APPDATA", str(Path.home()))) / "oc-usage"
COOKIE_FILE = COOKIE_DIR / "cookie.bin"


# ── DPAPI 加解密（ctypes，无额外依赖） ──


class _DATA_BLOB(ctypes.Structure):
    _fields_ = [("cbData", wintypes.DWORD), ("pbData", ctypes.POINTER(ctypes.c_ubyte))]


def _dpapi_protect(data: bytes) -> bytes:
    blob_in = _DATA_BLOB(len(data), ctypes.cast(ctypes.create_string_buffer(data), ctypes.POINTER(ctypes.c_ubyte)))
    blob_out = _DATA_BLOB()
    if not ctypes.windll.crypt32.CryptProtectData(
        ctypes.byref(blob_in), None, None, None, None, 0, ctypes.byref(blob_out)
    ):
        raise OSError("CryptProtectData 失败")
    try:
        return ctypes.string_at(blob_out.pbData, blob_out.cbData)
    finally:
        ctypes.windll.kernel32.LocalFree(blob_out.pbData)


def _dpapi_unprotect(data: bytes) -> bytes:
    buf = ctypes.create_string_buffer(data)
    blob_in = _DATA_BLOB(len(data), ctypes.cast(buf, ctypes.POINTER(ctypes.c_ubyte)))
    blob_out = _DATA_BLOB()
    if not ctypes.windll.crypt32.CryptUnprotectData(
        ctypes.byref(blob_in), None, None, None, None, 0, ctypes.byref(blob_out)
    ):
        raise OSError("CryptUnprotectData 失败（可能是其他用户/机器加密的数据）")
    try:
        return ctypes.string_at(blob_out.pbData, blob_out.cbData)
    finally:
        ctypes.windll.kernel32.LocalFree(blob_out.pbData)


# ── cookie 存储 ──


class CookieStore:
    """auth cookie + workspace id 的 DPAPI 加密存取（单个 JSON 负载）。"""

    @staticmethod
    def save(cookie_value: str, workspace_id: Optional[str] = None) -> None:
        COOKIE_DIR.mkdir(parents=True, exist_ok=True)
        import json

        payload = json.dumps({"cookie": cookie_value, "workspaceId": workspace_id}).encode("utf-8")
        COOKIE_FILE.write_bytes(_dpapi_protect(payload))

    @staticmethod
    def load() -> Optional[tuple[str, Optional[str]]]:
        """返回 (cookie, workspace_id)；无凭证时返回 None。"""
        if not COOKIE_FILE.exists():
            return None
        try:
            import json

            data = json.loads(_dpapi_unprotect(COOKIE_FILE.read_bytes()).decode("utf-8"))
            return data.get("cookie"), data.get("workspaceId")
        except (OSError, ValueError, json.JSONDecodeError):
            return None

    @staticmethod
    def clear() -> None:
        try:
            COOKIE_FILE.unlink()
        except FileNotFoundError:
            pass


# ── 登录窗口 ──


class LoginWindow(QWidget):
    """内嵌浏览器登录窗口：登录完成后自动捕获 auth cookie 与 workspace id。"""

    login_succeeded = Signal(str, str)  # cookie, workspace_id（可能为空）
    login_failed = Signal(str)
    cancelled = Signal()

    WORKSPACE_URL_RE = re.compile(r"/workspace/(wrk_[A-Za-z0-9]+)")

    def __init__(self, parent: Optional[QWidget] = None):
        super().__init__(parent)
        self.setWindowTitle("登录 OpenCode Console")
        self.resize(900, 700)

        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(0)
        hint = QLabel("请登录 OpenCode Console（Google 或邮箱）")
        hint.setStyleSheet("padding: 3px 10px; background: #f0f4ff; color: #333; font-size: 12px;")
        hint.setFixedHeight(24)
        layout.addWidget(hint)

        self._view = QWebEngineView(self)
        layout.addWidget(self._view)

        self._finish_btn = QPushButton("已完成登录")
        self._finish_btn.setVisible(False)
        self._finish_btn.clicked.connect(self._on_manual_finish)
        layout.addWidget(self._finish_btn)

        profile = QWebEngineProfile.defaultProfile()
        store: QWebEngineCookieStore = profile.cookieStore()
        store.cookieAdded.connect(self._on_cookie_added)
        self._view.urlChanged.connect(self._on_url_changed)
        self._view.loadFinished.connect(self._on_load_finished)

        self._captured: Optional[str] = None
        self._workspace_id: Optional[str] = None
        self._timeout_started = False
        self._probe_count = 0
        self._log_urls()
        self._view.load(QUrl(LOGIN_URL))

    def _log_urls(self) -> None:
        """诊断用：记录登录过程中的 URL 跳转链。"""
        import tempfile

        self._url_log = open(
            os.path.join(tempfile.gettempdir(), "ocusage_urls.log"),
            "a", encoding="utf-8",
        )

    def _trace(self, tag: str, url: str) -> None:
        try:
            import datetime

            self._url_log.write(f"[{datetime.datetime.now():%H:%M:%S}] {tag}: {url}\n")
            self._url_log.flush()
        except Exception:
            pass

    def _on_cookie_added(self, cookie) -> None:
        """捕获 opencode.ai 域下名为 auth 的 cookie。"""
        try:
            domain = cookie.domain()
            name = cookie.name().data().decode("utf-8", errors="replace")
        except Exception:
            return
        if "opencode.ai" not in domain or name != AUTH_COOKIE_NAME:
            return
        value = cookie.value().data().decode("utf-8", errors="replace")
        if not value or value == self._captured:
            return
        self._captured = value
        self._trace("cookie", f"auth len={len(value)}")
        if not self._timeout_started:
            self._timeout_started = True
            QTimer.singleShot(30000, self._on_timeout)
        self._maybe_finish()

    def _on_load_finished(self, ok: bool) -> None:
        """页面加载完成后，若在 console 相关页面且尚无 workspace id，注入 JS 探测。"""
        url = self._view.url().toString()
        self._trace("load" + (" ok" if ok else " FAIL"), url)
        if self._workspace_id or not ok:
            return
        if "/workspace/" in url:
            self._on_url_changed(self._view.url())
            return
        if "/console" in url:
            QTimer.singleShot(1500, self._probe_workspace)

    def _probe_workspace(self) -> None:
        """在 console SPA 页面里用 fetch 探测 workspace（同源请求，带会话 cookie）。"""
        if self._workspace_id or self._probe_count >= 6:
            return
        self._probe_count += 1
        js = r"""
(async () => {
  try {
    const r = await fetch('/console/api/orgs', {headers: {accept: 'application/json'}});
    if (!r.ok) return JSON.stringify({error: 'status ' + r.status});
    const data = await r.json();
    return JSON.stringify(data);
  } catch (e) { return JSON.stringify({error: String(e)}); }
})()
"""
        self._view.page().runJavaScript(js, self._on_probe_result)

    def _on_probe_result(self, result) -> None:
        """探测结果里找 wrk_ 开头的 workspace id。"""
        import re as _re

        text = str(result or "")
        m = _re.search(r"wrk_[A-Za-z0-9]+", text)
        if m:
            self._workspace_id = m.group(0)
            self._maybe_finish()
        elif self._captured:
            # 没探测到：过 2 秒再试（SPA 可能还在加载）
            QTimer.singleShot(2000, self._probe_workspace)

    def _on_manual_finish(self) -> None:
        """超时后的手动兜底：再试一次 URL 提取与探测。"""
        self._on_url_changed(self._view.url())
        self._probe_workspace()
        if not self._workspace_id and self._captured:
            self._finish_btn.setText("未找到工作区，请确认页面已打开工作区后重试")

    def _on_timeout(self) -> None:
        """超时兜底：显示手动完成按钮；有 workspace id 则正常完成。"""
        if self._workspace_id:
            self._maybe_finish()
            return
        if self._captured:
            self._finish_btn.setVisible(True)
            self._on_manual_finish()

    def _on_url_changed(self, url: QUrl) -> None:
        """登录后页面会跳转到 /workspace/{id}/...，从中提取 workspace id。"""
        url_str = url.toString()
        self._trace("url", url_str)
        # 登录失败：URL 带 error= 参数时显示明确提示
        if "error=" in url_str and "/console" in url_str:
            import urllib.parse

            m = re.search(r"[?&]error=([^&]+)", url_str)
            if m:
                err = urllib.parse.unquote(m.group(1))
                self._show_error(f"登录失败：{err}")
        m = self.WORKSPACE_URL_RE.search(url_str)
        if m:
            self._workspace_id = m.group(1)
            self._maybe_finish()

    def _show_error(self, message: str) -> None:
        """在窗口顶部提示条显示错误。"""
        try:
            label = self.findChild(QLabel)
            if label is not None:
                label.setText(message)
                label.setStyleSheet("padding: 3px 10px; background: #ffe9e9; color: #b00020; font-size: 12px;")
        except Exception:
            pass

    def _maybe_finish(self) -> None:
        """cookie 与 workspace id 都拿到才完成（避免只存 cookie 拿不到 id）。"""
        if not self._captured or not self._workspace_id:
            return
        CookieStore.save(self._captured, self._workspace_id)
        self.login_succeeded.emit(self._captured, self._workspace_id or "")
        self.close()

    def _on_timeout(self) -> None:
        """超时兜底：页面可能没跳到 /workspace/{id}（登录后落在 /console SPA）。"""
        if not self._captured or self._workspace_id:
            return
        # 再试一次当前 URL
        self._on_url_changed(self._view.url())
        if self._workspace_id:
            return
        CookieStore.save(self._captured, None)
        self.login_succeeded.emit(self._captured, "")
        self.close()

    def closeEvent(self, event) -> None:
        if self._captured is None:
            self.cancelled.emit()
        super().closeEvent(event)
