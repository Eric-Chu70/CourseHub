import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart' show WidgetsBinding, MemoryImage, ImageConfiguration, ImageStreamListener, ImageInfo;
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

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

  /// 判断路径是否为视频壁纸（公开给预载/课表页使用）
  static bool isVideoPath(String path) => _isVideo(path);

  /// 视频壁纸首帧缩略图路径（与视频同目录、同名 + .thumb.png 后缀）
  static String thumbPathFor(String videoPath) => '$videoPath.thumb.png';

  /// 持久化视频首帧缩略图（已存在则跳过，不覆盖已有版本）
  static Future<void> persistVideoThumb(String? videoPath, Uint8List pngBytes) async {
    if (videoPath == null) return;
    try {
      final thumb = File(thumbPathFor(videoPath));
      if (thumb.existsSync()) return;
      await thumb.writeAsBytes(pngBytes);
    } catch (_) {}
  }

  /// 生成视频首帧静态图并与视频文件绑定共存（<video>.thumb.png）
  ///
  /// 用 video_thumbnail 原生抽帧（Android MediaMetadataRetriever /
  /// iOS AVAssetImageGenerator），不依赖 widget 渲染，导入时同步生成，
  /// 启动预载直接读取秒显。缩略图已存在时跳过（幂等）。
  static Future<void> ensureVideoThumb(String videoPath) async {
    try {
      final thumb = File(thumbPathFor(videoPath));
      if (thumb.existsSync()) return;
      final bytes = await VideoThumbnail.thumbnailData(
        video: videoPath,
        imageFormat: ImageFormat.PNG,
        maxHeight: 720,
        quality: 80,
      );
      if (bytes != null && bytes.isNotEmpty) {
        await thumb.writeAsBytes(bytes);
      }
    } catch (_) {
      // 原生抽帧失败：预载无缩略图，回退运行时捕获兜底
    }
  }

  /// 分析壁纸亮度（平均亮度 > 128 视为浅色返回 true，用于决定标题栏/时间栏
  /// 字体颜色：浅壁纸用深字、深壁纸用浅字）
  ///
  /// 仅采样「屏幕顶部课表标题栏 + 左侧时间段栏」背后的壁纸区域——字体只
  /// 出现在这两个区域，全图平均会被中央大片无关内容带偏。
  /// 壁纸以 BoxFit.cover 铺满全屏，采样前先做 cover 逆映射：屏幕矩形 →
  /// 图片实际被裁剪显示的对应区域。屏幕几何取自 platformDispatcher 首个
  /// view（runApp 前预载阶段同样可用）；不可用时回退全图平均。
  static Future<bool> analyzeBrightness(String imagePath) async {
    try {
      final file = File(imagePath);
      if (!file.existsSync()) return true;
      final bytes = await file.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: 200);
      final frameInfo = await codec.getNextFrame();
      final image = frameInfo.image;
      final byteData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (byteData == null) return true;
      final pixels = byteData.buffer.asUint8List();
      final imgW = image.width;
      final imgH = image.height;
      image.dispose();

      // 采样区域（屏幕坐标，逻辑像素）：标题栏 + 左侧时间栏
      final screen = _screenGeometry();
      double totalLuminance = 0;
      int sampleCount = 0;

      if (screen == null) {
        // 回退：屏幕几何不可用，全图平均（老逻辑）
        final (lum, cnt) =
            _accumulateLuminance(pixels, imgW, 0, 0, imgW, imgH);
        totalLuminance += lum;
        sampleCount += cnt;
      } else {
        final screenW = screen.$1;
        final screenH = screen.$2;
        // BoxFit.cover 映射：图片等比缩放至铺满屏幕后居中，多出部分裁掉
        final scale = math.max(screenW / imgW, screenH / imgH);
        final dispW = imgW * scale;
        final dispH = imgH * scale;
        final dx = (dispW - screenW) / 2;
        final dy = (dispH - screenH) / 2;
        for (final rect in _wallpaperTextRects(
          topPadding: screen.$3,
          screenW: screenW,
          screenH: screenH,
        )) {
          // 屏幕矩形 → 原图坐标系（除以 scale 抵消缩放，加偏移抵消居中裁剪）
          final sx = (((rect.left + dx) / scale).round()).clamp(0, imgW - 1);
          final sy = (((rect.top + dy) / scale).round()).clamp(0, imgH - 1);
          final ex = (((rect.right + dx) / scale).round()).clamp(sx + 1, imgW);
          final ey = (((rect.bottom + dy) / scale).round()).clamp(sy + 1, imgH);
          final (lum, cnt) =
              _accumulateLuminance(pixels, imgW, sx, sy, ex, ey);
          totalLuminance += lum;
          sampleCount += cnt;
        }
      }
      if (sampleCount == 0) return true;
      final avgLuminance = totalLuminance / sampleCount;
      return avgLuminance > 128;
    } catch (_) {
      return true;
    }
  }

  /// 获取屏幕几何：(宽, 高, 状态栏高度)，逻辑像素；不可用返回 null
  static (double, double, double)? _screenGeometry() {
    try {
      final views = WidgetsBinding.instance.platformDispatcher.views;
      if (views.isEmpty) return null;
      final view = views.first;
      final dpr = view.devicePixelRatio;
      if (dpr <= 0) return null;
      final screenW = view.physicalSize.width / dpr;
      final screenH = view.physicalSize.height / dpr;
      if (screenW <= 0 || screenH <= 0) return null;
      return (screenW, screenH, view.padding.top / dpr);
    } catch (_) {
      return null;
    }
  }

  /// 课表页文字所在屏幕区域（与 timetable_screen 布局常量保持一致）：
  /// 顶部固定标题栏（状态栏 + 周选择行 48 + 日期行 52，全宽）与
  /// 左侧时间段栏（宽 40，标题栏以下到底部）
  static List<ui.Rect> _wallpaperTextRects({
    required double topPadding,
    required double screenW,
    required double screenH,
  }) {
    const weekSelectorRowHeight = 48.0;
    const dateHeaderRowHeight = 52.0;
    const timeColumnWidth = 40.0;
    final headerBottom = topPadding + weekSelectorRowHeight + dateHeaderRowHeight;
    return [
      // 标题栏背后区域（全宽）
      ui.Rect.fromLTWH(0, 0, screenW, headerBottom),
      // 左侧时间段栏背后区域
      ui.Rect.fromLTWH(0, headerBottom, timeColumnWidth, screenH - headerBottom),
    ];
  }

  /// 累加区域内像素亮度（跳过近透明像素），返回 (亮度总和, 采样数)
  static (double, int) _accumulateLuminance(
    Uint8List pixels,
    int imgW,
    int sx,
    int sy,
    int ex,
    int ey,
  ) {
    double totalLuminance = 0;
    int sampleCount = 0;
    for (int y = sy; y < ey; y++) {
      for (int x = sx; x < ex; x++) {
        final i = (y * imgW + x) * 4;
        final a = pixels[i + 3];
        if (a < 128) continue;
        totalLuminance +=
            0.299 * pixels[i] + 0.587 * pixels[i + 1] + 0.114 * pixels[i + 2];
        sampleCount++;
      }
    }
    return (totalLuminance, sampleCount);
  }

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

    // 视频与 GIF 不做有损处理；视频导入时同步生成首帧静态图绑定共存
    if (_isVideo(pickedPath) || isGif) {
      final dest = '${dir.path}/wallpaper_$timestamp.$ext';
      await File(pickedPath).copy(dest);
      if (!isGif) {
        await ensureVideoThumb(dest);
      }
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
        // 连带删除视频首帧缩略图
        final thumb = File(thumbPathFor(path));
        if (thumb.existsSync()) await thumb.delete();
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
      const thumbSuffix = '.thumb.png';
      for (final entity in dir.listSync()) {
        if (entity is File && !referenced.contains(entity.path)) {
          // 首帧缩略图跟随视频文件：基路径仍被引用则保留
          if (entity.path.endsWith(thumbSuffix)) {
            final base =
                entity.path.substring(0, entity.path.length - thumbSuffix.length);
            if (referenced.contains(base)) continue;
          }
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

/// 壁纸首帧预载：runApp 前完成 prefs 读取 + 壁纸解码并入全局 ImageCache
///
/// 课表页首帧用同一份 bytes 构造 MemoryImage 命中缓存，壁纸与课表同帧渲染，
/// 消除「课表先出来、壁纸约 1 秒后才闪现」的问题。
/// 原生启动页在首帧渲染前保持显示，观感是启动稍慢一两百毫秒，而非界面闪变。
/// 预载失败/超时时自动回退为课表页异步加载（与现状一致）。
class WallpaperPreload {
  WallpaperPreload._();

  static final WallpaperPreload instance = WallpaperPreload._();

  /// 当前壁纸路径
  String? path;

  /// 壁纸开关
  bool enabled = false;

  /// 是否视频壁纸
  bool isVideo = false;

  /// 壁纸亮度（浅色 true）
  bool isLight = true;

  /// 壁纸不透明度（0-100）
  int opacity = 100;

  /// 模糊开关（原始 prefs 值，减弱动态效果由课表页自行叠加）
  bool blurEnabled = false;

  bool reduceMotion = false;
  bool showInactiveCourses = true;
  bool videoSound = false;

  /// 图片壁纸字节（与 ImageCache 中 MemoryImage 为同一实例）
  Uint8List? imageBytes;

  /// 视频壁纸持久化首帧缩略图字节
  Uint8List? videoThumbBytes;

  /// 是否具备首帧同步渲染条件
  bool get available =>
      enabled &&
      path != null &&
      (imageBytes != null || (isVideo && videoThumbBytes != null));

  /// 执行预载（幂等；内部全量容错，失败静默回退异步加载）
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      path = prefs.getString('wallpaper_path');
      enabled = prefs.getBool('wallpaper_enabled') ?? false;
      opacity = prefs.getInt('wallpaper_opacity') ?? 100;
      blurEnabled = prefs.getBool('wallpaper_blur_enabled') ?? false;
      reduceMotion = prefs.getBool('reduce_motion_enabled') ?? false;
      showInactiveCourses = prefs.getBool('show_inactive_courses') ?? true;
      videoSound = prefs.getBool('wallpaper_video_sound') ?? false;
      isLight = prefs.getBool('wallpaper_is_light') ?? true;

      if (!enabled || path == null || !File(path!).existsSync()) return;

      isVideo = WallpaperStorageService.isVideoPath(path!);
      if (isVideo) {
        // 视频壁纸：秒显持久化首帧缩略图，视频控制器稍后异步接管
        var thumbFile = File(WallpaperStorageService.thumbPathFor(path!));
        if (!thumbFile.existsSync()) {
          // 历史视频无缩略图（旧版本导入）：原生抽帧补生成（一次性，
          // 之后绑定共存）；失败则回退运行时捕获兜底
          await WallpaperStorageService.ensureVideoThumb(path!);
          thumbFile = File(WallpaperStorageService.thumbPathFor(path!));
        }
        if (thumbFile.existsSync()) {
          videoThumbBytes = await thumbFile.readAsBytes();
          await _decodeIntoImageCache(videoThumbBytes!);
        }
      } else {
        imageBytes = await File(path!).readAsBytes();
        await _decodeIntoImageCache(imageBytes!);
        // 亮度缓存缺失时补算并持久化，课表页启动零解码分析
        // （v2 key：区域采样版，与旧全图平均结果不兼容，自动失效重算）
        if (prefs.getString('wallpaper_is_light_v2_path') != path) {
          isLight = await WallpaperStorageService.analyzeBrightness(path!);
          await prefs.setBool('wallpaper_is_light', isLight);
          await prefs.setString('wallpaper_is_light_v2_path', path!);
        }
      }
    } catch (_) {
      // 预载失败：回退为课表页异步加载，不影响启动
    }
  }

  /// 壁纸更换后调用：清空旧数据并按当前 prefs 立即重新加载
  ///
  /// 本单例是内存缓存，main() 只在冷启动执行一次；app 内更换壁纸后若
  /// 不刷新，「不杀进程的再次进入」会拿旧壁纸数据渲染首帧再被异步纠正，
  /// 造成闪变。所有写 wallpaper_path 的地方都应调用本方法。
  Future<void> reload() async {
    path = null;
    enabled = false;
    isVideo = false;
    isLight = true;
    opacity = 100;
    blurEnabled = false;
    reduceMotion = false;
    showInactiveCourses = true;
    videoSound = false;
    imageBytes = null;
    videoThumbBytes = null;
    await load();
  }

  /// 解码并写入全局 ImageCache
  ///
  /// MemoryImage 以 bytes 的同一实例为缓存 key：课表页 Image.memory
  /// 传入同一实例时命中缓存，首帧同步绘制不闪。
  Future<void> _decodeIntoImageCache(Uint8List bytes) async {
    final completer = Completer<void>();
    void onImage(ImageInfo _, bool __) {
      if (!completer.isCompleted) completer.complete();
    }

    final stream = MemoryImage(bytes).resolve(const ImageConfiguration());
    final listener = ImageStreamListener(
      onImage,
      onError: (Object _, StackTrace? __) {
        if (!completer.isCompleted) completer.complete();
      },
    );
    stream.addListener(listener);
    try {
      await completer.future;
    } finally {
      stream.removeListener(listener);
    }
  }
}
