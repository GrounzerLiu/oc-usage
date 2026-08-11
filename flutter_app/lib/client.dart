/// opencode.ai 数据获取（走 WebView2 会话，带登录态）。
library;

import 'dart:convert';
import 'dart:math' as math;

import 'logger.dart';
import 'models.dart';
import 'webview_session.dart';

const baseUrl = 'https://opencode.ai';
const usagePageSize = 50;

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
  final WebSession session;

  OpenCodeClient(this.session);

  // ── SSR 页面数据 ──

  /// 解析 /workspace/{id}/go 页面：Go 三层限额 + billing。
  ///
  /// 纯 HTTP 抓取 + 页面内联脚本解析（复刻 Python 版），不导航页面。
  Future<GoData> fetchGo(String workspaceId) async {
    AppLog.i('fetchGo: 开始（HTTP 抓取 SSR）');
    final out = await session.evalJsAsync(
      fetchGoSsrScript(workspaceId),
      timeout: const Duration(seconds: 20),
    );
    if (out == null) throw ClientError('go 页面抓取失败');
    final parsed = jsonDecode(out) as Map<String, dynamic>;
    if (parsed['ok'] != true) throw ClientError('go 页面抓取失败');
    final value = parsed['value'] as Map<String, dynamic>;
    final status = value['status'];
    if (status == 401 || status == 403) {
      throw ClientError('登录已过期，请重新登录');
    }
    if (status != 200 || value['data'] is! Map<String, dynamic>) {
      AppLog.e('fetchGo 失败详情: ${out.substring(0, out.length > 400 ? 400 : out.length)}');
      throw ClientError('go 页面解析失败（前端可能已改版）');
    }
    final data = value['data'] as Map<String, dynamic>;
    AppLog.i('fetchGo: 解析成功，keys=${data.keys.take(3).toList()}');
    final sub = _firstMatch(data, 'lite.subscription.get');
    final bill = _firstMatch(data, 'billing.get');
    AppLog.i('fetchGo: sub=$sub bill=$bill');

    UsageWindow? window(String label, String key) {
      final j = sub is Map<String, dynamic> ? sub[key] : null;
      if (j is Map<String, dynamic>) return UsageWindow.fromJson(j, label);
      return null;
    }

    return GoData(
      subscribed: (sub is Map<String, dynamic>) && sub['mine'] == true,
      rolling: window('滚动', 'rollingUsage'),
      weekly: window('每周', 'weeklyUsage'),
      monthly: window('每月', 'monthlyUsage'),
      balance: bill is Map<String, dynamic> && bill['balance'] is num
          ? (bill['balance'] as num).toDouble()
          : null,
    );
  }

  // ── RPC（历史聚合 / 请求记录分页） ──

  Future<List<HistoryEntry>> fetchUsageHistory(
    String workspaceId,
    int year,
    int month0, // 0-based（7 = 8 月）
  ) async {
    final body = {
      't': {
        't': 9, 'i': 0, 'l': 4,
        'a': [
          {'t': 1, 's': workspaceId},
          {'t': 0, 's': year},
          {'t': 0, 's': month0},
          {'t': 1, 's': '+08:00'},
        ],
        'o': 0,
      },
      'f': 31,
      'm': [],
    };
    final serverId = await _resolveServerId('history', workspaceId);
    if (serverId == null) throw ClientError('无法定位服务函数（前端可能已改版）');
    final result = await _rpcCall('history', serverId, workspaceId, body);
    if (result == null) throw ClientError('用量历史获取失败');
    final data = jsonDecode(result);
    final usage = data is Map<String, dynamic> ? data['usage'] : null;
    if (usage is! List) return [];
    return usage
        .whereType<Map<String, dynamic>>()
        .map(HistoryEntry.fromJson)
        .toList();
  }

  Future<List<UsageRecord>> fetchPageRecords(String workspaceId, int page) async {
    final body = {
      't': {
        't': 9, 'i': 0, 'l': 2,
        'a': [
          {'t': 1, 's': workspaceId},
          {'t': 0, 's': page},
        ],
        'o': 0,
      },
      'f': 31,
      'm': [],
    };
    final serverId = await _resolveServerId('page', workspaceId);
    if (serverId == null) throw ClientError('无法定位服务函数（前端可能已改版）');
    final result = await _rpcCall('page', serverId, workspaceId, body);
    if (result == null) return [];
    final data = jsonDecode(result);
    if (data is! List) return [];
    return data.map(UsageRecord.fromRaw).toList();
  }

  Future<String?> _rpcCall(
    String kind,
    String serverId,
    String workspaceId,
    Map<String, dynamic> body,
  ) async {
    final out = await session.evalJsAsync(
      fetchTextScript('/_server', 'POST', jsonEncode(body), serverId),
    );
    if (out == null) return null;
    final parsed = jsonDecode(out) as Map<String, dynamic>;
    if (parsed['ok'] != true) return null;
    final status = (parsed['value'] as Map<String, dynamic>)['status'];
    final text = '${(parsed['value'] as Map<String, dynamic>)['text']}';
    if (status == 401 || status == 403) {
      throw ClientError('登录已过期，请重新登录');
    }
    if (status == 404 || status == 500) {
      // 前端改版导致 id 失效：重新发现并重试一次
      final newId = await _discoverServerId(kind, workspaceId);
      if (newId != null && newId != serverId) {
        final retry = await _rpcCall(kind, newId, workspaceId, body);
        if (retry != null) return retry;
      }
      throw ClientError('$kind 接口失败：HTTP $status（前端可能已改版）');
    }
    if (status != 200) {
      throw ClientError('$kind 接口失败：HTTP $status');
    }
    if (text.trimLeft().startsWith('<')) {
      // 页面导航竞态：RPC 返回了 HTML 而非 JSON 流，稍后重试一次
      AppLog.e('RPC 返回 HTML（疑似导航竞态），500ms 后重试');
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final retry = await _rpcCall(kind, serverId, workspaceId, body);
      if (retry != null) return retry;
      throw ClientError('$kind 接口失败：响应异常');
    }
    final jsResult = await session.evalJs(evalServerResponseScript(text));
    if (jsResult != null && jsResult.startsWith('ERROR:')) {
      AppLog.e(
        'RPC 响应解析失败 [$kind]: $jsResult\n'
        '响应前 1200 字符: ${text.substring(0, math.min(1200, text.length))}',
      );
      return null;
    }
    return jsResult;
  }

  // ── server function id 发现 ──

  Future<String?> _resolveServerId(String kind, String workspaceId) async {
    final cached = await _loadIdCache();
    final key = '$kind:$workspaceId';
    if (cached.containsKey(key)) return cached[key];
    final known = knownServerIds[kind];
    if (known != null) return known;
    return _discoverServerId(kind, workspaceId);
  }

  Future<Map<String, String>> _loadIdCache() async {
    return {};
  }

  Future<String?> _discoverServerId(String kind, String workspaceId) async {
    // 1. 抓 usage 页面 HTML 取 JS bundle URL（纯 HTTP，不导航）
    final htmlOut = await session.evalJsAsync(
      fetchTextScript('/workspace/$workspaceId/usage', 'GET'),
      timeout: const Duration(seconds: 15),
    );
    final html = _rpcText(htmlOut) ?? '';
    final bundles = _bundleJsRe
        .allMatches(html)
        .map((m) => m.group(0)!)
        .toSet()
        .toList();

    // 2. 下载 bundle 收集 createServerReference id
    final candidates = <String>{};
    for (final b in bundles) {
      final js = await session.evalJsAsync(fetchTextScript(b, 'GET'));
      if (js == null) continue;
      try {
        final parsed = jsonDecode(js) as Map<String, dynamic>;
        final value = parsed['value'] as Map<String, dynamic>;
        final text = '${value['text']}';
        for (final m in _serverRefRe.allMatches(text)) {
          candidates.add(m.group(1)!);
        }
      } catch (_) {}
    }

    // 3. 逐个试调：响应结构匹配即为所需 id
    for (final cid in candidates) {
      final body = _probeBody(kind, workspaceId);
      try {
        final out = await session.evalJsAsync(
          fetchTextScript('/_server', 'POST', jsonEncode(body), cid),
        );
        final text = _rpcText(out);
        if (text == null) continue;
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

  String? _rpcText(String? out) {
    if (out == null) return null;
    try {
      final parsed = jsonDecode(out) as Map<String, dynamic>;
      if (parsed['ok'] != true) return null;
      return '${(parsed['value'] as Map<String, dynamic>)['text']}';
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> _probeBody(String kind, String workspaceId) {
    if (kind == 'history') {
      final now = DateTime.now();
      return {
        't': {
          't': 9, 'i': 0, 'l': 4,
          'a': [
            {'t': 1, 's': workspaceId},
            {'t': 0, 's': now.year},
            {'t': 0, 's': now.month - 1},
            {'t': 1, 's': '+08:00'},
          ],
          'o': 0,
        },
        'f': 31,
        'm': [],
      };
    }
    return {
      't': {
        't': 9, 'i': 0, 'l': 2,
        'a': [
          {'t': 1, 's': workspaceId},
          {'t': 0, 's': 0},
        ],
        'o': 0,
      },
      'f': 31,
      'm': [],
    };
  }
}

Object? _firstMatch(Map<String, dynamic> data, String prefix) {
  for (final e in data.entries) {
    if (e.key.startsWith(prefix)) return e.value;
  }
  return null;
}

/// 分页拉取全部请求记录（每页 50 条，连续拼接）。
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
