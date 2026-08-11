import 'dart:ui';

/// 全局主题色（亮/暗两套）。
///
/// 配色方案：Slate 中性背景 + 蓝→紫渐变主色（参考 Tailwind/CoreUI 2026 趋势），
/// 模型分类色板借鉴 Cloudscape/IBM Carbon 的高区分度 5 色序。
class AppColors {
  // ── 亮色 ──
  static const lightBg = Color(0xFFF8FAFC); // slate-50
  static const lightSurface = Color(0xFFFFFFFF);
  static const lightCardAlt = Color(0xFFF1F5F9); // slate-100
  static const lightBorder = Color(0xFFE2E8F0); // slate-200
  static const lightText = Color(0xFF0F172A); // slate-900
  static const lightSub = Color(0xFF64748B); // slate-500
  static const lightFaint = Color(0xFF94A3B8); // slate-400
  static const lightBarBg = Color(0xFFE2E8F0);
  static const lightAccent = Color(0xFF2563EB); // blue-600
  static const lightAccentEnd = Color(0xFF7C3AED); // violet-600

  // ── 暗色 ──
  static const darkBg = Color(0xFF0F172A); // slate-900
  static const darkSurface = Color(0xFF1E293B); // slate-800
  static const darkCardAlt = Color(0xFF263348); // slate-700/800 之间
  static const darkBorder = Color(0xFF334155); // slate-700
  static const darkText = Color(0xFFF1F5F9); // slate-100
  static const darkSub = Color(0xFF94A3B8); // slate-400
  static const darkFaint = Color(0xFF64748B); // slate-500
  static const darkBarBg = Color(0xFF334155);
  static const darkAccent = Color(0xFF3B82F6); // blue-500
  static const darkAccentEnd = Color(0xFF8B5CF6); // violet-500

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

/// cost 原始单位 → 美元（与网页一致：totalCost × 1e-8）。
const double costToUsd = 1e-8;
