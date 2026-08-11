# -*- mode: python ; coding: utf-8 -*-
"""PyInstaller 打包配置：oc-usage（含 QtWebEngine，onedir 模式）。"""

a = Analysis(
    ["main.py"],
    pathex=[],
    binaries=[],
    datas=[("ocusage/assets/opencode.png", "ocusage/assets")],
    hiddenimports=[],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[],
    noarchive=False,
)


def _trim(entries):
    """瘦身：删 DevTools 调试资源与软件渲染库，翻译只保留中英文。"""
    kept = []
    for e in entries:
        name = e[0]
        if name.endswith("qtwebengine_devtools_resources.debug.pak"):
            continue  # DevTools 调试资源（72MB），运行时用不到
        if name.endswith("qtwebengine_devtools_resources.pak"):
            kept.append(e)
            continue
        if "translations" in name:
            base = name.rsplit("/", 1)[-1]
            if base.startswith(("qtbase_zh_CN", "qtbase_zh_TW", "qtbase_en",
                                "qtwebengine_zh_CN", "qtwebengine_zh_TW", "qtwebengine_en")):
                kept.append(e)
            continue
        kept.append(e)
    return kept


a.binaries = _trim(a.binaries)
a.datas = _trim(a.datas)

pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name="oc-usage",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=False,
    icon="assets_icon.ico",
)
coll = COLLECT(
    exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=False,
    name="oc-usage",
)
