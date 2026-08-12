/// 用户设置：主题、开机自启；WebView2 用户数据目录。
///
/// - settings.json 存 %APPDATA%/oc-usage/settings.json
/// - 开机自启写 HKCU 注册表 Run 启动项
library;

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:win32_registry/win32_registry.dart';

class Settings {
  String theme = 'system'; // system / dark / light
  bool autostart = false;

  Future<File> _file() async {
    final dir = await ocUsageDir();
    return File('${dir.path}${Platform.pathSeparator}settings.json');
  }

  Future<void> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return;
      final data = jsonDecode(await f.readAsString());
      if (data is Map<String, dynamic>) {
        theme = data['theme'] ?? 'system';
        autostart = data['autostart'] == true;
      }
    } catch (_) {}
  }

  Future<void> save() async {
    try {
      final f = await _file();
      await f.parent.create(recursive: true);
      await f.writeAsString(
        jsonEncode({'theme': theme, 'autostart': autostart}),
      );
    } catch (_) {}
  }
}

/// %APPDATA%/oc-usage（设置、WebView2 用户数据等）。
Future<Directory> ocUsageDir() async {
  final appData = await getApplicationSupportDirectory();
  // path_provider 在 Windows 返回 %APPDATA%/<appname>；这里统一用 oc-usage
  final dir = Directory(
    '${appData.path}${Platform.pathSeparator}oc-usage',
  );
  await dir.create(recursive: true);
  return dir;
}

const _runKeyPath = r'Software\Microsoft\Windows\CurrentVersion\Run';
const _runValueName = 'oc-usage';

String _autostartCommand() {
  final exe = Platform.resolvedExecutable;
  final script =
      '${Directory.current.path}${Platform.pathSeparator}main.dart';
  // 打包后 main.dart 不存在，用 exe 自身
  if (!File(script).existsSync()) return '"$exe"';
  final dart = Platform.resolvedExecutable;
  return '"$dart" run "$script"';
}

void setAutostart(bool enabled) {
  final runKey = CURRENT_USER.open(
    _runKeyPath,
    config: const RegistryOpenConfig(
      access: RegistryAccess.all,
      create: true,
    ),
  );
  try {
    if (enabled) {
      runKey.setValue(_runValueName, RegistryValue.string(_autostartCommand()));
    } else {
      try {
        runKey.removeValue(_runValueName);
      } catch (_) {}
    }
  } finally {
    runKey.close();
  }
}

bool autostartEnabled() {
  try {
    final runKey = CURRENT_USER.open(
      _runKeyPath,
      config: const RegistryOpenConfig(access: RegistryAccess.read),
    );
    try {
      return runKey.getValue(_runValueName) != null;
    } finally {
      runKey.close();
    }
  } catch (_) {
    return false;
  }
}
