import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 崩溃/异常日志落盘工具
///
/// release 包没有控制台可看，全局错误兜底捕获到的异常统一追加写入
/// 应用支持目录下的 crash_log.txt，供复现后导出诊断。文件超过
/// 256KB 时截断保留后半部分，避免无限膨胀。
class CrashLog {
  CrashLog._();

  static File? _logFile;
  static bool _initFailed = false;
  static const int _maxBytes = 256 * 1024;

  static Future<void> init() async {
    if (_logFile != null || _initFailed) return;
    try {
      final dir = await getApplicationSupportDirectory();
      _logFile = File('${dir.path}/crash_log.txt');
    } catch (e) {
      _initFailed = true;
      debugPrint('[CrashLog] init failed: $e');
    }
  }

  /// 追加一条异常记录（失败静默，绝不影响主流程）
  static Future<void> record(String tag, Object error, [StackTrace? stack]) async {
    final file = _logFile;
    if (file == null) return;
    try {
      final buffer = StringBuffer()
        ..writeln('===== ${DateTime.now().toIso8601String()} [$tag] =====')
        ..writeln(error);
      if (stack != null) buffer.writeln(stack);
      await file.writeAsString(buffer.toString(), mode: FileMode.append, flush: true);
      await _truncateIfNeeded(file);
    } catch (_) {
      // 日志写入本身失败不处理
    }
  }

  static Future<void> _truncateIfNeeded(File file) async {
    try {
      final length = await file.length();
      if (length <= _maxBytes) return;
      final content = await file.readAsString();
      await file.writeAsString(content.substring(content.length - _maxBytes ~/ 2));
    } catch (_) {}
  }
}
