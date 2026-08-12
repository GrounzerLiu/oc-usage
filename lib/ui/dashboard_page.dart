/// 统计主界面：头部、三层限额环形卡片、成本趋势、模型占比、用量统计。
library;

import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import 'package:oc_usage/models.dart';
import 'package:oc_usage/theme.dart';
import 'package:oc_usage/ui/widgets.dart';

class DashboardData {
  GoData? go;
  List<HistoryEntry> history = [];
  MonthStats? stats;
  List<(String, int)> modelCosts = [];
  String status = '';
  bool loading = false;
  int viewYear = 0;
  int viewMonth = 0; // 1-based

  DashboardData();

  /// 拷贝构造：ValueNotifier 对同一实例赋值不会通知监听者，
  /// 因此每次更新必须生成新实例。
  DashboardData.from(DashboardData o)
      : go = o.go,
        history = List.of(o.history),
        stats = o.stats,
        modelCosts = List.of(o.modelCosts),
        status = o.status,
        loading = o.loading,
        viewYear = o.viewYear,
        viewMonth = o.viewMonth;
}

class DashboardPage extends StatefulWidget {
  final ValueNotifier<DashboardData> data;
  final VoidCallback onRefresh;
  final VoidCallback onFullStats;
  final VoidCallback onSettings;
  final void Function(int delta) onMonthChange;

  const DashboardPage({
    super.key,
    required this.data,
    required this.onRefresh,
    required this.onFullStats,
    required this.onSettings,
    required this.onMonthChange,
  });

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  int _xLabelStep = 1;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      backgroundColor: t.colorScheme.surfaceContainerLowest,
      body: ValueListenableBuilder<DashboardData>(
        valueListenable: widget.data,
        builder: (context, d, _) {
          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _header(context, d),
                const SizedBox(height: 14),
                _limitCards(d),
                const SizedBox(height: 14),
                _costChartSection(context, d),
                const SizedBox(height: 14),
                _pieSection(context, d),
                const SizedBox(height: 14),
                _statsSection(context, d),
              ],
            ),
          );
        },
      ),
    );
  }

  // ── 头部 ──

  Widget _header(BuildContext context, DashboardData d) {
    final t = Theme.of(context);
    return Row(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Image.asset(
            'assets/opencode.png',
            width: 44,
            height: 44,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF4A6CF7), Color(0xFF8B5CF6)],
                ),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Center(
                child: Text('%',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold)),
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('OpenCode 用量',
                  style: TextStyle(
                      fontSize: 21,
                      fontWeight: FontWeight.bold,
                      color: t.colorScheme.onSurface)),
              Text(
                d.go != null
                    ? (d.go!.subscribed ? '已订阅 OpenCode Go' : '未订阅 OpenCode Go')
                    : '请稍候…',
                style: TextStyle(fontSize: 12, color: t.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        _statusChip(context, d),
        const SizedBox(width: 10),
        _ghostBtn(context, '全量统计', widget.onFullStats),
        const SizedBox(width: 8),
        IconButton.filledTonal(
          onPressed: widget.onSettings,
          icon: const Icon(Icons.settings, size: 18),
          tooltip: '设置',
          style: IconButton.styleFrom(
            padding: const EdgeInsets.all(8),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
          ),
        ),
        const SizedBox(width: 8),
        _primaryBtn(context, d.loading ? '刷新中…' : '刷新', widget.onRefresh,
            loading: d.loading),
      ],
    );
  }

  Widget _statusChip(BuildContext context, DashboardData d) {
    final t = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: t.colorScheme.surface,
        border: Border.all(color: t.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (d.loading) ...[
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: t.colorScheme.primary,
              ),
            ),
            const SizedBox(width: 6),
          ],
          Text(
            d.status.isEmpty ? '…' : d.status,
            style: TextStyle(fontSize: 12, color: t.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _ghostBtn(BuildContext context, String text, VoidCallback onTap) {
    final t = Theme.of(context);
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        foregroundColor: t.colorScheme.primary,
        side: BorderSide(color: t.colorScheme.primary.withValues(alpha: 0.5)),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
      ),
      child: Text(text,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
    );
  }

  Widget _primaryBtn(BuildContext context, String text, VoidCallback onTap,
      {bool loading = false}) {
    final t = Theme.of(context);
    return FilledButton(
      onPressed: loading ? null : onTap,
      style: FilledButton.styleFrom(
        backgroundColor: t.colorScheme.primary,
        foregroundColor: Colors.white,
        disabledBackgroundColor:
            t.colorScheme.primary.withValues(alpha: 0.6),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 9),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
      ),
      child: loading
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(width: 8),
                Text(text,
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.bold)),
              ],
            )
          : Text(text,
              style: const TextStyle(
                  fontSize: 12, fontWeight: FontWeight.bold)),
    );
  }

  // ── 限额卡片 ──

  Widget _limitCards(DashboardData d) {
    final go = d.go;
    final cards = <Widget>[
      LimitCard(
        label: '滚动用量',
        percent: go?.rolling?.usagePercent,
        resetText: go?.rolling?.resetText() ?? '—',
      ),
      LimitCard(
        label: '每周用量',
        percent: go?.weekly?.usagePercent,
        resetText: go?.weekly?.resetText() ?? '—',
      ),
      LimitCard(
        label: '每月用量',
        percent: go?.monthly?.usagePercent,
        resetText: go?.monthly?.resetText() ?? '—',
      ),
    ];
    return Row(
      children: [
        for (var i = 0; i < cards.length; i++) ...[
          if (i > 0) const SizedBox(width: 14),
          Expanded(child: cards[i]),
        ],
      ],
    );
  }

  // ── 成本趋势 ──

  Widget _costChartSection(BuildContext context, DashboardData d) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionTitle(
          '成本趋势',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _monthBtn(context, Icons.chevron_left, () => widget.onMonthChange(-1)),
              const SizedBox(width: 4),
              SizedBox(
                width: 90,
                child: Text(
                  '${d.viewYear}年${d.viewMonth}月',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.onSurface),
                ),
              ),
              const SizedBox(width: 4),
              _monthBtn(context, Icons.chevron_right, () => widget.onMonthChange(1)),
            ],
          ),
        ),
        const SizedBox(height: 10),
        CardBox(
          padding: const EdgeInsets.all(8),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              final n = _uniqueDays(d.history).length;
              _xLabelStep =
                  n <= 0 ? 1 : math.max(1, ((n * 34 + width) ~/ (width + 1)));
              return SizedBox(height: 230, child: _buildBarChart(d));
            },
          ),
        ),
      ],
    );
  }

  List<int> _uniqueDays(List<HistoryEntry> history) {
    final days = <int>{};
    for (final h in history) {
      if (h.date.length >= 10) {
        days.add(int.tryParse(h.date.substring(8, 10)) ?? 0);
      }
    }
    final list = days.where((d) => d > 0).toList()..sort();
    return list;
  }

  Widget _monthBtn(BuildContext context, IconData icon, VoidCallback onTap) {
    final t = Theme.of(context);
    return IconButton.outlined(
      onPressed: onTap,
      icon: Icon(icon, size: 18),
      tooltip: icon == Icons.chevron_left ? '上一月' : '下一月',
      style: IconButton.styleFrom(
        foregroundColor: t.colorScheme.onSurface,
        side: BorderSide(color: t.colorScheme.outlineVariant),
        padding: const EdgeInsets.all(4),
        minimumSize: const Size(28, 28),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }

  Widget _buildBarChart(DashboardData d) {
    final days = _uniqueDays(d.history);
    if (days.isEmpty) {
      return const Center(
          child: Text('暂无成本数据', style: TextStyle(color: Colors.grey)));
    }
    final byDay = <int, Map<String, double>>{};
    final models = <String>[];
    for (final h in d.history) {
      if (h.date.length < 10) continue;
      final day = int.parse(h.date.substring(8, 10));
      final map = byDay.putIfAbsent(day, () => <String, double>{});
      map[h.model] = (map[h.model] ?? 0) + h.totalCost * costToUsd;
      if (!models.contains(h.model)) models.add(h.model);
    }

    final groups = <BarChartGroupData>[];
    final rodsModels = <List<String>>[]; // 每个 group 的 rod 顺序对应模型
    final maxTotal = days
        .map((d) => byDay[d]!.values.fold(0.0, (a, b) => a + b))
        .fold(0.0, math.max);
    final dark = Theme.of(context).brightness == Brightness.dark;
    for (var i = 0; i < days.length; i++) {
      final map = byDay[days[i]] ?? {};
      final rods = <BarChartRodData>[];
      final modelOrder = <String>[];
      var acc = 0.0;
      for (final m in models) {
        final v = map[m] ?? 0;
        if (v <= 0) continue;
        final base = AppColors.modelColor(m, models.indexOf(m));
        rods.add(BarChartRodData(
          fromY: acc,
          toY: acc + v,
          width: 14,
          color: base,
          // 标准用法：垂直渐变填充
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color.lerp(base, Colors.white, dark ? 0.12 : 0.25)!,
              base,
            ],
          ),
          borderRadius: BorderRadius.zero,
        ));
        modelOrder.add(m);
        acc += v;
      }
      rodsModels.add(modelOrder);
      groups.add(BarChartGroupData(
          x: i,
          groupVertically: true,
          barRods: rods.isEmpty ? [BarChartRodData(toY: 0)] : rods));
    }
    return BarChart(
      BarChartData(
        minY: 0,
        maxY: maxTotal * 1.15,
        barGroups: groups,
        alignment: BarChartAlignment.spaceAround,
        groupsSpace: 8,
        borderData: FlBorderData(show: false),
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          getDrawingHorizontalLine: (v) => FlLine(
            color: Theme.of(context).colorScheme.outlineVariant,
            strokeWidth: 1,
          ),
        ),
        titlesData: FlTitlesData(
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 44,
              getTitlesWidget: (v, meta) => Text(
                '\$${v.toStringAsFixed(1)}',
                style: TextStyle(
                    fontSize: 10,
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ),
          ),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 26,
              getTitlesWidget: (value, meta) {
                final i = value.toInt();
                if (i < 0 || i >= days.length || i % _xLabelStep != 0) {
                  return const SizedBox.shrink();
                }
                return Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    '${days[i]}日',
                    style: TextStyle(
                        fontSize: 10,
                        color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                );
              },
            ),
          ),
        ),
        barTouchData: BarTouchData(
          touchTooltipData: BarTouchTooltipData(
            getTooltipColor: (_) => Theme.of(context).colorScheme.surface,
            getTooltipItem: (group, groupIndex, rod, rodIndex) {
              final x = group.x;
              if (x < 0 || x >= rodsModels.length) return null;
              final order = rodsModels[x];
              if (rodIndex < 0 || rodIndex >= order.length) return null;
              final map = byDay[days[x]] ?? {};
              final model = order[rodIndex];
              final v = rod.toY - rod.fromY;
              final total = map.values.fold(0.0, (a, b) => a + b);
              final pct = total > 0 ? v / total * 100 : 0.0;
              return BarTooltipItem(
                '${days[x]}日 · $model\n\$${v.toStringAsFixed(2)}（占当日 ${pct.round()}%）',
                TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurface,
                  height: 1.5,
                ),
              );
            },
          ),
        ),
      ),
      duration: Duration.zero,
    );
  }

  // ── 模型成本占比 ──

  Widget _pieSection(BuildContext context, DashboardData d) {
    final costs = d.modelCosts;
    final total = costs.fold<int>(0, (a, e) => a + e.$2);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionTitle('模型成本占比'),
        const SizedBox(height: 10),
        CardBox(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              SizedBox(
                width: 196,
                height: 176,
                child: costs.isEmpty
                    ? const Center(
                        child: Text('（无数据，等待同步）',
                            style: TextStyle(fontSize: 12, color: Colors.grey)))
                    : PieChart(
                        PieChartData(
                          sectionsSpace: 2,
                          centerSpaceRadius: 30,
                          sections: [
                            for (var i = 0; i < costs.length; i++)
                              PieChartSectionData(
                                value: costs[i].$2.toDouble(),
                                color: AppColors.modelColor(costs[i].$1, i),
                                radius: 46,
                                title: _pieLabel(costs[i].$2, total),
                                titleStyle: TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.bold,
                                  color: AppColors.readableOn(
                                      AppColors.modelColor(costs[i].$1, i)),
                                ),
                              ),
                          ],
                        ),
                      ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < costs.length; i++)
                      ModelCostRow(
                        model: costs[i].$1,
                        cost: costs[i].$2,
                        total: total,
                        index: i,
                      ),
                    Divider(
                        height: 14,
                        color: Theme.of(context).colorScheme.outlineVariant),
                    Row(
                      children: [
                        Text('总计',
                            style: TextStyle(
                                fontSize: 12,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant)),
                        const Spacer(),
                        Text(
                          '\$${(total * costToUsd).toStringAsFixed(2)}',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _pieLabel(int cost, int total) {
    final pct = total > 0 ? cost / total * 100 : 0.0;
    if (pct < 12) return '';
    return '${pct.round()}%';
  }

  // ── 用量统计 ──

  Widget _statsSection(BuildContext context, DashboardData d) {
    final stats = d.stats;
    final req = stats?.requests ?? 0;
    final tokens = stats?.tokens ?? 0;
    final days = stats?.days ?? 0;
    final avgReq = days > 0 ? req / days : 0.0;
    final avgTok = days > 0 ? tokens / days : 0.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionTitle('用量统计'),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: Tooltip(
                message: stats == null || req == 0 ? '无数据' : '总请求：$req 次',
                waitDuration: const Duration(milliseconds: 100),
                child: StatCard(
                  label: '总请求',
                  number: req == 0 ? '—' : _grouped(req),
                  sub: req == 0 ? '' : '日均 ${avgReq.toStringAsFixed(1)} 次',
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Tooltip(
                message: stats == null || tokens == 0
                    ? '无数据'
                    : '总 Token：${_grouped(tokens)}',
                waitDuration: const Duration(milliseconds: 100),
                child: StatCard(
                  label: '总 Token',
                  number: tokens == 0 ? '—' : fmtTokens(tokens),
                  sub: tokens == 0 ? '' : '日均 ${fmtTokens(avgTok)}',
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Tooltip(
                message: stats == null ? '无数据' : '覆盖 $days 天',
                waitDuration: const Duration(milliseconds: 100),
                child: StatCard(
                  label: '覆盖天数',
                  number: stats == null ? '—' : '$days',
                  sub: '有请求记录的日子',
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  String _grouped(int n) {
    final s = n.toString();
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return buf.toString();
  }
}
