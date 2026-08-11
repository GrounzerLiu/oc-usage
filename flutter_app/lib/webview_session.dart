/// WebView2 会话：登录 + 页面数据提取 + 异步 JS（fetch/RPC）。
///
/// WebView2 自带持久化用户数据目录（%APPDATA%/oc-usage/webview），
/// 登录态由浏览器自动保存，无需手动管理 cookie。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:webview_win_floating/webview_win_floating.dart';

import 'logger.dart';

/// WebView2 原生 CookieManager 注入（本地 fork 插件提供）。
const _cookieChannel = MethodChannel('webview_win_floating');

class WebSession {
  final WinWebViewController controller;
  final _loadCompleters = <Completer<String?>>[];
  String? _lastUrl;
  bool _initialized = false;

  String? get lastUrl => _lastUrl;

  /// 任意导航发生（含登录跳转）时的回调。
  void Function(String url)? onUrlChanged;

  WebSession({String? userDataFolder, String profileName = 'default'})
      : controller = WinWebViewController(
          params: WindowsWebViewControllerCreationParams(
            userDataFolder: userDataFolder,
            profileName: profileName,
            suspendDuringDeactive: false,
          ),
        );

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    await controller.setNavigationDelegate(
      WinNavigationDelegate(
        onPageStarted: (url) {
          _lastUrl = url;
          onUrlChanged?.call(url);
        },
        onPageFinished: (url) {
          _lastUrl = url;
          onUrlChanged?.call(url);
          final pending = List.of(_loadCompleters);
          _loadCompleters.clear();
          for (final p in pending) {
            p.complete(url);
          }
        },
        onUrlChange: (u) {
          _lastUrl = u.url;
          onUrlChanged?.call(u.url ?? '');
        },
      ),
    );
    AppLog.i('WebView 导航委托已注册');
  }

  /// 通过 WebView2 原生 CookieManager 读取 cookie 值（含 httpOnly）。
  Future<String?> getCookie(String domain, String name) async {
    try {
      final value = await _cookieChannel.invokeMethod<String>('getCookie', {
        'webviewId': 1,
        'domain': domain,
        'name': name,
      });
      return (value == null || value.isEmpty) ? null : value;
    } catch (e) {
      AppLog.e('读取 cookie 失败', e);
      return null;
    }
  }

  /// 通过 WebView2 原生 CookieManager 注入 cookie（支持 httpOnly）。
  Future<bool> setCookie(
    String domain,
    String name,
    String value, {
    String path = '/',
  }) async {
    try {
      final ok = await _cookieChannel.invokeMethod<bool>('setCookie', {
        'webviewId': 1,
        'domain': domain,
        'name': name,
        'value': value,
        'path': path,
      });
      return ok == true;
    } catch (e) {
      AppLog.e('注入 cookie 失败', e);
      return false;
    }
  }

  /// 加载 URL 并等待页面加载完成（返回最终 URL，可检测登录跳转）。
  Future<String?> loadAndWait(
    String url, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final p = Completer<String?>();
    _loadCompleters.add(p);
    try {
      await controller.loadRequest(Uri.parse(url));
    } catch (e) {
      _loadCompleters.remove(p);
      p.complete(_lastUrl);
    }
    return p.future.timeout(
      timeout,
      onTimeout: () {
        _loadCompleters.remove(p);
        return _lastUrl;
      },
    );
  }

  /// 同步 JS 求值，返回结果字符串（带超时，防止 WebView2 挂起）。
  ///
  /// WebView2 会把 JS 字符串返回值再 JSON 编码一层（"abc" → "\"abc\""），
  /// 这里统一剥掉外层的 JSON 引号，返回真实字符串。
  Future<String?> evalJs(String js, {Duration timeout = const Duration(seconds: 5)}) async {
    try {
      final r = await controller
          .runJavaScriptReturningResult(js)
          .timeout(timeout, onTimeout: () {
        AppLog.e('evalJs 超时: ${js.substring(0, js.length > 60 ? 60 : js.length)}');
        return 'null';
      });
      if (r is String && r.startsWith('"')) {
        try {
          final decoded = jsonDecode(r);
          if (decoded is String) return decoded;
        } catch (_) {
          // 不是 JSON 字符串，原样返回
        }
      }
      return r.toString();
    } catch (_) {
      return null;
    }
  }

  /// 异步 JS（含 fetch/await）：注入 async IIFE 存 window.__ocR，轮询读取。
  Future<String?> evalJsAsync(
    String asyncBody, {
    Duration timeout = const Duration(seconds: 30),
    Duration poll = const Duration(milliseconds: 120),
  }) async {
    await evalJs('window.__ocR = undefined;');
    final script = '''
      (async () => {
        try {
          window.__ocR = { ok: true, value: await (${_sanitizeForAsync(asyncBody)}) };
        } catch (e) {
          window.__ocR = { ok: false, error: String(e) };
        }
      })();
      'ok'
    ''';
    final r = await evalJs(script);
    if (r == null || !r.contains('ok')) return null;
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final out = await evalJs(
        "window.__ocR === undefined ? 'PENDING' : JSON.stringify(window.__ocR)",
      );
      if (out == null) return null;
      if (out == 'PENDING') {
        await Future<void>.delayed(poll);
        continue;
      }
      return out;
    }
    return null;
  }

  String _sanitizeForAsync(String body) {
    final t = body.trim();
    if (t.startsWith('async')) return t;
    if (t.startsWith('(') && t.endsWith(')')) return t;
    return '($t)';
  }
}

/// WebView2 用户数据目录（持久化登录态）。
Future<String> webviewDataDir() async {
  final appData = Platform.environment['APPDATA'] ??
      '${Directory.systemTemp.path}${Platform.pathSeparator}oc-usage';
  final dir = Directory('$appData${Platform.pathSeparator}oc-usage'
      '${Platform.pathSeparator}webview');
  await dir.create(recursive: true);
  return dir.path;
}

/// fetch 一个同源接口，返回 {status, text}（带会话 cookie）。
String fetchTextScript(String path, String method,
    [String? bodyJson, String? serverId]) {
  final headers = StringBuffer(
    "{'Content-Type': 'application/json', 'X-Server-Instance': 'server-fn:0', 'Origin': location.origin",
  );
  if (serverId != null) headers.write(", 'X-Server-Id': '$serverId'");
  headers.write('}');
  final opt = StringBuffer("{method: '$method', headers: $headers");
  if (bodyJson != null) {
    opt.write(", body: JSON.stringify($bodyJson)");
  }
  opt.write('}');
  return '''
    (async () => {
      try {
        const r = await fetch('$path', $opt);
        const t = await r.text();
        return {status: r.status, text: t};
      } catch (e) {
        return {status: 0, text: String(e)};
      }
    })()
  ''';
}

/// 提取 _$HY.r 中 key 前缀匹配的已 resolve 数据（与 Python 版逻辑一致）。
///
/// 防御 _$HY 尚未初始化（页面脚本未执行完）的情况，返回 "{}" 而非抛错。
String extractSsrScript(List<String> prefixes) {
  final p = jsonEncode(prefixes);
  return '''
    (function () {
      var root = window._${r'$'}HY || {};
      var out = {};
      for (var k in (root.r || {})) {
        for (var i = 0; i < $p.length; i++) {
          if (k.indexOf($p[i]) === 0) {
            var v = root.r[k];
            out[k] = (v && v.v !== undefined) ? v.v : (v && v.p && v.p.v);
          }
        }
      }
      return JSON.stringify(out);
    })()
  ''';
}

/// 执行 SolidStart RPC 响应流，返回 self.$R['server-fn:0'][0] 的 JSON。
///
/// 响应代码用 `self.$R` 与裸 `$R` 两种方式引用结果容器，因此挂载到
/// window.$R 并用直接 eval 执行（裸标识符解析到函数作用域的同名变量）。
String evalServerResponseScript(String text) {
  final escaped = jsonEncode(text);
  final dollar = r'$';
  return '''
    (function () {
      try {
        var self = window;
        var _R = self.${dollar}R || {};
        self.${dollar}R = _R;
        var ${dollar}R = _R;
        var text = $escaped;
        eval(text);
        return JSON.stringify(self.${dollar}R['server-fn:0'][0]);
      } catch (e) {
        return 'ERROR: ' + String(e);
      }
    })()
  ''';
}
