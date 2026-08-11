/// SQLite 缓存：请求记录（id 去重）+ 历史聚合缓存 + 统计。
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart' show rootBundle;
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';

import 'client.dart';
import 'logger.dart';
import 'models.dart';
import 'settings.dart';

const _historyTtlSec = 10 * 60;

/// 从 assets 释放 sqlite3.dll 并加载（避免构建期从 GitHub 下载）。
Future<void> initSqlite() async {
  try {
    final dir = await ocUsageDir();
    final dll = File('${dir.path}${Platform.pathSeparator}sqlite3.dll');
    if (!await dll.exists()) {
      final data = await rootBundle.load('assets/sqlite3.dll');
      await dll.writeAsBytes(data.buffer.asUint8List());
    }
    open.overrideFor(OperatingSystem.windows,
        () => DynamicLibrary.open(dll.absolute.path));
  } catch (e) {
    throw StateError('无法加载 sqlite3.dll: $e');
  }
}

class UsageCache {
  Database? _db;

  Database get db {
    final d = _db;
    if (d != null) return d;
    throw StateError('db not opened');
  }

  Future<void> open() async {
    final dir = await ocUsageDir();
    final path = '${dir.path}${Platform.pathSeparator}cache.db';
    final database = sqlite3.open(path);
    database.execute('PRAGMA journal_mode=WAL');
    database.execute('''
      CREATE TABLE IF NOT EXISTS records (
        id TEXT PRIMARY KEY,
        time_created TEXT NOT NULL,
        time_local TEXT NOT NULL,
        model TEXT NOT NULL,
        provider TEXT NOT NULL DEFAULT '',
        input_tokens INTEGER NOT NULL DEFAULT 0,
        output_tokens INTEGER NOT NULL DEFAULT 0,
        reasoning_tokens INTEGER NOT NULL DEFAULT 0,
        cache_read_tokens INTEGER NOT NULL DEFAULT 0,
        cost INTEGER NOT NULL DEFAULT 0,
        key_id TEXT NOT NULL DEFAULT ''
      )''');
    database.execute(
      'CREATE INDEX IF NOT EXISTS idx_records_local ON records(time_local)',
    );
    database.execute('''
      CREATE TABLE IF NOT EXISTS history_cache (
        workspace TEXT NOT NULL,
        year INTEGER NOT NULL,
        month INTEGER NOT NULL,
        payload TEXT NOT NULL,
        cached_at TEXT NOT NULL,
        PRIMARY KEY (workspace, year, month)
      )''');
    database.execute('CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT)');
    _db = database;
  }

  void close() {
    _db?.dispose();
    _db = null;
  }

  String _localIso(String utcIso) {
    try {
      final dt = DateTime.parse(utcIso.replaceAll('Z', '+00:00')).toLocal();
      return dt.toIso8601String();
    } catch (_) {
      return utcIso;
    }
  }

  // ── 请求记录 ──

  Set<String> knownIds() {
    final rows = db.select('SELECT id FROM records');
    return rows.map((r) => '${r['id']}').toSet();
  }

  int insertRecords(List<UsageRecord> records) {
    if (records.isEmpty) return 0;
    final stmt = db.prepare('''
      INSERT OR IGNORE INTO records
        (id, time_created, time_local, model, provider,
         input_tokens, output_tokens, reasoning_tokens, cache_read_tokens,
         cost, key_id)
      VALUES (?,?,?,?,?,?,?,?,?,?,?)
    ''');
    var n = 0;
    try {
      for (final r in records) {
        stmt.execute([
          r.id,
          r.timeCreated,
          _localIso(r.timeCreated),
          r.model,
          r.provider,
          r.inputTokens,
          r.outputTokens,
          r.reasoningTokens,
          r.cacheReadTokens,
          r.cost,
          r.keyId,
        ]);
        n += db.select('SELECT changes() c').first['c'] as int;
      }
    } finally {
      stmt.dispose();
    }
    return n;
  }

  /// 增量同步：批量并发扫描，找到第一个已缓存 id 即截断停止。
  Future<int> syncIncremental(
    OpenCodeClient client,
    String workspaceId, {
    int maxPages = 800,
    int batchSize = 8,
  }) async {
    final known = knownIds();
    if (known.isEmpty) {
      return syncFull(client, workspaceId);
    }
    final newest = await client.fetchPageRecords(workspaceId, 0);
    if (newest.isNotEmpty) {
      AppLog.i('增量: 第一页 ${newest.length} 条，首条=${newest.first.id} '
          '命中=${known.contains(newest.first.id)}，known=${known.length}');
      if (known.contains(newest.first.id)) {
        return insertRecords(newest.where((r) => !known.contains(r.id)).toList());
      }
    }
    var totalNew = 0;
    var page = 0;
    while (page < maxPages) {
      final pages = <int>[];
      for (var p = page; p < math.min(page + batchSize, maxPages); p++) {
        pages.add(p);
      }
      final futures = pages.map(
        (p) => client.fetchPageRecords(workspaceId, p).catchError(
              (_) => <UsageRecord>[],
            ),
      );
      final results = await Future.wait(futures);
      var done = false;
      for (var i = 0; i < results.length; i++) {
        final records = results[i];
        if (records.isEmpty) {
          done = true;
          break;
        }
        var cut = -1;
        for (var j = 0; j < records.length; j++) {
          if (known.contains(records[j].id)) {
            cut = j;
            break;
          }
        }
        if (cut >= 0) {
          totalNew += insertRecords(records.sublist(0, cut));
          done = true;
          break;
        }
        totalNew += insertRecords(records);
        known.addAll(records.map((r) => r.id));
        if (records.length < 50) {
          done = true;
          break;
        }
      }
      if (done) break;
      page += batchSize;
    }
    return totalNew;
  }

  /// 全量同步：并发批量拉取所有页（每批 8 页，直到不足一页为止）。
  Future<int> syncFull(
    OpenCodeClient client,
    String workspaceId, {
    int maxPages = 800,
    int batchSize = 8,
  }) async {
    var total = 0;
    var page = 0;
    while (page < maxPages) {
      final pages = <int>[];
      for (var p = page; p < math.min(page + batchSize, maxPages); p++) {
        pages.add(p);
      }
      final futures = pages.map(
        (p) => client.fetchPageRecords(workspaceId, p).catchError(
              (_) => <UsageRecord>[],
            ),
      );
      final results = await Future.wait(futures);
      var done = false;
      for (var i = 0; i < results.length; i++) {
        final records = results[i];
        if (records.isEmpty) {
          done = true;
          break;
        }
        total += insertRecords(records);
        if (records.length < 50) {
          done = true;
          break;
        }
      }
      if (done) break;
      page += batchSize;
    }
    return total;
  }

  // ── 统计 ──

  int recordCount() {
    return db.select('SELECT COUNT(*) c FROM records').first['c'] as int;
  }

  MonthStats allStats() {    final row = db.select('''
      SELECT COUNT(*) c,
             COALESCE(SUM(input_tokens+output_tokens+reasoning_tokens+cache_read_tokens),0) t,
             COUNT(DISTINCT substr(time_local,1,10)) d
      FROM records
    ''').first;
    return MonthStats(
      requests: (row['c'] as int),
      tokens: (row['t'] as int),
      days: (row['d'] as int),
    );
  }

  List<(String, int)> allModelCosts() {
    final rows = db.select(
      'SELECT model, SUM(cost) c FROM records GROUP BY model ORDER BY c DESC',
    );
    return rows.map((r) => ('${r['model']}', r['c'] as int)).toList();
  }

  List<HistoryEntry> monthHistory(int year, int month) {
    final prefix = '$year-${month.toString().padLeft(2, '0')}';
    final rows = db.select('''
      SELECT substr(time_local,1,10) d, model, SUM(cost) c
      FROM records WHERE time_local LIKE ?
      GROUP BY substr(time_local,1,10), model ORDER BY d, model
    ''', [prefix + '%']);
    return rows
        .map((r) =>
            HistoryEntry(date: '${r['d']}', model: '${r['model']}', totalCost: r['c'] as int))
        .toList();
  }

  // ── 历史聚合缓存（当前月 10 分钟 TTL，历史月永久） ──

  List<HistoryEntry>? getHistoryCache(String workspaceId, int year, int month) {
    final rows = db.select(
      'SELECT payload, cached_at FROM history_cache WHERE workspace=? AND year=? AND month=?',
      [workspaceId, year, month],
    );
    if (rows.isEmpty) return null;
    final payload = '${rows.first['payload']}';
    final cachedAt = DateTime.tryParse('${rows.first['cached_at']}');
    if (cachedAt == null) return null;
    final now = DateTime.now();
    if (year < now.year || (year == now.year && month < now.month)) {
      return _decodeHistory(payload);
    }
    if (cachedAt.year == now.year &&
        cachedAt.month == now.month &&
        cachedAt.day == now.day &&
        now.difference(cachedAt).inSeconds < _historyTtlSec) {
      return _decodeHistory(payload);
    }
    return null;
  }

  void putHistoryCache(
      String workspaceId, int year, int month, List<HistoryEntry> entries) {
    db.execute(
      'INSERT OR REPLACE INTO history_cache(workspace,year,month,payload,cached_at) VALUES (?,?,?,?,?)',
      [
        workspaceId,
        year,
        month,
        jsonEncode(entries.map((e) => e.toJson()).toList()),
        DateTime.now().toIso8601String(),
      ],
    );
  }

  List<HistoryEntry> _decodeHistory(String payload) {
    final list = jsonDecode(payload) as List;
    return list
        .map((e) => HistoryEntry.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }
}
