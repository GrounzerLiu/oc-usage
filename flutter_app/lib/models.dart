/// 数据模型（移植自 Python 版 ocusage/models.py）。
library;

import 'theme.dart';

class UsageWindow {
  final String label;
  final double usagePercent;
  final int resetInSec;

  UsageWindow({
    required this.label,
    required this.usagePercent,
    required this.resetInSec,
  });

  double get remainingPercent => (100 - usagePercent).clamp(0, 100);

  String resetText() {
    final s = resetInSec < 0 ? 0 : resetInSec;
    final days = s ~/ 86400;
    final hours = (s % 86400) ~/ 3600;
    final minutes = (s % 3600) ~/ 60;
    if (days > 0) return '$days 天 $hours 小时';
    if (hours > 0) return '$hours 小时 $minutes 分钟';
    return '$minutes 分钟';
  }

  factory UsageWindow.fromJson(Map<String, dynamic> j, String label) =>
      UsageWindow(
        label: label,
        usagePercent: (j['usagePercent'] as num?)?.toDouble() ?? 0,
        resetInSec: (j['resetInSec'] as num?)?.toInt() ?? 0,
      );
}

class GoData {
  final bool subscribed;
  final UsageWindow? rolling;
  final UsageWindow? weekly;
  final UsageWindow? monthly;
  final double? balance;

  GoData({
    required this.subscribed,
    this.rolling,
    this.weekly,
    this.monthly,
    this.balance,
  });

  List<String> summaryLines() {
    final lines = <String>[];
    if (subscribed) {
      for (final w in [rolling, weekly, monthly]) {
        if (w != null) {
          lines.add(
            '${w.label}：已用 ${w.usagePercent.round()}%'
            '（剩 ${w.remainingPercent.round()}%，${w.resetText()} 后重置）',
          );
        }
      }
    } else {
      lines.add('未订阅 Go');
    }
    return lines;
  }
}

class UsageRecord {
  final String id;
  final String timeCreated;
  final String model;
  final String provider;
  final int inputTokens;
  final int outputTokens;
  final int reasoningTokens;
  final int cacheReadTokens;
  final int cost;
  final String keyId;

  UsageRecord({
    required this.id,
    required this.timeCreated,
    required this.model,
    required this.provider,
    required this.inputTokens,
    required this.outputTokens,
    required this.reasoningTokens,
    required this.cacheReadTokens,
    required this.cost,
    required this.keyId,
  });

  int get totalTokens =>
      inputTokens + outputTokens + reasoningTokens + cacheReadTokens;

  double get costUsd => cost * costToUsd;

  factory UsageRecord.fromRaw(dynamic r) {
    final m = (r is Map<String, dynamic>) ? r : <String, dynamic>{};
    return UsageRecord(
      id: '${m['id'] ?? ''}',
      timeCreated: '${m['timeCreated'] ?? ''}',
      model: '${m['model'] ?? ''}',
      provider: '${m['provider'] ?? ''}',
      inputTokens: (m['inputTokens'] as num?)?.toInt() ?? 0,
      outputTokens: (m['outputTokens'] as num?)?.toInt() ?? 0,
      reasoningTokens: (m['reasoningTokens'] as num?)?.toInt() ?? 0,
      cacheReadTokens: (m['cacheReadTokens'] as num?)?.toInt() ?? 0,
      cost: (m['cost'] as num?)?.toInt() ?? 0,
      keyId: '${m['keyID'] ?? ''}',
    );
  }
}

class HistoryEntry {
  final String date; // YYYY-MM-DD
  final String model;
  final int totalCost;

  HistoryEntry({
    required this.date,
    required this.model,
    required this.totalCost,
  });

  factory HistoryEntry.fromJson(Map<String, dynamic> j) => HistoryEntry(
        date: '${j['date'] ?? ''}',
        model: '${j['model'] ?? ''}',
        totalCost: (j['totalCost'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() =>
      {'date': date, 'model': model, 'totalCost': totalCost};
}

class MonthStats {
  final int requests;
  final int tokens;
  final int days;

  MonthStats({required this.requests, required this.tokens, required this.days});
}
