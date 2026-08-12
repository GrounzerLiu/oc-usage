/// 登录页：探测登录态（自动进入统计页），未登录时显示 WebView2 授权页。
///
/// 探测期间显示加载遮罩，避免闪现无效页面（如 /workspace 的 404）。
library;

import 'package:flutter/material.dart';
import 'package:webview_win_floating/webview_win_floating.dart';

import '../cookie_store.dart';
import '../logger.dart';
import '../webview_session.dart';

class LoginPage extends StatefulWidget {
  final WebSession session;
  final void Function(String workspaceId) onLoggedIn;
  final VoidCallback onCancelled;

  const LoginPage({
    super.key,
    required this.session,
    required this.onLoggedIn,
    required this.onCancelled,
  });

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  bool _probed = false;
  bool _showWebView = false; // 探测完成前隐藏 WebView（避免 404 闪现）

  @override
  void initState() {
    super.initState();
    _probe();
  }

  /// 优先用旧 cookie 直接登录；无有效会话则显示授权页。
  Future<void> _probe() async {
    if (_probed) return;
    _probed = true;
    await widget.session.init();
    AppLog.i('登录页：探测登录态');

    final legacy = await CookieStore.load();
    if (legacy != null && legacy['cookie']!.isNotEmpty) {
      AppLog.i('发现旧 cookie，通过 CookieManager 注入');
      final ok = await widget.session
          .setCookie('.opencode.ai', 'auth', legacy['cookie']!);
      AppLog.i('注入结果: $ok');
      await Future<void>.delayed(const Duration(seconds: 1));
      final wid = legacy['workspaceId'] ?? '';
      if (wid.isNotEmpty) {
        // 直接加载有效的 go 页面验证会话
        await widget.session.loadAndWait(
          'https://opencode.ai/workspace/$wid/go',
          timeout: const Duration(seconds: 15),
        );
        final probe = await widget.session.evalJsAsync(
          fetchTextScript('/workspace/$wid/go', 'GET'),
          timeout: const Duration(seconds: 12),
        );
        if (probe != null && probe.contains('"status":200')) {
          AppLog.i('旧 cookie 有效，直接进入 workspace=$wid');
          if (mounted) widget.onLoggedIn(wid);
          return;
        }
      }
    }

    AppLog.i('无有效会话，显示登录页');
    if (!mounted) return;
    setState(() => _showWebView = true);
    if (mounted) {
      await widget.session.controller
          .loadRequest(Uri.parse('https://opencode.ai/auth/authorize'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      backgroundColor: t.colorScheme.surfaceContainerLowest,
      body: Stack(
        children: [
          // WebView 在探测期间隐藏
          if (_showWebView)
            Column(
              children: [
                Container(
                  width: double.infinity,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  color: const Color(0xFFF0F4FF),
                  child: Row(
                    children: [
                      const Text(
                        '请登录 OpenCode Console（Google 或邮箱）',
                        style:
                            TextStyle(fontSize: 12, color: Color(0xFF333333)),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: widget.onCancelled,
                        child: const Text('取消',
                            style: TextStyle(fontSize: 12)),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: WinWebViewWidget(
                    controller: widget.session.controller,
                  ),
                ),
              ],
            )
          else
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(strokeWidth: 3),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '正在连接…',
                    style: TextStyle(
                      fontSize: 13,
                      color: t.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
