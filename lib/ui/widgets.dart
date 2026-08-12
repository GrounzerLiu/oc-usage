/// 共用 UI 组件：环形进度、卡片、区块标题、模型列表行。
library;

import 'package:flutter/material.dart';

import '../theme.dart';

/// Material 3 卡片（标准 Card 组件 + M3 语义色）。
class CardBox extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? color;

  const CardBox({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(14),
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      elevation: 1,
      margin: EdgeInsets.zero,
      color: color ?? t.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: t.colorScheme.outlineVariant),
      ),
      child: Padding(padding: padding, child: child),
    );
  }
}

/// 区块标题（左侧 accent 竖条）。
class SectionTitle extends StatelessWidget {
  final String text;
  final Widget? trailing;

  const SectionTitle(this.text, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Row(
      children: [
        Container(
          width: 3,
          height: 16,
          margin: const EdgeInsets.only(right: 8),
          decoration: BoxDecoration(
            color: t.colorScheme.primary,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        Text(
          text,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            color: t.colorScheme.onSurface,
          ),
        ),
        const Spacer(),
        if (trailing != null) trailing!,
      ],
    );
  }
}

/// 环形进度（圆角弧 + 居中百分比）。percent 为 null 时显示 "—" 占位。
class RingProgress extends StatelessWidget {
  final double? percent; // null = 数据未就绪
  final Color color;
  final double size;
  final double strokeWidth;

  const RingProgress({
    super.key,
    required this.percent,
    required this.color,
    this.size = 104,
    this.strokeWidth = 9,
  });

  @override
  Widget build(BuildContext context) {
    final pct = percent;
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _RingPainter(
          percent: pct,
          color: color,
          trackColor:
              Theme.of(context).colorScheme.surfaceContainerHighest,
        ),
        child: Center(
          child: Text(
            pct == null ? '—' : '${pct.round()}%',
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.bold,
              color: pct == null
                  ? Theme.of(context).colorScheme.outline
                  : color,
            ),
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final double? percent;
  final Color color;
  final Color trackColor;

  _RingPainter({
    required this.percent,
    required this.color,
    required this.trackColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 9
      ..strokeCap = StrokeCap.butt
      ..color = trackColor;
    final rect = Rect.fromLTWH(4.5, 4.5, size.width - 9, size.height - 9);
    canvas.drawOval(rect, track);

    final pct = percent;
    if (pct == null) return;
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 9
      ..strokeCap = StrokeCap.round
      ..color = color;
    canvas.drawArc(rect, -90 * (pi180), -360 * (pct.clamp(0, 100) / 100) * (pi180), false, arc);
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) =>
      old.percent != percent || old.color != color;
}

const _pi = 3.141592653589793;
double get pi180 => _pi / 180;

/// 限额卡片：名称 + 环形进度 + 重置倒计时。
class LimitCard extends StatelessWidget {
  final String label;
  final double? percent; // null = 数据未就绪
  final String resetText;

  const LimitCard({
    super.key,
    required this.label,
    required this.percent,
    required this.resetText,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final color = AppColors.accentFor(percent ?? 0);
    return CardBox(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 1,
              color: t.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          RingProgress(percent: percent, color: color),
          const SizedBox(height: 6),
          Text(
            percent == null || resetText == '—'
                ? '—'
                : '剩余 ${(100 - percent!).round()}% · $resetText后重置',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: t.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// 统计卡片：小标签 + 大数字 + 副注。
class StatCard extends StatelessWidget {
  final String label;
  final String number;
  final String sub;
  final String? tipText; // 悬浮显示完整数字

  const StatCard({
    super.key,
    required this.label,
    required this.number,
    required this.sub,
    this.tipText,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return CardBox(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 1,
              color: t.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            number,
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: t.colorScheme.onSurface,
            ),
          ),
          Text(
            sub,
            style: TextStyle(fontSize: 11, color: t.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// 模型列表行（成本占比）。
class ModelCostRow extends StatelessWidget {
  final String model;
  final int cost;
  final int total;
  final int index;

  const ModelCostRow({
    super.key,
    required this.model,
    required this.cost,
    required this.total,
    required this.index,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final color = AppColors.modelColor(model, index);
    final pct = total > 0 ? cost / total * 100 : 0.0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              model,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: t.colorScheme.onSurface,
              ),
            ),
          ),
          Text(
            '${pct.toStringAsFixed(1)}%',
            style: TextStyle(fontSize: 12, color: t.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 64,
            child: Text(
              '\$${(cost * costToUsd).toStringAsFixed(2)}',
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: t.colorScheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
