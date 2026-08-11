"""用户设置：主题、开机自启。

- settings.json 存 %APPDATA%/oc-usage/settings.json
- 开机自启写 HKCU 注册表 Run 启动项（Windows 标准做法）
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

SETTINGS_DIR = Path(os.environ.get("APPDATA", str(Path.home()))) / "oc-usage"
SETTINGS_FILE = SETTINGS_DIR / "settings.json"

RUN_KEY_PATH = r"Software\Microsoft\Windows\CurrentVersion\Run"
RUN_VALUE_NAME = "oc-usage"

DEFAULT = {"theme": "system", "autostart": False}


class Settings:
    """主题与自启配置（JSON 持久化）。"""

    def __init__(self, path: Path | None = None):
        self.path = Path(path) if path else SETTINGS_FILE
        self.data = dict(DEFAULT)
        try:
            self.data.update(json.loads(self.path.read_text(encoding="utf-8")))
        except (OSError, json.JSONDecodeError):
            pass

    @property
    def theme(self) -> str:
        """"system" / "dark" / "light"。"""
        return self.data.get("theme", "system")

    @theme.setter
    def theme(self, value: str) -> None:
        self.data["theme"] = value

    @property
    def autostart(self) -> bool:
        return bool(self.data.get("autostart"))

    @autostart.setter
    def autostart(self, value: bool) -> None:
        self.data["autostart"] = bool(value)

    def save(self) -> None:
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            self.path.write_text(
                json.dumps(self.data, ensure_ascii=False, indent=2),
                encoding="utf-8",
            )
        except OSError:
            pass


def _autostart_command() -> str:
    """开机启动命令：pythonw.exe + main.py 的绝对路径。"""
    exe = Path(sys.executable)
    main = Path(__file__).resolve().parent.parent / "main.py"
    return f'"{exe}" "{main}"'


def set_autostart(enabled: bool) -> None:
    """写/删 HKCU Run 启动项。"""
    import winreg

    key = winreg.OpenKey(
        winreg.HKEY_CURRENT_USER, RUN_KEY_PATH, 0,
        winreg.KEY_SET_VALUE | winreg.KEY_READ,
    )
    try:
        if enabled:
            winreg.SetValueEx(
                key, RUN_VALUE_NAME, 0, winreg.REG_SZ, _autostart_command()
            )
        else:
            try:
                winreg.DeleteValue(key, RUN_VALUE_NAME)
            except FileNotFoundError:
                pass
    finally:
        winreg.CloseKey(key)


def autostart_enabled() -> bool:
    """查询 HKCU Run 启动项是否存在。"""
    import winreg

    try:
        key = winreg.OpenKey(
            winreg.HKEY_CURRENT_USER, RUN_KEY_PATH, 0, winreg.KEY_READ
        )
    except OSError:
        return False
    try:
        try:
            winreg.QueryValueEx(key, RUN_VALUE_NAME)
            return True
        except FileNotFoundError:
            return False
    finally:
        winreg.CloseKey(key)
