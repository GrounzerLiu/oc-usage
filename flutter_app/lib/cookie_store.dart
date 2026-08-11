/// 旧版（Python）cookie 迁移：解密 %APPDATA%/oc-usage/cookie.bin。
library;

import 'dart:convert';
import 'dart:io';

import 'dpapi.dart';

/// 读取 Python 版保存的 DPAPI cookie。
/// 返回 {cookie, workspaceId}；不存在或解密失败返回 null。
Future<Map<String, String>?> loadLegacyCookie() async {
  try {
    final appData = Platform.environment['APPDATA'] ??
        '${Directory.systemTemp.path}${Platform.pathSeparator}oc-usage';
    final f = File('$appData${Platform.pathSeparator}oc-usage'
        '${Platform.pathSeparator}cookie.bin');
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
