import 'package:flutter_test/flutter_test.dart';
import 'package:webview_win_floating/webview_win_floating.dart';
import 'package:webview_win_floating/webview_win_floating_platform_interface.dart';
import 'package:webview_win_floating/webview_win_floating_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockWebviewWinFloatingPlatform
    with MockPlatformInterfaceMixin
    implements WebviewWinFloatingPlatform {

  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final WebviewWinFloatingPlatform initialPlatform = WebviewWinFloatingPlatform.instance;

  test('$MethodChannelWebviewWinFloating is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelWebviewWinFloating>());
  });

  test('getPlatformVersion', () async {
    WebviewWinFloating webviewWinFloatingPlugin = WebviewWinFloating();
    MockWebviewWinFloatingPlatform fakePlatform = MockWebviewWinFloatingPlatform();
    WebviewWinFloatingPlatform.instance = fakePlatform;

    expect(await webviewWinFloatingPlugin.getPlatformVersion(), '42');
  });
}
