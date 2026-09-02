// 应用内更新服务：从 Supabase Storage 公共桶读取 latest.json 检查新版本，
// 下载 APK 安装包（带进度回调）并拉起系统安装器。
// 二进制不占用 Supabase 存储额度：latest.json 中 url 指向实际托管地址
// （GitHub Releases / R2 等），Supabase 只承担「版本公告牌」角色。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

/// Supabase Storage 公共桶 releases 下的版本元数据地址
const String _latestJsonUrl =
    'https://jnwhpbkhvumiyjwyjwhu.supabase.co/storage/v1/object/public/releases/latest.json';

/// 单次检查更新请求超时
const Duration _checkTimeout = Duration(seconds: 10);

/// 版本元数据（latest.json 字段）
class AppUpdateInfo {
  final String version; // 最新版本号，如 '1.0.7'
  final String url; // APK 下载地址
  final String? notes; // 更新说明
  final bool force; // 是否强制更新（预留）
  final int? apkSize; // 安装包大小（字节，可选）

  AppUpdateInfo({
    required this.version,
    required this.url,
    this.notes,
    this.force = false,
    this.apkSize,
  });

  factory AppUpdateInfo.fromJson(Map<String, dynamic> json) => AppUpdateInfo(
        version: json['version']?.toString() ?? '',
        url: json['url']?.toString() ?? '',
        notes: json['notes']?.toString(),
        force: json['force'] == true,
        apkSize: json['apkSize'] is num ? (json['apkSize'] as num).toInt() : null,
      );
}

/// 检查结果
class UpdateCheckResult {
  final bool hasUpdate; // 是否有新版本
  final AppUpdateInfo? info; // 最新版本信息（检查成功时）
  final String? error; // 检查失败的错误信息

  UpdateCheckResult({required this.hasUpdate, this.info, this.error});
}

class UpdateService {
  /// 比较语义化版本号（如 '1.0.7' > '1.0.6'；'1.10.0' > '1.9.0'）
  static int compareVersions(String a, String b) {
    List<int> parse(String v) => v
        .trim()
        .split(RegExp(r'[+.\-]'))
        .where((s) => s.isNotEmpty)
        .map((s) => int.tryParse(s) ?? 0)
        .toList();
    final pa = parse(a);
    final pb = parse(b);
    final len = pa.length > pb.length ? pa.length : pb.length;
    for (int i = 0; i < len; i++) {
      final x = i < pa.length ? pa[i] : 0;
      final y = i < pb.length ? pb[i] : 0;
      if (x != y) return x.compareTo(y);
    }
    return 0;
  }

  /// 检查更新：拉取 latest.json 并与当前版本比较。
  /// 失败时返回 error（不抛异常），调用方据此显示「检查失败」。
  static Future<UpdateCheckResult> checkForUpdate(String currentVersion) async {
    try {
      final resp = await http
          .get(Uri.parse(_latestJsonUrl))
          .timeout(_checkTimeout);
      if (resp.statusCode != 200) {
        return UpdateCheckResult(
            hasUpdate: false, error: '服务器返回 ${resp.statusCode}');
      }
      final Map<String, dynamic> json =
          jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      final info = AppUpdateInfo.fromJson(json);
      if (info.version.isEmpty || info.url.isEmpty) {
        return UpdateCheckResult(hasUpdate: false, error: '版本信息格式错误');
      }
      final hasUpdate = compareVersions(info.version, currentVersion) > 0;
      return UpdateCheckResult(hasUpdate: hasUpdate, info: info);
    } on TimeoutException {
      return UpdateCheckResult(hasUpdate: false, error: '检查超时，请稍后重试');
    } catch (e) {
      return UpdateCheckResult(hasUpdate: false, error: '网络连接失败');
    }
  }

  /// 安装包本地文件名：coursehub_<版本号>.<url 扩展名或 .apk>，
  /// 仅保留文件名安全字符。下载落盘与本地检测共用，保证一致。
  static String _installerFileName(AppUpdateInfo info) {
    final String urlName =
        Uri.tryParse(info.url)?.pathSegments.lastOrNull ?? '';
    final String ext = urlName.contains('.')
        ? urlName.substring(urlName.lastIndexOf('.'))
        : '.apk';
    return 'coursehub_${info.version}$ext'
        .replaceAll(RegExp(r'[^0-9A-Za-z._]'), '_');
  }

  /// 检测本地是否已有该版本的完整安装包，有则返回路径（跳过重复下载）。
  /// 只有经 .part 完整落盘后改名的文件才会被命中，中断残留不会误判；
  /// 元数据带 apkSize 时额外校验文件大小。
  static Future<String?> findLocalInstaller(AppUpdateInfo info) async {
    try {
      final dir = await getTemporaryDirectory();
      final file = File(
          '${dir.path}${Platform.pathSeparator}${_installerFileName(info)}');
      if (!file.existsSync()) return null;
      if (info.apkSize != null && file.lengthSync() != info.apkSize) {
        return null;
      }
      return file.path;
    } catch (e) {
      debugPrint('findLocalInstaller error: $e');
      return null;
    }
  }

  /// 下载 APK 到应用缓存目录，返回本地文件路径。
  /// [onProgress] 回调 (已下载字节, 总字节)，取消下载请传入 [cancelToken]。
  /// 先写 .part 临时文件、完整落盘后改名为正式文件名，
  /// 保证「本地已有安装包」检测只命中完整文件。
  static Future<String?> downloadApk(
    AppUpdateInfo info, {
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final client = http.Client();
    File partFile = File('');
    try {
      final request = http.Request('GET', Uri.parse(info.url));
      final resp = await client.send(request);

      if (resp.statusCode != 200) {
        debugPrint('downloadApk: HTTP ${resp.statusCode}');
        return null;
      }

      final total = resp.contentLength ?? 0;
      final dir = await getTemporaryDirectory();
      final fileName = _installerFileName(info);
      final finalFile = File('${dir.path}${Platform.pathSeparator}$fileName');
      partFile = File('${finalFile.path}.part');
      final sink = partFile.openWrite();
      int received = 0;
      List<int> buffer = [];

      await for (final chunk in resp.stream) {
        if (cancelToken?.isCancelled ?? false) {
          await sink.close();
          await partFile.delete().catchError((_) => partFile);
          return null;
        }
        buffer.addAll(chunk);
        // 分块刷盘：避免每 chunk 一次 await 造成微任务堆积
        if (buffer.length >= 64 * 1024) {
          sink.add(buffer);
          buffer = [];
        }
        received += chunk.length;
        onProgress?.call(received, total);
      }
      if (buffer.isNotEmpty) sink.add(buffer);
      await sink.flush();
      await sink.close();
      // 完整落盘后才转正；目标已存在（旧版本残留）先移除，
      // Windows 下 rename 不会覆盖已有文件
      if (finalFile.existsSync()) {
        await finalFile.delete().catchError((_) => finalFile);
      }
      try {
        await partFile.rename(finalFile.path);
      } catch (_) {
        // 跨卷等场景 rename 失败时退化为复制
        await partFile.copy(finalFile.path);
        await partFile.delete().catchError((_) => partFile);
      }
      return finalFile.path;
    } catch (e) {
      debugPrint('downloadApk error: $e');
      // 失败时清掉半成品，避免下次被「本地已有」检测误命中
      if (partFile.existsSync()) {
        await partFile.delete().catchError((_) => partFile);
      }
      return null;
    } finally {
      client.close();
    }
  }

  /// 拉起系统安装器（Android）。非 Android 平台不支持，返回 false。
  static Future<bool> installApk(String filePath) async {
    if (!Platform.isAndroid) return false;
    final result = await OpenFilex.open(filePath,
        type: 'application/vnd.android.package-archive');
    return result.type == ResultType.done;
  }

  /// 桌面平台直接运行已下载的安装包：
  /// Windows 下 .exe 直接启动，其余（.msi 等）按系统文件关联打开；
  /// macOS 用 open，Linux 用 xdg-open。返回是否成功启动。
  static Future<bool> launchInstaller(String filePath) async {
    try {
      if (Platform.isWindows) {
        if (filePath.toLowerCase().endsWith('.exe')) {
          await Process.start(filePath, [], mode: ProcessStartMode.detached);
        } else {
          // start 的第一个参数是窗口标题占位，路径含空格也不会被拆分
          await Process.run('cmd', ['/c', 'start', '', filePath]);
        }
        return true;
      }
      if (Platform.isMacOS) {
        await Process.run('open', [filePath]);
        return true;
      }
      if (Platform.isLinux) {
        await Process.run('xdg-open', [filePath]);
        return true;
      }
    } catch (e) {
      debugPrint('launchInstaller error: $e');
    }
    return false;
  }

  /// 非 Android 平台：用系统浏览器打开下载页
  static Future<void> openInBrowser(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  /// 安装包启动成功后自动清理本地文件：安装进程可能仍占用着安装包，
  /// 每隔几秒重试删除，直至成功或超过重试上限（后台静默执行，无需等待）。
  static Future<void> deleteInstallerLater(
    String filePath, {
    int maxRetries = 6,
  }) async {
    for (var i = 0; i < maxRetries; i++) {
      await Future<void>.delayed(const Duration(seconds: 5));
      try {
        final file = File(filePath);
        if (!file.existsSync()) return;
        await file.delete();
        debugPrint('deleteInstaller: cleaned $filePath');
        return;
      } catch (_) {
        // 文件仍被安装进程占用，稍后重试
      }
    }
    debugPrint('deleteInstaller: gave up on $filePath');
  }

  /// 在系统文件管理器中显示已下载的文件（Windows 选中该文件）
  static Future<void> revealInFileManager(String filePath) async {
    try {
      if (Platform.isWindows) {
        await Process.run('explorer', ['/select,', filePath]);
      } else if (Platform.isMacOS) {
        await Process.run('open', ['-R', filePath]);
      } else {
        await Process.run('xdg-open', [File(filePath).parent.path]);
      }
    } catch (e) {
      debugPrint('revealInFileManager error: $e');
    }
  }
}

/// 简易取消令牌：取消下载用
class CancelToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}
