/// 设置页：主题（跟随系统/亮色/暗色）、开机自启、关于。
library;

import 'package:flutter/material.dart';

import '../settings.dart';
import 'widgets.dart';

class SettingsPage extends StatefulWidget {
  final Settings settings;
  final ValueNotifier<String> themeMode; // system / light / dark
  final ValueChanged<bool> onAutostartChanged;

  const SettingsPage({
    super.key,
    required this.settings,
    required this.themeMode,
    required this.onAutostartChanged,
  });

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _autostart = false;

  @override
  void initState() {
    super.initState();
    _autostart = widget.settings.autostart || autostartEnabled();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      backgroundColor: t.colorScheme.surfaceContainerLowest,
      appBar: AppBar(
        title: const Text('设置'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _groupTitle(context, '外观'),
            const SizedBox(height: 8),
            CardBox(
              padding: const EdgeInsets.all(12),
              child: ValueListenableBuilder<String>(
                valueListenable: widget.themeMode,
                builder: (context, mode, _) {
                  return Row(
                    children: [
                      for (final (m, label) in [
                        ('system', '跟随系统'),
                        ('light', '亮色'),
                        ('dark', '暗色'),
                      ]) ...[
                        if (m != 'system') const SizedBox(width: 10),
                        Expanded(
                          child: _themeBtn(context, label, mode == m, () {
                            widget.themeMode.value = m;
                            widget.settings.theme = m;
                            widget.settings.save();
                          }),
                        ),
                      ],
                    ],
                  );
                },
              ),
            ),
            const SizedBox(height: 16),
            _groupTitle(context, '常规'),
            const SizedBox(height: 8),
            CardBox(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: [
                  Switch(
                    value: _autostart,
                    onChanged: (v) {
                      setState(() => _autostart = v);
                      widget.settings.autostart = v;
                      widget.settings.save();
                      widget.onAutostartChanged(v);
                    },
                  ),
                  const SizedBox(width: 12),
                  Text(
                    '开机时自动启动',
                    style: TextStyle(fontSize: 13, color: t.colorScheme.onSurface),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _groupTitle(context, '关于'),
            const SizedBox(height: 8),
            CardBox(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Image.asset(
                          'assets/opencode.png',
                          width: 40,
                          height: 40,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) =>
                              const SizedBox(width: 40, height: 40),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'OpenCode 用量 v1.0.0',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: t.colorScheme.onSurface,
                            ),
                          ),
                          Text(
                            'GitHub · GrounzerLiu/oc-usage',
                            style: TextStyle(
                              fontSize: 12,
                              color: t.colorScheme.primary,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Windows 托盘常驻，查询 OpenCode Go 订阅用量'
                    '（滚动 / 每周 / 每月三层限额）与 Zen 请求级计费明细。\n'
                    '数据来自 opencode.ai web console，无官方 API。',
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.6,
                      color: t.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _groupTitle(BuildContext context, String text) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 4),
      child: Text(
        text,
        style: t.textTheme.titleSmall?.copyWith(
          color: t.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _themeBtn(
      BuildContext context, String label, bool selected, VoidCallback onTap) {
    final t = Theme.of(context);
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        foregroundColor: selected ? Colors.white : t.colorScheme.onSurface,
        backgroundColor: selected
            ? t.colorScheme.primary
            : t.colorScheme.surfaceContainerHighest,
        side: selected
            ? BorderSide(color: t.colorScheme.primary)
            : BorderSide(color: t.colorScheme.outlineVariant),
        padding: const EdgeInsets.symmetric(vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      child: Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
    );
  }
}

/// 自绘滑块开关。
class _Switch extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;

  const _Switch({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return GestureDetector(
      onTap: () => onChanged(!value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOutCubic,
        width: 46,
        height: 24,
        decoration: BoxDecoration(
          color: value ? t.colorScheme.primary : t.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: t.colorScheme.outlineVariant),
        ),
        child: AnimatedAlign(
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOutCubic,
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: 18,
            height: 18,
            margin: const EdgeInsets.all(2),
            decoration: const BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 2)],
            ),
          ),
        ),
      ),
    );
  }
}
