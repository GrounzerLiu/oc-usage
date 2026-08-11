/// 入口：托盘常驻 + 登录 + 后台刷新 + 统计/设置窗口。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'client.dart';
import 'db.dart';
import 'models.dart';
import 'settings.dart';
import 'theme.dart';
import 'package:oc_usage/ui/dashboard_page.dart';
import 'package:oc_usage/ui/login_page.dart';
import 'package:oc_usage/ui/settings_page.dart';
import 'webview_session.dart';

const _refreshInterval = Duration(minutes: 5);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  const size = Size(780, 940);
  windowManager.setMinimumSize(size);
  windowManager.setSize(size);
  await windowManager.setPreventClose(true);
  await windowManager.setTitle('OpenCode 用量');
  runApp(const OcUsageApp());
}

class OcUsageApp extends StatefulWidget {
  const OcUsageApp({super.key});

  @override
  State<OcUsageApp> createState() => _OcUsageAppState();
}

class _OcUsageAppState extends State<OcUsageApp>
    with TrayListener, WindowListener {
  final _settings = Settings();
  final _themeMode = ValueNotifier<String>('system');
  final _data = ValueNotifier<DashboardData>(DashboardData());
  late final WebSession _session;
  final _db = UsageCache();

  OpenCodeClient? _client;
  String? _workspaceId;
  Timer? _timer;
  bool _loggedIn = false;
  bool _busy = false;
  bool _busySync = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _settings.load();
    _themeMode.value = _settings.theme;
    await initSqlite();
    await _db.open();

    // WebView2 持久化用户数据目录（登录态自动保存）
    final dataDir = await webviewDataDir();
    _session = WebSession(userDataFolder: dataDir);
    _session.onUrlChanged = _onWebUrl;

    trayManager.addListener(this);
    windowManager.addListener(this);
    await _setupTray();

    final now = DateTime.now();
    final d = _data.value;
    d.viewYear = now.year;
    d.viewMonth = now.month;

    // 登录页会在 WebView 创建后自动加载；先进入未登录态
    setState(() => _loggedIn = false);
  }

  void _onWebUrl(String url) {
    final wid = _extractWorkspace(url);
    if (wid != null && !_loggedIn) {
      _onLoggedIn(wid);
    }
  }

  String? _extractWorkspace(String url) {
    final m = RegExp(r'/workspace/(wrk_[A-Za-z0-9]+)').firstMatch(url);
    return m?.group(1);
  }

  void _onLoggedIn(String wid) {
    if (wid.isEmpty) return;
    _workspaceId = wid;
    _client = OpenCodeClient(_session);
    setState(() => _loggedIn = true);
    _data.value.status = '登录成功，正在获取数据…';
    _refresh();
    _loadHistory();
    _timer?.cancel();
    _timer = Timer.periodic(_refreshInterval, (_) => _refresh());
  }

  // ── 数据 ──

  Future<void> _refresh() async {
    if (_busy) return;
    final client = _client;
    final wid = _workspaceId;
    if (client == null || wid == null) return;
    _busy = true;
    _data.value.status = '刷新中…';
    try {
      final go = await client.fetchGo(wid);
      final d = _data.value;
      d.go = go;
      d.status = '上次刷新 ${_nowText()}';
      _data.value = d;
      _updateTrayTooltip(go);
    } on ClientError catch (e) {
      _data.value.status = '刷新失败：${e.message}';
      if (e.message.contains('登录已过期')) {
        _timer?.cancel();
        setState(() => _loggedIn = false);
      }
    } catch (_) {
      _data.value.status = '刷新失败';
    } finally {
      _busy = false;
    }
  }

  Future<void> _syncStats() async {
    if (_busySync) return;
    final client = _client;
    final wid = _workspaceId;
    if (client == null || wid == null) return;
    _busySync = true;
    try {
      final d = _data.value;
      if (d.stats == null || d.stats!.requests == 0) {
        final records = await client.fetchPageRecords(wid, 0);
        _db.insertRecords(records);
      } else {
        await _db.syncIncremental(client, wid);
      }
      _applyStats();
    } catch (_) {
      // 网络失败保留快照
    } finally {
      _busySync = false;
    }
  }

  void _applyStats() {
    final d = _data.value;
    d.stats = _db.allStats();
    d.modelCosts = _db.allModelCosts();
    _data.value = d;
  }

  Future<void> _loadHistory() async {
    final client = _client;
    final wid = _workspaceId;
    if (client == null || wid == null) return;
    final d = _data.value;
    final year = d.viewYear;
    final month = d.viewMonth; // 1-based
    final cached = _db.getHistoryCache(wid, year, month);
    if (cached != null) {
      d.history = cached;
      _data.value = d;
      return;
    }
    try {
      final entries = await client.fetchUsageHistory(wid, year, month - 1);
      _db.putHistoryCache(wid, year, month, entries);
      d.history = entries;
      _data.value = d;
    } on ClientError catch (e) {
      d.status = '历史加载失败：${e.message}';
      _data.value = d;
    } catch (_) {}
  }

  void _onMonthChange(int delta) {
    final d = _data.value;
    var m = d.viewMonth + delta;
    var y = d.viewYear;
    if (m < 1) {
      m = 12;
      y -= 1;
    } else if (m > 12) {
      m = 1;
      y += 1;
    }
    d.viewYear = y;
    d.viewMonth = m;
    d.status = '加载 $y 年 $m 月…';
    _data.value = d;
    _loadHistory();
  }

  String _nowText() {
    final n = DateTime.now();
    return '${n.hour.toString().padLeft(2, '0')}:'
        '${n.minute.toString().padLeft(2, '0')}:'
        '${n.second.toString().padLeft(2, '0')}';
  }

  // ── 托盘 ──

  Future<void> _setupTray() async {
    await trayManager.setIcon('assets/opencode.png');
    await trayManager.setToolTip('OpenCode 用量');
    await trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(key: 'open', label: '打开统计'),
          MenuItem(key: 'refresh', label: '立即刷新'),
          MenuItem.separator(),
          MenuItem(key: 'settings', label: '设置…'),
          MenuItem.separator(),
          MenuItem(key: 'relogin', label: '重新登录…'),
          MenuItem(key: 'quit', label: '退出'),
        ],
      ),
    );
  }

  void _updateTrayTooltip(GoData go) {
    trayManager.setToolTip('OpenCode 用量\n${go.summaryLines().join('\n')}');
  }

  @override
  void onTrayIconMouseDown() {
    windowManager.show();
    windowManager.focus();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'open':
        windowManager.show();
        windowManager.focus();
      case 'refresh':
        _refresh();
        _syncStats();
      case 'settings':
        _showSettings();
      case 'relogin':
        _logout();
      case 'quit':
        _quit();
    }
  }

  @override
  void onWindowClose() {
    windowManager.hide();
  }

  void _logout() {
    _timer?.cancel();
    setState(() => _loggedIn = false);
  }

  Future<void> _quit() async {
    _timer?.cancel();
    _db.close();
    await windowManager.destroy();
  }

  void _showSettings() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => SettingsPage(
        settings: _settings,
        themeMode: _themeMode,
        onAutostartChanged: (v) {
          try {
            setAutostart(v);
          } catch (_) {}
        },
      )),
    );
  }

  // ── 构建 ──

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: _themeMode,
      builder: (context, mode, _) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'OpenCode 用量',
          themeMode: mode == 'dark'
              ? ThemeMode.dark
              : mode == 'light'
                  ? ThemeMode.light
                  : ThemeMode.system,
          theme: _buildTheme(Brightness.light),
          darkTheme: _buildTheme(Brightness.dark),
          home: ValueListenableBuilder<DashboardData>(
            valueListenable: _data,
            builder: (context, d, _) {
              if (!_loggedIn) {
                return LoginPage(
                  session: _session,
                  onCancelled: () => windowManager.hide(),
                );
              }
              return DashboardPage(
                data: _data,
                onRefresh: () {
                  _refresh();
                  _loadHistory();
                },
                onFullStats: () {
                  _applyStats();
                  _syncStats();
                },
                onSettings: _showSettings,
                onMonthChange: _onMonthChange,
              );
            },
          ),
        );
      },
    );
  }

  ThemeData _buildTheme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: AppColors.lightAccent,
      brightness: brightness,
      primary: dark ? AppColors.darkAccent : AppColors.lightAccent,
      secondary: AppColors.lightAccentEnd,
      surface: dark ? AppColors.darkSurface : AppColors.lightSurface,
      surfaceContainerLowest: dark ? AppColors.darkBg : AppColors.lightBg,
      surfaceContainerHighest:
          dark ? AppColors.darkCardAlt : AppColors.lightCardAlt,
      outline: dark ? AppColors.darkBorder : AppColors.lightBorder,
      outlineVariant: dark ? AppColors.darkBorder : AppColors.lightBorder,
      onSurface: dark ? AppColors.darkText : AppColors.lightText,
      onSurfaceVariant: dark ? AppColors.darkSub : AppColors.lightSub,
    );
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      fontFamily: 'Microsoft YaHei UI',
      scaffoldBackgroundColor: dark ? AppColors.darkBg : AppColors.lightBg,
      appBarTheme: AppBarTheme(
        backgroundColor: dark ? AppColors.darkBg : AppColors.lightBg,
        foregroundColor: dark ? AppColors.darkText : AppColors.lightText,
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: scheme.surface,
          border: Border.all(color: scheme.primary),
          borderRadius: BorderRadius.circular(6),
        ),
        textStyle: TextStyle(fontSize: 12, color: scheme.onSurface),
      ),
    );
  }
}
