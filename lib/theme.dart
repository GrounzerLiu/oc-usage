import 'dart:ui';

/// cost 原始单位 → 美元（与网页一致：totalCost × 1e-8）。
const double costToUsd = 1e-8;

/// 图表与语义色（主题色由 Material 3 ColorScheme 原生派生）。
class AppColors {
  // ── 用量状态色 ──
  static const ok = Color(0xFF10B981); // emerald-500
  static const warn = Color(0xFFF59E0B); // amber-500
  static const danger = Color(0xFFEF4444); // red-500

  // ── 模型分类色板（高区分度，亮/暗主题通用） ──
  static const modelColors = <String, Color>{
    'deepseek-v4-flash': Color(0xFF10B981), // emerald
    'deepseek-v4-pro': Color(0xFFF59E0B), // amber
    'gpt-5.6-luna': Color(0xFF3B82F6), // blue
    'mimo-v2.5': Color(0xFFEC4899), // pink
  };
  static const fallbackColors = <Color>[
    Color(0xFF14B8A6), // teal
    Color(0xFF8B5CF6), // violet
    Color(0xFFEF4444), // red
    Color(0xFF06B6D4), // cyan
    Color(0xFF84CC16), // lime
    Color(0xFF94A3B8), // slate
  ];

  static Color modelColor(String model, int index) =>
      modelColors[model] ?? fallbackColors[index % fallbackColors.length];

  /// 按底色亮度选文字色：亮底深字、暗底白字。
  static Color readableOn(Color bg) {
    final lum = 0.299 * bg.r * 255 + 0.587 * bg.g * 255 + 0.114 * bg.b * 255;
    return lum > 165 ? const Color(0xFF1B2233) : const Color(0xFFFFFFFF);
  }

  static Color accentFor(double pct) {
    if (pct >= 80) return danger;
    if (pct >= 50) return warn;
    return ok;
  }
}

/// 大数中文格式：2.35亿 / 5678万 / 890。
String fmtTokens(num n) {
  if (n >= 1e8) return '${(n / 1e8).toStringAsFixed(2)}亿';
  if (n >= 1e4) return '${(n / 1e4).toStringAsFixed(2)}万';
  return n.round().toString();
}
