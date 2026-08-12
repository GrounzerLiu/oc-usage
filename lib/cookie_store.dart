/// 登录态 cookie 存取：WebView2 捕获 → DPAPI 加密存 %APPDATA%/oc-usage/cookie.bin。
///
/// 与 Python 版同格式、同路径（{"cookie", "workspaceId"}），登录后自动续期。
library;

import 'dart:convert';
import 'dart:io';

import 'dpapi.dart';

/// 与 Python 版共用的 cookie 文件位置。
String cookieFilePath() {
  final appData = Platform.environment['APPDATA'] ??
      '${Directory.systemTemp.path}${Platform.pathSeparator}oc-usage';
  return '$appData${Platform.pathSeparator}oc-usage'
      '${Platform.pathSeparator}cookie.bin';
}

class CookieStore {
  /// 保存 cookie（DPAPI 加密，与 Python 版兼容）。
  static Future<void> save(String cookie, String workspaceId) async {
    try {
      final f = File(cookieFilePath());
      await f.parent.create(recursive: true);
      final payload = utf8.encode(jsonEncode({
        'cookie': cookie,
        'workspaceId': workspaceId,
      }));
      await f.writeAsBytes(dpapiProtect(payload));
    } catch (_) {}
  }

  /// 读取并解密 cookie；不存在或失败返回 null。
  static Future<Map<String, String>?> load() async {
    try {
      final f = File(cookieFilePath());
      if (!await f.exists()) return null;
      final decrypted = dpapiUnprotect(await f.readAsBytes());
      final data = jsonDecode(utf8.decode(decrypted)) as Map<String, dynamic>;
      final cookie = data['cookie'];
      if (cookie is! String || cookie.isEmpty) return null;
      return {
        'cookie': cookie,
        'workspaceId': '${data['workspaceId'] ?? ''}',
      };
    } catch (_) {
      return null;
    }
  }
}
