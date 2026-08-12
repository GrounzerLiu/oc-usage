/// 简易文件日志：%APPDATA%/oc-usage/app.log（同步追加，可靠落盘）。
library;

import 'dart:io';

import 'settings.dart';

class AppLog {
  static String? _path;

  static Future<void> init() async {
    try {
      final dir = await ocUsageDir();
      _path = '${dir.path}${Platform.pathSeparator}app.log';
    } catch (_) {}
  }

  static void i(String msg) => _write('', msg);

  static void e(String msg, [Object? err, StackTrace? stack]) {
    var line = '[ERROR] $msg';
    if (err != null) line += '\n  $err';
    if (stack != null) line += '\n  $stack';
    _write('[ERROR]', msg, extra: line);
  }

  static void _write(String tag, String msg, {String? extra}) {
    final line =
        '[${DateTime.now().toIso8601String()}] ${tag.isEmpty ? '' : '$tag '}$msg';
    print(line);
    final path = _path;
    if (path == null) return;
    try {
      final f = File(path);
      f.writeAsStringSync('$line\n', mode: FileMode.append);
      if (extra != null) {
        f.writeAsStringSync('$extra\n', mode: FileMode.append);
      }
    } catch (_) {}
  }

  static void close() {}
}
