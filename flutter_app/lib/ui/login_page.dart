/// 登录页：内嵌 WebView2，登录后自动检测 workspace 并回调。
library;

import 'package:flutter/material.dart';
import 'package:webview_win_floating/webview_win_floating.dart';

import '../webview_session.dart';

class LoginPage extends StatefulWidget {
  final WebSession session;
  final VoidCallback onCancelled;

  const LoginPage({
    super.key,
    required this.session,
    required this.onCancelled,
  });

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await widget.session.init();
    widget.session.controller.loadRequest(Uri.parse('https://opencode.ai/auth/authorize'));
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
