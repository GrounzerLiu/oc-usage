/// 登录页：探测登录态（自动进入统计页），未登录时显示 WebView2 授权页。
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
  static final _workspaceRe = RegExp(r'/workspace/(wrk_[A-Za-z0-9]+)');
  bool _probed = false;

  @override
  void initState() {
    super.initState();
    _probe();
  }

  /// 访问 /workspace 并轮询 SPA 跳转：已有会话自动进入统计页，
  /// 无会话则加载授权页让用户登录。
  ///
  /// 注意：WebView2 在页面导航中调用 executeJavaScript 会挂起，
  /// 必须先 loadAndWait 等待加载完成再求值。
  Future<void> _probe() async {
    if (_probed) return;
    _probed = true;
    await widget.session.init();
    AppLog.i('登录页：探测登录态');
    if (await _tryProbe('https://opencode.ai/workspace')) return;

    // 未登录：尝试注入旧版（Python）cookie 后直接验证
    final legacy = await loadLegacyCookie();
    if (legacy != null) {
      AppLog.i('发现旧 cookie，通过 CookieManager 注入');
      final ok = await widget.session.setCookie(
        '.opencode.ai',
        'auth',
        legacy['cookie']!,
      );
      AppLog.i('注入结果: $ok');
      await Future<void>.delayed(const Duration(seconds: 1));
      final check = await widget.session.evalJs('document.cookie');
      AppLog.i('注入后 document.cookie 长度: ${check?.length ?? -1}');
      // 用同源 fetch 请求 go 页面验证 cookie 是否被服务端接受
      final legacyWid = legacy['workspaceId'] ?? '';
      final probe = await widget.session.evalJsAsync(
        fetchTextScript('/workspace/$legacyWid/go', 'GET'),
        timeout: const Duration(seconds: 12),
      );
      AppLog.i('go 页面探测: ${probe?.substring(0, (probe?.length ?? 0) > 120 ? 120 : (probe?.length ?? 0))}');
      if (probe != null &&
          probe.contains('"status":200') &&
          legacyWid.isNotEmpty) {
        AppLog.i('旧 cookie 有效，直接进入 workspace=$legacyWid');
        if (mounted) widget.onLoggedIn(legacyWid);
        return;
      }
      if (await _tryProbe('https://opencode.ai/workspace')) return;
    }

    AppLog.i('未登录，加载授权页');
    if (mounted) {
      await widget.session.controller
          .loadRequest(Uri.parse('https://opencode.ai/auth/authorize'));
    }
  }

  /// 加载 URL 并轮询 SPA 跳转，返回是否已登录。
  ///
  /// 注意：WebView2 在页面导航中调用 executeJavaScript 会挂起，
  /// 必须先 loadAndWait 等待加载完成再求值。
  Future<bool> _tryProbe(String url) async {
    await widget.session.loadAndWait(url, timeout: const Duration(seconds: 15));
    for (var i = 0; i < 24; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final href = await widget.session.evalJs('location.href');
      if (href == null || href.isEmpty) continue;
      final m = _workspaceRe.firstMatch(href);
      if (m != null) {
        AppLog.i('探测到已登录 workspace=${m.group(1)}');
        if (mounted) widget.onLoggedIn(m.group(1)!);
        return true;
      }
      if (href.contains('/auth/')) {
        return false;
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: const Color(0xFFF0F4FF),
            child: Row(
              children: [
                const Text(
                  '请登录 OpenCode Console（Google 或邮箱）',
                  style: TextStyle(fontSize: 12, color: Color(0xFF333333)),
                ),
                const Spacer(),
                TextButton(
                  onPressed: widget.onCancelled,
                  child: const Text('取消', style: TextStyle(fontSize: 12)),
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
      ),
    );
  }
}
