/// opencode.ai 数据获取（复刻 Python 版架构）。
///
/// - HTTP 请求走 dart:io（快、可并发、不依赖页面状态）
/// - JS 解析（SSR 提取 / RPC 响应流）在 WebView 中执行
/// - 登录态 = auth cookie（CookieStore 持久化）
library;

import 'dart:convert';
import 'dart:io';

import 'package:win32_registry/win32_registry.dart';

import 'logger.dart';
import 'models.dart';
import 'webview_session.dart';

const baseUrl = 'https://opencode.ai';
const usagePageSize = 50;

const _userAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36';

/// 读取 Windows 系统代理（直连 opencode.ai 的响应会被网络栈截断，
/// 浏览器走系统代理才稳定）。
String systemProxyString() {
  try {
    final key = CURRENT_USER.open(
      r'Software\Microsoft\Windows\CurrentVersion\Internet Settings',
      config: const RegistryOpenConfig(access: RegistryAccess.read),
    );
    try {
      final enable = key.getValue('ProxyEnable');
      final server = key.getValue('ProxyServer');
      final enabled = enable is DwordValue ? enable.value : 0;
      final host = server is StringValue ? server.value : '';
      if (enabled == 1 && host.isNotEmpty) return 'PROXY $host';
    } finally {
      key.close();
    }
  } catch (_) {}
  return 'DIRECT';
}

/// 已知 server function id（2026-08 抓取）；失效时自动重新发现。
const knownServerIds = {
  'history': '15702f3a12ff8bff357f8c2aa154a17e65b746d5f6b96adc9002c86ee0c15205',
  'page': 'bfd684bfc2e4eed05cd0b518f5e4eafd3f3376e3938abb9e536e7c03df831e5c',
};

final _serverRefRe = RegExp(r'createServerReference\("([0-9a-f]{64})"\)');
final _bundleJsRe = RegExp(r'/_build/assets/[A-Za-z0-9_.-]+\.js');

class ClientError implements Exception {
  final String message;
  ClientError(this.message);
  @override
  String toString() => message;
}

class OpenCodeClient {
  final String cookie;
  final WebSession session; // 仅用于执行 JS 解析

  OpenCodeClient(this.cookie, this.session);

  // ── HTTP（dart:io，不走 WebView） ──

  Future<String> _httpGet(String path) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..findProxy = (uri) => systemProxyString();
    try {
      final req = await client.getUrl(Uri.parse('$baseUrl$path'));
      req.headers
        ..set(HttpHeaders.cookieHeader, 'auth=$cookie')
        ..set(HttpHeaders.userAgentHeader, _userAgent)
        ..set(HttpHeaders.acceptHeader,
            'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8');
      final resp = await req.close();
      if (resp.statusCode == 401 || resp.statusCode == 403) {
        throw ClientError('登录已过期，请重新登录');
      }
      final body = await resp
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) {
        throw ClientError('请求失败：HTTP ${resp.statusCode}');
      }
      return body;
    } finally {
      client.close();
    }
  }

  Future<(int, String)> _httpPost(
    String path,
    String bodyJson,
    String? serverId,
  ) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..findProxy = (uri) => systemProxyString();
    try {
      final req = await client.postUrl(Uri.parse('$baseUrl$path'));
      req.headers
        ..set(HttpHeaders.cookieHeader, 'auth=$cookie')
        ..set(HttpHeaders.userAgentHeader, _userAgent)
        ..set(HttpHeaders.contentTypeHeader, 'application/json')
        ..set('X-Server-Instance', 'server-fn:0')
        ..set(HttpHeaders.refererHeader, '$baseUrl/workspace/x/usage');
      if (serverId != null) {
        req.headers.set('X-Server-Id', serverId);
      }
      req.write(bodyJson);
      final resp = await req.close();
      final text = await resp
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 8));
      return (resp.statusCode, text);
    } finally {
      client.close();
    }
  }

  // ── go 页面（HTTP + iframe JS 解析） ──

  /// 解析 /workspace/{id}/go 页面：Go 三层限额 + billing。
  ///
  /// HTTP 抓取 HTML → Dart 正则提取内联脚本 → WebView 同步 eval（复刻
  /// Python 版 QJSEngine：无 DOM 执行，毫秒级、不污染页面）。
  Future<GoData> fetchGo(String workspaceId) async {
    AppLog.i('fetchGo: HTTP 抓取 SSR');
    final html = await _httpGet('/workspace/$workspaceId/go');
    final scripts = _inlineScripts(html);
    AppLog.i('fetchGo: 内联脚本 ${scripts.length} 个');
    String? raw;
    for (var attempt = 0; attempt < 3; attempt++) {
      raw = await session.evalJs(ssrExtractScript(scripts));
      if (raw != null && raw != '{}' && !raw.startsWith('ERROR')) break;
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    if (raw == null || raw == '{}') {
      throw ClientError('go 页面解析失败（前端可能已改版）');
    }
    final data = jsonDecode(raw) as Map<String, dynamic>;
    AppLog.i('fetchGo: 解析成功，keys=${data.keys.take(3).toList()}');
    final sub = _firstMatch(data, 'lite.subscription.get');
    final bill = _firstMatch(data, 'billing.get');

    UsageWindow? window(String label, String key) {
      final j = sub is Map<String, dynamic> ? sub[key] : null;
      if (j is Map<String, dynamic>) {
        final w = UsageWindow.fromJson(j);
        return UsageWindow(label: label, usagePercent: w.usagePercent, resetInSec: w.resetInSec);
      }
      return null;
    }

    return GoData(
      subscribed: (sub is Map<String, dynamic>) && sub['mine'] == true,
      rolling: window('滚动', 'rollingUsage'),
      weekly: window('每周', 'weeklyUsage'),
      monthly: window('每月', 'monthlyUsage'),
    );
  }

  // ── RPC（HTTP POST + WebView 解析响应流） ──

  Future<List<HistoryEntry>> fetchUsageHistory(
    String workspaceId,
    int year,
    int month0, // 0-based（7 = 8 月）
  ) async {
    final body = _rpcBody([
      {'t': 1, 's': workspaceId},
      {'t': 0, 's': year},
      {'t': 0, 's': month0},
      {'t': 1, 's': '+08:00'},
    ]);
    final text = await _rpcCall('history', workspaceId, body);
    final data = jsonDecode(text);
    final usage = data is Map<String, dynamic> ? data['usage'] : null;
    if (usage is! List) return [];
    return usage
        .whereType<Map<String, dynamic>>()
        .map(HistoryEntry.fromJson)
        .toList();
  }

  Future<List<UsageRecord>> fetchPageRecords(String workspaceId, int page) async {
    final body = _rpcBody([
      {'t': 1, 's': workspaceId},
      {'t': 0, 's': page},
    ]);
    final text = await _rpcCall('page', workspaceId, body);
    final data = jsonDecode(text);
    if (data is! List) return [];
    return data.map(UsageRecord.fromRaw).toList();
  }

  Map<String, dynamic> _rpcBody(List<Map<String, dynamic>> args) => {
        't': {'t': 9, 'i': 0, 'l': args.length, 'a': args, 'o': 0},
        'f': 31,
        'm': [],
      };

  Future<String> _rpcCall(
    String kind,
    String workspaceId,
    Map<String, dynamic> body,
  ) async {
    // RPC 走 dart:io HTTP（走系统代理，8 秒超时快失败）
    var serverId = await _resolveServerId(kind, workspaceId);
    if (serverId == null) throw ClientError('无法定位服务函数（前端可能已改版）');
    for (var attempt = 0; attempt < 3; attempt++) {
      final (status, text) = await _httpPost('/_server', jsonEncode(body), serverId);
      if (status == 401 || status == 403) {
        throw ClientError('登录已过期，请重新登录');
      }
      if (status == 404 || status == 500) {
        // 前端改版导致 id 失效：重新发现后重试
        serverId = await _discoverServerId(kind, workspaceId);
        if (serverId == null) throw ClientError('$kind 接口失败：HTTP $status（前端可能已改版）');
        continue;
      }
      if (status != 200) {
        throw ClientError('$kind 接口失败：HTTP $status');
      }
      if (text.trimLeft().startsWith('<')) {
        AppLog.e('RPC 返回 HTML（响应异常），重试');
        await Future<void>.delayed(const Duration(milliseconds: 300));
        continue;
      }
      final jsResult = await session.evalJs(evalServerResponseScript(text));
      if (jsResult == null || jsResult.startsWith('ERROR:')) {
        AppLog.e('RPC 响应解析失败 [$kind]: ${jsResult ?? 'null'}');
        throw ClientError('$kind 接口失败：响应解析错误');
      }
      return jsResult;
    }
    throw ClientError('$kind 接口失败：重试耗尽');
  }

  // ── server function id 发现（纯 HTTP + Dart 正则） ──

  Future<String?> _resolveServerId(String kind, String workspaceId) async {
    return knownServerIds[kind];
  }

  Future<String?> _discoverServerId(String kind, String workspaceId) async {
    AppLog.i('discover: 开始 $kind');
    // 1. usage 页面取 JS bundle URL
    final html = await _httpGet('/workspace/$workspaceId/usage');
    final bundles = _bundleJsRe
        .allMatches(html)
        .map((m) => m.group(0)!)
        .toSet()
        .toList();
    AppLog.i('discover: bundles=${bundles.length}');

    // 2. 下载 bundle，收集 createServerReference id
    final candidates = <String>{};
    for (final b in bundles) {
      try {
        final js = await _httpGet(b);
        for (final m in _serverRefRe.allMatches(js)) {
          candidates.add(m.group(1)!);
        }
      } catch (_) {}
    }
    AppLog.i('discover: candidates=${candidates.length}');

    // 3. 逐个试调
    for (final cid in candidates) {
      try {
        final body = _probeBody(kind, workspaceId);
        final (status, text) = await _httpPost('/_server', jsonEncode(body), cid);
        if (status != 200) continue;
        if (kind == 'history' && text.contains('usage:') && text.contains('totalCost')) {
          return cid;
        }
        if (kind == 'page' && text.contains('"usg_')) {
          return cid;
        }
      } catch (_) {}
    }
    return null;
  }

  Map<String, dynamic> _probeBody(String kind, String workspaceId) {
    if (kind == 'history') {
      final now = DateTime.now();
      return _rpcBody([
        {'t': 1, 's': workspaceId},
        {'t': 0, 's': now.year},
        {'t': 0, 's': now.month - 1},
        {'t': 1, 's': '+08:00'},
      ]);
    }
    return _rpcBody([
      {'t': 1, 's': workspaceId},
      {'t': 0, 's': 0},
    ]);
  }
}

Object? _firstMatch(Map<String, dynamic> data, String prefix) {
  for (final e in data.entries) {
    if (e.key.startsWith(prefix)) return e.value;
  }
  return null;
}

/// 提取页面内联 <script>（不带 src 的）。
List<String> _inlineScripts(String html) {
  final re = RegExp(r'<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)</script>');
  return re.allMatches(html).map((m) => m.group(1)!).toList();
}

/// 分页拉取全部请求记录（每页 50 条，顺序直到不足一页）。
Future<List<UsageRecord>> fetchAllUsage(
  OpenCodeClient client,
  String workspaceId, {
  int maxPages = 800,
}) async {
  final all = <UsageRecord>[];
  final seen = <String>{};
  for (var page = 0; page < maxPages; page++) {
    final records = await client.fetchPageRecords(workspaceId, page);
    if (records.isEmpty) break;
    for (final r in records) {
      if (seen.add(r.id)) all.add(r);
    }
    if (records.length < usagePageSize) break;
  }
  return all;
}
