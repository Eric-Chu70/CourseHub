import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 壁纸持久化存储服务
///
/// 解决问题：image_picker / file_picker 返回的是 cache 临时路径，
/// 系统"清理缓存"会删掉文件导致壁纸失效。
///
/// 方案（业界主流做法，HITA 课程表同款）：
/// 选图后复制到应用内部持久目录 documents/wallpapers/，文件名带时间戳；
/// 图片自动压缩瘦身，视频/GIF 原样保留。
class WallpaperStorageService {
  static const _videoExts = ['mp4', 'mov', 'avi', 'mkv', 'webm', '3gp'];
  static const _dirName = 'wallpapers';

  /// 图片压缩参数：长边上限 & JPEG 质量
  static const _maxSide = 1440;
  static const _jpegQuality = 85;

  static Directory? _cachedDir;

  /// 壁纸持久目录（懒创建）
  static Future<Directory> _wallpaperDir() async {
    if (_cachedDir != null) return _cachedDir!;
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/$_dirName');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    _cachedDir = dir;
    return dir;
  }

  static bool _isVideo(String path) =>
      _videoExts.contains(path.toLowerCase().split('.').last);

  /// 将选中的壁纸文件持久化到内部存储，返回持久路径
  ///
  /// - 图片：解码后长边压到 [_maxSide] 以内、JPEG 质量 85 重新编码（GIF 为保留动画原样复制）
  /// - 视频：原样复制
  /// - 压缩失败时回退为原样复制，保证功能可用
  static Future<String> persistWallpaper(String pickedPath) async {
    final dir = await _wallpaperDir();
    final ext = pickedPath.toLowerCase().split('.').last;
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final isGif = ext == 'gif';

    // 视频与 GIF 不做有损处理
    if (_isVideo(pickedPath) || isGif) {
      final dest = '${dir.path}/wallpaper_$timestamp.$ext';
      await File(pickedPath).copy(dest);
      return dest;
    }

    // 图片：压缩瘦身
    try {
      final bytes = await File(pickedPath).readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded != null) {
        var image = decoded;
        // 只缩小不放大
        final longSide = image.width >= image.height ? image.width : image.height;
        if (longSide > _maxSide) {
          final ratio = _maxSide / longSide;
          image = img.copyResize(
            image,
            width: (image.width * ratio).round(),
            height: (image.height * ratio).round(),
          );
        }
        final encoded = img.encodeJpg(image, quality: _jpegQuality);
        final dest = '${dir.path}/wallpaper_$timestamp.jpg';
        await File(dest).writeAsBytes(encoded);
        return dest;
      }
    } catch (_) {
      // 解码失败走原样复制
    }

    final dest = '${dir.path}/wallpaper_$timestamp.$ext';
    await File(pickedPath).copy(dest);
    return dest;
  }

  /// 删除壁纸物理文件（仅限自家 wallpapers 目录，防误删）
  static Future<void> deleteWallpaperFile(String path) async {
    try {
      final dir = await _wallpaperDir();
      final file = File(path);
      // 路径必须位于壁纸目录内才允许删除
      if (file.existsSync() && path.startsWith(dir.path)) {
        await file.delete();
      }
    } catch (_) {}
  }

  /// 启动时维护入口：旧 cache 路径自动迁移 + 孤儿文件清理
  ///
  /// 迁移逻辑（老用户无感升级）：
  /// prefs 中的 wallpaper_path / wallpaper_recent_paths 若仍指向 cache 临时目录
  /// 且文件还存活，则复制到持久目录并改写 prefs；文件已死（清过缓存）则剔除该记录。
  ///
  /// 清理逻辑：
  /// wallpapers/ 目录中不在「当前壁纸 + 最近使用列表」里的文件视为孤儿，删除以防空间膨胀。
  static Future<void> migrateAndCleanup() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final currentPath = prefs.getString('wallpaper_path');
      final recentPaths = prefs.getStringList('wallpaper_recent_paths') ?? [];

      // ---- 迁移 ----
      String? newCurrent = currentPath;
      final migratedRecent = <String>[];
      bool prefsChanged = false;

      if (currentPath != null && _isLegacyCachePath(currentPath)) {
        if (File(currentPath).existsSync()) {
          newCurrent = await persistWallpaper(currentPath);
          prefsChanged = true;
        } else {
          // 文件已被清理，重置壁纸
          newCurrent = null;
          prefsChanged = true;
        }
      }

      for (final p in recentPaths) {
        if (_isLegacyCachePath(p)) {
          if (File(p).existsSync()) {
            migratedRecent.add(await persistWallpaper(p));
          }
          // 死文件直接丢弃
        } else {
          migratedRecent.add(p);
        }
      }
      if (!_listEquals(migratedRecent, recentPaths)) prefsChanged = true;

      if (prefsChanged) {
        if (newCurrent != null) {
          await prefs.setString('wallpaper_path', newCurrent);
        } else {
          await prefs.remove('wallpaper_path');
          await prefs.setBool('wallpaper_enabled', false);
        }
        await prefs.setStringList('wallpaper_recent_paths', migratedRecent);
      }

      // ---- 清理孤儿 ----
      final dir = await _wallpaperDir();
      final referenced = <String>{
        if (newCurrent != null) newCurrent,
        ...migratedRecent,
      };
      for (final entity in dir.listSync()) {
        if (entity is File && !referenced.contains(entity.path)) {
          try {
            await entity.delete();
          } catch (_) {}
        }
      }
    } catch (_) {
      // 维护失败不影响启动
    }
  }

  /// 判断是否为 picker 返回的 cache 临时路径
  static bool _isLegacyCachePath(String path) =>
      path.contains('/cache/') || path.contains('/tmp/');

  static bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
