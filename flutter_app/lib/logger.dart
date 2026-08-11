/// 简易文件日志：%APPDATA%/oc-usage/app.log（追加写入）。
library;

import 'dart:io';

import 'settings.dart';

class AppLog {
  static IOSink? _sink;

  static Future<void> init() async {
    try {
      final dir = await ocUsageDir();
      _sink = File(
        '${dir.path}${Platform.pathSeparator}app.log',
      ).openWrite(mode: FileMode.append);
    } catch (_) {}
  }

  static void i(String msg) {
    final line = '[${DateTime.now().toIso8601String()}] $msg';
    print(line);
    try {
      _sink?.writeln(line);
      _sink?.flush();
    } catch (_) {}
  }

  static void e(String msg, [Object? err, StackTrace? stack]) {
    var line = '[${DateTime.now().toIso8601String()}] [ERROR] $msg';
    if (err != null) line += '\n  $err';
    if (stack != null) line += '\n  $stack';
    print(line);
    try {
      _sink?.writeln(line);
      _sink?.flush();
    } catch (_) {}
  }

  static void close() {
    try {
      _sink?.close();
    } catch (_) {}
    _sink = null;
  }
}
