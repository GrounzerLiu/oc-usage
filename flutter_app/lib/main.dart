/// 入口：托盘常驻 + 登录 + 后台刷新 + 统计/设置窗口。
library;

import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'client.dart';
import 'cookie_store.dart';
import 'db.dart';
import 'logger.dart';
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
  // 全局错误捕获 → app.log（桌面应用无 console）
  FlutterError.onError = (details) {
    AppLog.e('Flutter 错误: ${details.exception}', details.exception, details.stack);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    AppLog.e('未捕获异常', error, stack);
    return true;
  };
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
  bool _loggingIn = false;
  bool _busy = false;
  bool _busySync = false;
  bool _sessionReady = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await AppLog.init();
    AppLog.i('启动 oc-usage');
    await _settings.load();
    _themeMode.value = _settings.theme;
    await initSqlite();
    await _db.open();
    AppLog.i('数据库就绪');

    // WebView2 持久化用户数据目录（登录态自动保存）
    final dataDir = await webviewDataDir();
    _session = WebSession(userDataFolder: dataDir);
    _session.onUrlChanged = _onWebUrl;
    _sessionReady = true;

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
    if (!_sessionReady) return;
    AppLog.i('URL 变化: $url');
    final wid = _extractWorkspace(url);
    if (wid != null && !_loggedIn) {
      _onLoggedIn(wid);
    }
  }

  String? _extractWorkspace(String url) {
    final m = RegExp(r'/workspace/(wrk_[A-Za-z0-9]+)').firstMatch(url);
    return m?.group(1);
  }

  Future<void> _onLoggedIn(String wid) async {
    if (wid.isEmpty || _loggingIn || _loggedIn) return;
    _loggingIn = true;
    try {
      _workspaceId = wid;
      // cookie 从 CookieStore 读取（登录页已注入/保存）
      final cred = await CookieStore.load();
      if (cred == null) {
        AppLog.e('登录成功但无 cookie');
        return;
      }
      _client = OpenCodeClient(cred['cookie']!, _session);
      AppLog.i('登录成功 workspace=$wid');
      // 捕获最新 cookie 并保存（DPAPI，与 Python 版同路径）—— 登录态自动续期
      _persistCookie(wid);
      setState(() => _loggedIn = true);
      // 快照立即展示（DB 缓存：限额 + 统计），后台并行刷新/历史/统计
      final cachedGo = _db.getGoCache();
      if (cachedGo != null) {
        final d = _data.value;
        d.go = cachedGo;
        d.status = '上次刷新 ${_nowText()}';
        _data.value = DashboardData.from(d);
        _updateTrayTooltip(cachedGo);
      }
      _applyStats();
      _refresh();
      _loadHistory();
      _syncStats();
      _timer?.cancel();
      _timer = Timer.periodic(_refreshInterval, (_) => _refresh());
    } finally {
      _loggingIn = false;
    }
  }

  Future<void> _persistCookie(String wid) async {
    try {
      final cookie = await _session.getCookie('https://opencode.ai', 'auth');
      if (cookie != null && cookie.isNotEmpty) {
        await CookieStore.save(cookie, wid);
        AppLog.i('cookie 已保存（${cookie.length} 字符）');
      } else {
        AppLog.e('读取 cookie 为空');
      }
    } catch (e) {
      AppLog.e('保存 cookie 失败', e);
    }
  }

  int _loadingCount = 0;

  /// 合并多个并发加载任务的 loading 状态（引用计数）。
  void _setLoading(bool on, [String? status]) {
    if (on) {
      _loadingCount++;
    } else {
      _loadingCount = (_loadingCount - 1).clamp(0, 1 << 30);
    }
    final d = _data.value;
    d.loading = _loadingCount > 0;
    if (status != null) d.status = status;
    _data.value = DashboardData.from(d);
  }

  // ── 数据 ──

  Future<void> _refresh() async {
    if (_busy) return;
    final client = _client;
    final wid = _workspaceId;
    if (client == null || wid == null) return;
    _busy = true;
    _setLoading(true, '正在刷新用量…');
    AppLog.i('刷新开始');
    final t0 = DateTime.now();
    try {
      AppLog.i('调用 fetchGo');
      final go = await client.fetchGo(wid);
      AppLog.i('fetchGo 返回，开始更新 UI');
      final d = _data.value;
      d.go = go;
      if (!d.loading) d.status = '上次刷新 ${_nowText()}';
      _data.value = DashboardData.from(d);
      _updateTrayTooltip(go);
      _db.putGoCache(go);
      AppLog.i('刷新完成（${DateTime.now().difference(t0).inMilliseconds}ms）'
          ' subscribed=${go.subscribed} '
          '滚动=${go.rolling?.usagePercent.round()}% '
          '每周=${go.weekly?.usagePercent.round()}% '
          '每月=${go.monthly?.usagePercent.round()}%');
    } on ClientError catch (e) {
      _data.value.status = '刷新失败：${e.message}';
      AppLog.e('刷新失败: ${e.message}');
      if (e.message.contains('登录已过期')) {
        _timer?.cancel();
        setState(() => _loggedIn = false);
      }
    } catch (e, st) {
      _data.value.status = '刷新失败';
      AppLog.e('刷新异常', e, st);
    } finally {
      _busy = false;
      _setLoading(false, _loadingCount == 1 ? '上次刷新 ${_nowText()}' : null);
    }
  }

  Future<void> _syncStats() async {
    if (_busySync) return;
    final client = _client;
    final wid = _workspaceId;
    if (client == null || wid == null) return;
    _busySync = true;
    final t0 = DateTime.now();
    try {
      // 用 DB 判断（而非内存 stats）：库空才全量，否则增量秒级补新
      int added;
      if (_db.recordCount() == 0) {
        added = await _db.syncFull(client, wid);
      } else {
        added = await _db.syncIncremental(client, wid);
      }
      _applyStats();
      AppLog.i('统计同步完成（${DateTime.now().difference(t0).inMilliseconds}ms）'
          ' 新增 $added 条，库内 ${_db.recordCount()} 条');
      // 状态栏显示同步结果（与 Python 版一致）
      final d = _data.value;
      d.status = '缓存已同步 · 新增 $added 条 · ${_nowText()}';
      _data.value = DashboardData.from(d);
    } catch (e, st) {
      AppLog.e('统计同步失败', e, st);
    } finally {
      _busySync = false;
    }
  }

  void _applyStats() {
    final d = _data.value;
    d.stats = _db.allStats();
    d.modelCosts = _db.allModelCosts();
    _data.value = DashboardData.from(d);
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
      AppLog.i('历史缓存命中 $year-$month（${cached.length} 条）');
      d.history = cached;
      _data.value = DashboardData.from(d);
      return;
    }
    AppLog.i('历史缓存未命中 $year-$month，拉取中…');
    _setLoading(true, '正在加载 $year 年 $month 月历史…');
    final t0 = DateTime.now();
    try {
      final entries = await client.fetchUsageHistory(wid, year, month - 1);
      _db.putHistoryCache(wid, year, month, entries);
      d.history = entries;
      _data.value = DashboardData.from(d);
      AppLog.i('历史加载完成 $year-$month（${DateTime.now().difference(t0).inMilliseconds}ms）'
          ' ${entries.length} 条');
    } on ClientError catch (e) {
      d.status = '历史加载失败：${e.message}';
      AppLog.e('历史加载失败: ${e.message}');
      _data.value = DashboardData.from(d);
    } catch (e, st) {
      AppLog.e('历史加载异常', e, st);
    } finally {
      _setLoading(false, _loadingCount == 1 ? '上次刷新 ${_nowText()}' : null);
    }
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
    _data.value = DashboardData.from(d);
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
    _openWindow();
  }

  /// 打开统计窗口：立即显示缓存快照，后台刷新限额 + 增量同步统计。
  void _openWindow() {
    windowManager.show();
    windowManager.focus();
    _refresh();
    _syncStats();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'open':
        _openWindow();
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
    AppLog.i('退出');
    _timer?.cancel();
    _db.close();
    // 先释放 WebView2（正常退出浏览器进程，登录态 cookie 才会落盘）
    try {
      await _session.controller.dispose();
    } catch (_) {}
    AppLog.close();
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
                  onLoggedIn: _onLoggedIn,
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
