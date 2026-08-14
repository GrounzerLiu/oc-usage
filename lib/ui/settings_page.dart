/// 设置页（Material 3）：主题（SegmentedButton）、开机自启（SwitchListTile）、关于。
library;

import 'package:flutter/material.dart';

import '../settings.dart';

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

  void _setTheme(String mode) {
    widget.themeMode.value = mode;
    widget.settings.theme = mode;
    widget.settings.save();
  }

  void _setAutostart(bool v) {
    setState(() => _autostart = v);
    widget.settings.autostart = v;
    widget.settings.save();
    widget.onAutostartChanged(v);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          _sectionTitle(context, '外观'),
          const SizedBox(height: 8),
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('主题', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 12),
                  ValueListenableBuilder<String>(
                    valueListenable: widget.themeMode,
                    builder: (context, mode, _) {
                      return SegmentedButton<String>(
                        segments: const [
                          ButtonSegment(
                            value: 'system',
                            label: Text('跟随系统'),
                            icon: Icon(Icons.brightness_auto_outlined),
                          ),
                          ButtonSegment(
                            value: 'light',
                            label: Text('亮色'),
                            icon: Icon(Icons.light_mode_outlined),
                          ),
                          ButtonSegment(
                            value: 'dark',
                            label: Text('暗色'),
                            icon: Icon(Icons.dark_mode_outlined),
                          ),
                        ],
                        selected: {mode},
                        onSelectionChanged: (s) => _setTheme(s.first),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          _sectionTitle(context, '常规'),
          const SizedBox(height: 8),
          Card(
            margin: EdgeInsets.zero,
            child: SwitchListTile(
              secondary: const Icon(Icons.power_settings_new_outlined),
              title: const Text('开机自启'),
              subtitle: const Text('登录 Windows 后自动启动'),
              value: _autostart,
              onChanged: _setAutostart,
            ),
          ),
          const SizedBox(height: 20),
          _sectionTitle(context, '关于'),
          const SizedBox(height: 8),
          Card(
            margin: EdgeInsets.zero,
            child: Column(
              children: [
                ListTile(
                  leading: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Image.asset(
                      'assets/opencode.png',
                      width: 40,
                      height: 40,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) =>
                          const Icon(Icons.insights, size: 40),
                    ),
                  ),
                  title: const Text('OpenCode 用量 v1.0.2'),
                  subtitle: const Text('GitHub · GrounzerLiu/oc-usage'),
                ),
                const Divider(height: 1),
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'Windows 托盘常驻，查询 OpenCode Go 订阅用量'
                    '（滚动 / 每周 / 每月三层限额）与请求级计费明细。\n'
                    '数据来自 opencode.ai web console，无官方 API。',
                    style: TextStyle(height: 1.6),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(BuildContext context, String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 4),
      child: Text(
        text,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
      ),
    );
  }
}
