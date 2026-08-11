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
