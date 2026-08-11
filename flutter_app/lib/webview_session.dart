/// WebView2 会话：登录 + 页面数据提取 + 异步 JS（fetch/RPC）。
///
/// WebView2 自带持久化用户数据目录（%APPDATA%/oc-usage/webview），
/// 登录态由浏览器自动保存，无需手动管理 cookie。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:webview_win_floating/webview_win_floating.dart';

class WebSession {
  final WinWebViewController controller;
  final _loadCompleters = <Completer<String?>>[];
  String? _lastUrl;
  bool _initialized = false;

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

  /// 同步 JS 求值，返回结果字符串。
  Future<String?> evalJs(String js) async {
    try {
      final r = await controller.runJavaScriptReturningResult(js);
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
String extractSsrScript(List<String> prefixes) {
  final p = jsonEncode(prefixes);
  return '''
    (function () {
      var out = {};
      for (var k in _${r'$'}HY.r) {
        for (var i = 0; i < $p.length; i++) {
          if (k.indexOf($p[i]) === 0) {
            var v = _${r'$'}HY.r[k];
            out[k] = (v && v.v !== undefined) ? v.v : (v && v.p && v.p.v);
          }
        }
      }
      return JSON.stringify(out);
    })()
  ''';
}

/// 执行 SolidStart RPC 响应流，返回 self.$R['server-fn:0'][0] 的 JSON。
String evalServerResponseScript(String text) {
  final escaped = jsonEncode(text);
  return '''
    (function () {
      try {
        var self = window;
        var _${r'$'}R = window._${r'$'}R || [];
        window._${r'$'}R = _${r'$'}R;
        var text = $escaped;
        (0, eval)(text);
        return JSON.stringify(window._${r'$'}R['server-fn:0'][0]);
      } catch (e) {
        return 'ERROR: ' + String(e);
      }
    })()
  ''';
}
