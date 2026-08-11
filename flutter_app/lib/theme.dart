import 'dart:ui';

/// 全局主题色（亮/暗两套，风格与 Python 版一致）。
class AppColors {
  // ── 亮色 ──
  static const lightBg = Color(0xFFF8F9FD);
  static const lightSurface = Color(0xFFFFFFFF);
  static const lightCardAlt = Color(0xFFF6F8FF);
  static const lightBorder = Color(0xFFE7EBF4);
  static const lightText = Color(0xFF1B2233);
  static const lightSub = Color(0xFF6A7490);
  static const lightFaint = Color(0xFF9AA3BA);
  static const lightBarBg = Color(0xFFE9EDF7);
  static const lightAccent = Color(0xFF4A6CF7);
  static const lightAccentEnd = Color(0xFF8B5CF6);

  // ── 暗色 ──
  static const darkBg = Color(0xFF0E1118);
  static const darkSurface = Color(0xFF161B28);
  static const darkCardAlt = Color(0xFF1C2233);
  static const darkBorder = Color(0xFF272E42);
  static const darkText = Color(0xFFE8ECF6);
  static const darkSub = Color(0xFF8E97AD);
  static const darkFaint = Color(0xFF5F6880);
  static const darkBarBg = Color(0xFF232A3D);
  static const darkAccent = Color(0xFF6A8CFF);
  static const darkAccentEnd = Color(0xFF8B5CF6);

  // ── 用量状态色 ──
  static const ok = Color(0xFF2ECC71);
  static const warn = Color(0xFFE67E22);
  static const danger = Color(0xFFE74C3C);

  // ── 模型色板 ──
  static const modelColors = <String, Color>{
    'deepseek-v4-flash': Color(0xFF10B981),
    'deepseek-v4-pro': Color(0xFF8B5CF6),
    'gpt-5.6-luna': Color(0xFF3B82F6),
    'mimo-v2.5': Color(0xFF06B6D4),
  };
  static const fallbackColors = <Color>[
    Color(0xFFF59E0B),
    Color(0xFFEC4899),
    Color(0xFFF97316),
    Color(0xFF6366F1),
    Color(0xFF14B8A6),
    Color(0xFFA3A3A3),
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

/// cost 原始单位 → 美元（与网页一致：totalCost × 1e-8）。
const double costToUsd = 1e-8;
