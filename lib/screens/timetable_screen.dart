import 'dart:async';
import 'dart:io';
import 'package:video_player/video_player.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:ui' show ImageFilter, ImageByteFormat, lerpDouble;
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show ValueListenable, kDebugMode;
import 'package:flutter/services.dart';
import 'package:intl/intl.dart' as intl;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/course.dart';
import '../models/task.dart';
import '../utils/storage.dart';
import '../services/wallpaper_storage_service.dart';
import '../dialogs/course_dialog.dart';
import '../widgets/toast_notification.dart';
import '../widgets/time_picker_dialog.dart';
import '../widgets/animated_calendar.dart';
import '../widgets/glass_dialog.dart';
import '../widgets/blur_selection_menu.dart';

class TimetableScreen extends StatefulWidget {
  final Function(bool) onScrollDirectionChanged;
  
  const TimetableScreen({super.key, required this.onScrollDirectionChanged});

  @override
  State<TimetableScreen> createState() => TimetableScreenState();
}

class TimetableScreenState extends State<TimetableScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver, AutomaticKeepAliveClientMixin {
  // 数据变更标志（参考对话页 _needsRefresh 模式，避免 tab 切换时无条件重载）
  static bool _needsRefresh = false;
  static void markNeedsRefresh() => _needsRefresh = true;

  List<Course> _courses = [];
  final Set<String> _retainedCompletedTaskIds = <String>{};
  List<Map<String, String>> _timeSlots = [];
  int _dailyPeriods = 10;
  DateTime _semesterStartDate = DateTime.now();
  int _currentWeek = 1;

  final List<String> _weekDays = ['一', '二', '三', '四', '五', '六', '日'];
  
  late PageController _pageController;
  
  int _previousWeek = 1;
  
  double _pageOffset = 0.0;
  String? _wallpaperPath;
  int _wallpaperOpacity = 100;
  bool _wallpaperEnabled = false;
  bool _wallpaperIsLight = true;
  bool _wallpaperBlurEnabled = false;

  /// 减弱动态效果（设置页开关）：开启后课表页 morph 动画改走统一
  /// 对话框淡入淡出（无背景/内容模糊），卡片模糊强制关闭
  bool _reduceMotionEnabled = false;

  /// 显示非本周课程（设置页开关，默认开启）：关闭后非本周课程
  /// 不再以灰色卡片显示
  bool _showInactiveCourses = true;

  /// morph 翻转动画期间由翻转卡片（课程块复刻）接管的源课程块所在格
  /// （day, period）：原课程块不再瞬隐/瞬现，而是随 _morphBlockFade
  /// 渐隐/渐显——打开时在起飞的卡片下方溶解，关闭时在落定的卡片下方
  /// 浮现，消除直接跳过渲染带来的一帧闪现
  int? _morphHiddenDay;
  int? _morphHiddenPeriod;
  /// 接管代数：每次 morph 对话框打开时自增。详情→编辑链中，详情关闭
  /// 动画播完（dismissed）时编辑对话框已接管同格标记——详情的
  /// land/restore 若不校验代数，会把 fade 拉回 1 并清掉编辑的接管
  /// 标记，课程块在编辑对话框打开期间就出现在网格上（提前出现
  /// 竞态，本次修复）；校验后过期代数的收尾回调全部跳过
  int _morphTakeoverSeq = 0;
  /// 源课程块的渐隐/渐显进度（1 完全可见 → 0 隐藏），170ms
  late final AnimationController _morphBlockFade;
  VideoPlayerController? _videoController;
  bool _isVideoWallpaper = false;
  String? _currentVideoPath;
  Uint8List? _videoFirstFrameBytes;
  bool _videoSoundEnabled = false;
  bool _isTabVisible = true;
  final GlobalKey _videoRepaintKey = GlobalKey();
  Uint8List? _wallpaperBytes;
  /// _wallpaperBytes 对应的壁纸路径：路径未变时跳过重复读盘（预载已备好）
  String? _wallpaperBytesPath;
  /// 冷启动首帧同步初始化只执行一次（防止刷新时把旧预载值覆盖到新 prefs 上）
  bool _wallpaperSyncInitDone = false;
  final Map<int, double> _pageScrollOffsets = {};

  // 长按课程块弹出的操作菜单（Overlay 浮层）
  OverlayEntry? _courseBlockMenuOverlay;
  final GlobalKey<_CourseBlockActionMenuState> _courseBlockMenuKey = GlobalKey<_CourseBlockActionMenuState>();
  // 空白课程块的选中状态（第一次点击显示遮罩，第二次点击弹出添加对话框）
  int? _selectedEmptyDay;
  int? _selectedEmptyPeriod;
  // 切换选中时的待显示位置：当前遮罩收起后再淡入新位置
  int? _pendingEmptyDay;
  int? _pendingEmptyPeriod;
  late final AnimationController _emptySlotMaskController;
  /// 遮罩显示/收起共用的缓动视图（easeOut 正向 / easeInCubic 反向）：
  /// 遮罩本体与该格高斯模糊都用它，保证模糊 sigma 与遮罩透明度逐帧同步
  late final CurvedAnimation _emptySlotMaskCurved = CurvedAnimation(
    parent: _emptySlotMaskController,
    curve: Curves.easeOut,
    reverseCurve: Curves.easeInCubic,
  );
  BuildContext? _emptySlotMaskContext;

  /// 加号遮罩自动消失倒计时：遮罩显示满 5 秒后自动收起（复用原收起
  /// 动画）。首次点空白格显示、取消添加 morph 归位后重新开始计时；
  /// 收起/再次点击/对话框接管时取消
  Timer? _emptySlotAutoHideTimer;

  /// 「显示非本周课程」关闭时的原课程卡片短暂浮现：点击被隐藏的
  /// 非本周课程原位后，原课程卡片以淡入动画短暂显示，满 5 秒自动
  /// 淡出（动画参考添加/删除课程：淡入=由模糊变清晰+由内部伸展，
  /// 淡出反向即删除样式）；左右滑动切换周页自动隐藏（同加号遮罩）
  AnimationController? _inactivePeekController;
  CurvedAnimation? _inactivePeekCurved;
  String? _inactivePeekCourseId;
  Timer? _inactivePeekTimer;

  /// 浮现倒计时到期时刻（timer 挂着时有效）与暂停期间保存的剩余时长：
  /// 详情对话框/长按菜单打开期间暂停（取消 timer 并记录剩余），关闭后
  /// 按剩余时长续接——暂停期间不走表
  DateTime? _inactivePeekDeadline;
  Duration? _inactivePeekPausedRemaining;

  /// 暂停嵌套计数：菜单→编辑/添加等对话框链式打开时，菜单关闭的续接
  /// 可能晚于对话框的暂停（菜单收起动画异步回调）。计数保证只有最外
  /// 层暂停源全部关闭后才真正续接计时
  int _inactivePeekPauseCount = 0;

  /// 课程块 GlobalKey 注册表（course.id → key）：删除动画启动前测量
  /// 课程块的屏幕矩形（幽灵卡片按此矩形定位）
  final Map<String, GlobalKey> _courseCellKeys = {};

  /// 删除动画（幽灵卡片）：数据删除后在原位以 Overlay 渲染课程卡片
  /// 复刻，一边模糊度增大一边向内部缩小消失（220ms）
  AnimationController? _vanishController;
  CurvedAnimation? _vanishCurved;
  OverlayEntry? _vanishOverlay;
  /// morph 关闭动画期间确认删除（课程详情入口）：幽灵延迟到 morph 落定
  /// 后播，避免与归位中的复刻卡片同位重叠（届时复刻已消失，幽灵从
  /// 满态开始，衔接连贯）
  Course? _pendingVanishCourse;
  Rect? _pendingVanishRect;

  /// 课表删除动画（切换对话框列表项原位消失）：参数对齐课程删除
  /// 动画（220ms easeInCubic、模糊增大 + 向内缩小），另叠加淡出透明度，
  /// 动画播完后转入占位收起阶段（见 _timetableCollapseController）
  AnimationController? _timetableVanishController;
  CurvedAnimation? _timetableVanishCurved;
  String? _vanishingTimetableId;

  /// 课表删除占位收起动画：vanish 播完后收缩该列表项的占位高度，
  /// 剩余项平滑上移补位、对话框高度同步收缩，播完才真正从列表移除；
  /// 200ms easeOutCubic（与 vanish 的 easeInCubic 收尾速度衔接连续），
  /// 避免移除瞬间列表与对话框高度闪现跳变
  AnimationController? _timetableCollapseController;
  CurvedAnimation? _timetableCollapseCurved;
  String? _collapsingTimetableId;

  /// 课表新增出现动画（切换对话框，删除动画的逆过程）：先占位展开
  ///（对话框变长），再由模糊变清晰 + 由内部伸展 + 淡入
  AnimationController? _timetableExpandController;
  CurvedAnimation? _timetableExpandCurved;
  String? _expandingTimetableId;
  AnimationController? _timetableAppearController;
  CurvedAnimation? _timetableAppearCurved;
  String? _appearingTimetableId;

  /// 新增课程块出现动画（统一添加入口）：由内部伸展 + 由模糊变清晰
  ///（删除动画的逆过程，240ms easeOutCubic）
  AnimationController? _appearController;
  CurvedAnimation? _appearCurved;
  String? _appearingCourseId;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 加号遮罩的显示/收起动画控制器
    _emptySlotMaskController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
      reverseDuration: const Duration(milliseconds: 200),
    );
    _emptySlotMaskController.addStatusListener((status) {
      // 该格高斯模糊由 _buildDayColumn 内的 AnimatedBuilder 逐帧驱动
      // （sigma 随遮罩动画同步渐变），状态切换无需额外刷新
      if (status != AnimationStatus.dismissed) return;
      // 收起动画结束后：切换到待显示的新位置，或彻底清除选中
      if (_pendingEmptyDay != null && _pendingEmptyPeriod != null) {
        final day = _pendingEmptyDay!;
        final period = _pendingEmptyPeriod!;
        _pendingEmptyDay = null;
        _pendingEmptyPeriod = null;
        setState(() {
          _selectedEmptyDay = day;
          _selectedEmptyPeriod = period;
        });
        _emptySlotMaskController.forward(from: 0);
        _startEmptySlotAutoHideTimer();
      } else if (_selectedEmptyDay != null || _selectedEmptyPeriod != null) {
        setState(() {
          _selectedEmptyDay = null;
          _selectedEmptyPeriod = null;
        });
      }
    });
    // morph 源课程块的隐藏/显现控制器。两个方向都瞬时（Duration.zero）：
    // - 隐藏（reverse，打开方向）：morph 卡片第 0 帧起即与课程块像素
    //   重合（t=0 映射回原位），课程块必须立即腾空——此前 170ms 渐隐
    //   期间半透明卡片（颜色 alpha≈0.75）叠在渐隐中的课程块上，两层
    //   叠出「实色课程块」并随起步缓慢的卡片持续 ~0.5s（本次修复的
    //   不透明闪现）；
    // - 显现（forward，关闭方向）：仅在关闭动画播完（dismissed）才
    //   触发，与末帧复刻卡片（像素一致）同帧交接无空档——动画结束
    //   前课程块绝不出现（用户明确要求）
    _morphBlockFade = AnimationController(
      vsync: this,
      duration: Duration.zero,
      reverseDuration: Duration.zero,
      value: 1.0,
    );
    _morphBlockFade.addListener(() {
      // 仅在 morph 接管期间驱动课表重建（控制器只在该时段动画）
      if (_morphHiddenDay != null || _morphHiddenPeriod != null) {
        setState(() {});
      }
    });
    _loadData();
    _previousWeek = _currentWeek;
    // 假期状态下初始定位到假期页（最后一页）
    final initialPage = _isInHoliday ? _effectiveTotalWeeks : _currentWeek - 1;
    _pageOffset = initialPage.toDouble();
    _pageController = PageController(initialPage: initialPage);
    _pageController.addListener(_onPageScroll);
  }

  /// 仅当数据变更时才刷新（参考对话页 refreshRuntimeConfig 模式）
  void refreshIfNeeded() {
    if (!_needsRefresh) return;
    _needsRefresh = false;
    refreshData();
  }

  void _onPageScroll() {
    if (_pageController.hasClients) {
      final page = _pageController.page;
      if (page != null && page.isFinite) {
        _pageOffset = page.clamp(0.0, double.infinity);
      }
    }
    // 左右滑动（周页位移）自动收起加号遮罩：滑动时选中空格随页移走，
    // 遮罩滞留原位观感割裂。监听器在拖动首像素即触发；无选中时
    // _dismissEmptySlotMask 幂等直接返回，拖动中重复调用无副作用
    _dismissEmptySlotMask();
    // 同理：非本周课程浮现卡片随页移走也割裂，滑动即隐藏
    _dismissInactivePeek();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _courseBlockMenuOverlay?.remove();
    _courseBlockMenuOverlay = null;
    _emptySlotAutoHideTimer?.cancel();
    _emptySlotMaskController.dispose();
    _inactivePeekTimer?.cancel();
    _inactivePeekCurved?.dispose();
    _inactivePeekController?.dispose();
    _morphBlockFade.dispose();
    _vanishOverlay?.remove();
    _vanishOverlay = null;
    _vanishCurved?.dispose();
    _vanishController?.dispose();
    _timetableVanishCurved?.dispose();
    _timetableVanishController?.dispose();
    _timetableCollapseCurved?.dispose();
    _timetableCollapseController?.dispose();
    _appearCurved?.dispose();
    _appearController?.dispose();
    _pageController.removeListener(_onPageScroll);
    _pageController.dispose();
    _videoController?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_isVideoWallpaper && _videoController != null) {
      if (state == AppLifecycleState.resumed && _isTabVisible) {
        _resumeVideoWallpaper();
      } else if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
        // inactive 比 paused 更早触发，立即暂停避免后台解码堆积导致掉帧
        _videoController!.pause();
      }
    }
  }

  /// 视频壁纸恢复：长后台/进程被杀后 Surface 与解码纹理可能已失效，
  /// 盲目 play() 会卡在错误状态（外部纹理重注册有冻结风险）。
  /// 控制器出错或未初始化时整体重建；正常时静默恢复播放
  Future<void> _resumeVideoWallpaper() async {
    final controller = _videoController;
    if (controller == null) return;
    if (!controller.value.isInitialized || controller.value.hasError) {
      final path = _currentVideoPath;
      if (path == null) return;
      try {
        controller.pause();
      } catch (_) {}
      final replacement = VideoPlayerController.file(File(path));
      try {
        await replacement.initialize();
      } catch (_) {
        // 初始化失败（文件被清/解码器异常）：放弃重建，避免反复失败
        await replacement.dispose();
        return;
      }
      if (!mounted || _videoController != controller) {
        await replacement.dispose();
        return;
      }
      controller.dispose();
      _videoController = replacement;
      replacement.setLooping(true);
      replacement.setVolume(_videoSoundEnabled ? 1 : 0);
      await replacement.seekTo(Duration.zero);
      await replacement.play();
      if (mounted) setState(() {});
      return;
    }
    try {
      await controller.play();
    } catch (_) {}
  }

  /// 页面可见性变化（由 HomeScreen 在 tab 切换动画结束后调用）
  void onTabVisibilityChanged(bool visible) {
    _isTabVisible = visible;
    if (_isVideoWallpaper && _videoController != null && _videoController!.value.isInitialized) {
      if (visible) {
        _videoController!.play();
      } else {
        _videoController!.pause();
      }
    }
  }

  void _loadData() {
    _courses = StorageService.getCourses();
    _timeSlots = StorageService.getTimeSlots();
    _dailyPeriods = StorageService.getDailyPeriods();
    _semesterStartDate = StorageService.getSemesterStartDate();
    _currentWeek = StorageService.getCurrentWeek();
    // 冷启动时先用 main 预载的数据同步初始化壁纸（首帧即有壁纸），
    // 再走异步 _loadWallpaper 补全视频初始化等剩余逻辑
    _initWallpaperFromPreload();
    // 总是调用 _loadWallpaper，内部已有视频路径未变则跳过重新初始化的逻辑
    _loadWallpaper();
  }

  /// 用 main() 预载结果同步初始化壁纸状态（仅冷启动执行一次）
  ///
  /// 图片壁纸：预载字节已解码入全局 ImageCache（同一 Uint8List 实例为
  /// MemoryImage 缓存 key），首帧 Image.memory 命中缓存同步绘制；
  /// 视频壁纸：先显示持久化首帧缩略图，视频控制器异步初始化后接管。
  void _initWallpaperFromPreload() {
    if (_wallpaperSyncInitDone) return;
    _wallpaperSyncInitDone = true;
    final pre = WallpaperPreload.instance;
    if (!pre.available) return;
    _wallpaperPath = pre.path;
    _wallpaperEnabled = pre.enabled;
    _wallpaperOpacity = pre.opacity;
    _wallpaperIsLight = pre.isLight;
    _wallpaperBlurEnabled = pre.blurEnabled && !pre.reduceMotion;
    _reduceMotionEnabled = pre.reduceMotion;
    _showInactiveCourses = pre.showInactiveCourses;
    _videoSoundEnabled = pre.videoSound;
    if (pre.isVideo) {
      _isVideoWallpaper = true;
      _currentVideoPath = pre.path;
      _videoFirstFrameBytes = pre.videoThumbBytes;
    } else {
      _isVideoWallpaper = false;
      _currentVideoPath = null;
      _wallpaperBytes = pre.imageBytes;
      _wallpaperBytesPath = pre.path;
    }
  }

  Future<void> _loadWallpaper() async {
    final prefs = await SharedPreferences.getInstance();
    final path = prefs.getString('wallpaper_path');
    final opacity = prefs.getInt('wallpaper_opacity') ?? 100;
    final enabled = prefs.getBool('wallpaper_enabled') ?? false;
    _reduceMotionEnabled = prefs.getBool('reduce_motion_enabled') ?? false;
    _showInactiveCourses = prefs.getBool('show_inactive_courses') ?? true;
    // 减弱动态效果开启时强制关闭卡片模糊（选项已在设置页隐藏）
    final blur =
        (prefs.getBool('wallpaper_blur_enabled') ?? false) && !_reduceMotionEnabled;
    final soundEnabled = prefs.getBool('wallpaper_video_sound') ?? false;
    _videoSoundEnabled = soundEnabled;

    // 提前检查：如果视频路径未变且控制器已初始化，仅更新参数（避免重建导致重播）
    if (enabled && path != null) {
      final ext = path.toLowerCase().split('.').last;
      final isVideo = ['mp4', 'mov', 'avi', 'mkv', 'webm', '3gp'].contains(ext);
      if (isVideo && _currentVideoPath == path && _videoController != null && _videoController!.value.isInitialized) {
        _isVideoWallpaper = true;
        _videoController!.setVolume(_videoSoundEnabled ? 1 : 0);
        if (_isTabVisible) _videoController!.play();
        // 仍需更新透明度/模糊等参数
        if (mounted) {
          setState(() {
            _wallpaperPath = path;
            _wallpaperOpacity = opacity;
            _wallpaperEnabled = enabled;
            _wallpaperBlurEnabled = blur;
          });
        }
        return;
      }
    }

    bool isLight = true;
    if (enabled && path != null) {
      final ext = path.toLowerCase().split('.').last;
      final isVid = ['mp4', 'mov', 'avi', 'mkv', 'webm', '3gp'].contains(ext);
      // 视频文件跳过亮度分析（instantiateImageCodec 不支持视频，会报错且浪费内存），
      // 视频固定视为浅色壁纸；图片亮度按路径缓存（wallpaper_is_light_v2_path，
      // v2 为标题栏+时间栏区域采样版），仅壁纸变更时重算一次
      if (!isVid) {
        if (prefs.getString('wallpaper_is_light_v2_path') == path &&
            prefs.containsKey('wallpaper_is_light')) {
          isLight = prefs.getBool('wallpaper_is_light')!;
        } else {
          isLight = await WallpaperStorageService.analyzeBrightness(path);
          await prefs.setBool('wallpaper_is_light', isLight);
          await prefs.setString('wallpaper_is_light_v2_path', path);
        }
      }
    }
    if (mounted) {
      setState(() {
        _wallpaperPath = path;
        _wallpaperOpacity = opacity;
        _wallpaperEnabled = enabled;
        _wallpaperIsLight = isLight;
        _wallpaperBlurEnabled = blur;
      });
    }
    if (enabled && path != null) {
      final ext = path.toLowerCase().split('.').last;
      final isVideo = ['mp4', 'mov', 'avi', 'mkv', 'webm', '3gp'].contains(ext);
      if (isVideo) {
        _isVideoWallpaper = true;
        _currentVideoPath = path;
        _videoController?.dispose();
        _videoController = VideoPlayerController.file(File(path));
        await _videoController!.initialize();
        _videoController!.setLooping(true);
        _videoController!.setVolume(_videoSoundEnabled ? 1 : 0);
        // 先播放再捕获首帧
        _videoController!.seekTo(Duration.zero);
        _videoController!.play();
        // 捕获首帧作为过渡背景
        _captureFirstFrame();
        if (mounted) setState(() {});
      } else {
        _isVideoWallpaper = false;
        _currentVideoPath = null;
        _videoFirstFrameBytes = null;
        _videoController?.dispose();
        _videoController = null;
        // 预载已读取且路径未变时跳过重复读盘（字节与 ImageCache 同源）
        if (_wallpaperBytes == null || _wallpaperBytesPath != path) {
          _wallpaperBytes = await File(path).readAsBytes();
          _wallpaperBytesPath = path;
        }
        if (mounted) {
          // 渲染走 Image.memory（MemoryImage key），预缓存同一 provider
          // 确保解码结果复用；同时主动刷新，避免旧壁纸残留到下次 setState
          precacheImage(MemoryImage(_wallpaperBytes!), context);
          setState(() {});
        }
      }
    } else {
      _isVideoWallpaper = false;
      _currentVideoPath = null;
      _videoFirstFrameBytes = null;
      _videoController?.dispose();
      _videoController = null;
    }
  }

  /// 捕获视频当前帧作为过渡背景，并持久化首帧缩略图供下次启动秒显
  ///
  /// [attempt] 帧重试计数：视频层未挂载/纹理未就绪时等下一帧再试（上限 8 次）
  void _captureFirstFrame({int attempt = 0}) {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (attempt >= 8) return;
      final ctx = _videoRepaintKey.currentContext;
      if (ctx == null) {
        _captureFirstFrame(attempt: attempt + 1);
        return;
      }
      try {
        final boundary = ctx.findRenderObject() as dynamic;
        if (boundary == null) {
          _captureFirstFrame(attempt: attempt + 1);
          return;
        }
        // debugNeedsPaint 仅 debug 模式可读：release 下该 getter 的 assert
        // 被剥离，读取未赋值的 late 变量会抛 LateInitializationError，
        // 导致首帧捕获（含缩略图持久化）在 release 包从未生效——本次修复
        if (kDebugMode && boundary.debugNeedsPaint == true) {
          _captureFirstFrame(attempt: attempt + 1);
          return;
        }
        // 等视频纹理实际渲染出画面再捕获，避免抓到纯黑帧
        if (attempt == 0) {
          await Future.delayed(const Duration(milliseconds: 300));
        }
        final image = await boundary.toImage(pixelRatio: 1.0);
        final byteData = await image.toByteData(format: ImageByteFormat.png);
        if (byteData == null || !mounted) return;
        setState(() {
          _videoFirstFrameBytes = byteData.buffer.asUint8List();
        });
        // 持久化半分辨率首帧缩略图（仅首次生成）：
        // 下次启动由预载秒显，视频初始化期间不再露底
        final videoPath = _currentVideoPath;
        if (videoPath != null) {
          try {
            final small = await boundary.toImage(pixelRatio: 0.5);
            final smallData = await small.toByteData(format: ImageByteFormat.png);
            if (smallData != null) {
              await WallpaperStorageService.persistVideoThumb(
                videoPath,
                smallData.buffer.asUint8List(),
              );
            }
          } catch (_) {}
        }
      } catch (_) {
        // 捕获失败（视频纹理未就绪等）：下一帧重试
        _captureFirstFrame(attempt: attempt + 1);
      }
    });
  }

  void refreshData() {
    _loadData();
    _pageOffset = (_currentWeek - 1).toDouble();
    // 视频壁纸已初始化时跳过 setState，避免 widget 重建导致视频视觉重播
    final skipSetState = _isVideoWallpaper &&
        _videoController != null &&
        _videoController!.value.isInitialized;
    if (mounted && !skipSetState) {
      setState(() {});
    }
  }

  Future<void> clearRetainedCompletedTasks() async {
    if (_retainedCompletedTaskIds.isEmpty) return;

    final idsToDelete = _retainedCompletedTaskIds.toList();
    _retainedCompletedTaskIds.clear();
    for (final taskId in idsToDelete) {
      await StorageService.deleteTask(taskId);
    }
    if (mounted) {
      setState(() {});
    }
  }

  void _showTimetableSwitcher({bool autoFocusNewField = false}) {
    var timetables = StorageService.getTimetables();
    String currentId = StorageService.currentTimetableId;
    final TextEditingController nameController = TextEditingController();
    final FocusNode nameFocusNode = FocusNode();
    String? editingId;
    final TextEditingController editController = TextEditingController();

    void showTimetableTip(String message, {ToastType type = ToastType.info}) {
      if (!mounted) return;
      toastNotification.show(context, message, type: type);
    }
    
    showBouncyDialog(
      context: context,
      barrierLabel: '切换课表',
      margin: EdgeInsets.zero,
      shellPadding: const EdgeInsets.all(20),
      // 壳总宽含壳内边距（与旧版 Container(width:) 包壳一致）
      shellWidth: 320,
      shellBoxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.1),
          blurRadius: 20,
          offset: const Offset(0, 10),
        ),
      ],
      avoidKeyboard: true,
      builder: (context) => StatefulBuilder(
                    builder: (context, setDialogState) {
                      final mediaQuery = MediaQuery.of(context);
                      final keyboardHeight = mediaQuery.viewInsets.bottom;
                      final topInset = mediaQuery.padding.top;
                      final screenHeight = mediaQuery.size.height;
                      double dialogMaxHeight = 450;
                      final availableHeight = screenHeight - topInset - keyboardHeight - 24;
                      if (availableHeight < dialogMaxHeight) {
                        dialogMaxHeight = availableHeight;
                      }
                      dialogMaxHeight = dialogMaxHeight.clamp(260.0, 450.0).toDouble();

                      return AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            curve: Curves.easeOut,
                            constraints: BoxConstraints(maxHeight: dialogMaxHeight),
                            child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text(
                              '切换课表',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF1A1A2E),
                              ),
                            ),
                            const SizedBox(height: 16),
                            Flexible(
                              child: ListView.builder(
                                shrinkWrap: true,
                                physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
                                itemCount: timetables.length,
                                itemBuilder: (context, index) {
                                  final timetable = timetables[index];
                                  final isSelected = timetable.id == currentId;
                                  final isEditing = editingId == timetable.id;
                                  
                                  final Widget item = Container(
                                    margin: const EdgeInsets.only(bottom: 8),
                                    decoration: BoxDecoration(
                                      color: isSelected
                                          ? const Color(0xFF4A90E2).withValues(alpha: 0.1)
                                          : Colors.white.withValues(alpha: 0.4),
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                        color: isSelected
                                            ? const Color(0xFF4A90E2)
                                            : Colors.grey.shade200,
                                      ),
                                    ),
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(12),
                                      child: Material(
                                        color: Colors.transparent,
                                        child: ListTile(
                                      contentPadding: const EdgeInsets.only(left: 16, right: 4),
                                      leading: Container(
                                        width: 40,
                                        height: 40,
                                        decoration: BoxDecoration(
                                          gradient: isSelected 
                                              ? const LinearGradient(
                                                  colors: [Color(0xFF4A90E2), Color(0xFF5BA0F2)],
                                                  begin: Alignment.topLeft,
                                                  end: Alignment.bottomRight,
                                                )
                                              : null,
                                          color: isSelected ? null : Colors.white.withValues(alpha: 0.4),
                                          borderRadius: BorderRadius.circular(10),
                                        ),
                                        child: Icon(
                                          Icons.calendar_month_rounded,
                                          color: isSelected ? Colors.white : Colors.grey.shade500,
                                          size: 20,
                                        ),
                                      ),
                                      title: isEditing
                                          ? Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                              decoration: BoxDecoration(
                                                color: const Color(0xFF4A90E2).withValues(alpha: 0.1),
                                                borderRadius: BorderRadius.circular(8),
                                              ),
                                              child: TextField(
                                                contextMenuBuilder: styledEditableContextMenu,
                                                controller: editController,
                                                autofocus: true,
                                                style: TextStyle(
                                                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                                  color: isSelected ? const Color(0xFF4A90E2) : Colors.grey.shade700,
                                                ),
                                                decoration: const InputDecoration(
                                                  isDense: true,
                                                  contentPadding: EdgeInsets.zero,
                                                  border: InputBorder.none,
                                                ),
                                                onSubmitted: (value) async {
                                                  if (value.trim().isNotEmpty) {
                                                    await StorageService.renameTimetable(timetable.id, value.trim());
                                                    setDialogState(() {
                                                      timetables[index] = TimetableInfo(
                                                        id: timetable.id,
                                                        name: value.trim(),
                                                        createdAt: timetable.createdAt,
                                                      );
                                                      editingId = null;
                                                    });
                                                    showTimetableTip('课表已重命名：${value.trim()}');
                                                  }
                                                },
                                              ),
                                            )
                                          : Text(
                                              timetable.name,
                                              style: TextStyle(
                                                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                                color: isSelected ? const Color(0xFF4A90E2) : Colors.grey.shade700,
                                              ),
                                            ),
                                      trailing: timetable.id != 'default'
                                          ? AnimatedSwitcher(
                                              duration: const Duration(milliseconds: 200),
                                              transitionBuilder: (child, animation) {
                                                return ScaleTransition(scale: animation, child: child);
                                              },
                                              child: isEditing
                                                  ? Padding(
                                                      key: const ValueKey('check'),
                                                      padding: const EdgeInsets.only(right: 8),
                                                      child: GestureDetector(
                                                        onTap: () async {
                                                          final value = editController.text;
                                                          if (value.trim().isNotEmpty) {
                                                            await StorageService.renameTimetable(timetable.id, value.trim());
                                                            setDialogState(() {
                                                              timetables[index] = TimetableInfo(
                                                                id: timetable.id,
                                                                name: value.trim(),
                                                                createdAt: timetable.createdAt,
                                                              );
                                                              editingId = null;
                                                            });
                                                            showTimetableTip('课表已重命名：${value.trim()}');
                                                          }
                                                        },
                                                        child: Container(
                                                          width: 32,
                                                          height: 32,
                                                          decoration: BoxDecoration(
                                                            color: const Color(0xFF4A90E2),
                                                            borderRadius: BorderRadius.circular(8),
                                                          ),
                                                          child: const Icon(Icons.check, color: Colors.white, size: 18),
                                                        ),
                                                      ),
                                                    )
                                                  : Padding(
                                                      key: const ValueKey('menu'),
                                                      padding: EdgeInsets.zero,
                                                      child: Listener(
                                                        behavior: HitTestBehavior.translucent,
                                                        onPointerDown: (_) => HapticFeedback.selectionClick(),
                                                        child: BlurredPopupMenuButton<String>(
                                                          icon: Icon(Icons.more_vert, color: Colors.grey.shade400, size: 20),
                                                          items: const [
                                                            BlurredPopupMenuItem(
                                                              value: 'rename',
                                                              icon: Icons.edit_outlined,
                                                              label: '重命名',
                                                              iconColor: Color(0xFF4A90E2),
                                                            ),
                                                            BlurredPopupMenuItem(
                                                              value: 'delete',
                                                              icon: Icons.delete_outline,
                                                              label: '删除课表',
                                                              iconColor: Colors.red,
                                                              textColor: Colors.red,
                                                            ),
                                                          ],
                                                          onSelected: (value) async {
                                                            if (value == 'rename') {
                                                              editController.text = timetable.name;
                                                              setDialogState(() {
                                                                editingId = timetable.id;
                                                              });
                                                            } else if (value == 'delete') {
                                                              final confirmed = await _confirmDeleteTimetable(timetable.name);
                                                              if (confirmed != true || !mounted) return;
                                                              // 删除动画（对齐课程删除动画参数）：先让该列表项
                                                              // 原位向内模糊淡出播完，再收起其占位高度，
                                                              // 全部播完才真正删数据并从列表移除（列表与
                                                              // 对话框高度平滑过渡，不闪现跳变）
                                                              _vanishingTimetableId = timetable.id;
                                                              _timetableVanishCurved?.dispose();
                                                              _timetableVanishController?.dispose();
                                                              _timetableVanishController = AnimationController(
                                                                vsync: this,
                                                                duration: const Duration(milliseconds: 220),
                                                              );
                                                              _timetableVanishCurved = CurvedAnimation(
                                                                parent: _timetableVanishController!,
                                                                curve: Curves.easeInCubic,
                                                              );
                                                              setDialogState(() {});
                                                              await _timetableVanishController!.forward(from: 0);
                                                              if (!mounted) return;
                                                              // 占位收起：该项已不可见，逐帧收缩其占位高度，
                                                              // 剩余项平滑上移补位、对话框高度同步收缩，
                                                              // 避免从列表移除瞬间高度闪现跳变
                                                              _vanishingTimetableId = null;
                                                              _collapsingTimetableId = timetable.id;
                                                              _timetableCollapseCurved?.dispose();
                                                              _timetableCollapseController?.dispose();
                                                              _timetableCollapseController = AnimationController(
                                                                vsync: this,
                                                                duration: const Duration(milliseconds: 200),
                                                              );
                                                              _timetableCollapseCurved = CurvedAnimation(
                                                                parent: _timetableCollapseController!,
                                                                curve: Curves.easeOutCubic,
                                                              );
                                                              setDialogState(() {});
                                                              await _timetableCollapseController!.forward(from: 0);
                                                              if (!mounted) return;
                                                              final deletedName = timetable.name;
                                                              await StorageService.deleteTimetable(timetable.id);
                                                              currentId = StorageService.currentTimetableId;
                                                              _loadData();
                                                              setDialogState(() {
                                                                timetables = StorageService.getTimetables();
                                                                editingId = null;
                                                                _collapsingTimetableId = null;
                                                              });
                                                              setState(() {
                                                                _previousWeek = _currentWeek;
                                                                _currentWeek = 1;
                                                                _pageOffset = 0;
                                                              });
                                                              if (_pageController.hasClients) {
                                                                _pageController.jumpToPage(0);
                                                              }
                                                              showTimetableTip('课表已删除：$deletedName');
                                                            }
                                                          },
                                                        ),
                                                      ),
                                                    ),
                                            )
                                          : null,
                                      onTap: isEditing
                                          ? null
                                          : () async {
                                              if (!isSelected) {
                                                await StorageService.switchTimetable(timetable.id);
                                                currentId = timetable.id;
                                                _loadData();
                                                if (mounted) {
                                                  setState(() {
                                                    _previousWeek = _currentWeek;
                                                    _currentWeek = 1;
                                                    _pageOffset = 0;
                                                  });
                                                }
                                                if (_pageController.hasClients) {
                                                  _pageController.jumpToPage(0);
                                                }
                                                setDialogState(() {
                                                  timetables = StorageService.getTimetables();
                                                });
                                                showTimetableTip('已切换到课表：${timetable.name}');
                                                Navigator.pop(context);
                                              }
                                            },
                                        ),
                                      ),
                                    ),
                                  );
                                  if (timetable.id == _collapsingTimetableId) {
                                    // 占位收起阶段（vanish 播完后）：该项已完全不可见，
                                    // 逐帧收缩其占位高度，剩余项平滑上移补位、对话框高度
                                    // 同步收缩，避免从列表移除瞬间高度闪现跳变。
                                    // easeOutCubic 起始速度与 vanish 的 easeInCubic 收尾速度衔接连续
                                    return AnimatedBuilder(
                                      animation: _timetableCollapseCurved ?? kAlwaysDismissedAnimation,
                                      builder: (context, child) {
                                        final t = _timetableCollapseCurved?.value ?? 0.0;
                                        return SizeTransition(
                                          sizeFactor: AlwaysStoppedAnimation((1.0 - t).clamp(0.0, 1.0)),
                                          axisAlignment: -1.0,
                                          child: Opacity(opacity: 0.0, child: child),
                                        );
                                      },
                                      child: item,
                                    );
                                  }
                                  if (timetable.id == _expandingTimetableId) {
                                    // 新增占位展开阶段（collapse 的逆过程）：该项不可见，
                                    // 占位高度逐帧展开（对话框高度同步增长），播完转入
                                    // 出现阶段。easeInCubic 为 collapse easeOutCubic 的
                                    // 逆曲线（严格镜像对称）
                                    return AnimatedBuilder(
                                      animation: _timetableExpandCurved ?? kAlwaysDismissedAnimation,
                                      builder: (context, child) {
                                        final t = _timetableExpandCurved?.value ?? 0.0;
                                        return IgnorePointer(
                                          child: SizeTransition(
                                            sizeFactor: AlwaysStoppedAnimation(t.clamp(0.0, 1.0)),
                                            axisAlignment: -1.0,
                                            child: Opacity(opacity: 0.0, child: child),
                                          ),
                                        );
                                      },
                                      child: item,
                                    );
                                  }
                                  if (timetable.id == _appearingTimetableId) {
                                    // 新增出现阶段（vanish 的逆过程）：由模糊变清晰 +
                                    // 由内部伸展 + 淡入，播完恢复正常交互。
                                    // easeOutCubic 为 vanish easeInCubic 的逆曲线
                                    return AnimatedBuilder(
                                      animation: _timetableAppearCurved ?? kAlwaysDismissedAnimation,
                                      builder: (context, child) {
                                        final t = _timetableAppearCurved?.value ?? 0.0;
                                        return IgnorePointer(
                                          child: Opacity(
                                            opacity: t.clamp(0.0, 1.0),
                                            child: ImageFiltered(
                                              imageFilter: ImageFilter.blur(
                                                sigmaX: 14 * (1.0 - t),
                                                sigmaY: 14 * (1.0 - t),
                                              ),
                                              child: Transform.scale(
                                                scale: 0.55 + 0.45 * t,
                                                child: child,
                                              ),
                                            ),
                                          ),
                                        );
                                      },
                                      child: item,
                                    );
                                  }
                                  if (timetable.id != _vanishingTimetableId) return item;
                                  // 删除中动画（参数对齐课程删除动画）：模糊增大 + 向内缩小 +
                                  // 淡出，逐帧驱动；数据在动画播完后才真正删除移除
                                  return AnimatedBuilder(
                                    animation: _timetableVanishCurved ?? kAlwaysDismissedAnimation,
                                    builder: (context, child) {
                                      final t = _timetableVanishCurved?.value ?? 0.0;
                                      return IgnorePointer(
                                        child: Opacity(
                                          opacity: (1.0 - t).clamp(0.0, 1.0),
                                          child: ImageFiltered(
                                            imageFilter: ImageFilter.blur(
                                              sigmaX: 14 * t,
                                              sigmaY: 14 * t,
                                            ),
                                            child: Transform.scale(
                                              scale: 1.0 - 0.45 * t,
                                              child: child,
                                            ),
                                          ),
                                        ),
                                      );
                                    },
                                    child: item,
                                  );
                                },
                              ),
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              contextMenuBuilder: styledEditableContextMenu,
                              controller: nameController,
                              focusNode: nameFocusNode,
                              autofocus: autoFocusNewField,
                              decoration: InputDecoration(
                                hintText: '新建课表名称',
                                hintStyle: TextStyle(color: Colors.grey.shade400, fontSize: 14),
                                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                filled: true,
                                fillColor: Colors.white.withValues(alpha: 0.4),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide(color: Colors.grey.shade300),
                                ),
                                focusedBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: const BorderSide(color: Color(0xFF4A90E2)),
                                ),
                                suffixIcon: IconButton(
                                  icon: const Icon(Icons.add, color: Color(0xFF4A90E2)),
                                  onPressed: () async {
                                    final name = nameController.text.trim();
                                    if (name.isNotEmpty) {
                                      await StorageService.createTimetable(name);
                                      currentId = StorageService.currentTimetableId;
                                      _loadData();
                                      if (mounted) {
                                        setState(() {
                                          _previousWeek = _currentWeek;
                                          _currentWeek = 1;
                                          _pageOffset = 0;
                                        });
                                      }
                                      if (_pageController.hasClients) {
                                        _pageController.jumpToPage(0);
                                      }
                                      setDialogState(() {
                                        timetables = StorageService.getTimetables();
                                      });
                                      nameController.clear();
                                      showTimetableTip('课表已新建并切换：$name');
                                      // 新增课表项出现动画（删除动画的逆过程，对称）：
                                      // 先占位展开（对话框变长）再由模糊变清晰 +
                                      // 由内部伸展 + 淡入；对话框保持打开（与删除后
                                      // 行为一致），用户可继续添加或自行关闭
                                      await _playTimetableAppearAnimation(
                                        StorageService.currentTimetableId,
                                        setDialogState,
                                      );
                                    }
                                  },
                                ),
                              ),
                              onSubmitted: (value) async {
                                final name = value.trim();
                                if (name.isNotEmpty) {
                                  await StorageService.createTimetable(name);
                                  currentId = StorageService.currentTimetableId;
                                  _loadData();
                                  if (mounted) {
                                    setState(() {
                                      _previousWeek = _currentWeek;
                                      _currentWeek = 1;
                                      _pageOffset = 0;
                                    });
                                  }
                                  if (_pageController.hasClients) {
                                    _pageController.jumpToPage(0);
                                  }
                                  setDialogState(() {
                                    timetables = StorageService.getTimetables();
                                  });
                                  nameController.clear();
                                  showTimetableTip('课表已新建并切换：$name');
                                  // 新增课表项出现动画（删除动画的逆过程，对称）：
                                  // 先占位展开（对话框变长）再由模糊变清晰 +
                                  // 由内部伸展 + 淡入；对话框保持打开（与删除后
                                  // 行为一致），用户可继续添加或自行关闭
                                  await _playTimetableAppearAnimation(
                                    StorageService.currentTimetableId,
                                    setDialogState,
                                  );
                                }
                              },
                            ),
                          ],
                        ),
                      );
                    },
                  ),
    );
  }

  /// 新增课表项出现动画（删除动画的逆过程，严格镜像对称）：
  /// 1) 占位展开 200ms easeInCubic（collapse 200ms easeOutCubic 的逆曲线）：
  ///    该项不可见、占位高度逐帧展开，列表下方内容与对话框高度同步增长；
  /// 2) 出现 220ms easeOutCubic（vanish 220ms easeInCubic 的逆曲线）：
  ///    由模糊变清晰（sigma 14→0）+ 由内部伸展（0.55→1）+ 淡入
  Future<void> _playTimetableAppearAnimation(
    String timetableId,
    void Function(VoidCallback) setDialogState,
  ) async {
    // 阶段一：占位展开（对话框变长）
    _expandingTimetableId = timetableId;
    _appearingTimetableId = null;
    _timetableExpandCurved?.dispose();
    _timetableExpandController?.dispose();
    _timetableExpandController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _timetableExpandCurved = CurvedAnimation(
      parent: _timetableExpandController!,
      curve: Curves.easeInCubic,
    );
    setDialogState(() {});
    await _timetableExpandController!.forward(from: 0);
    if (!mounted) return;
    // 阶段二：出现（由模糊变清晰 + 由内部伸展 + 淡入）
    _expandingTimetableId = null;
    _appearingTimetableId = timetableId;
    _timetableAppearCurved?.dispose();
    _timetableAppearController?.dispose();
    _timetableAppearController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    _timetableAppearCurved = CurvedAnimation(
      parent: _timetableAppearController!,
      curve: Curves.easeOutCubic,
    );
    setDialogState(() {});
    await _timetableAppearController!.forward(from: 0);
    if (!mounted) return;
    setDialogState(() => _appearingTimetableId = null);
  }

  /// 第1周所在的周一。按开学日期所在自然周对齐，
  /// 避免“开学日期不管选几号都被当作星期一”导致的星期与日期错位。
  DateTime get _mondayOfWeek1 =>
      _semesterStartDate.subtract(Duration(days: _semesterStartDate.weekday - 1));

  DateTime _getDateForDay(int dayIndex) {
    final startOfWeek = _mondayOfWeek1.add(Duration(days: (_currentWeek - 1) * 7));
    return startOfWeek.add(Duration(days: dayIndex));
  }

  List<Course> _getCoursesForSlot(int day, int period) {
    return _courses.where((c) => 
      c.day == day && 
      c.time <= period && 
      c.time + c.duration > period
    ).toList();
  }

  bool _isCourseStart(Course course, int period) {
    return course.time == period;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    const timeColumnWidth = 40.0;
    final topPadding = MediaQuery.of(context).padding.top;
    final hasWallpaper = _wallpaperEnabled && _wallpaperPath != null && File(_wallpaperPath!).existsSync();

    return Scaffold(
      backgroundColor: hasWallpaper ? const Color(0xFF1A1A2E) : const Color(0xFFF8F9FC),
      body: RepaintBoundary(
        child: Stack(
          children: [
            _buildPageView(),
            // 假期页滑动时标题栏与课表主体同步左移直到离开屏幕
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: AnimatedBuilder(
                animation: _pageController,
                builder: (context, child) {
                  double dx = 0;
                  if (_isInHoliday) {
                    final page = _pageController.hasClients ? _pageController.page : null;
                    if (page != null && page >= _effectiveTotalWeeks - 1) {
                      final progress = (page - (_effectiveTotalWeeks - 1)).clamp(0.0, 1.0);
                      dx = -progress * MediaQuery.of(context).size.width;
                    }
                  }
                  return Transform.translate(
                    offset: Offset(dx, 0),
                    child: child,
                  );
                },
                child: _buildPinnedHeader(topPadding, timeColumnWidth, hasWallpaper: hasWallpaper),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPinnedHeader(double topPadding, double timeColumnWidth, {bool hasWallpaper = false}) {
    return ClipRRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          decoration: BoxDecoration(
            color: hasWallpaper
                ? Colors.white.withValues(alpha: 0.35)
                : const Color(0xFFF8F9FC).withValues(alpha: 0.75),
            border: Border(
              bottom: BorderSide(color: Colors.grey.shade200, width: 0.5),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(height: topPadding),
              Stack(
                children: [
                  _buildWeekSelectorRow(),
                  // 视频壁纸设置按钮（与切换课表按钮对称，仅视频壁纸时显示）
                  if (_isVideoWallpaper)
                    Positioned(
                      left: 8,
                      top: 0,
                      bottom: 0,
                      child: Center(
                        child: IconButton(
                          icon: Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: const Color(0xFF4A90E2).withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Icon(Icons.equalizer, color: Color(0xFF4A90E2), size: 18),
                          ),
                          onPressed: _showVideoWallpaperSettings,
                        ),
                      ),
                    ),
                  Positioned(
                    right: 8,
                    top: 0,
                    bottom: 0,
                    child: Center(
                      child: IconButton(
                        icon: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: const Color(0xFF4A90E2).withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Icon(Icons.swap_horiz, color: Color(0xFF4A90E2), size: 18),
                        ),
                        onPressed: _showTimetableSwitcher,
                      ),
                    ),
                  ),
                ],
              ),
              AnimatedBuilder(
                animation: _pageController,
                builder: (context, _) {
                  return _buildDateHeaderRow(timeColumnWidth, hasWallpaper: hasWallpaper, wallpaperIsLight: _wallpaperIsLight);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 课表总页数：仅取学期周数（不再用 max 包含当前周，避免假期时私自增加页数）
  int get _effectiveTotalWeeks => StorageService.getSemesterWeeks();

  /// 假期状态下 PageView 额外追加一页假期页
  int get _pageCount => _isInHoliday ? _effectiveTotalWeeks + 1 : _effectiveTotalWeeks;

  bool get _isInHoliday {
    final semesterWeeks = StorageService.getSemesterWeeks();
    final currentWeek = StorageService.getCurrentWeek();
    return currentWeek > semesterWeeks;
  }

  Widget _buildWeekSelectorRow() {
    final totalWeeks = _effectiveTotalWeeks;
    final pageCount = _pageCount;
    final rawPage = _pageController.hasClients
        ? (_pageController.page?.round() ?? (_currentWeek - 1))
        : (_currentWeek - 1);
    final currentPage = rawPage.clamp(0, totalWeeks - 1);
    final hasWallpaper = _wallpaperEnabled && _wallpaperPath != null && File(_wallpaperPath!).existsSync();
    final headerTextColor = hasWallpaper
        ? (_wallpaperIsLight ? const Color(0xFF1A1A2E) : const Color(0xFFE8E8E8))
        : const Color(0xFF1A1A2E);
    
    return SizedBox(
      height: 48,
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _buildWeekNavButton(
              icon: Icons.chevron_left,
              onPressed: currentPage > 0 ? () => _navigateWeek(-1) : null,
            ),
            const SizedBox(width: 8),
            Text(
              '第',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: headerTextColor,
                fontSize: 16,
                height: 1.0,
              ),
            ),
            SizedBox(
              width: 21,
              height: 24,
              child: AnimatedBuilder(
                animation: _pageController,
                builder: (context, _) => _buildAnimatedWeekNumber(totalWeeks, headerTextColor),
              ),
            ),
            Text(
              '周',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: headerTextColor,
                fontSize: 16,
                height: 1.0,
              ),
            ),
            const SizedBox(width: 8),
            _buildWeekNavButton(
              icon: Icons.chevron_right,
              onPressed: currentPage < pageCount - 1 ? () => _navigateWeek(1) : null,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAnimatedWeekNumber(int totalWeeks, Color textColor) {
    final page = (_pageController.hasClients ? _pageController.page : null) ?? (_currentWeek - 1).toDouble();
    final pageOffset = page.clamp(0.0, (totalWeeks - 1).toDouble());
    final integerPart = pageOffset.floor();
    final fractionalPart = pageOffset - integerPart;
    
    final currentNum = integerPart + 1;
    final nextNum = currentNum + 1;
    
    final displayCurrent = currentNum.clamp(1, totalWeeks);
    final displayNext = nextNum.clamp(1, totalWeeks);
    
    final canShowNext = currentNum < totalWeeks;
    
    return GestureDetector(
      onTap: _showWeekPickerDialog,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          Transform.translate(
            offset: Offset(-fractionalPart * 21, 0),
            child: Opacity(
              opacity: (1.0 - fractionalPart).clamp(0.0, 1.0),
              child: SizedBox(
                width: 21,
                child: Text(
                  '$displayCurrent',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: textColor,
                    fontSize: 16,
                    height: 1.0,
                  ),
                ),
              ),
            ),
          ),
          if (canShowNext && fractionalPart > 0.01)
            Transform.translate(
              offset: Offset(21 - fractionalPart * 21, 0),
              child: Opacity(
                opacity: fractionalPart.clamp(0.0, 1.0),
                child: SizedBox(
                  width: 21,
                  child: Text(
                    '$displayNext',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: textColor,
                      fontSize: 16,
                      height: 1.0,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildDateHeaderRow(double timeWidth, {bool hasWallpaper = false, bool wallpaperIsLight = true}) {
    final screenWidth = MediaQuery.of(context).size.width;
    final dayWidth = (screenWidth - timeWidth) / 7;
    final page = (_pageController.hasClients ? _pageController.page : null) ?? (_currentWeek - 1).toDouble();
    final pageOffset = page.clamp(0.0, (_effectiveTotalWeeks - 1).toDouble());
    final currentWeekIndex = pageOffset.floor();
    final fractionalPart = (pageOffset - currentWeekIndex).clamp(0.0, 1.0);
    
    final currentStartOfWeek = _mondayOfWeek1.add(Duration(days: currentWeekIndex * 7));
    final nextStartOfWeek = _mondayOfWeek1.add(Duration(days: (currentWeekIndex + 1) * 7));
    
    Color dayLabelColor;
    Color dateNumberColor;
    if (hasWallpaper) {
      dayLabelColor = wallpaperIsLight ? Colors.grey.shade700 : Colors.grey.shade400;
      dateNumberColor = wallpaperIsLight ? Colors.grey.shade900 : Colors.grey.shade300;
    } else {
      dayLabelColor = Colors.grey.shade600;
      dateNumberColor = Colors.grey.shade800;
    }
    
    return Container(
      height: 52,
      clipBehavior: Clip.none,
      decoration: const BoxDecoration(),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: timeWidth - fractionalPart * dayWidth * 7,
            child: Row(
              children: [
                ...List.generate(7, (dayIndex) {
                  final date = currentStartOfWeek.add(Duration(days: dayIndex));
                  final isToday = _isToday(date);
                  return SizedBox(
                    width: dayWidth,
                    child: Opacity(
                      opacity: (1.0 - fractionalPart).clamp(0.0, 1.0),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            '周${_weekDays[dayIndex]}',
                            style: TextStyle(
                              fontSize: 12,
                              color: isToday ? const Color(0xFF4A90E2) : dayLabelColor,
                              fontWeight: isToday ? FontWeight.bold : FontWeight.normal,
                            ),
                          ),
                          Text(
                            '${date.month}/${date.day}',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: isToday ? const Color(0xFF4A90E2) : dateNumberColor,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }),
                ...List.generate(7, (dayIndex) {
                  final date = nextStartOfWeek.add(Duration(days: dayIndex));
                  final isToday = _isToday(date);
                  return SizedBox(
                    width: dayWidth,
                    child: Opacity(
                      opacity: fractionalPart.clamp(0.0, 1.0),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            '周${_weekDays[dayIndex]}',
                            style: TextStyle(
                              fontSize: 12,
                              color: isToday ? const Color(0xFF4A90E2) : dayLabelColor,
                              fontWeight: isToday ? FontWeight.bold : FontWeight.normal,
                            ),
                          ),
                          Text(
                            '${date.month}/${date.day}',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: isToday ? const Color(0xFF4A90E2) : dateNumberColor,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }),
              ],
            ),
          ),
        ],
      ),
    );
  }
  
  void _showWeekPickerDialog() {
    int selectedWeek = _currentWeek;
    final int totalWeeks = _effectiveTotalWeeks;
    final FixedExtentScrollController scrollController = FixedExtentScrollController(initialItem: (selectedWeek - 1).clamp(0, totalWeeks - 1));
    
    showBouncyDialog(
      context: context,
      barrierLabel: '选择周数',
      margin: EdgeInsets.zero,
      shellPadding: const EdgeInsets.all(20),
      // 壳总宽含壳内边距（与旧版 SizedBox(width:) 包壳一致）
      shellWidth: 280,
      shellBoxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.1),
          blurRadius: 20,
          offset: const Offset(0, 10),
        ),
      ],
      builder: (context) => StatefulBuilder(
                    builder: (context, setDialogState) {
                      return SizedBox(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text(
                              '选择周数',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF1A1A2E),
                              ),
                            ),
                            const SizedBox(height: 20),
                            SizedBox(
                              height: 150,
                              child: ListWheelScrollView.useDelegate(
                                controller: scrollController,
                                itemExtent: 40,
                                perspective: 0.005,
                                diameterRatio: 1.5,
                                physics: const FixedExtentScrollPhysics(
                                  parent: BouncingScrollPhysics(),
                                ),
                                onSelectedItemChanged: (index) {
                                  setDialogState(() {
                                    selectedWeek = index + 1;
                                  });
                                },
                                childDelegate: ListWheelChildBuilderDelegate(
                                  childCount: totalWeeks,
                                  builder: (context, index) {
                                    final week = index + 1;
                                    final isSelected = week == selectedWeek;
                                    return Container(
                                      alignment: Alignment.center,
                                      child: Text(
                                        '第 $week 周',
                                        style: TextStyle(
                                          fontSize: isSelected ? 18 : 16,
                                          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                          color: isSelected ? const Color(0xFF4A90E2) : Colors.grey.shade600,
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ),
                            const SizedBox(height: 16),
                            Row(
                              children: [
                                Expanded(
                                  child: OutlinedButton(
                                    onPressed: () => Navigator.pop(context),
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: Colors.grey.shade600,
                                      padding: const EdgeInsets.symmetric(vertical: 12),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      side: BorderSide(color: Colors.grey.shade300),
                                    ),
                                    child: const Text('取消'),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: ElevatedButton(
                                    onPressed: () {
                                      Navigator.pop(context);
                                      if (selectedWeek != _currentWeek) {
                                        setState(() {
                                          _currentWeek = selectedWeek;
                                        });
                                        _pageController.animateToPage(
                                          selectedWeek - 1,
                                          duration: const Duration(milliseconds: 400),
                                          curve: Curves.easeInOut,
                                        );
                                      }
                                    },
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFF4A90E2),
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets.symmetric(vertical: 12),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                    ),
                                    child: const Text('确定'),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      );
                    },
                  ),
    );
  }

  Widget _buildWeekNavButton({
    required IconData icon,
    required VoidCallback? onPressed,
  }) {
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 200),
      opacity: onPressed != null ? 1.0 : 0.3,
      child: Material(
        color: onPressed != null
            ? const Color(0xFF4A90E2).withValues(alpha: 0.1)
            : Colors.grey.shade100,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Icon(
              icon,
              color: onPressed != null
                  ? const Color(0xFF4A90E2)
                  : Colors.grey.shade400,
              size: 20,
            ),
          ),
        ),
      ),
    );
  }

  void _navigateWeek(int delta) {
    final totalWeeks = _effectiveTotalWeeks;
    final currentPage = _pageController.hasClients
        ? (_pageController.page?.round() ?? _currentWeek - 1)
        : _currentWeek - 1;
    final newPage = currentPage + delta;
    if (newPage >= 0 && newPage < _pageCount) {
      _pageController.animateToPage(
        newPage,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeInOut,
      );
    }
  }

  /// 构建壁纸背景：视频壁纸优先显示首帧过渡图，视频就绪后覆盖播放
  Widget _buildWallpaperBackground() {
    if (_isVideoWallpaper) {
      final videoReady = _videoController != null && _videoController!.value.isInitialized;
      return Stack(
        fit: StackFit.expand,
        children: [
          // 过渡层：首帧图片（视频未就绪时显示）
          if (_videoFirstFrameBytes != null)
            Image.memory(
              _videoFirstFrameBytes!,
              fit: BoxFit.cover,
              filterQuality: FilterQuality.none,
              gaplessPlayback: true,
            ),
          // 视频层：就绪后覆盖首帧
          if (videoReady)
            FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width: _videoController!.value.size.width,
                height: _videoController!.value.size.height,
                child: RepaintBoundary(
                  key: _videoRepaintKey,
                  child: VideoPlayer(_videoController!),
                ),
              ),
            ),
        ],
      );
    }
    // 图片壁纸
    if (_wallpaperBytes != null) {
      return Image.memory(
        _wallpaperBytes!,
        fit: BoxFit.cover,
        filterQuality: FilterQuality.none,
        gaplessPlayback: true,
      );
    }
    return Image.file(
      File(_wallpaperPath!),
      fit: BoxFit.cover,
      filterQuality: FilterQuality.none,
      gaplessPlayback: true,
    );
  }

  Widget _buildPageView() {
    final totalWeeks = _effectiveTotalWeeks;
    final pageCount = _pageCount;
    final hasWallpaper = _wallpaperEnabled && _wallpaperPath != null && File(_wallpaperPath!).existsSync();
    return Stack(
      children: [
        if (hasWallpaper)
          Positioned.fill(
            child: _buildWallpaperBackground(),
          ),
        // 禁用 overscroll（Android 12+ stretch 效果会导致 BackdropFilter 模糊失效）
        ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(
            overscroll: false,
          ),
          child: PageView.builder(
            controller: _pageController,
            physics: const ClampingScrollPhysics(),
            itemCount: pageCount,
            onPageChanged: (index) {
              setState(() {
                _previousWeek = _currentWeek;
                // 假期页（最后一页）的 _currentWeek 保持为最后一周
                _currentWeek = (index >= totalWeeks) ? totalWeeks : index + 1;
              });
            },
            itemBuilder: (context, index) {
              // 最后一页为假期页
              if (_isInHoliday && index == totalWeeks) {
                return _buildHolidayPage(hasWallpaper: hasWallpaper);
              }
              return _buildTimetableForWeek(index + 1, hasWallpaper: hasWallpaper);
            },
          ),
        ),
      ],
    );
  }

  /// 假期页面（作为 PageView 最后一页）
  Widget _buildHolidayPage({bool hasWallpaper = false}) {
    // 根据壁纸深浅决定文字颜色：浅色壁纸用深色字，深色壁纸用白字
    final textColor = hasWallpaper
        ? (_wallpaperIsLight ? const Color(0xFF1A1A2E) : Colors.white)
        : const Color(0xFF1A1A2E);
    return RepaintBoundary(
      child: SafeArea(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ShaderMask(
                shaderCallback: (bounds) => const LinearGradient(
                  colors: [
                    Color(0xFFFF6B6B),
                    Color(0xFFFFD93D),
                    Color(0xFF6BCB77),
                    Color(0xFF4D96FF),
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ).createShader(bounds),
                child: const Icon(
                  Icons.celebration_rounded,
                  size: 64,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                '本学期结束了！',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: textColor,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '右滑可查看课表哦',
                style: TextStyle(
                  fontSize: 13,
                  color: textColor.withValues(alpha: 0.6),
                ),
              ),
              const SizedBox(height: 32),
              // 按钮加透明度+模糊
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _buildHolidayButton(
                    label: '切换课表',
                    icon: Icons.swap_horiz,
                    textColor: textColor,
                    onTap: _showTimetableSwitcher,
                  ),
                  const SizedBox(width: 16),
                  _buildHolidayButton(
                    label: '新建课表',
                    icon: Icons.add,
                    textColor: textColor,
                    onTap: () => _showTimetableSwitcher(autoFocusNewField: true),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 假期页按钮：透明背景+模糊
  Widget _buildHolidayButton({
    required String label,
    required IconData icon,
    required Color textColor,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: textColor.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: textColor.withValues(alpha: 0.2),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 18, color: textColor.withValues(alpha: 0.8)),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    color: textColor.withValues(alpha: 0.9),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTimetableForWeek(int week, {bool hasWallpaper = false}) {
    const cellHeight = 75.0;
    const timeColumnWidth = 40.0;
    final topPadding = MediaQuery.of(context).padding.top;
    final headerHeight = topPadding + 48 + 52;
    final screenWidth = MediaQuery.of(context).size.width;
    final t = hasWallpaper ? (100 - _wallpaperOpacity) / 50.0 : 0.0;
    final scrollOffset = _pageScrollOffsets[week] ?? 0.0;
    final showBlur = hasWallpaper && _wallpaperBlurEnabled;

    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
          if (notification is ScrollUpdateNotification) {
            _pageScrollOffsets[week] = notification.metrics.pixels;
          }
          return false;
        },
      child: SingleChildScrollView(
        physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
        child: Padding(
          padding: EdgeInsets.only(top: headerHeight),
          child: Row(
            children: [
              _buildTimeColumn(cellHeight, timeColumnWidth, hasWallpaper: hasWallpaper),
              Expanded(
                child: Row(
                  children: List.generate(7, (dayIndex) {
                    return Expanded(
                      child: _buildDayColumn(dayIndex, cellHeight, week,
                        hasWallpaper: hasWallpaper,
                        transparencyFactor: t,
                        scrollOffset: scrollOffset,
                        screenWidth: screenWidth,
                        headerHeight: headerHeight,
                        timeColumnWidth: timeColumnWidth,
                        showBlur: showBlur,
                      ),
                    );
                  }),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  bool _isToday(DateTime date) {
    final now = DateTime.now();
    return date.year == now.year && date.month == now.month && date.day == now.day;
  }

  Widget _buildTimeColumn(double cellHeight, double width, {bool hasWallpaper = false}) {
    final timeTextColor = hasWallpaper
        ? (_wallpaperIsLight ? const Color(0xFF666E78) : const Color(0xFFD0D0D0))
        : Colors.grey.shade500;
    final timeNumColor = hasWallpaper
        ? (_wallpaperIsLight ? const Color(0xFF1A1A2E) : const Color(0xFFE8E8E8))
        : const Color(0xFF1A1A2E);
    return Container(
      width: width,
      decoration: BoxDecoration(
        color: hasWallpaper ? Colors.white.withValues(alpha: 0.5) : Colors.grey.shade50,
        border: Border(
          right: BorderSide(color: Colors.grey.shade200),
        ),
      ),
      child: Column(
        children: List.generate(_dailyPeriods, (index) {
          final timeSlot = index < _timeSlots.length ? _timeSlots[index] : null;
          return Container(
            height: cellHeight,
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: Colors.grey.shade200),
              ),
            ),
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    '${index + 1}',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: timeNumColor,
                    ),
                  ),
                  if (timeSlot != null) ...[
                    Text(
                      timeSlot['start']!,
                      style: TextStyle(
                        fontSize: 8,
                        color: timeTextColor,
                      ),
                    ),
                    Text(
                      timeSlot['end']!,
                      style: TextStyle(
                        fontSize: 8,
                        color: timeTextColor,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _buildDayColumn(int dayIndex, double cellHeight, int week, {
    bool hasWallpaper = false,
    double transparencyFactor = 1.0,
    double scrollOffset = 0.0,
    double screenWidth = 0.0,
    double headerHeight = 0.0,
    double timeColumnWidth = 40.0,
    bool showBlur = false,
  }) {
    return LayoutBuilder(builder: (context, columnConstraints) {
      // 该列的模糊区域（列内坐标，含非本周课程块）
      final columnBlurRRects = <RRect>[];
      if (showBlur) {
        final columnWidth = columnConstraints.maxWidth;
        for (int period = 0; period < _dailyPeriods; period++) {
          // morph 飞行中：源课程块由翻转卡片接管。课程块近乎完全隐没
          // （透明度 ≤5%）时才移除该格模糊区域，渐隐/渐显过程中模糊
          // 的消失/出现都发生在几乎不可见的时刻
          if (dayIndex == _morphHiddenDay &&
              period == _morphHiddenPeriod &&
              _morphBlockFade.value <= 0.05) {
            continue;
          }
          final sameStartCourses = _courses.where((c) =>
            c.day == dayIndex && c.time == period).toList();
          if (sameStartCourses.isEmpty) continue;
          final activeCourses = sameStartCourses.where((c) => _shouldShowCourse(c, week)).toList();
          // 「显示非本周课程」关闭：非本周课程块不渲染，也不加模糊区域
          if (activeCourses.isEmpty && !_showInactiveCourses) continue;
          final course = activeCourses.isEmpty
              ? _pickFallbackCourse(sameStartCourses, week)
              : activeCourses.first;
          // 出现动画期间：新课程块的模糊区域不走静态层（恒 sigma 8 会在
          // 动画开始前（420ms 对话框退出期内）就完整露出——「先出现一个
          // 模糊再出现动画」的根源），改由下方逐帧同步模糊层随出现动画
          // 渐入（与加号遮罩的同步模糊层同方案）
          if (course.id == _appearingCourseId) continue;
          columnBlurRRects.add(RRect.fromRectAndRadius(
            Rect.fromLTWH(
              2,
              cellHeight * period + 2,
              columnWidth - 4,
              course.duration * cellHeight - 4,
            ),
            const Radius.circular(5),
          ));
        }
        // 加号遮罩格子的模糊不再走 columnBlurRRects（那要求 isCompleted，
        // 表现为「出现动画播完才出现 / 收起动画开始前就消失」的阶跃切换）
        // ——改由下方独立的逐帧同步模糊层负责
      }
      // 出现动画中的课程（统一添加入口保存后）：其格子的模糊由下方
      // 逐帧同步模糊层渲染，静态模糊层已跳过（见上）
      Course? appearingCourse;
      if (_appearingCourseId != null) {
        for (final c in _courses) {
          if (c.id == _appearingCourseId) {
            appearingCourse = c;
            break;
          }
        }
      }
      return Container(
        decoration: BoxDecoration(
          color: hasWallpaper ? Colors.transparent : Colors.white,
          border: Border(
            right: BorderSide(color: Colors.grey.shade200),
          ),
        ),
        child: Stack(
          children: [
            _buildGridLines(cellHeight, dayIndex, week),
            // 模糊层置于网格线之上、课程块之下：开启壁纸模糊时跨节大课程块
            // 区域内的网格线也被模糊，不再透过半透明块露出清晰横线（割裂感）
            if (columnBlurRRects.isNotEmpty)
              Positioned.fill(
                child: IgnorePointer(
                  child: ClipPath(
                    clipper: _CourseBlurClipper(columnBlurRRects),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
              ),
            // 加号遮罩格子的模糊：sigma 与遮罩动画逐帧同步（出现时随遮罩
            // 渐显、收起时随遮罩渐隐，与遮罩本体同一缓动），全显时
            // sigma=8 与课程块模糊层一致；v=0 时不渲染
            if (showBlur &&
                _selectedEmptyDay == dayIndex &&
                _selectedEmptyPeriod != null)
              Positioned.fill(
                child: IgnorePointer(
                  child: AnimatedBuilder(
                    animation: _emptySlotMaskCurved,
                    builder: (context, _) {
                      final v = _emptySlotMaskCurved.value;
                      if (v <= 0.0) return const SizedBox.shrink();
                      return ClipPath(
                        clipper: _CourseBlurClipper([
                          RRect.fromRectAndRadius(
                            Rect.fromLTWH(
                              2,
                              cellHeight * _selectedEmptyPeriod! + 2,
                              columnConstraints.maxWidth - 4,
                              cellHeight - 4,
                            ),
                            const Radius.circular(5),
                          ),
                        ]),
                        child: BackdropFilter(
                          filter: ImageFilter.blur(
                            sigmaX: 8 * v,
                            sigmaY: 8 * v,
                          ),
                          child: const SizedBox.expand(),
                        ),
                      );
                    },
                  ),
                ),
              ),
            if (_selectedEmptyDay == dayIndex && _selectedEmptyPeriod != null)
              _buildEmptySlotSelection(
                _selectedEmptyPeriod!,
                cellHeight,
                hasWallpaper: hasWallpaper,
                transparencyFactor: transparencyFactor,
              ),
            // 新增课程块出现动画的模糊：sigma 与出现动画逐帧同步
            //（sigma = 8×t，与加号遮罩的同步模糊层同方案）——动画
            // 开始前（t=0）无模糊，卡片伸展变清晰的同时模糊渐入；
            // 动画完成（id 清空）末帧 sigma=8 与静态层无缝交接
            if (showBlur &&
                appearingCourse != null &&
                appearingCourse.day == dayIndex)
              Positioned.fill(
                child: IgnorePointer(
                  child: AnimatedBuilder(
                    animation: _appearCurved!,
                    builder: (context, _) {
                      final v = _appearCurved!.value;
                      if (v <= 0.0) return const SizedBox.shrink();
                      return ClipPath(
                        clipper: _CourseBlurClipper([
                          RRect.fromRectAndRadius(
                            Rect.fromLTWH(
                              2,
                              cellHeight * appearingCourse!.time + 2,
                              columnConstraints.maxWidth - 4,
                              appearingCourse.duration * cellHeight - 4,
                            ),
                            const Radius.circular(5),
                          ),
                        ]),
                        child: BackdropFilter(
                          filter: ImageFilter.blur(
                            sigmaX: 8 * v,
                            sigmaY: 8 * v,
                          ),
                          child: const SizedBox.expand(),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ..._buildCourseWidgets(dayIndex, cellHeight, week,
              hasWallpaper: hasWallpaper,
              transparencyFactor: transparencyFactor,
              scrollOffset: scrollOffset,
              screenWidth: screenWidth,
              headerHeight: headerHeight,
              timeColumnWidth: timeColumnWidth,
            ),
          ],
        ),
      );
    });
  }

  Widget _buildGridLines(double cellHeight, int dayIndex, int week) {
    return Column(
      children: List.generate(_dailyPeriods, (period) {
        return GestureDetector(
          onTap: () => _handleEmptySlotTap(dayIndex, period),
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: Container(
              height: cellHeight,
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: Colors.grey.shade200),
                ),
              ),
              child: const SizedBox.expand(),
            ),
          ),
        );
      }),
    );
  }

  /// 空白课程块两段式点击：第一次点击选中（显示遮罩+加号），第二次点击弹出添加课程对话框
  void _handleEmptySlotTap(int day, int period) {
    // 该格存在课程卡片（含跨多节课程覆盖的后续格）时绝不弹出加号遮罩——
    // 无论 morph 状态如何（接管期间课程块 IgnorePointer + 隐藏，点击会
    // 穿透到网格线；morph 归位 dismissed 瞬间标记已清但课程块可能尚未
    // 实际渲染到位，手速快会抢在这一帧点击原位），统一按"有课程即拦截"
    // 处理，彻底杜绝课程卡片处出现加号遮罩
    for (final c in _courses) {
      if (c.day == day &&
          period >= c.time &&
          period < c.time + c.duration) {
        return;
      }
    }
    // 任何点击交互都重置自动消失倒计时（下方各显示分支重新起算）
    _cancelEmptySlotAutoHideTimer();
    // 点击其它空白格显示加号遮罩时，收起可能仍在显示的非本周课程
    // 浮现卡片（避免两处提示同时存在）；无浮现时幂等直接返回
    _dismissInactivePeek();
    if (_selectedEmptyDay == day && _selectedEmptyPeriod == period) {
      // 第二次点击：测量遮罩矩形后弹出添加课程对话框——遮罩不收起：
      // morph 从遮罩原位起飞（t=0 复刻与遮罩像素重合），取消时 morph
      // 翻回归位、遮罩保持显示
      Rect? sourceRect;
      final maskContext = _emptySlotMaskContext;
      if (maskContext != null) {
        final renderObject = maskContext.findRenderObject();
        if (renderObject is RenderBox && renderObject.attached && renderObject.hasSize) {
          sourceRect = renderObject.localToGlobal(Offset.zero) & renderObject.size;
        }
      }
      _showCourseDialog(
        selectedDay: day,
        selectedPeriod: period,
        sourceRect: sourceRect,
        sourceWidget: _buildEmptySlotMaskReplica(),
        plusMaskSource: true,
      );
    } else if (_selectedEmptyDay != null || _selectedEmptyPeriod != null) {
      // 切换选中位置：当前遮罩动画收起后再淡入新位置
      _pendingEmptyDay = day;
      _pendingEmptyPeriod = period;
      _emptySlotMaskController.reverse();
    } else {
      setState(() {
        _selectedEmptyDay = day;
        _selectedEmptyPeriod = period;
      });
      _emptySlotMaskController.forward(from: 0);
      _startEmptySlotAutoHideTimer();
    }
  }

  /// 以动画方式收起加号遮罩（收起完成后清除选中状态）
  void _dismissEmptySlotMask() {
    _cancelEmptySlotAutoHideTimer();
    _pendingEmptyDay = null;
    _pendingEmptyPeriod = null;
    if (_selectedEmptyDay == null && _selectedEmptyPeriod == null) return;
    if (_emptySlotMaskController.value > 0) {
      _emptySlotMaskController.reverse();
    } else {
      setState(() {
        _selectedEmptyDay = null;
        _selectedEmptyPeriod = null;
      });
    }
  }

  /// 启动加号遮罩自动消失倒计时：满 5 秒自动收起（复用原有收起动画）。
  /// 重复调用先取消旧倒计时；首次点击显示、取消添加 morph 归位后调用
  void _startEmptySlotAutoHideTimer() {
    _emptySlotAutoHideTimer?.cancel();
    _emptySlotAutoHideTimer = Timer(const Duration(seconds: 5), () {
      if (!mounted) return;
      _dismissEmptySlotMask();
    });
  }

  void _cancelEmptySlotAutoHideTimer() {
    _emptySlotAutoHideTimer?.cancel();
    _emptySlotAutoHideTimer = null;
  }

  /// 非本周课程卡片开始浮现：淡入动画（240ms easeOutCubic）+ 5 秒
  /// 自动淡出倒计时。重复点击同一格重置计时；点击另一格切换浮现对象
  void _beginInactivePeek(Course course) {
    if (!mounted) return;
    _inactivePeekTimer?.cancel();
    _inactivePeekCurved?.dispose();
    _inactivePeekController?.dispose();
    _inactivePeekController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
    );
    _inactivePeekCurved = CurvedAnimation(
      parent: _inactivePeekController!,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    setState(() => _inactivePeekCourseId = course.id);
    _inactivePeekController!.forward(from: 0);
    _inactivePeekPauseCount = 0;
    _inactivePeekPausedRemaining = null;
    _startInactivePeekTimer(const Duration(seconds: 5));
  }

  /// 启动/续接浮现倒计时（记录到期时刻，暂停时用于计算剩余时长）
  void _startInactivePeekTimer(Duration remaining) {
    _inactivePeekTimer?.cancel();
    _inactivePeekDeadline = DateTime.now().add(remaining);
    _inactivePeekTimer = Timer(remaining, () {
      if (!mounted) return;
      _dismissInactivePeek();
    });
  }

  /// 暂停浮现倒计时（卡片保持显示、暂停期间不走表）：点击浮现卡片
  /// 打开课程详情/长按呼出菜单/打开编辑或添加对话框时调用，对应关闭
  /// 回调配对调用 _resumeInactivePeek。可嵌套（菜单→编辑对话框链），
  /// 仅当计数归零才真正续接计时。无浮现时幂等返回
  void _pauseInactivePeek() {
    if (_inactivePeekCourseId == null) return;
    final timer = _inactivePeekTimer;
    if (timer != null) {
      var remaining =
          _inactivePeekDeadline?.difference(DateTime.now()) ?? Duration.zero;
      if (remaining < Duration.zero) remaining = Duration.zero;
      _inactivePeekPausedRemaining = remaining;
      timer.cancel();
      _inactivePeekTimer = null;
    }
    _inactivePeekPauseCount++;
  }

  /// 续接浮现倒计时：详情对话框/长按菜单/编辑添加对话框关闭时调用。
  /// 嵌套计数未归零（上层对话框仍开着）时不续接；无浮现或从未暂停时
  /// 幂等返回；剩余时长耗尽则直接收起
  void _resumeInactivePeek() {
    if (_inactivePeekCourseId == null) return;
    if (_inactivePeekPauseCount > 0) _inactivePeekPauseCount--;
    if (_inactivePeekPauseCount > 0 || _inactivePeekTimer != null) return;
    final remaining = _inactivePeekPausedRemaining;
    _inactivePeekPausedRemaining = null;
    if (remaining == null) return;
    if (remaining <= Duration.zero) {
      _dismissInactivePeek();
      return;
    }
    _startInactivePeekTimer(remaining);
  }

  /// 以动画方式收起非本周课程浮现卡片（5 秒到期/滑动切周触发）
  void _dismissInactivePeek() {
    _inactivePeekTimer?.cancel();
    _inactivePeekTimer = null;
    _inactivePeekPauseCount = 0;
    _inactivePeekPausedRemaining = null;
    if (_inactivePeekCourseId == null) return;
    if (_inactivePeekController != null &&
        _inactivePeekController!.value > 0) {
      final id = _inactivePeekCourseId;
      _inactivePeekController!.reverse().whenComplete(() {
        if (mounted && _inactivePeekCourseId == id) {
          setState(() => _inactivePeekCourseId = null);
        }
      });
    } else {
      setState(() => _inactivePeekCourseId = null);
    }
  }

  /// 被隐藏的非本周课程原位的透明点击区：点击触发原课程卡片短暂
  /// 浮现；浮现期间以添加课程同款动画（淡入=由模糊变清晰+由内部
  /// 伸展，反向收起即删除课程样式）显示灰色原课程卡片
  Widget _buildInactivePeekSlot(
    Course course,
    int period,
    double cellHeight, {
    bool hasWallpaper = false,
    double transparencyFactor = 1.0,
    // morph 飞行中：浮现卡片由翻转卡片（复刻）接管，随 _morphBlockFade
    // 渐隐/渐显。Opacity/IgnorePointer 必须包在 Positioned **内部**——
    // Positioned 是 Stack 的直接子级，ParentData 才能正确落到 RenderStack
    //（包在外部会触发 Incorrect use of ParentDataWidget，窄屏/任意屏上
    // 展开该卡片时课表网格与其它课程卡片消失、所在列变灰）
    double? morphOpacity,
  }) {
    Widget content = _inactivePeekCourseId == course.id && _inactivePeekCurved != null
        ? Builder(
              builder: (context) {
                // 浮现期间可点按/长按（与正常课程块一致）：点击打开课程
                // 详情（morph 从浮现卡片原位起飞，起飞前瞬时清除浮现，
                // 复刻与浮现卡片像素重合无闪现）；长按弹出课程块菜单
                final card = _buildCourseCellCard(
                  course,
                  isInactiveInCurrentWeek: true,
                  hasWallpaper: hasWallpaper,
                  transparencyFactor: transparencyFactor,
                );
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    // 卡片保持显示、倒计时暂停（morph 复刻 t=0 与浮现
                    // 卡片像素重合），详情关闭后续接剩余倒计时
                    _pauseInactivePeek();
                    _showCourseDetail(
                      course,
                      sourceContext: context,
                      sourceWidget: card,
                    );
                  },
                  onLongPress: () => _showCourseBlockMenu(course, context),
                  child: AnimatedBuilder(
                    animation: _inactivePeekCurved!,
                    builder: (context, _) {
                      final t = _inactivePeekCurved!.value;
                      final blur = 12 * (1 - t);
                      // t=0 完全不可见；blur≈0 时跳过 ImageFiltered
                      //（sigma≈0 的 blur 在 Impeller 上渲染成空白）
                      return Opacity(
                        opacity: t,
                        child: Transform.scale(
                          scale: 0.55 + 0.45 * t,
                          child: blur > 0.05
                              ? ImageFiltered(
                                  imageFilter: ImageFilter.blur(
                                    sigmaX: blur,
                                    sigmaY: blur,
                                  ),
                                  child: card,
                                )
                              : card,
                        ),
                      );
                    },
                  ),
                );
              },
            )
          : GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () => _beginInactivePeek(course),
              child: const SizedBox.expand(),
            );
    // morph 接管期：整个 Positioned 的内容随 _morphBlockFade 渐隐/渐显
    //（包在 Positioned 内部，Positioned 仍是 Stack 的直接子级）
    if (morphOpacity != null) {
      content = IgnorePointer(
        child: Opacity(opacity: morphOpacity, child: content),
      );
    }
    return Positioned(
      top: period * cellHeight + 2,
      left: 2,
      right: 2,
      height: course.duration * cellHeight - 4,
      child: content,
    );
  }

  /// 空白课程块选中后的灰白色遮罩（与非本周课程样式一致，仅占一个小节），中部显示灰色加号
  Widget _buildEmptySlotSelection(int period, double cellHeight, {
    bool hasWallpaper = false,
    double transparencyFactor = 1.0,
  }) {
    final inactiveT = hasWallpaper ? transparencyFactor : 0.4;
    final backgroundStart = const Color(0xFFF4F5F7).withValues(alpha: lerpDouble(1.0, 0.25, inactiveT)!);
    final backgroundEnd = const Color(0xFFEDEFF2).withValues(alpha: lerpDouble(1.0, 0.18, inactiveT)!);
    final borderColor = const Color(0xFFDDE1E6).withValues(alpha: lerpDouble(0.85, 0.7, inactiveT)!);
    final iconColor = const Color(0xFF8C939C).withValues(alpha: lerpDouble(1.0, 0.7, inactiveT)!);

    return Positioned(
      top: period * cellHeight + 2,
      left: 2,
      right: 2,
      height: cellHeight - 4,
      child: IgnorePointer(
        child: Builder(
          builder: (context) {
            // 无条件注册：构建期子树尚未挂载时 findRenderObject() 会返回 null，
            // 条件判断会导致注册永远不生效（点击时测量，attached 检查可兜底陈旧上下文）
            _emptySlotMaskContext = context;
            final curved = _emptySlotMaskCurved;
            return AnimatedBuilder(
              animation: curved,
              builder: (context, child) {
                final t = curved.value;
                return Opacity(
                  opacity: t,
                  child: Transform.scale(
                    scale: 0.9 + 0.1 * t,
                    child: child,
                  ),
                );
              },
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [backgroundStart, backgroundEnd],
                  ),
                  border: Border.all(color: borderColor),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Center(
                  child: Icon(Icons.add, size: 24, color: iconColor),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  List<Widget> _buildCourseWidgets(int dayIndex, double cellHeight, int week, {
    bool hasWallpaper = false,
    double transparencyFactor = 1.0,
    double scrollOffset = 0.0,
    double screenWidth = 0.0,
    double headerHeight = 0.0,
    double timeColumnWidth = 40.0,
  }) {
    final widgets = <Widget>[];

    for (int period = 0; period < _dailyPeriods; period++) {
      final sameStartCourses = _courses.where((c) {
        return c.day == dayIndex && c.time == period;
      }).toList();

      if (sameStartCourses.isEmpty) {
        continue;
      }

      // morph 飞行中：源课程块由翻转卡片（复刻）接管——瞬时隐藏/
      // 显现（_morphBlockFade 两向 Duration.zero）：卡片第 0 帧即与
      // 课程块像素重合，无需渐隐衔接；渐隐反而使半透明卡片叠在渐隐
      // 块上叠出「实色块」（不透明闪现 bug）
      final isMorphSourceCell =
          dayIndex == _morphHiddenDay && period == _morphHiddenPeriod;

      final activeCourses = sameStartCourses.where((c) => _shouldShowCourse(c, week)).toList();
      final isInactiveInCurrentWeek = activeCourses.isEmpty;
      // 设置页「显示非本周课程」关闭：非本周课程不再以灰色卡片显示，
      // 原位改放透明点击区——点击后原课程卡片淡入短暂显示 5s（见
      // _beginInactivePeek），左右滑动切换周页自动隐藏（同加号遮罩）
      if (isInactiveInCurrentWeek && !_showInactiveCourses) {
        final hiddenCourse = _pickFallbackCourse(sameStartCourses, week);
        // morph 飞行中：浮现卡片与真课程块同样由翻转卡片（复刻）接管，
        // 随 _morphBlockFade 渐隐/渐显（Opacity 包在 Positioned 内部，
        // 避免将 Positioned 包进 IgnorePointer/Opacity 破坏 Stack 布局）
        final cell = _buildInactivePeekSlot(
          hiddenCourse,
          period,
          cellHeight,
          hasWallpaper: hasWallpaper,
          transparencyFactor: transparencyFactor,
          morphOpacity: isMorphSourceCell ? _morphBlockFade.value : null,
        );
        widgets.add(cell);
        continue;
      }
        final course = isInactiveInCurrentWeek
          ? _pickFallbackCourse(sameStartCourses, week)
          : activeCourses.first;

      final hasAlternativeCourses = sameStartCourses.length > 1;

      Widget cell = _buildCourseCell(
        course,
        hasAlternativeCourses: hasAlternativeCourses,
        isInactiveInCurrentWeek: isInactiveInCurrentWeek,
        hasWallpaper: hasWallpaper,
        transparencyFactor: transparencyFactor,
        week: week,
      );
      if (isMorphSourceCell) {
        cell = IgnorePointer(
          child: Opacity(opacity: _morphBlockFade.value, child: cell),
        );
      }
      widgets.add(
        Positioned(
          top: period * cellHeight + 2,
          left: 2,
          right: 2,
          height: course.duration * cellHeight - 4,
          child: cell,
        ),
      );
    }

    return widgets;
  }

  bool _shouldShowCourse(Course course, int week) {
    if (course.weeks == null || course.weeks!.isEmpty) return true;

    final weeks = _parseWeeks(course.weeks!);
    return weeks.contains(week);
  }

  /// 多课程叠加但本周都不上时选「代表课程」：
  /// 全部未开始 → 开始周离本周最近者；已全部结束 → 结束周离本周最近者；
  /// 并列时保持列表原序（稳定）。网格卡片、模糊层、非本周浮现位共用
  Course _pickFallbackCourse(List<Course> courses, int week) {
    Course pick(Course best, Course c, int Function(Course) dist) {
      final dc = dist(c);
      final db = dist(best);
      if (dc < db) return c;
      return best;
    }

    int startDist(Course c) {
      final weeks = _parseWeeks(c.weeks ?? '');
      if (weeks.isEmpty) return 0;
      return weeks.reduce((a, b) => a < b ? a : b) - week;
    }

    int endDist(Course c) {
      final weeks = _parseWeeks(c.weeks ?? '');
      if (weeks.isEmpty) return 0;
      return week - weeks.reduce((a, b) => a > b ? a : b);
    }

    final allNotStarted = courses.every((c) => startDist(c) > 0);
    if (allNotStarted) {
      return courses.reduce((best, c) => pick(best, c, startDist));
    }
    return courses.reduce((best, c) => pick(best, c, endDist));
  }

  Set<int> _parseWeeks(String weeks) {
    final result = <int>{};
    String cleaned = weeks.replaceAll('连', '').replaceAll('周', '').replaceAll(' ', '');
    final parts = cleaned.split(',');
    for (var part in parts) {
      part = part.trim();
      if (part.contains('-')) {
        final range = part.split('-');
        if (range.length == 2) {
          final start = int.tryParse(range[0].trim());
          final end = int.tryParse(range[1].trim());
          if (start != null && end != null) {
            for (var i = start; i <= end; i++) {
              result.add(i);
            }
          }
        }
      } else {
        final week = int.tryParse(part);
        if (week != null) result.add(week);
      }
    }
    return result;
  }

  Color _lighten(Color c, double amount) {
    return Color.fromARGB(
      255,
      (c.red + (255 - c.red) * amount).round(),
      (c.green + (255 - c.green) * amount).round(),
      (c.blue + (255 - c.blue) * amount).round(),
    );
  }

  Widget _buildCourseCell(
    Course course, {
    bool hasAlternativeCourses = false,
    bool isInactiveInCurrentWeek = false,
    bool hasWallpaper = false,
    double transparencyFactor = 1.0,
    required int week,
  }) {
    // 卡片视觉提取到 _buildCourseCellCard：同一实例既渲染在网格内，
    // 也作为 morph 翻转动画的「正面」复刻（与真实课程块像素级一致）
    final card = _buildCourseCellCard(
      course,
      isInactiveInCurrentWeek: isInactiveInCurrentWeek,
      hasWallpaper: hasWallpaper,
      transparencyFactor: transparencyFactor,
      hasAlternativeCourses: hasAlternativeCourses,
    );

    // 供点击回调捕获课程块自身的 BuildContext，用于容器变换动画的起始矩形
    BuildContext? cellContext;
    // 挂 key：删除动画启动前测量课程块屏幕矩形（见 _courseCellKeys）。
    // key 必须带周次：PageView 滑动过程中相邻两页同时存活，同一门跨周
    // 课程在两页各渲染一份 cell——共用同一 GlobalKey 会触发元素被跨页
    // 抢占/注销，表现为滑动切换后某页课程块整周消失（本次修复的 bug）
    final cellKey =
        _courseCellKeys.putIfAbsent('${course.id}@$week', () => GlobalKey());
    return Builder(
      builder: (context) {
        cellContext = context;
        return GestureDetector(
          onTap: () => _showCourseDetail(
            course,
            sourceContext: cellContext,
            sourceWidget: card,
          ),
          onLongPress: () => _showCourseBlockMenu(course, cellContext),
          child: KeyedSubtree(
            key: cellKey,
            // 新增课程块出现动画（统一添加入口保存成功）：由内部伸展
            //（0.55→1）+ 由模糊变清晰（sigma 12→0）。t≈1 时跳过
            // ImageFiltered（sigma≈0 的 blur 在 Impeller 上渲染成空白）
            child: _appearingCourseId == course.id
                ? AnimatedBuilder(
                    animation: _appearCurved!,
                    builder: (context, _) {
                      final t = _appearCurved!.value;
                      final blur = 12 * (1 - t);
                      // 淡入：t=0（对话框退出动画播完前）完全不可见，
                      // 避免新块在退出动画期间就以完整形态露出
                      return Opacity(
                        opacity: t,
                        child: Transform.scale(
                          scale: 0.55 + 0.45 * t,
                          child: blur > 0.05
                              ? ImageFiltered(
                                  imageFilter: ImageFilter.blur(
                                    sigmaX: blur,
                                    sigmaY: blur,
                                  ),
                                  child: card,
                                )
                              : card,
                        ),
                      );
                    },
                  )
                : card,
          ),
        );
      },
    );
  }

  /// 课程块的纯视觉卡片（无手势）：网格渲染与 morph 翻转「正面」共用，
  /// 保证动画起始帧与真实课程块完全一致
  Widget _buildCourseCellCard(
    Course course, {
    bool isInactiveInCurrentWeek = false,
    bool hasWallpaper = false,
    double transparencyFactor = 1.0,
    bool hasAlternativeCourses = false,
  }) {
    final t = transparencyFactor;
    final displayColor = _parseColor(course.color);

    final LinearGradient gradient;
    final Color titleColor;
    final Color metaColor;
    final Color triangleColor;
    final Color borderColor;
    if (!isInactiveInCurrentWeek) {
      final effectiveT = hasWallpaper ? t : 0.4;
      final lightColor = _lighten(displayColor, 0.55);
      gradient = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          lightColor.withValues(alpha: lerpDouble(1.0, 0.25, effectiveT)!),
          lightColor.withValues(alpha: lerpDouble(1.0, 0.18, effectiveT)!),
        ],
      );
      titleColor = displayColor;
      metaColor = displayColor;
      triangleColor = displayColor;
      borderColor = displayColor.withValues(alpha: lerpDouble(0.2, 0.06, effectiveT)!);
    } else {
      final inactiveT = hasWallpaper ? t : 0.4;
      gradient = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          const Color(0xFFF4F5F7).withValues(alpha: lerpDouble(1.0, 0.25, inactiveT)!),
          const Color(0xFFEDEFF2).withValues(alpha: lerpDouble(1.0, 0.18, inactiveT)!),
        ],
      );
      titleColor = const Color(0xFF8C939C).withValues(alpha: lerpDouble(1.0, 0.7, inactiveT)!);
      metaColor = const Color(0xFFA2A8B0).withValues(alpha: lerpDouble(1.0, 0.6, inactiveT)!);
      triangleColor = const Color(0xFFCDD2D9).withValues(alpha: lerpDouble(1.0, 0.65, inactiveT)!);
      borderColor = const Color(0xFFDDE1E6).withValues(alpha: lerpDouble(0.85, 0.7, inactiveT)!);
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      decoration: BoxDecoration(
        gradient: gradient,
        border: Border.all(color: borderColor),
        borderRadius: BorderRadius.circular(5),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(5),
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  course.name,
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: titleColor, height: 1.15),
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                ),
                if (course.location != null && course.location!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Text('@${course.location!}', style: TextStyle(fontSize: 9, color: metaColor, height: 1.1), maxLines: 2, overflow: TextOverflow.ellipsis),
                  ),
                if (course.teacher != null && course.teacher!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Text(course.teacher!, style: TextStyle(fontSize: 9, color: metaColor, height: 1.1), maxLines: 2, overflow: TextOverflow.ellipsis),
                  ),
              ],
            ),
            if (hasAlternativeCourses)
              Positioned(
                right: 0,
                bottom: 0,
                child: SizedBox(width: 12, height: 12, child: CustomPaint(painter: _CornerTrianglePainter(color: triangleColor))),
              ),
          ],
        ),
      ),
    );
  }

  /// 按当前课表状态推导参数，构建课程块卡片的静态复刻：
  /// 长按菜单等入口打开 morph 对话框时用作翻转动画的「正面」
  Widget _buildCourseCellReplica(Course course) {
    final hasWallpaper = _wallpaperEnabled && _wallpaperPath != null && File(_wallpaperPath!).existsSync();
    final t = hasWallpaper ? (100 - _wallpaperOpacity) / 50.0 : 0.0;
    final sameStartCourses = _courses
        .where((c) => c.day == course.day && c.time == course.time)
        .toList();
    final activeCourses = sameStartCourses.where((c) => _shouldShowCourse(c, _currentWeek)).toList();
    return _buildCourseCellCard(
      course,
      isInactiveInCurrentWeek: activeCourses.isEmpty,
      hasWallpaper: hasWallpaper,
      transparencyFactor: t,
      hasAlternativeCourses: sameStartCourses.length > 1,
    );
  }

  /// 加号遮罩的静态复刻（样式与 _buildEmptySlotSelection 一致）：
  /// 第二次点击空白格弹出添加课程对话框时用作翻转动画的「正面」
  Widget _buildEmptySlotMaskReplica() {
    final hasWallpaper = _wallpaperEnabled && _wallpaperPath != null && File(_wallpaperPath!).existsSync();
    final t = hasWallpaper ? (100 - _wallpaperOpacity) / 50.0 : 0.0;
    final inactiveT = hasWallpaper ? t : 0.4;
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            const Color(0xFFF4F5F7).withValues(alpha: lerpDouble(1.0, 0.25, inactiveT)!),
            const Color(0xFFEDEFF2).withValues(alpha: lerpDouble(1.0, 0.18, inactiveT)!),
          ],
        ),
        border: Border.all(color: const Color(0xFFDDE1E6).withValues(alpha: lerpDouble(0.85, 0.7, inactiveT)!)),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Center(
        child: Icon(Icons.add, size: 24, color: const Color(0xFF8C939C).withValues(alpha: lerpDouble(1.0, 0.7, inactiveT)!)),
      ),
    );
  }

  void _showCourseDetail(Course course, {BuildContext? sourceContext, Widget? sourceWidget}) {
    final slotCourses = _courses
        .where((c) => c.day == course.day && c.time == course.time)
        .toList();
    if (slotCourses.isEmpty) {
      return;
    }

    // 打开详情时以动画方式收起加号遮罩
    _dismissEmptySlotMask();

    // 捕获被点击课程块在屏幕上的矩形，作为打开/关闭容器变换动画的起止位置
    Rect? sourceRect;
    if (sourceContext != null) {
      final renderObject = sourceContext.findRenderObject();
      if (renderObject is RenderBox && renderObject.attached && renderObject.hasSize) {
        sourceRect = renderObject.localToGlobal(Offset.zero) & renderObject.size;
      }
    }

    slotCourses.sort((a, b) {
      final aRank = _shouldShowCourse(a, _currentWeek) ? 0 : 1;
      final bRank = _shouldShowCourse(b, _currentWeek) ? 0 : 1;
      if (aRank != bRank) return aRank - bRank;
      return a.name.compareTo(b.name);
    });

    // 翻转卡片接管源课程块的时机由 _MorphDialogHost 控制：
    // onSourceHidden——路由首帧（隐形测量帧）结束后标记接管，课程块
    // 渐隐溶解（复刻卡片同帧起飞盖在其上，交叉无感）；
    // onLanding——关闭动画播完（dismissed）时课程块瞬时显现，与
    // 末帧复刻（像素一致）同帧交接（动画结束前绝不出现）；
    // onDismissed——同一时刻清除接管标记（课程块已恢复）。
    // land/restore 带代数校验：详情→编辑链中编辑对话框已重新接管同格，
    // 详情（过期代数）的收尾不得把 fade 拉回 1、清掉编辑的接管标记
    // （课程块会在编辑打开期间提前出现在网格上——竞态修复）
    final takeoverSeq = ++_morphTakeoverSeq;
    void hideSourceBlock() {
      if (!mounted) return;
      setState(() {
        _morphHiddenDay = course.day;
        _morphHiddenPeriod = course.time;
      });
      _morphBlockFade.reverse();
    }

    void landSourceBlock() {
      if (!mounted || takeoverSeq != _morphTakeoverSeq) return;
      _morphBlockFade.forward();
    }

    void restoreSourceBlock() {
      if (!mounted ||
          takeoverSeq != _morphTakeoverSeq ||
          (_morphHiddenDay == null && _morphHiddenPeriod == null)) {
        return;
      }
      setState(() {
        _morphHiddenDay = null;
        _morphHiddenPeriod = null;
      });
      // 详情 morph 落定：播挂起的删除幽灵（morph 期间确认删除的场景，
      // 见 _deleteCourseWithConfirmation；无挂起则 no-op）
      _flushPendingVanish();
    }

    int currentPage = slotCourses.indexWhere((c) => _shouldShowCourse(c, _currentWeek));
    if (currentPage == -1) {
      currentPage = slotCourses.indexWhere((c) => c.id == course.id);
    }
    if (currentPage == -1) {
      currentPage = 0;
    }
    var previousPage = currentPage;

    final pageController = PageController(initialPage: currentPage);
    final editButtonKey = GlobalKey();
    // 挂在详情对话框壳上：morph/孔洞测量壳矩形本身（不含水平 margin）
    final detailShellKey = GlobalKey();
    // 卡片模糊跟随：壁纸模式且设置开启「卡片模糊」时，morph 卡片正面
    // 背后以同 sigma（22.0，与编辑/添加对话框场景一致）实时模糊，
    // 起飞/落定帧与网格上的真实课程块（覆于模糊层上）视觉一致；
    // 课程块透明度由复刻颜色 alpha 跟随设置
    final detailHasWallpaper = _wallpaperEnabled &&
        _wallpaperPath != null &&
        File(_wallpaperPath!).existsSync();
    final detailBackdropBlur =
        detailHasWallpaper && _wallpaperBlurEnabled ? 22.0 : null;

    // 课程详情内容（morph 宿主与减弱动态的统一对话框共用）：
    // 减弱动态时由 showBouncyDialog 的壳包裹（无模糊、高不透明度），
    // 默认路径在 builder 内自行包 morph 专用壳
    Widget buildDetailContent() => StatefulBuilder(
            builder: (context, setDialogState) {
            final currentCourse = slotCourses[currentPage];
            final courseColor = _parseColor(currentCourse.color);
            final dialogTasks = _getDialogTasksForCourse(currentCourse);
            final dialogWidth = math.min(420.0, MediaQuery.of(context).size.width - 48);
            final headerHeight = _calculateCourseHeaderHeight(
              course: currentCourse,
              dialogWidth: dialogWidth,
              textDirection: Directionality.of(context),
            );
            final headerContentHeight = (headerHeight - 40).clamp(24.0, double.infinity).toDouble();
            final iconBoxSize = headerContentHeight.clamp(24.0, 48.0).toDouble();
            final iconGlyphSize = (iconBoxSize * 0.5).clamp(14.0, 24.0).toDouble();
            final closeBoxSize = headerContentHeight.clamp(24.0, 30.0).toDouble();
            final closeGlyphSize = (closeBoxSize * 0.6).clamp(14.0, 18.0).toDouble();
            final dynamicMaxHeight = (505.0 + (dialogTasks.length.clamp(0, 5) * 20.0))
                .clamp(505.0, 590.0)
                .toDouble();

            final Widget content = Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Opacity(
                                  opacity: 0.82,
                                  child: AnimatedContainer(
                                    duration: const Duration(milliseconds: 320),
                                    curve: Curves.easeInOutCubic,
                                    height: headerHeight,
                                    padding: const EdgeInsets.all(20),
                                    decoration: BoxDecoration(
                                      gradient: LinearGradient(
                                        colors: [
                                          courseColor.withValues(alpha: 0.42),
                                          courseColor.withValues(alpha: 0.16),
                                        ],
                                      ),
                                      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
                                    ),
                                    child: Row(
                                children: [
                                  // 课程图标：单一静态组件（不随课程重建），
                                  // 尺寸随头部高度平滑缩放、颜色随课程渐变，
                                  // 垂直位置随头部高度动画自然平滑位移保持居中
                                  AnimatedContainer(
                                    duration: const Duration(milliseconds: 260),
                                    curve: Curves.easeOut,
                                    width: iconBoxSize,
                                    height: iconBoxSize,
                                    decoration: BoxDecoration(
                                      color: courseColor.withValues(alpha: 0.28),
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Center(
                                      child: TweenAnimationBuilder<Color?>(
                                        duration: const Duration(milliseconds: 260),
                                        tween: ColorTween(end: courseColor),
                                        builder: (context, color, child) {
                                          return Icon(
                                            Icons.book,
                                            size: iconGlyphSize,
                                            color: color,
                                          );
                                        },
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 16),
                                  Expanded(
                                    child: AnimatedSwitcher(
                                      duration: const Duration(milliseconds: 350),
                                      switchInCurve: Curves.easeOut,
                                      switchOutCurve: Curves.easeIn,
                                      // 切换课程时文字原地模糊淡入淡出 + 轻微
                                      // 原地缩放（参考登录对话框副标题切换）；
                                      // 「减弱动态效果」开启时去掉模糊，保留
                                      // 同时长的淡入淡出与缩放
                                      transitionBuilder: (child, anim) {
                                        if (_reduceMotionEnabled) {
                                          return FadeTransition(
                                            opacity: anim,
                                            child: AnimatedBuilder(
                                              animation: anim,
                                              builder: (context, grandChild) => Transform.scale(
                                                scale: 0.94 + 0.06 * anim.value,
                                                child: grandChild,
                                              ),
                                              child: child,
                                            ),
                                          );
                                        }
                                        return FadeTransition(
                                          opacity: anim,
                                          child: AnimatedBuilder(
                                            animation: anim,
                                            builder: (context, grandChild) => ImageFiltered(
                                              imageFilter: ImageFilter.blur(
                                                sigmaX: 8 * (1.0 - anim.value),
                                                sigmaY: 8 * (1.0 - anim.value),
                                              ),
                                              child: Transform.scale(
                                                scale: 0.94 + 0.06 * anim.value,
                                                child: grandChild,
                                              ),
                                            ),
                                            child: child,
                                          ),
                                        );
                                      },
                                      layoutBuilder: (currentChild, previousChildren) {
                                        return currentChild ?? const SizedBox.shrink();
                                      },
                                      child: Column(
                                        key: ValueKey(currentCourse.id),
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            currentCourse.name,
                                            style: TextStyle(
                                              fontSize: 20,
                                              fontWeight: FontWeight.bold,
                                              color: courseColor,
                                              height: 1.2,
                                            ),
                                            maxLines: 4,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                          if (currentCourse.location != null && currentCourse.location!.isNotEmpty)
                                            Text(
                                              '@${currentCourse.location!}',
                                              style: TextStyle(
                                                fontSize: 14,
                                                color: Colors.grey.shade600,
                                                height: 1.2,
                                              ),
                                              maxLines: 3,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          if (currentCourse.teacher != null && currentCourse.teacher!.isNotEmpty)
                                            Text(
                                              currentCourse.teacher!,
                                              style: TextStyle(
                                                fontSize: 14,
                                                color: Colors.grey.shade600,
                                                height: 1.2,
                                              ),
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  // 关闭按钮：单一静态组件——不缩放、不变色，
                                  // 仅随头部高度动画平滑位移保持居中（高度不变
                                  // 时完全静止，消除此前按课程 id 重建的闪现）
                                  GestureDetector(
                                    onTap: () => Navigator.pop(context),
                                    child: Container(
                                      width: closeBoxSize,
                                      height: closeBoxSize,
                                      decoration: BoxDecoration(
                                        color: Colors.black.withValues(alpha: 0.05),
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Icon(
                                        Icons.close,
                                        size: closeGlyphSize,
                                        color: Colors.grey.shade600,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                                ),
                                ),
                            Flexible(
                              child: PageView.builder(
                                controller: pageController,
                                physics: slotCourses.length > 1
                                    ? const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics())
                                    : const NeverScrollableScrollPhysics(),
                                onPageChanged: (index) {
                                  setDialogState(() {
                                    previousPage = currentPage;
                                    currentPage = index;
                                  });
                                },
                                itemCount: slotCourses.length,
                                itemBuilder: (context, index) {
                                  final pageCourse = slotCourses[index];
                                  final pageColor = _parseColor(pageCourse.color);
                                  final pageTimeSlot = pageCourse.time < _timeSlots.length ? _timeSlots[pageCourse.time] : null;
                                  final pageTasks = _getDialogTasksForCourse(pageCourse);

                                  return SingleChildScrollView(
                                    physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
                                    padding: const EdgeInsets.all(20),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Expanded(
                                              child: _buildDetailRowCompact(
                                                Icons.calendar_today,
                                                '时间',
                                                '周${_weekDays[pageCourse.day]} ${pageTimeSlot != null ? pageTimeSlot['start']! : '第${pageCourse.time + 1}节'}',
                                                onTap: () {
                                                  Navigator.pop(context);
                                                  WidgetsBinding.instance.addPostFrameCallback((_) {
                                                    if (!mounted) return;
                                                    _showCourseDialog(course: pageCourse, initialFocusSection: CourseEditFocusSection.time);
                                                  });
                                                },
                                              ),
                                            ),
                                            const SizedBox(width: 16),
                                            Expanded(
                                              child: _buildDetailRowCompact(
                                                Icons.access_time,
                                                '时长',
                                                '${pageCourse.duration} 节',
                                                onTap: () {
                                                  Navigator.pop(context);
                                                  WidgetsBinding.instance.addPostFrameCallback((_) {
                                                    if (!mounted) return;
                                                    _showCourseDialog(course: pageCourse, initialFocusSection: CourseEditFocusSection.time);
                                                  });
                                                },
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 12),
                                        Row(
                                          children: [
                                            Expanded(
                                              child: _buildDetailRowCompact(
                                                Icons.location_on_outlined,
                                                '地点',
                                                pageCourse.location != null && pageCourse.location!.isNotEmpty
                                                    ? pageCourse.location!
                                                    : '未设置',
                                                onTap: () {
                                                  Navigator.pop(context);
                                                  WidgetsBinding.instance.addPostFrameCallback((_) {
                                                    if (!mounted) return;
                                                    _showCourseDialog(course: pageCourse, initialFocusSection: CourseEditFocusSection.basicInfo);
                                                  });
                                                },
                                              ),
                                            ),
                                            const SizedBox(width: 16),
                                            Expanded(
                                              child: _buildDetailRowCompact(
                                                Icons.date_range,
                                                '周次',
                                                pageCourse.weeks != null && pageCourse.weeks!.isNotEmpty
                                                    ? pageCourse.weeks!
                                                    : '未设置',
                                                onTap: () {
                                                  Navigator.pop(context);
                                                  WidgetsBinding.instance.addPostFrameCallback((_) {
                                                    if (!mounted) return;
                                                    _showCourseDialog(course: pageCourse, initialFocusSection: CourseEditFocusSection.weeks);
                                                  });
                                                },
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 20),
                                        Row(
                                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                          children: [
                                            Text(
                                              '相关任务',
                                              style: TextStyle(
                                                fontSize: 16,
                                                fontWeight: FontWeight.bold,
                                                color: Colors.grey.shade800,
                                              ),
                                            ),
                                            TextButton.icon(
                                              onPressed: () => _showAddTaskDialog(pageCourse, pageColor, setDialogState, pageTasks),
                                              icon: const Icon(Icons.add, size: 18),
                                              label: const Text('添加任务'),
                                              style: TextButton.styleFrom(
                                                foregroundColor: pageColor,
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 8),
                                        if (pageTasks.isEmpty)
                                          Center(
                                            child: Padding(
                                              padding: const EdgeInsets.all(20),
                                              child: Text(
                                                '暂无任务',
                                                style: TextStyle(
                                                  color: Colors.grey.shade400,
                                                ),
                                              ),
                                            ),
                                          )
                                        else
                                          ...pageTasks.map((task) => _buildTaskItem(task, pageColor, setDialogState, pageTasks)),
                                      ],
                                    ),
                                  );
                                },
                              ),
                            ),
                            if (slotCourses.length > 1)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 10),
                                child: Column(
                                  children: [
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: List.generate(slotCourses.length, (index) {
                                        final selected = index == currentPage;
                                        return AnimatedContainer(
                                          duration: const Duration(milliseconds: 220),
                                          margin: const EdgeInsets.symmetric(horizontal: 4),
                                          width: selected ? 18 : 6,
                                          height: 6,
                                          decoration: BoxDecoration(
                                            color: selected
                                                ? courseColor.withValues(alpha: 0.9)
                                                : Colors.white.withValues(alpha: 0.4),
                                            borderRadius: BorderRadius.circular(4),
                                          ),
                                        );
                                      }),
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      '${currentPage + 1}/${slotCourses.length}',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.grey.shade500,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            Padding(
                              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: ElevatedButton.icon(
                                      key: editButtonKey,
                                      onPressed: () async {
                                        final action = await _showCourseEditActionMenu(anchorKey: editButtonKey);
                                        if (action == 'edit_current') {
                                          _openCourseEditorFromDetail(course: currentCourse, addSameSlotCourse: false);
                                        } else if (action == 'add_same_slot') {
                                          _openCourseEditorFromDetail(course: currentCourse, addSameSlotCourse: true);
                                        }
                                      },
                                      icon: const Icon(Icons.edit_outlined, size: 18),
                                      label: const Text('编辑课程'),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: courseColor,
                                        foregroundColor: Colors.white,
                                        padding: const EdgeInsets.symmetric(vertical: 12),
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(12),
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: ElevatedButton.icon(
                                      onPressed: () => _deleteCourseWithConfirmation(
                                        currentCourse,
                                        popContextAfterDelete: context,
                                      ),
                                      icon: const Icon(Icons.delete_outline, size: 18),
                                      label: const Text('删除课程'),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: Colors.red,
                                        foregroundColor: Colors.white,
                                        padding: const EdgeInsets.symmetric(vertical: 12),
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(12),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        );
            // 减弱动态效果：内容直接交给 showBouncyDialog 的壳
            // （无模糊、高不透明度）；默认路径包 morph 专用壳
            if (_reduceMotionEnabled) {
              // 与默认路径同款高度约束：Flexible(PageView) 会填满可用高度，
              // 必须按任务数收紧（dynamicMaxHeight），否则固定 590 上限
              // 会把对话框拉长，与默认 morph 路径高度不一致
              return ConstrainedBox(
                constraints: BoxConstraints(maxWidth: 420, maxHeight: dynamicMaxHeight),
                child: content,
              );
            }
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: 420, maxHeight: dynamicMaxHeight),
                // 壳换成 GlassDialogShell：孔洞内未压暗背景的毛玻璃（提亮层洗灰），
                // key 供 morph/孔洞精确测量壳矩形
                child: GlassDialogShell(
                  key: detailShellKey,
                  padding: EdgeInsets.zero,
                  blurSigma: 5,
                  backgroundAlpha: 0.7,
                  // 紧凑阴影：阴影可见范围（约 16px+4 偏移）明显小于
                  // 对话框本体，不再「阴影面积大于对话框」
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.15),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                  child: content,
                ),
              ),
            );
                },
              );

    // 减弱动态效果：取消 morph 容器变换，改走统一对话框淡入淡出样式
    // （改动同全局对话框：壳仅半透明无模糊、四周压暗裁切与开闭动画
    // 不变、移除内容模糊淡入淡出）
    if (_reduceMotionEnabled) {
      showBouncyDialog(
        context: context,
        barrierLabel: '课程详情',
        margin: const EdgeInsets.symmetric(horizontal: 24),
        shellPadding: EdgeInsets.zero,
        shellMaxWidth: 420,
        shellMaxHeight: 590,
        shellBoxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
        reduceMotion: true,
        builder: (context) => buildDetailContent(),
      ).whenComplete(() {
        clearRetainedCompletedTasks();
        pageController.dispose();
      });
      return;
    }

    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: '课程详情',
      // 压暗遮罩由 _MorphDialogHost 自绘（孔洞跟随 morph 矩形逐帧开合）：
      // 对话框背后采样到未压暗的原始背景，壳内毛玻璃白净不发灰；四周仅压暗
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 600),
      // 恒等过渡：RawDialogRoute 未传 transitionBuilder 时默认给整个
      // 内容包一层 FadeTransition(opacity: animation)（线性）——关闭末段
      // 卡片被线性淡出成半透明「幽灵」，落定的不是实心课程块形态，
      // dismissed 时真块突然替换 → 闪现 + 颜色不一致（本次修复根源）。
      // morph 卡片必须全程不透明：淡入白纱（翻转期）由 morph 内部自控，
      // 落定帧与真课程块像素一致，路由移除与真块出现同帧无缝交接
      transitionBuilder: (context, animation, secondaryAnimation, child) => child,
      pageBuilder: (context, animation, secondaryAnimation) {
        // morph 动画（打开先快后慢，关闭缩回课程块时减速）由 host 内部构建
        return _MorphDialogHost(
          animation: animation,
          sourceRect: sourceRect,
          sourceWidget: sourceWidget,
          backdropBlurSigma: detailBackdropBlur,
          shellKey: detailShellKey,
          onSourceHidden: sourceRect != null ? hideSourceBlock : null,
          onLanding: sourceRect != null ? landSourceBlock : null,
          onDismissed: sourceRect != null ? restoreSourceBlock : null,
          child: buildDetailContent(),
        );
      },
    ).whenComplete(() {
      clearRetainedCompletedTasks();
      pageController.dispose();
      // 详情关闭：续接非本周课程浮现卡片的剩余倒计时（若来自浮现入口）
      _resumeInactivePeek();
      // 注意：此处**不得**恢复源课程块——popped future 在 pop() 调用瞬间
      // 即完成（先于退出动画，见 Route.didComplete 文档），此时恢复会让
      // 真课程块在关闭动画第 0 帧就暴露在网格上（「固定课程块提前出现」
      // 的真正根源）。恢复只由 _MorphDialogHost 在动画播完（dismissed）
      // 时经 onLanding/onDismissed 触发；host dispose 兜底防漏
    });
  }

  /// 长按课程块：标记选中（浅蓝描边）并在课程块上方弹出操作菜单
  void _showCourseBlockMenu(Course course, BuildContext? cellContext) {
    Rect? anchorRect;
    if (cellContext != null) {
      final renderObject = cellContext.findRenderObject();
      if (renderObject is RenderBox && renderObject.attached && renderObject.hasSize) {
        anchorRect = renderObject.localToGlobal(Offset.zero) & renderObject.size;
      }
    }
    if (anchorRect == null || anchorRect.isEmpty) return;

    // 若上一菜单仍在收起动画中，立即移除避免 GlobalKey 冲突
    _courseBlockMenuOverlay?.remove();
    _courseBlockMenuOverlay = null;

    _dismissEmptySlotMask();
    // 菜单显示期间暂停非本周课程浮现卡片的倒计时（无浮现时幂等），
    // 菜单关闭（onClosed）时按剩余时长续接
    _pauseInactivePeek();

    _courseBlockMenuOverlay = OverlayEntry(
      builder: (context) => _CourseBlockActionMenu(
        key: _courseBlockMenuKey,
        anchorRect: anchorRect!,
        onDismiss: _hideCourseBlockMenu,
        onClosed: _removeCourseBlockMenuOverlay,
        onEditCurrent: () {
          _hideCourseBlockMenu();
          _showCourseDialog(
            course: course,
            sourceRect: anchorRect,
            sourceWidget: _buildCourseCellReplica(course),
          );
        },
        onAddSameSlot: () {
          _hideCourseBlockMenu();
          _showCourseDialog(
            selectedDay: course.day,
            selectedPeriod: course.time,
            initialFocusSection: CourseEditFocusSection.weeks,
            sourceRect: anchorRect,
            sourceWidget: _buildCourseCellReplica(course),
          );
        },
        onDelete: () {
          _hideCourseBlockMenu();
          _deleteCourseWithConfirmation(course);
        },
      ),
    );
    Overlay.of(context).insert(_courseBlockMenuOverlay!);
  }

  /// 收起长按菜单：先播放收起动画，动画结束后由 onClosed 移除浮层
  void _hideCourseBlockMenu() {
    final menuState = _courseBlockMenuKey.currentState;
    if (menuState != null) {
      menuState.close();
    } else {
      _removeCourseBlockMenuOverlay();
    }
  }

  void _removeCourseBlockMenuOverlay() {
    _courseBlockMenuOverlay?.remove();
    _courseBlockMenuOverlay = null;
    // 菜单关闭（含点外关闭/选择操作后收起）：续接浮现卡片剩余倒计时
    _resumeInactivePeek();
  }

  /// 删除动画：数据删除后在原位以 Overlay 幽灵渲染课程卡片复刻，
  /// 一边模糊度增大一边向内部缩小消失（220ms easeInCubic）
  void _startCourseVanishAnimation(Course course, Rect rect) {
    if (!mounted) return;
    // 复用当前渲染参数，幽灵卡片与被删课程块视觉一致
    final hasWallpaper = _wallpaperEnabled &&
        _wallpaperPath != null &&
        File(_wallpaperPath!).existsSync();
    final card = _buildCourseCellCard(
      course,
      hasWallpaper: hasWallpaper,
      transparencyFactor:
          hasWallpaper ? (100 - _wallpaperOpacity) / 50.0 : 0.0,
    );
    // 替换进行中的幽灵（连续快速删除）
    _vanishOverlay?.remove();
    _vanishOverlay = null;
    _vanishCurved?.dispose();
    _vanishController?.dispose();
    _vanishController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    _vanishCurved = CurvedAnimation(
      parent: _vanishController!,
      curve: Curves.easeInCubic,
    );
    _vanishOverlay = OverlayEntry(
      builder: (_) => Positioned(
        left: rect.left,
        top: rect.top,
        width: rect.width,
        height: rect.height,
        child: IgnorePointer(
          child: Material(
            // Overlay 顶层无 Material/DefaultTextStyle 祖先，文字会继承
            // Flutter debug 黄下划线警告。transparent Material 提供默认
            // 文字样式，复刻卡片文字与网格内一致
            type: MaterialType.transparency,
            child: AnimatedBuilder(
              animation: _vanishCurved!,
              builder: (context, _) {
                final t = _vanishCurved!.value;
                if (t >= 1.0) return const SizedBox.shrink();
                return ImageFiltered(
                  imageFilter: ImageFilter.blur(
                    sigmaX: 14 * t,
                    sigmaY: 14 * t,
                  ),
                  child: Transform.scale(
                    scale: 1.0 - 0.45 * t,
                    child: card,
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
    Overlay.of(context).insert(_vanishOverlay!);
    _vanishController!.forward(from: 0).whenComplete(() {
      _vanishOverlay?.remove();
      _vanishOverlay = null;
    });
  }

  /// morph 关闭动画落定后播挂起的删除幽灵（见 _pendingVanishCourse 注释）
  void _flushPendingVanish() {
    final course = _pendingVanishCourse;
    final rect = _pendingVanishRect;
    _pendingVanishCourse = null;
    _pendingVanishRect = null;
    if (course != null && rect != null && mounted) {
      _startCourseVanishAnimation(course, rect);
    }
  }

  /// StorageService.addCourse 会给课程 id 加当前课程表前缀（_courseKey），
  /// 对话框弹出的 saved.id 是**未加前缀**的原始 id；而网格渲染、
  /// _courseCellKeys 注册、_appearingCourseId 匹配用的都是存储后的
  /// **前缀 id**——直接用 saved.id 查 Key 永远为 null（morph 落位矩形
  /// 测不到、出现动画不匹配的根源）。用后缀匹配从 _courses 找到存储后
  /// 的课程（编辑路径 id 未变，全等匹配）
  Course? _resolveStoredCourse(Course saved) {
    for (final c in _courses) {
      if (c.id == saved.id || c.id.endsWith('_${saved.id}')) return c;
    }
    return null;
  }

  /// 新增课程块出现动画（删除动画的逆过程）：由内部伸展（0.55→1）
  /// + 由模糊变清晰（sigma 12→0）+ 淡入。
  /// begin：pop 瞬间调用——新块立即以隐藏态（t=0 不可见）渲染，避免
  /// 在对话框退出动画（400ms）期间就以完整形态露出（「直接出现」）
  void _beginCourseAppearAnimation(Course course) {
    if (!mounted) return;
    _appearCurved?.dispose();
    _appearController?.dispose();
    _appearController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
    );
    _appearCurved = CurvedAnimation(
      parent: _appearController!,
      curve: Curves.easeOutCubic,
    );
    setState(() => _appearingCourseId = course.id);
  }

  /// play：对话框退出动画播完后调用——伸展动画此刻才开始
  void _playCourseAppearAnimation() {
    if (!mounted || _appearController == null) return;
    final id = _appearingCourseId;
    _appearController!.forward(from: 0).whenComplete(() {
      if (mounted && _appearingCourseId == id) {
        setState(() => _appearingCourseId = null);
      }
    });
  }

  /// 删除课程确认对话框（长按菜单与课程详情共用），确认后删除课程及其相关任务
  Future<void> _deleteCourseWithConfirmation(Course course, {BuildContext? popContextAfterDelete}) async {
    final courseTasks = _getDialogTasksForCourse(course);
    final confirmed = await showBouncyDialog<bool>(
      context: context,
      barrierLabel: '确认删除',
      shellPadding: EdgeInsets.zero,
      shellBoxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.2),
          blurRadius: 20,
          offset: const Offset(0, 10),
        ),
      ],
      builder: (context) => ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 340),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 56,
                                height: 56,
                                decoration: BoxDecoration(
                                  color: Colors.red.withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                child: const Icon(Icons.delete_outline, color: Colors.red, size: 28),
                              ),
                              const SizedBox(height: 16),
                              const Text(
                                '确认删除',
                                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                '确定要删除课程"${course.name}"吗？\n相关任务也会被删除。',
                                textAlign: TextAlign.center,
                                style: TextStyle(fontSize: 14, color: Colors.grey.shade600),
                              ),
                              const SizedBox(height: 24),
                              Row(
                                children: [
                                  Expanded(
                                    child: GestureDetector(
                                      onTap: () => Navigator.pop(context, false),
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(vertical: 14),
                                        decoration: BoxDecoration(
                                          color: Colors.white.withValues(alpha: 0.4),
                                          borderRadius: BorderRadius.circular(12),
                                        ),
                                        child: Center(
                                          child: Text(
                                            '取消',
                                            style: TextStyle(color: Colors.grey.shade700, fontWeight: FontWeight.w600),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: GestureDetector(
                                      onTap: () => Navigator.pop(context, true),
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(vertical: 14),
                                        decoration: BoxDecoration(
                                          color: Colors.red,
                                          borderRadius: BorderRadius.circular(12),
                                        ),
                                        child: const Center(
                                          child: Text(
                                            '删除',
                                            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
          ),
    );
    if (confirmed == true) {
      // 数据删除前测量课程块矩形（morph 隐藏用 Opacity 不卸载布局，
      // 详情删除场景下块仍可测）——删除动画的幽灵按此矩形定位。
      // 测当前页（_currentWeek）上的 cell：删除确认对话框为模态，
      // 打开期间页面不会切换
      Rect? vanishRect;
      // 优先测当前周；测不到（key 对应的 cell 未挂载——切换周数后
      // PageView 旧页被回收，或新课程 weeks 不含当前周以 inactive
      // 渲染但用的不是该 course 的 key）时遍历所有周次 key 兜底
      for (final w in [
        _currentWeek,
        ...List.generate(_effectiveTotalWeeks, (i) => i + 1)
      ]) {
        final cellKey = _courseCellKeys['${course.id}@$w'];
        final cellRo = cellKey?.currentContext?.findRenderObject();
        if (cellRo is RenderBox && cellRo.attached && cellRo.hasSize) {
          vanishRect = cellRo.localToGlobal(Offset.zero) & cellRo.size;
          break;
        }
      }
      // 清掉该课程在所有周次页上的 key（key 已按周隔离）
      _courseCellKeys.removeWhere((k, _) => k.startsWith('${course.id}@'));
      for (final task in courseTasks) {
        await StorageService.deleteTask(task.id);
      }
      await StorageService.deleteCourse(course.id);
      if (popContextAfterDelete != null && popContextAfterDelete.mounted) {
        Navigator.pop(popContextAfterDelete);
      }
      _loadData();
      setState(() {});
      // 删除动画：morph 接管该格（详情删除，关闭动画即将/正在播放）时
      // 挂起到落定后播，避免幽灵与归位中的复刻卡片同位重叠；否则立即播
      if (vanishRect != null) {
        if (mounted &&
            _morphHiddenDay == course.day &&
            _morphHiddenPeriod == course.time) {
          _pendingVanishCourse = course;
          _pendingVanishRect = vanishRect;
        } else {
          _startCourseVanishAnimation(course, vanishRect);
        }
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        toastNotification.show(context, '课程已删除', type: ToastType.error);
      });
    }
  }

  /// 删除课表确认对话框（切换课表对话框内用），样式与动画对齐删除课程确认对话框；
  /// 确认后由调用方播删除动画并真正删除课表（含其内课程与任务）
  Future<bool?> _confirmDeleteTimetable(String name) {
    return showBouncyDialog<bool>(
      context: context,
      barrierLabel: '确认删除',
      shellPadding: EdgeInsets.zero,
      shellBoxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.2),
          blurRadius: 20,
          offset: const Offset(0, 10),
        ),
      ],
      builder: (context) => ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 340),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(Icons.delete_outline, color: Colors.red, size: 28),
              ),
              const SizedBox(height: 16),
              const Text(
                '确认删除',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                '确定要删除课表“$name”吗？\n该课表内的所有课程和任务也会被删除。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: Colors.grey.shade600),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: () => Navigator.pop(context, false),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.4),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Center(
                          child: Text(
                            '取消',
                            style: TextStyle(color: Colors.grey.shade700, fontWeight: FontWeight.w600),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: GestureDetector(
                      onTap: () => Navigator.pop(context, true),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        decoration: BoxDecoration(
                          color: Colors.red,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Center(
                          child: Text(
                            '删除',
                            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Task> _getDialogTasksForCourse(Course course) {
    return StorageService.getTasks().where((t) {
      final isCurrentCourseTask = t.courseId == course.id;
      final isNameBoundTask = t.courseId.startsWith('course_name:') &&
          t.courseId.substring('course_name:'.length) == course.name;
      if (!isCurrentCourseTask && !isNameBoundTask) return false;

      if (!t.completed) return true;
      return _retainedCompletedTaskIds.contains(t.id);
    }).toList();
  }

  double _calculateCourseHeaderHeight({
    required Course course,
    required double dialogWidth,
    required TextDirection textDirection,
  }) {
    final textAreaWidth = (dialogWidth - 40 - 48 - 16 - 8 - 30).clamp(120.0, 320.0);

    final namePainter = TextPainter(
      text: TextSpan(
        text: course.name,
        style: const TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.bold,
          height: 1.2,
        ),
      ),
      textDirection: textDirection,
      maxLines: 4,
    )..layout(maxWidth: textAreaWidth);

    final nameHeight = namePainter.size.height;
    double infoHeight = 0;

    if (course.location != null && course.location!.isNotEmpty) {
      final locationPainter = TextPainter(
        text: TextSpan(
          text: '@${course.location!}',
          style: const TextStyle(fontSize: 14, height: 1.2),
        ),
        textDirection: textDirection,
        maxLines: 3,
      )..layout(maxWidth: textAreaWidth);
      infoHeight += locationPainter.size.height;
    }

    if (course.teacher != null && course.teacher!.isNotEmpty) {
      final teacherPainter = TextPainter(
        text: TextSpan(
          text: course.teacher!,
          style: const TextStyle(fontSize: 14, height: 1.2),
        ),
        textDirection: textDirection,
        maxLines: 2,
      )..layout(maxWidth: textAreaWidth);
      infoHeight += teacherPainter.size.height;
    }

    return nameHeight + infoHeight + 42;
  }

  Future<String?> _showCourseEditActionMenu({
    required GlobalKey anchorKey,
  }) async {
    final anchorContext = anchorKey.currentContext;
    if (anchorContext == null) return null;

    final button = anchorContext.findRenderObject() as RenderBox?;
    final overlayState = Overlay.of(context);
    final overlay = overlayState.context.findRenderObject() as RenderBox?;
    if (button == null || overlay == null) return null;

    final topLeft = button.localToGlobal(Offset.zero, ancestor: overlay);
    final bottomRight = button.localToGlobal(button.size.bottomRight(Offset.zero), ancestor: overlay);
    const menuWidth = 188.0;
    const menuHeight = 97.0;
    final maxLeft = overlay.size.width - menuWidth - 12;
    final left = topLeft.dx.clamp(12.0, maxLeft > 12 ? maxLeft : 12.0);
    final preferTop = topLeft.dy - menuHeight - 8;
    final top = preferTop >= 12 ? preferTop : (bottomRight.dy + 8);

    return showGeneralDialog<String>(
      context: context,
      barrierLabel: '编辑课程菜单',
      barrierDismissible: true,
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (context, animation, secondaryAnimation) {
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => Navigator.pop(context),
              ),
            ),
            Positioned(
              left: left,
              top: top,
              child: FadeTransition(
                opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
                child: Material(
                  color: Colors.transparent,
                  child: SizedBox(
                    width: menuWidth,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.7),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: Colors.white.withValues(alpha: 0.5), width: 0.5),
                            boxShadow: [
                              BoxShadow(color: Colors.black.withValues(alpha: 0.15), blurRadius: 12, offset: const Offset(0, 4)),
                            ],
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(16),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _buildCourseEditMenuItem(
                                  icon: Icons.edit_outlined,
                                  label: '编辑当前课程',
                                  borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
                                  onTap: () => Navigator.pop(context, 'edit_current'),
                                ),
                                Divider(height: 1, color: Colors.grey.shade200),
                                _buildCourseEditMenuItem(
                                  icon: Icons.add_circle_outline,
                                  label: '添加同时段课程',
                                  borderRadius: const BorderRadius.vertical(bottom: Radius.circular(16)),
                                  onTap: () => Navigator.pop(context, 'add_same_slot'),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildCourseEditMenuItem({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    BorderRadius borderRadius = BorderRadius.zero,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: borderRadius,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            mainAxisSize: MainAxisSize.max,
            children: [
              Icon(icon, color: const Color(0xFF4A90E2), size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    color: Color(0xFF333333),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTaskItem(Task task, Color courseColor, StateSetter setDialogState, List<Task> dialogTasks) {
    final isOverdue = task.dueDate.isBefore(DateTime.now());
    final priorityColor = task.priority == '高' ? Colors.red : 
                          task.priority == '中' ? Colors.orange : Colors.green;
    final isCompleted = task.completed;
    
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: isCompleted ? Colors.grey.shade300 : Colors.grey.shade200),
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: () async {
              HapticFeedback.selectionClick();

              final updatedTask = Task(
                id: task.id,
                courseId: task.courseId,
                name: task.name,
                type: task.type,
                dueDate: task.dueDate,
                priority: task.priority,
                note: task.note,
                completed: !task.completed,
              );
              if (updatedTask.completed) {
                _retainedCompletedTaskIds.add(updatedTask.id);
              } else {
                _retainedCompletedTaskIds.remove(updatedTask.id);
              }
              await StorageService.updateTask(updatedTask);
              final index = dialogTasks.indexWhere((t) => t.id == task.id);
              if (index != -1) {
                dialogTasks[index] = updatedTask;
              }
              setDialogState(() {});
              if (mounted) setState(() {});
            },
            child: Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: isCompleted ? courseColor : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: isCompleted ? courseColor : Colors.grey.shade400,
                  width: 2,
                ),
              ),
              child: isCompleted
                  ? const Icon(Icons.check, color: Colors.white, size: 14)
                  : null,
            ),
          ),
          const SizedBox(width: 12),
          Container(
            width: 4,
            height: 40,
            decoration: BoxDecoration(
              color: isCompleted ? Colors.grey.shade400 : (isOverdue ? Colors.red : priorityColor),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: isCompleted 
                            ? Colors.white.withValues(alpha: 0.4)
                                            : priorityColor.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        task.type,
                        style: TextStyle(
                          fontSize: 10,
                          color: isCompleted ? Colors.grey.shade500 : priorityColor,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        task.name,
                        style: TextStyle(
                          fontWeight: FontWeight.w500,
                          fontSize: 13,
                          color: isCompleted ? Colors.grey.shade500 : null,
                          decoration: isCompleted ? TextDecoration.lineThrough : null,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '截止: ${intl.DateFormat('MM/dd HH:mm').format(task.dueDate)}${isOverdue && !isCompleted ? ' (已逾期)' : ''}',
                  style: TextStyle(
                    fontSize: 11,
                    color: isCompleted 
                        ? Colors.grey.shade400 
                        : (isOverdue ? Colors.red : Colors.grey.shade600),
                    decoration: isCompleted ? TextDecoration.lineThrough : null,
                  ),
                ),
              ],
            ),
          ),
          if (!isCompleted)
            Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: (_) => HapticFeedback.selectionClick(),
              child: BlurredPopupMenuButton<String>(
                icon: Icon(Icons.more_vert, color: Colors.grey.shade400, size: 20),
                items: const [
                  BlurredPopupMenuItem(
                    value: 'edit',
                    icon: Icons.edit_outlined,
                    label: '编辑',
                    iconColor: Color(0xFF4A90E2),
                  ),
                  BlurredPopupMenuItem(
                    value: 'delete',
                    icon: Icons.delete_outline,
                    label: '删除',
                    iconColor: Colors.red,
                    textColor: Colors.red,
                  ),
                ],
                onSelected: (value) async {
                  if (value == 'edit') {
                    await Future.delayed(const Duration(milliseconds: 200));
                    _showEditTaskDialog(task, setDialogState);
                  } else if (value == 'delete') {
                    await StorageService.deleteTask(task.id);
                    setDialogState(() {});
                    _loadData();
                    setState(() {});
                    if (context.mounted) {
                      toastNotification.show(context, '任务已删除', type: ToastType.error);
                    }
                  }
                },
              ),
            ),
        ],
      ),
    );
  }

  void _showAddTaskDialog(Course course, Color courseColor, StateSetter setDialogState, List<Task> dialogTasks) {
    final nameController = TextEditingController();
    DateTime dueDate = DateTime.now().add(const Duration(days: 7));
    String type = '作业';
    String priority = '中';
    final noteController = TextEditingController();
    
    showBouncyDialog(
      context: context,
      barrierLabel: '添加任务',
      margin: EdgeInsets.symmetric(
        horizontal: MediaQuery.of(context).size.height < 700 ? 16 : 24,
      ),
      shellPadding: EdgeInsets.zero,
      shellBoxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.2),
          blurRadius: 20,
          offset: const Offset(0, 10),
        ),
      ],
      avoidKeyboard: true,
      builder: (context) => StatefulBuilder(
          builder: (context, setState) {
            final screenHeight = MediaQuery.of(context).size.height;
            final keyboardHeight = MediaQuery.of(context).viewInsets.bottom;
            final topInset = MediaQuery.of(context).padding.top;
            final isSmallScreen = screenHeight < 700;
            final baseMaxHeight = isSmallScreen ? screenHeight * 0.85 : 580.0;
            double dialogMaxHeight = baseMaxHeight;
            final availableHeight = screenHeight - topInset - keyboardHeight - 24;
            if (availableHeight < dialogMaxHeight) {
              dialogMaxHeight = availableHeight;
            }
            dialogMaxHeight = dialogMaxHeight.clamp(260.0, baseMaxHeight).toDouble();

            return AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            curve: Curves.easeOut,
                            constraints: BoxConstraints(
                              maxWidth: 400,
                              maxHeight: dialogMaxHeight,
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Opacity(
                                  opacity: 0.82,
                                  child: Container(
                                    padding: EdgeInsets.all(isSmallScreen ? 16 : 20),
                                    decoration: BoxDecoration(
                                      gradient: LinearGradient(
                                        colors: [courseColor, courseColor.withValues(alpha: 0.8)],
                                      ),
                                      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
                                    ),
                                    child: Row(
                                children: [
                                  Container(
                                    padding: EdgeInsets.all(isSmallScreen ? 8 : 10),
                                    decoration: BoxDecoration(
                                      color: Colors.white.withValues(alpha: 0.2),
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Icon(Icons.add_task, color: Colors.white, size: isSmallScreen ? 20 : 22),
                                  ),
                                  SizedBox(width: isSmallScreen ? 10 : 14),
                                  Expanded(
                                    child: Text(
                                      '添加任务 - ${course.name}',
                                      style: TextStyle(
                                        fontSize: isSmallScreen ? 16 : 18,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                  GestureDetector(
                                    onTap: () => Navigator.pop(context),
                                    child: Container(
                                      padding: const EdgeInsets.all(6),
                                      decoration: BoxDecoration(
                                        color: Colors.white.withValues(alpha: 0.2),
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: const Icon(Icons.close, color: Colors.white, size: 18),
                                    ),
                                  ),
                                ],
                              ),
                                    ),
                                  ),
                            Expanded(
                              child: SingleChildScrollView(
                                physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
                                padding: EdgeInsets.all(isSmallScreen ? 16 : 20),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    TextField(
                                      contextMenuBuilder: styledEditableContextMenu,
                                      controller: nameController,
                                      decoration: InputDecoration(
                                        labelText: '任务名称',
                                        prefixIcon: Icon(Icons.task, color: courseColor.withValues(alpha: 0.7)),
                                        filled: true,
                                        fillColor: Colors.white.withValues(alpha: 0.4),
                                        border: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(12),
                                          borderSide: BorderSide(color: Colors.grey.shade200),
                                        ),
                                        enabledBorder: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(12),
                                          borderSide: BorderSide(color: Colors.grey.shade200),
                                        ),
                                        focusedBorder: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(12),
                                          borderSide: BorderSide(color: courseColor, width: 2),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 16),
                                    Row(
                                      children: [
                                        Icon(Icons.category_outlined, color: courseColor.withValues(alpha: 0.7), size: 20),
                                        const SizedBox(width: 8),
                                        Text('任务类型', style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                                      ],
                                    ),
                                    const SizedBox(height: 8),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 12),
                                      decoration: BoxDecoration(
                                        color: Colors.white.withValues(alpha: 0.4),
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(color: Colors.grey.shade200),
                                      ),
                                      child: BlurredDropdown<String>(
                                        value: type,
                                        isExpanded: true,
                                        icon: Icon(Icons.expand_more, color: courseColor),
                                        items: ['作业', '考试', '报告', '其他'].map((e) => DropdownMenuItem(
                                          value: e,
                                          child: Text(e),
                                        )).toList(),
                                        onChanged: (v) => setState(() => type = v!),
                                      ),
                                    ),
                                    const SizedBox(height: 16),
                                    InkWell(
                                      onTap: () async {
                                        final date = await showAnimatedDatePicker(
                                          context: context,
                                          initialDate: dueDate,
                                          firstDate: DateTime.now(),
                                          lastDate: DateTime.now().add(const Duration(days: 365)),
                                        );
                                        if (date != null) {
                                          if (!context.mounted) return;
                                          final time = await show3DTimePicker(
                                            context: context,
                                            initialHour: dueDate.hour,
                                            initialMinute: dueDate.minute,
                                            title: '选择截止时间',
                                          );
                                          if (time != null) {
                                            setState(() {
                                              dueDate = DateTime(date.year, date.month, date.day, time.hour, time.minute);
                                            });
                                          }
                                        }
                                      },
                                      borderRadius: BorderRadius.circular(12),
                                      child: Container(
                                        padding: const EdgeInsets.all(16),
                                        decoration: BoxDecoration(
                                          color: Colors.white.withValues(alpha: 0.4),
                                          borderRadius: BorderRadius.circular(12),
                                          border: Border.all(color: Colors.grey.shade200),
                                        ),
                                        child: Row(
                                          children: [
                                            Icon(Icons.calendar_today, color: courseColor.withValues(alpha: 0.7)),
                                            const SizedBox(width: 12),
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment: CrossAxisAlignment.start,
                                                children: [
                                                  Text('截止日期', style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                                                  Text(intl.DateFormat('yyyy/MM/dd HH:mm').format(dueDate), style: const TextStyle(fontWeight: FontWeight.w500)),
                                                ],
                                              ),
                                            ),
                                            Icon(Icons.chevron_right, color: Colors.grey.shade400),
                                          ],
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 16),
                                    Row(
                                      children: [
                                        Icon(Icons.flag_outlined, color: courseColor.withValues(alpha: 0.7), size: 20),
                                        const SizedBox(width: 8),
                                        Text('优先级', style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                                      ],
                                    ),
                                    const SizedBox(height: 8),
                                    Row(
                                      children: ['高', '中', '低'].map((p) {
                                        final isSelected = priority == p;
                                        Color priorityColor;
                                        if (p == '高') {
                                          priorityColor = Colors.red;
                                        } else if (p == '中') priorityColor = Colors.orange;
                                        else priorityColor = Colors.green;
                                        
                                        return Expanded(
                                          child: GestureDetector(
                                            onTap: () => setState(() => priority = p),
                                            child: Container(
                                              margin: const EdgeInsets.symmetric(horizontal: 4),
                                              padding: const EdgeInsets.symmetric(vertical: 10),
                                              decoration: BoxDecoration(
                                                color: isSelected ? priorityColor.withValues(alpha: 0.15) : Colors.white.withValues(alpha: 0.4),
                                                borderRadius: BorderRadius.circular(10),
                                                border: Border.all(
                                                  color: isSelected ? priorityColor : Colors.grey.shade200,
                                                  width: isSelected ? 2 : 1,
                                                ),
                                              ),
                                              child: Text(
                                                p,
                                                textAlign: TextAlign.center,
                                                style: TextStyle(
                                                  color: isSelected ? priorityColor : Colors.grey.shade600,
                                                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                                ),
                                              ),
                                            ),
                                          ),
                                        );
                                      }).toList(),
                                    ),
                                    const SizedBox(height: 16),
                                    TextField(
                                      contextMenuBuilder: styledEditableContextMenu,
                                      controller: noteController,
                                      maxLines: 1,
                                      decoration: InputDecoration(
                                        labelText: '备注（可选）',
                                        prefixIcon: Icon(Icons.note_outlined, color: courseColor.withValues(alpha: 0.7)),
                                        filled: true,
                                        fillColor: Colors.white.withValues(alpha: 0.4),
                                        border: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(12),
                                          borderSide: BorderSide(color: Colors.grey.shade200),
                                        ),
                                        enabledBorder: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(12),
                                          borderSide: BorderSide(color: Colors.grey.shade200),
                                        ),
                                        focusedBorder: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(12),
                                          borderSide: BorderSide(color: courseColor, width: 2),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                              child: SizedBox(
                                width: double.infinity,
                                child: ElevatedButton(
                                  onPressed: () async {
                                    if (nameController.text.trim().isEmpty) return;
                                    final isMergedCourse = StorageService.getCourses()
                                          .where((c) => c.name == course.name)
                                          .length > 1;
                                    final taskCourseId = isMergedCourse
                                        ? 'course_name:${course.name}'
                                        : course.id;
                                    final task = Task(
                                      id: DateTime.now().millisecondsSinceEpoch.toString(),
                                      courseId: taskCourseId,
                                      name: nameController.text.trim(),
                                      dueDate: dueDate,
                                      type: type,
                                      priority: priority,
                                      note: noteController.text.trim(),
                                    );
                                    await StorageService.addTask(task);
                                    dialogTasks.add(task);
                                    _loadData();
                                    setDialogState(() {});
                                    if (context.mounted) Navigator.pop(context);
                                    WidgetsBinding.instance.addPostFrameCallback((_) {
                                      toastNotification.show(context, '添加任务成功', type: ToastType.success);
                                    });
                                  },
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: courseColor,
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(vertical: 14),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                  ),
                                  child: const Text('添加任务', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                                ),
                              ),
                            ),
                          ],
                        ),
            );
          },
        ),
    );
  }

  void _showEditTaskDialog(Task task, StateSetter setDialogState) {
    final nameController = TextEditingController(text: task.name);
    DateTime dueDate = task.dueDate;
    String type = task.type;
    String priority = task.priority;
    final noteController = TextEditingController(text: task.note);
    Color courseColor = const Color(0xFF4A90E2);
    if (task.courseId.startsWith('course_name:')) {
      final courseName = task.courseId.substring('course_name:'.length);
      final matchedCourse = StorageService.getCourses().where((c) => c.name == courseName).firstOrNull;
      if (matchedCourse != null) {
        courseColor = _parseColor(matchedCourse.color);
      }
    } else if (task.courseId != 'ai_created') {
      final matchedCourse = StorageService.getCourses().where((c) => c.id == task.courseId).firstOrNull;
      if (matchedCourse != null) {
        courseColor = _parseColor(matchedCourse.color);
      }
    }
    
    showBouncyDialog(
      context: context,
      barrierLabel: '编辑任务',
      margin: EdgeInsets.symmetric(
        horizontal: MediaQuery.of(context).size.height < 700 ? 16 : 24,
      ),
      shellPadding: EdgeInsets.zero,
      shellBoxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.2),
          blurRadius: 20,
          offset: const Offset(0, 10),
        ),
      ],
      avoidKeyboard: true,
      builder: (context) => StatefulBuilder(
          builder: (context, setState) {
            final screenHeight = MediaQuery.of(context).size.height;
            final keyboardHeight = MediaQuery.of(context).viewInsets.bottom;
            final topInset = MediaQuery.of(context).padding.top;
            final isSmallScreen = screenHeight < 700;
            final baseMaxHeight = isSmallScreen ? screenHeight * 0.85 : 580.0;
            double dialogMaxHeight = baseMaxHeight;
            final availableHeight = screenHeight - topInset - keyboardHeight - 24;
            if (availableHeight < dialogMaxHeight) {
              dialogMaxHeight = availableHeight;
            }
            dialogMaxHeight = dialogMaxHeight.clamp(260.0, baseMaxHeight).toDouble();

            return AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            curve: Curves.easeOut,
                            constraints: BoxConstraints(
                              maxWidth: 400,
                              maxHeight: dialogMaxHeight,
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Opacity(
                                  opacity: 0.82,
                                  child: Container(
                                    padding: EdgeInsets.all(isSmallScreen ? 16 : 20),
                                    decoration: BoxDecoration(
                                      gradient: LinearGradient(
                                        colors: [courseColor, courseColor.withValues(alpha: 0.8)],
                                      ),
                                      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
                                    ),
                                    child: Row(
                                children: [
                                  Container(
                                    padding: EdgeInsets.all(isSmallScreen ? 8 : 10),
                                    decoration: BoxDecoration(
                                      color: Colors.white.withValues(alpha: 0.2),
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Icon(Icons.edit_note, color: Colors.white, size: isSmallScreen ? 20 : 22),
                                  ),
                                  SizedBox(width: isSmallScreen ? 10 : 14),
                                  Expanded(
                                    child: Text(
                                      '编辑任务',
                                      style: TextStyle(
                                        fontSize: isSmallScreen ? 16 : 18,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                  GestureDetector(
                                    onTap: () => Navigator.pop(context),
                                    child: Container(
                                      padding: const EdgeInsets.all(6),
                                      decoration: BoxDecoration(
                                        color: Colors.white.withValues(alpha: 0.2),
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Icon(Icons.close, color: Colors.white, size: isSmallScreen ? 16 : 18),
                                    ),
                                  ),
                                ],
                              ),
                                    ),
                                  ),
                            Expanded(
                              child: SingleChildScrollView(
                                physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
                                padding: EdgeInsets.all(isSmallScreen ? 16 : 20),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    TextField(
                                      contextMenuBuilder: styledEditableContextMenu,
                                      controller: nameController,
                                      decoration: InputDecoration(
                                        labelText: '任务名称',
                                        prefixIcon: Icon(Icons.task, color: courseColor.withValues(alpha: 0.7), size: isSmallScreen ? 18 : 20),
                                        filled: true,
                                        fillColor: Colors.white.withValues(alpha: 0.4),
                                        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: isSmallScreen ? 12 : 14),
                                        border: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(12),
                                          borderSide: BorderSide(color: Colors.grey.shade200),
                                        ),
                                        enabledBorder: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(12),
                                          borderSide: BorderSide(color: Colors.grey.shade200),
                                        ),
                                        focusedBorder: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(12),
                                          borderSide: BorderSide(color: courseColor, width: 2),
                                        ),
                                      ),
                                      style: TextStyle(fontSize: isSmallScreen ? 14 : 16),
                                    ),
                                    SizedBox(height: isSmallScreen ? 12 : 16),
                                    Row(
                                      children: [
                                        Icon(Icons.category_outlined, color: courseColor.withValues(alpha: 0.7), size: isSmallScreen ? 18 : 20),
                                        SizedBox(width: isSmallScreen ? 6 : 8),
                                        Text(
                                          '任务类型',
                                          style: TextStyle(
                                            fontSize: isSmallScreen ? 11 : 12,
                                            color: Colors.grey.shade600,
                                          ),
                                        ),
                                      ],
                                    ),
                                    SizedBox(height: isSmallScreen ? 6 : 8),
                                    Container(
                                      padding: EdgeInsets.symmetric(horizontal: isSmallScreen ? 10 : 12),
                                      decoration: BoxDecoration(
                                        color: Colors.white.withValues(alpha: 0.4),
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(color: Colors.grey.shade200),
                                      ),
                                      child: BlurredDropdown<String>(
                                        value: type,
                                        isExpanded: true,
                                        icon: Icon(Icons.expand_more, color: courseColor, size: isSmallScreen ? 18 : 20),
                                        items: ['作业', '考试', '报告', '其他'].map((e) => DropdownMenuItem(
                                          value: e, 
                                          child: Text(e, style: TextStyle(fontSize: isSmallScreen ? 14 : 16))
                                        )).toList(),
                                        onChanged: (v) => setState(() => type = v!),
                                      ),
                                    ),
                                    SizedBox(height: isSmallScreen ? 12 : 16),
                                    InkWell(
                                      onTap: () async {
                                        final date = await showAnimatedDatePicker(
                                          context: context,
                                          initialDate: dueDate,
                                          firstDate: DateTime(2020),
                                          lastDate: DateTime.now().add(const Duration(days: 365 * 2)),
                                        );
                                        if (date != null) {
                                          if (!context.mounted) return;
                                          final time = await show3DTimePicker(
                                            context: context,
                                            initialHour: dueDate.hour,
                                            initialMinute: dueDate.minute,
                                            title: '选择截止时间',
                                          );
                                          if (time != null) {
                                            setState(() {
                                              dueDate = DateTime(date.year, date.month, date.day, time.hour, time.minute);
                                            });
                                          }
                                        }
                                      },
                                      borderRadius: BorderRadius.circular(12),
                                      child: Container(
                                        padding: EdgeInsets.all(isSmallScreen ? 12 : 16),
                                        decoration: BoxDecoration(
                                          color: Colors.white.withValues(alpha: 0.4),
                                          borderRadius: BorderRadius.circular(12),
                                          border: Border.all(color: Colors.grey.shade200),
                                        ),
                                        child: Row(
                                          children: [
                                            Icon(Icons.calendar_today, color: courseColor.withValues(alpha: 0.7), size: isSmallScreen ? 18 : 20),
                                            SizedBox(width: isSmallScreen ? 10 : 12),
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment: CrossAxisAlignment.start,
                                                children: [
                                                  Text('截止日期', style: TextStyle(fontSize: isSmallScreen ? 11 : 12, color: Colors.grey.shade600)),
                                                  Text(intl.DateFormat('yyyy/MM/dd HH:mm').format(dueDate), style: TextStyle(fontWeight: FontWeight.w500, fontSize: isSmallScreen ? 14 : 16)),
                                                ],
                                              ),
                                            ),
                                            Icon(Icons.chevron_right, color: Colors.grey.shade400, size: isSmallScreen ? 18 : 20),
                                          ],
                                        ),
                                      ),
                                    ),
                                    SizedBox(height: isSmallScreen ? 12 : 16),
                                    Row(
                                      children: [
                                        Icon(Icons.flag_outlined, color: courseColor.withValues(alpha: 0.7), size: isSmallScreen ? 18 : 20),
                                        SizedBox(width: isSmallScreen ? 6 : 8),
                                        Text(
                                          '优先级',
                                          style: TextStyle(
                                            fontSize: isSmallScreen ? 11 : 12,
                                            color: Colors.grey.shade600,
                                          ),
                                        ),
                                      ],
                                    ),
                                    SizedBox(height: isSmallScreen ? 6 : 8),
                                    Row(
                                      children: ['高', '中', '低'].map((p) {
                                        final isSelected = priority == p;
                                        Color priorityColor;
                                        if (p == '高') {
                                          priorityColor = Colors.red;
                                        } else if (p == '中') priorityColor = Colors.orange;
                                        else priorityColor = Colors.green;
                                        
                                        return Expanded(
                                          child: GestureDetector(
                                            onTap: () => setState(() => priority = p),
                                            child: Container(
                                              margin: EdgeInsets.symmetric(horizontal: isSmallScreen ? 3 : 4),
                                              padding: EdgeInsets.symmetric(vertical: isSmallScreen ? 8 : 10),
                                              decoration: BoxDecoration(
                                                color: isSelected ? priorityColor.withValues(alpha: 0.15) : Colors.white.withValues(alpha: 0.4),
                                                borderRadius: BorderRadius.circular(10),
                                                border: Border.all(
                                                  color: isSelected ? priorityColor : Colors.grey.shade200,
                                                  width: isSelected ? 2 : 1,
                                                ),
                                              ),
                                              child: Text(
                                                p,
                                                textAlign: TextAlign.center,
                                                style: TextStyle(
                                                  fontSize: isSmallScreen ? 13 : 14,
                                                  color: isSelected ? priorityColor : Colors.grey.shade600,
                                                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                                ),
                                              ),
                                            ),
                                          ),
                                        );
                                      }).toList(),
                                    ),
                                    SizedBox(height: isSmallScreen ? 12 : 16),
                                    TextField(
                                      contextMenuBuilder: styledEditableContextMenu,
                                      controller: noteController,
                                      maxLines: 1,
                                      decoration: InputDecoration(
                                        labelText: '备注（可选）',
                                        prefixIcon: Icon(Icons.note_outlined, color: courseColor.withValues(alpha: 0.7), size: isSmallScreen ? 18 : 20),
                                        filled: true,
                                        fillColor: Colors.white.withValues(alpha: 0.4),
                                        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: isSmallScreen ? 12 : 14),
                                        border: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(12),
                                          borderSide: BorderSide(color: Colors.grey.shade200),
                                        ),
                                        enabledBorder: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(12),
                                          borderSide: BorderSide(color: Colors.grey.shade200),
                                        ),
                                        focusedBorder: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(12),
                                          borderSide: BorderSide(color: courseColor, width: 2),
                                        ),
                                      ),
                                      style: TextStyle(fontSize: isSmallScreen ? 14 : 16),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            Container(
                              padding: EdgeInsets.fromLTRB(isSmallScreen ? 16 : 20, 0, isSmallScreen ? 16 : 20, isSmallScreen ? 16 : 20),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: OutlinedButton(
                                      onPressed: () => Navigator.pop(context),
                                      style: OutlinedButton.styleFrom(
                                        padding: EdgeInsets.symmetric(vertical: isSmallScreen ? 12 : 14),
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                        side: BorderSide(color: Colors.grey.shade300),
                                      ),
                                      child: Text('取消', style: TextStyle(fontSize: isSmallScreen ? 13 : 14)),
                                    ),
                                  ),
                                  SizedBox(width: isSmallScreen ? 10 : 12),
                                  Expanded(
                                    flex: 2,
                                    child: ElevatedButton(
                                      onPressed: () async {
                                        if (nameController.text.isEmpty) return;
                                        final updatedTask = Task(
                                          id: task.id,
                                          courseId: task.courseId,
                                          name: nameController.text,
                                          type: type,
                                          dueDate: dueDate,
                                          priority: priority,
                                          note: noteController.text.isEmpty ? null : noteController.text,
                                          completed: task.completed,
                                        );
                                        await StorageService.updateTask(updatedTask);
                                        if (context.mounted) {
                                          Navigator.pop(context);
                                        }
                                        setDialogState(() {});
                                        _loadData();
                                        setState(() {});
                                        WidgetsBinding.instance.addPostFrameCallback((_) {
                                          toastNotification.show(context, '任务已更新', type: ToastType.success);
                                        });
                                      },
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: courseColor,
                                        foregroundColor: Colors.white,
                                        padding: EdgeInsets.symmetric(vertical: isSmallScreen ? 12 : 14),
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                      ),
                                      child: Text('保存', style: TextStyle(fontSize: isSmallScreen ? 13 : 15)),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
            );
          },
        ),
    );
  }

  Widget _buildDetailRow(IconData icon, String label, String value) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.grey.shade100,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, size: 18, color: Colors.grey.shade600),
        ),
        const SizedBox(width: 12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey.shade500,
              ),
            ),
            Text(
              value,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildDetailRowCompact(
    IconData icon,
    String label,
    String value, {
    VoidCallback? onTap,
  }) {
    final isClickable = onTap != null;
    final content = AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: Colors.grey.shade200,
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(5),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(5),
            ),
            child: Icon(
              icon,
              size: 14,
              color: Colors.grey.shade600,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 10,
                    color: Colors.grey.shade500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  softWrap: true,
                ),
              ],
            ),
          ),
          if (isClickable)
            Icon(
              Icons.chevron_right,
              size: 14,
              color: Colors.grey.shade400,
            ),
        ],
      ),
    );

    if (!isClickable) {
      return content;
    }

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: content,
      ),
    );
  }

  /// 视频壁纸设置底部弹窗
  void _showVideoWallpaperSettings() {
    if (_videoController == null || !_videoController!.value.isInitialized) return;
    bool isDragging = false;
    // 拖拽中的临时进度，避免视频 position 反馈干扰跟手
    double? dragProgress;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => Container(
          margin: const EdgeInsets.all(16),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.8),
                    width: 1.5,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.15),
                      blurRadius: 25,
                      spreadRadius: 2,
                      offset: const Offset(0, -4),
                    ),
                    BoxShadow(
                      color: Colors.white.withValues(alpha: 0.6),
                      blurRadius: 0,
                      offset: const Offset(0, -1),
                    ),
                  ],
                ),
                child: SafeArea(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 标题行
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              '视频壁纸设置',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            GestureDetector(
                              onTap: () => Navigator.pop(context),
                              child: Container(
                                width: 32,
                                height: 32,
                                decoration: BoxDecoration(
                                  color: Colors.grey.shade100,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Icon(Icons.close, size: 18, color: Colors.grey.shade600),
                              ),
                            ),
                          ],
                        ),
                      ),
                      // 第一行：播放进度控制（暂停按钮 + 当前时间 + 进度条 + 总时长）
                      // 进度条位置固定，不随读秒跳动（不监听视频 position 实时更新）
                      // 只在拖拽或点击时更新进度
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            // 暂停/播放按钮（单独监听视频状态）
                            AnimatedBuilder(
                              animation: _videoController!,
                              builder: (context, _) {
                                final isPlaying = _videoController!.value.isPlaying;
                                return GestureDetector(
                                  onTap: () {
                                    if (isPlaying) {
                                      _videoController!.pause();
                                    } else {
                                      _videoController!.play();
                                    }
                                  },
                                  child: Container(
                                    width: 40,
                                    height: 40,
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF4A90E2).withValues(alpha: 0.15),
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Icon(
                                      isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                                      color: const Color(0xFF4A90E2),
                                      size: 22,
                                    ),
                                  ),
                                );
                              },
                            ),
                            const SizedBox(width: 12),
                            // 当前时间（固定宽度，避免秒数跳动挤压进度条左侧边界）
                            SizedBox(
                              width: 42,
                              child: AnimatedBuilder(
                                animation: _videoController!,
                                builder: (context, _) {
                                  final position = _videoController!.value.position;
                                  String fmt(Duration d) {
                                    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
                                    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
                                    return '$m:$s';
                                  }
                                  return Text(
                                    fmt(position),
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: Color(0xFF4A90E2),
                                      fontWeight: FontWeight.w600,
                                    ),
                                  );
                                },
                              ),
                            ),
                            const SizedBox(width: 8),
                            // 胶囊形进度条（占据剩余空间，长度随页面尺寸自适应）
                            // 监听视频 position 以跟随播放进度（左侧秒数已用固定宽度，不会跳动）
                            Expanded(
                              child: AnimatedBuilder(
                                animation: _videoController!,
                                builder: (ctx, _) {
                                  return LayoutBuilder(
                                    builder: (ctx, constraints) {
                                      final trackWidth = constraints.maxWidth;
                                      // 获取当前进度（拖拽中用临时值，否则用视频实际进度）
                                      final durMs = _videoController!.value.duration.inMilliseconds.toDouble().clamp(1, double.infinity);
                                      final posMs = _videoController!.value.position.inMilliseconds.toDouble();
                                      final videoProgress = (posMs / durMs).clamp(0.0, 1.0);
                                      final displayProgress = isDragging ? (dragProgress ?? videoProgress) : videoProgress;
                                      return GestureDetector(
                                        behavior: HitTestBehavior.opaque,
                                        onHorizontalDragStart: (details) {
                                          // 按住任意位置即放大并可拖动
                                          final localX = details.localPosition.dx;
                                          final ratio = (localX / trackWidth).clamp(0.0, 1.0);
                                          setSheetState(() {
                                            isDragging = true;
                                            dragProgress = ratio;
                                          });
                                        },
                                        onHorizontalDragUpdate: (details) {
                                          // 手指拖动距离与进度条移动距离一致
                                          final localX = details.localPosition.dx;
                                          final ratio = (localX / trackWidth).clamp(0.0, 1.0);
                                          setSheetState(() {
                                            dragProgress = ratio;
                                          });
                                        },
                                        onHorizontalDragEnd: (_) {
                                          // 拖拽结束后才 seek
                                          if (dragProgress != null) {
                                            _videoController!.seekTo(Duration(milliseconds: (dragProgress! * durMs).toInt()));
                                          }
                                          setSheetState(() {
                                            isDragging = false;
                                            dragProgress = null;
                                          });
                                        },
                                        onTapDown: (details) {
                                          final localX = details.localPosition.dx;
                                          final ratio = (localX / trackWidth).clamp(0.0, 1.0);
                                          _videoController!.seekTo(Duration(milliseconds: (ratio * durMs).toInt()));
                                        },
                                        child: ClipRRect(
                                          borderRadius: BorderRadius.circular(isDragging ? 6 : 3),
                                          child: Stack(
                                            children: [
                                              // 背景轨道
                                              Container(
                                                height: isDragging ? 12 : 6,
                                                color: Colors.grey.withValues(alpha: 0.3),
                                              ),
                                              // 已播放部分（从左向右增长）
                                              Align(
                                                alignment: Alignment.centerLeft,
                                                child: Container(
                                                  height: isDragging ? 12 : 6,
                                                  width: trackWidth * displayProgress,
                                                  color: const Color(0xFF4A90E2),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      );
                                    },
                                  );
                                },
                              ),
                            ),
                            const SizedBox(width: 8),
                            // 总时长（固定宽度，避免右侧边界跳动）
                            SizedBox(
                              width: 42,
                              child: Text(
                                () {
                                  final duration = _videoController!.value.duration;
                                  final m = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
                                  final s = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
                                  return '$m:$s';
                                }(),
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey.shade600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      // 第二行：两个圆角矩形（与 showAddOptions 统一样式）
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          children: [
                            // 左侧：启用动态壁纸声音
                            Expanded(
                              child: _buildAddOptionCard(
                                icon: _videoSoundEnabled ? Icons.volume_up_rounded : Icons.volume_off_rounded,
                                label: _videoSoundEnabled ? '声音已开启' : '启用声音',
                                color: _videoSoundEnabled ? Colors.green : Colors.grey,
                                onTap: () async {
                                  final newValue = !_videoSoundEnabled;
                                  _videoSoundEnabled = newValue;
                                  _videoController?.setVolume(newValue ? 1 : 0);
                                  final prefs = await SharedPreferences.getInstance();
                                  await prefs.setBool('wallpaper_video_sound', newValue);
                                  setSheetState(() {});
                                  setState(() {});
                                },
                              ),
                            ),
                            const SizedBox(width: 12),
                            // 右侧：当前帧设为壁纸
                            Expanded(
                              child: _buildAddOptionCard(
                                icon: Icons.image_outlined,
                                label: '当前帧设为壁纸',
                                color: const Color(0xFF4A90E2),
                                onTap: () {
                                  Navigator.pop(context);
                                  _setCurrentFrameAsWallpaper();
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 将视频当前帧捕获并设置为静态图片壁纸
  Future<void> _setCurrentFrameAsWallpaper() async {
    final ctx = _videoRepaintKey.currentContext;
    if (ctx == null) {
      if (mounted) {
        toastNotification.show(context, '无法捕获当前帧', type: ToastType.error);
      }
      return;
    }
    try {
      final boundary = ctx.findRenderObject() as dynamic;
      final image = await boundary.toImage(pixelRatio: 1.0);
      final byteData = await image.toByteData(format: ImageByteFormat.png);
      if (byteData == null) throw Exception('编码失败');
      final bytes = byteData.buffer.asUint8List();

      // 保存为文件
      final dir = await getApplicationDocumentsDirectory();
      final filePath = '${dir.path}/wallpaper_frame_${DateTime.now().millisecondsSinceEpoch}.png';
      final file = File(filePath);
      await file.writeAsBytes(bytes);

      // 更新壁纸设置
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('wallpaper_path', filePath);
      await prefs.setString('wallpaper_type', 'image');

      // 同步添加到壁纸列表（最多保留5个，超出剔除最后一个）
      final recentPaths = List<String>.from(
          prefs.getStringList('wallpaper_recent_paths') ?? []);
      recentPaths.insert(0, filePath);
      if (recentPaths.length > 5) {
        recentPaths.removeLast();
      }
      await prefs.setStringList('wallpaper_recent_paths', recentPaths);

      // 先用捕获的帧作为过渡，再重新加载壁纸
      _videoFirstFrameBytes = bytes;
      _wallpaperBytes = bytes;
      _wallpaperBytesPath = filePath;
      await _loadWallpaper();

      if (mounted) {
        toastNotification.show(context, '当前帧已设为壁纸', type: ToastType.success);
      }
    } catch (e) {
      if (mounted) {
        toastNotification.show(context, '设置失败', type: ToastType.error);
      }
    }
  }

  void showAddOptions() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        margin: const EdgeInsets.all(16),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.8),
                  width: 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.15),
                    blurRadius: 25,
                    spreadRadius: 2,
                    offset: const Offset(0, -4),
                  ),
                  BoxShadow(
                    color: Colors.white.withValues(alpha: 0.6),
                    blurRadius: 0,
                    offset: const Offset(0, -1),
                  ),
                ],
              ),
              child: SafeArea(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            '添加',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          GestureDetector(
                            onTap: () => Navigator.pop(context),
                            child: Container(
                              width: 32,
                              height: 32,
                              decoration: BoxDecoration(
                                color: Colors.grey.shade100,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Icon(Icons.close, size: 18, color: Colors.grey.shade600),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          Expanded(
                            child: _buildAddOptionCard(
                              icon: Icons.book,
                              label: '课程',
                              color: const Color(0xFF4A90E2),
                              onTap: () {
                                Navigator.pop(context);
                                _showCourseDialog();
                              },
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _buildAddOptionCard(
                              icon: Icons.task_alt,
                              label: '任务',
                              color: Colors.orange,
                              onTap: () {
                                Navigator.pop(context);
                                _showAddTaskWithOptions();
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAddOptionCard({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 20),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withValues(alpha: 0.2)),
        ),
        child: Column(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: color, size: 24),
            ),
            const SizedBox(height: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showAddTaskWithOptions() {
    final allCourses = StorageService.getCourses();
    final screenHeight = MediaQuery.of(context).size.height;

    final Map<String, List<Course>> grouped = {};
    for (final c in allCourses) {
      grouped.putIfAbsent(c.name, () => []).add(c);
    }
    final courseGroups = grouped.entries.toList();
    
    showBouncyDialog(
      context: context,
      barrierLabel: '选择课程',
      shellPadding: EdgeInsets.zero,
      shellBoxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.2),
          blurRadius: 20,
          offset: const Offset(0, 10),
        ),
      ],
      builder: (context) => ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 360,
          maxHeight: screenHeight * 0.6
        ),
        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Opacity(
                              opacity: 0.82,
                              child: Container(
                                padding: const EdgeInsets.all(20),
                                decoration: const BoxDecoration(
                                  gradient: LinearGradient(
                                    colors: [Color(0xFF4A90E2), Color(0xFF5BA0F2)],
                                  ),
                                  borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                                ),
                                child: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.2),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: const Icon(Icons.book, color: Colors.white, size: 22),
                              ),
                              const SizedBox(width: 14),
                              const Expanded(
                                child: Text(
                                  '选择课程',
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                              GestureDetector(
                                onTap: () => Navigator.pop(context),
                                child: Container(
                                  padding: const EdgeInsets.all(6),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(alpha: 0.2),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: const Icon(Icons.close, color: Colors.white, size: 18),
                                ),
                              ),
                            ],
                          ),
                            ),
                              ),
                        if (allCourses.isEmpty)
                          Padding(
                            padding: const EdgeInsets.all(40),
                            child: Column(
                              children: [
                                Icon(Icons.book_outlined, size: 48, color: Colors.grey.shade400),
                                const SizedBox(height: 12),
                                Text(
                                  '暂无课程',
                                  style: TextStyle(color: Colors.grey.shade500),
                                ),
                                const SizedBox(height: 8),
                                TextButton(
                                  onPressed: () {
                                    Navigator.pop(context);
                                    _showCourseDialog();
                                  },
                                  child: const Text('先添加课程'),
                                ),
                              ],
                            ),
                          )
                        else
                          Flexible(
                            child: ListView.builder(
                              shrinkWrap: true,
                              physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
                              padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
                              itemCount: courseGroups.length,
                              itemBuilder: (context, index) {
                                final entry = courseGroups[index];
                                final courseName = entry.key;
                                final courses = entry.value;
                                final courseColor = _parseColor(courses.first.color);
                                return Container(
                                  margin: const EdgeInsets.only(bottom: 8),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(alpha: 0.4),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(color: Colors.grey.shade200),
                                  ),
                                  child: ListTile(
                                    leading: Container(
                                      width: 40,
                                      height: 40,
                                      decoration: BoxDecoration(
                                        color: courseColor.withValues(alpha: 0.15),
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      child: Icon(Icons.book, color: courseColor, size: 20),
                                    ),
                                    title: Text(
                                      courseName,
                                      style: const TextStyle(fontWeight: FontWeight.w500),
                                    ),
                                    subtitle: courses.first.teacher != null && courses.first.teacher!.isNotEmpty
                                        ? Text(courses.first.teacher!, style: TextStyle(fontSize: 12, color: Colors.grey.shade600))
                                        : null,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    onTap: () {
                                      Navigator.pop(context);
                                      _showTaskDialog(courses.first);
                                    },
                                  ),
                                );
                              },
                            ),
                          ),
                      ],
                    ),
        ),
    );
  }

  void _showTaskDialog(Course course) {
    _showAddTaskDialog(
      course,
      _parseColor(course.color),
      (callback) {
        if (!mounted) return;
        setState(callback);
      },
      <Task>[],
    );
  }

  void _openCourseEditorFromDetail({
    required Course course,
    required bool addSameSlotCourse,
  }) {
    Navigator.pop(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (addSameSlotCourse) {
        _showCourseDialog(
          selectedDay: course.day,
          selectedPeriod: course.time,
          initialFocusSection: CourseEditFocusSection.weeks,
        );
      } else {
        _showCourseDialog(course: course);
      }
    });
  }

  void _showCourseDialog({
    Course? course,
    int? selectedDay,
    int? selectedPeriod,
    CourseEditFocusSection? initialFocusSection,
    Rect? sourceRect,
    Widget? sourceWidget,
    bool plusMaskSource = false,
  }) {
    // 打开编辑对话框时以动画方式收起加号遮罩；加号遮罩来源保留遮罩：
    // morph 从遮罩原位起飞（t=0 复刻与遮罩像素重合），取消时 morph 翻回
    // 归位、遮罩保持显示（对话框期间仅取消自动消失倒计时）
    // 减弱动态效果：无 morph，遮罩一律收起
    if (plusMaskSource && !_reduceMotionEnabled) {
      _cancelEmptySlotAutoHideTimer();
    } else {
      _dismissEmptySlotMask();
    }

    // 编辑/添加对话框打开期间暂停非本周课程浮现卡片倒计时（含菜单
    // 「编辑/添加同时段」链式入口；计数嵌套，见 _pauseInactivePeek），
    // 对话框关闭（then 回调）时续接
    _pauseInactivePeek();

    // 减弱动态效果：取消 morph 容器变换，改走下方无锚点统一对话框分支
    // （showBouncyDialog + reduceMotion：壳仅半透明无模糊、四周压暗裁切
    // 与开闭动画不变、移除内容模糊淡入淡出）。不直接置空 sourceRect——
    // 参数重赋值会破坏下方 then 闭包里的空安全提升
    final bool useReducedDialog = _reduceMotionEnabled;

    void afterClosed() {
      _loadData();
      setState(() {});
    }

    // 新课程卡片复刻的渲染参数（与网格课程块同源，保证落定帧一致）
    final hasWallpaper = _wallpaperEnabled &&
        _wallpaperPath != null &&
        File(_wallpaperPath!).existsSync();
    final cardTransparency =
        hasWallpaper ? (100 - _wallpaperOpacity) / 50.0 : 0.0;

    // 无锚点（FAB 添加、详情页快捷编辑、编辑菜单等）：关于式弹性对话框
    // （果冻开闭 + 内容聚焦 + 孔洞遮罩），与其它对话框统一；
    // 有锚点（课程块/加号遮罩）走下方的 morph 容器变换；
    // 减弱动态效果：忽略锚点，一律走统一对话框（reduceMotion 无模糊）
    if (sourceRect == null || useReducedDialog) {
      final isSmallScreen = MediaQuery.of(context).size.height < 700;
      showBouncyDialog<Course>(
        context: context,
        barrierLabel: '课程对话框',
        avoidKeyboard: true,
        margin: EdgeInsets.symmetric(horizontal: isSmallScreen ? 12 : 24),
        shellPadding: EdgeInsets.zero,
        // 紧凑阴影（与 morph 入口一致）：阴影可见区域明显小于对话框本体
        shellBoxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
        builder: (context) => CourseDialog(
          course: course,
          selectedDay: selectedDay ?? course?.day ?? DateTime.now().weekday - 1,
          selectedPeriod: selectedPeriod ?? course?.time,
          initialFocusSection: initialFocusSection,
          hosted: true,
        ),
        reduceMotion: _reduceMotionEnabled,
      ).then((saved) {
        afterClosed();
        _resumeInactivePeek();
        // 统一添加入口保存成功：新课程块出现动画（由模糊小块伸展变
        // 清晰，删除动画的逆过程）。pop 瞬间先以隐藏态渲染新块（避免
        // 在对话框退出动画 400ms 期间以完整形态露出——「直接出现」），
        // 退出动画播完后（420ms）再开始伸展。morph 来源（加号遮罩/
        // 课程块）不走这里——morph 落定帧直接渲染新卡片复刻，无缝
        // 交接后再出现动画会重复。
        // id 注意：saved.id 未加课程表前缀，须解析为存储后的课程
        //（见 _resolveStoredCourse）
        if (saved != null && course == null && (sourceRect == null || useReducedDialog)) {
          final stored = _resolveStoredCourse(saved) ?? saved;
          _beginCourseAppearAnimation(stored);
          Future.delayed(const Duration(milliseconds: 420), () {
            if (mounted) _playCourseAppearAnimation();
          });
        }
      });
      return;
    }

    // 挂在课程对话框壳上：morph/孔洞测量壳矩形本身（不含对话框 margin）
    final courseShellKey = GlobalKey();
    // 动态复刻：pop 瞬间按保存结果切换 morph「正面」——
    // - 保存成功（新增/编辑）：换成保存后课程卡片复刻，关闭动画落定
    //   即所见即所得（加号遮罩添加课程后直接渲染新增课程卡片）；
    // - 加号遮罩取消添加：保留遮罩复刻，morph 翻回归位到遮罩原位，
    //   落定后 landSourceBlock 恢复遮罩显示并重启自动消失倒计时
    final replicaNotifier = ValueNotifier<Widget?>(sourceWidget);
    // 统一淡出模式（历史路径：取消曾统一淡出，现改 morph 归位）：
    // 仍传给 CourseDialog 但不再置 true
    final unifiedFadeMode = ValueNotifier(false);
    // 加号遮罩取消标记：pop（saved == null）瞬间置 true，供落定回调识别
    bool plusMaskCancelled = false;
    // 动态源矩形：保存成功后更新为新课程块的实际矩形（加号单格 →
    // 多节块 / 编辑改时长位置），morph 按实际大小落位
    final sourceRectNotifier = ValueNotifier<Rect?>(null);
    // 卡片模糊跟随（同课程详情）：壁纸模式且开启「卡片模糊」时，morph
    // 卡片正面背后以 sigma 22 实时模糊；课程块/加号遮罩
    // 透明度由复刻颜色 alpha 跟随设置
    final dialogHasWallpaper = _wallpaperEnabled &&
        _wallpaperPath != null &&
        File(_wallpaperPath!).existsSync();
    // sigma 视觉校准：网格模糊层（sigma 8）与真块的合成观感深于 morph
    // 卡片的单层 BackdropFilter，提到 22（用户校准值）后起飞/落定帧与
    // 固定课程块模糊程度一致。大/小卡片统一 22（与 detailBackdropBlur
    // 同值，视觉观感跨场景一致）
    final dialogBackdropBlur =
        dialogHasWallpaper && _wallpaperBlurEnabled ? 22.0 : null;
    // 翻转卡片接管源课程块（编辑/添加场景）的时机由 host 控制（同课程
    // 详情，动画结束前课程块绝不出现）；添加场景（course == null）以
    // 目标格为源：新增课程保存后由 onLanding 在动画播完时同步刷新
    // 数据（_loadData 为同步读取），新课程块瞬时呈现。
    // land/restore 带代数校验（同详情，防过期代数收尾干扰新接管）
    final takeoverSeq = ++_morphTakeoverSeq;
    void hideSourceBlock() {
      if (!mounted) return;
      setState(() {
        _morphHiddenDay = course?.day ?? selectedDay;
        _morphHiddenPeriod = course?.time ?? selectedPeriod;
      });
      _morphBlockFade.reverse();
      // 加号遮罩来源：复刻卡片已同帧盖在遮罩上起飞，真遮罩此刻开始
      // 200ms 淡出（不再残留原位）；取消归位落定时由 landSourceBlock
      // 同帧恢复全显，衔接无缝（收起前已取消自动消失倒计时）
      if (plusMaskSource) {
        _dismissEmptySlotMask();
      }
    }

    void landSourceBlock() {
      if (!mounted || takeoverSeq != _morphTakeoverSeq) return;
      // 动画播完（dismissed）时刷新并瞬时显现：课程块出现即最新数据
      // （编辑/新增保存后的内容）
      _loadData();
      _morphBlockFade.forward();
      if (plusMaskSource && selectedDay != null && selectedPeriod != null) {
        if (plusMaskCancelled) {
          // 取消归位落定：遮罩与复刻末帧同帧恢复全显（像素一致无缝
          // 交接），并重新开始 5 秒自动消失倒计时
          setState(() {
            _selectedEmptyDay = selectedDay;
            _selectedEmptyPeriod = selectedPeriod;
          });
          _emptySlotMaskController.value = 1.0;
          _startEmptySlotAutoHideTimer();
        } else {
          // 新增保存落定：目标格已有新课程块，清除遮罩选中避免残留叠加
          setState(() {
            _selectedEmptyDay = null;
            _selectedEmptyPeriod = null;
          });
        }
      }
    }

    void restoreSourceBlock() {
      if (!mounted ||
          takeoverSeq != _morphTakeoverSeq ||
          (_morphHiddenDay == null && _morphHiddenPeriod == null)) {
        return;
      }
      setState(() {
        _morphHiddenDay = null;
        _morphHiddenPeriod = null;
      });
      // morph 落定：播挂起的删除幽灵（详情删除链路，无挂起则 no-op）
      _flushPendingVanish();
    }

    // 泛型 <Course?>：then 拿到保存的 Course（保存）/ null（取消），
    // 用于 pop 瞬间切换 morph 复刻（新卡片 / 统一淡出）
    // 用 RawDialogRoute 替代 showGeneralDialog：关闭时长按路径区分——
    // 保存归位 400ms（与 BouncyDialogHost / 正常对话框关闭一致，干脆）；
    // 取消翻回归位 pop 瞬间改 600ms，与课程卡片 morph（详情 showGeneralDialog
    // 600/600）节奏一致（用户反馈归位过快的根源是统一 400）。打开仍 600ms。
    //
    // RawDialogRoute 构造器不支持 reverseTransitionDuration，用子类覆盖；
    // pop 前（then 回调在路由 reverse 启动之前）可再改时长生效
    final route = _Reverse400MorphRoute<Course?>(
      pageBuilder: (context, animation, secondaryAnimation) {
        return _MorphDialogHost(
          animation: animation,
          sourceRect: sourceRect,
          sourceWidget: sourceWidget,
          sourceWidgetListenable: replicaNotifier,
          sourceRectListenable: sourceRectNotifier,
          backdropBlurSigma: dialogBackdropBlur,
          shellKey: courseShellKey,
          onSourceHidden: hideSourceBlock,
          onLanding: landSourceBlock,
          onDismissed: restoreSourceBlock,
          child: CourseDialog(
            course: course,
            selectedDay: selectedDay ?? course?.day ?? DateTime.now().weekday - 1,
            selectedPeriod: selectedPeriod ?? course?.time,
            initialFocusSection: initialFocusSection,
            shellKey: courseShellKey,
            // 壳内局部背景模糊（圆角对齐 + 提亮层）：采样孔洞内未压暗背景
            backgroundBlurSigma: 5,
            // 统一淡出（取消路径）的壳内内容失焦模糊
            routeAnimation: animation,
            unifiedFadeMode: unifiedFadeMode,
          ),
        );
      },
      barrierDismissible: true,
      barrierLabel: '课程对话框',
      // 压暗遮罩由 _MorphDialogHost 自绘（孔洞跟随 morph 矩形逐帧开合）：
      // 对话框背后采样到未压暗的原始背景，壳内毛玻璃白净不发灰；四周仅压暗
      barrierColor: Colors.transparent,
      // 打开 600ms（morph 翻转从容）；关闭时长由子类覆盖为 400ms
      transitionDuration: const Duration(milliseconds: 600),
      // 恒等过渡：禁用 RawDialogRoute 默认的线性
      // FadeTransition——morph 卡片全程不透明，落定帧与真课程块/
      // 加号遮罩像素一致，路由移除与真块出现同帧无缝交接
      transitionBuilder: (context, animation, secondaryAnimation, child) => child,
    );
    Navigator.of(context).push<Course?>(route).then((saved) {
      _resumeInactivePeek();
      // 注意：此处**不得**恢复源课程块——popped future 在 pop() 调用瞬间
      // 即完成（先于 600ms 退出动画，见 Route.didComplete 文档），此刻
      // restoreSourceBlock 会让真课程块在关闭动画第 0 帧就出现在网格
      // 固定位置上（「固定课程块提前出现」的真正根源，此前多轮曲线/
      // 翻转窗口调参均未触及此路径）。恢复只由 _MorphDialogHost 在动画
      // 播完（dismissed）时经 onLanding/onDismissed 触发（host dispose
      // 兜底防漏）；这里仅做数据刷新
      _loadData();
      setState(() {});
      // popped future 在 pop 瞬间即完成（先于退出动画首帧）：此刻切换
      // 复刻，morph 下一帧（动画首帧）起就渲染新卡片/淡出形态
      if (saved != null) {
        // 保存成功：复刻换成保存后的课程卡片（新增=新卡片、编辑=编辑
        // 后内容），关闭动画落定即所见即所得。
        // id 注意：saved.id 未加课程表前缀，网格 Key 注册用的是前缀
        // id——必须解析为存储后的课程（见 _resolveStoredCourse），
        // 否则测量查 Key 永远为 null，morph 落回旧的单格矩形
        //（「归位仍只有一格」的根源）
        final stored = _resolveStoredCourse(saved) ?? saved;
        replicaNotifier.value = _buildCourseCellCard(
          stored,
          hasWallpaper: hasWallpaper,
          transparencyFactor: cardTransparency,
        );
        // 同步预置新课程块落位矩形（加号遮罩新增且未改日期时）：加号格与
        // 新块同列同节距（cellHeight = 遮罩高 + 4），pop 瞬间即可由遮罩矩形
        // 直接算出——morph 自关闭第 1 帧直奔实际矩形，消除等 GlobalKey 逐帧
        // 重试测量才中途改靶的绕行（阴影/孔洞裁切跟随延迟的根源）
        if (plusMaskSource &&
            course == null &&
            selectedPeriod != null &&
            stored.day == selectedDay) {
          final cellHeight = sourceRect.height + 4;
          final top = sourceRect.top + (stored.time - selectedPeriod) * cellHeight;
          sourceRectNotifier.value = Rect.fromLTRB(
            sourceRect.left,
            top,
            sourceRect.right,
            top + stored.duration * cellHeight - 4,
          );
        }
        // 下一帧测量新课程块的实际矩形（_loadData 后新块已布局在网格，
        // 处于 morph 隐藏透明态但可测）——morph 落定到实际大小/位置，
        // 与真块无缝交接（加号单格 → 多节块的大小修正）。
        // 重试链：pop 触发帧末 setState 的 rebuild 可能尚未发生（新块
        // 未挂 key）；逐帧重试直到测到或满 8 帧。
        // Fallback：新课程 weeks 不含当前周时，新块以 inactive 态渲染
        // 但用的是 sameStartCourses 中 duration 最大的 course 的 key
        // （不一定是新课程）——GlobalKey 永远测不到。此时用加号遮罩
        // sourceRect 的 left/top/right + duration×cellHeight 计算矩形
        //（同一格的起始位置，高度按节数扩展）
        void measureNewCell({int attempt = 0}) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            final ro = _courseCellKeys['${stored.id}@$_currentWeek']
                ?.currentContext
                ?.findRenderObject();
            if (ro is RenderBox && ro.attached && ro.hasSize) {
              sourceRectNotifier.value =
                  ro.localToGlobal(Offset.zero) & ro.size;
            } else if (attempt < 8) {
              measureNewCell(attempt: attempt + 1);
            } else if (sourceRectNotifier.value == null) {
              // Fallback：GlobalKey 测不到（新课程不在当前周渲染等场景）
              // 且无同步预置矩形——用 sourceRect（加号遮罩单格）的
              // left/top/right + duration×默认节高估算多节块矩形
              sourceRectNotifier.value = Rect.fromLTRB(
                sourceRect.left,
                sourceRect.top,
                sourceRect.right,
                sourceRect.top + stored.duration * 75.0 - 4,
              );
            }
          });
        }

        measureNewCell();
      } else if (plusMaskSource) {
        // 加号遮罩取消添加：保留遮罩复刻 → morph 翻回归位到遮罩原位，
        // 落定后 landSourceBlock 同帧恢复遮罩显示并重启自动消失倒计时。
        // 关闭时长与保存路径同为 600（路由默认），与课程卡片 morph 一致
        plusMaskCancelled = true;
      }
    });
  }

  Color _parseColor(String hex) {
    try {
      hex = hex.replaceAll('#', '');
      if (hex.length == 6) {
        return Color(int.parse('FF$hex', radix: 16));
      }
    } catch (e) {
      debugPrint('Error parsing color: $e');
    }
    return const Color(0xFF4A90E2);
  }
}

class _CornerTrianglePainter extends CustomPainter {
  final Color color;

  const _CornerTrianglePainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final path = Path()
      ..moveTo(size.width, 0)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _CornerTrianglePainter oldDelegate) {
    return oldDelegate.color != color;
  }
}

class _TaskDialog extends StatefulWidget {
  final Course course;
  final Color courseColor;
  final TextEditingController nameController;
  final DateTime dueDate;
  final String type;
  final String priority;
  final TextEditingController noteController;
  final Function(Task) onSave;

  const _TaskDialog({
    required this.course,
    required this.courseColor,
    required this.nameController,
    required this.dueDate,
    required this.type,
    required this.priority,
    required this.noteController,
    required this.onSave,
  });

  @override
  State<_TaskDialog> createState() => _TaskDialogState();
}

class _TaskDialogState extends State<_TaskDialog> with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;
  late Animation<double> _scaleAnimation;
  // 对话框内可编辑的临时值，初值取自 widget（widget 本身保持不可变）
  late DateTime dueDate;
  late String type;
  late String priority;

  @override
  void initState() {
    super.initState();
    dueDate = widget.dueDate;
    type = widget.type;
    priority = widget.priority;
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _fadeAnimation = CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeOut,
    );
    _scaleAnimation = Tween<double>(begin: 0.9, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeOut),
    );
    _animationController.forward();
  }

  void _closeDialog() async {
    await _animationController.reverse();
    if (mounted) {
      Navigator.pop(context);
    }
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    final keyboardHeight = MediaQuery.of(context).viewInsets.bottom;
    final topInset = MediaQuery.of(context).padding.top;
    final isSmallScreen = screenHeight < 700;
    final baseMaxHeight = isSmallScreen ? screenHeight * 0.8 : 520.0;
    double dialogMaxHeight = baseMaxHeight;
    final availableHeight = screenHeight - topInset - keyboardHeight - 24;
    if (availableHeight < dialogMaxHeight) {
      dialogMaxHeight = availableHeight;
    }
    dialogMaxHeight = dialogMaxHeight.clamp(240.0, baseMaxHeight).toDouble();

    return BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
      child: FadeTransition(
        opacity: _fadeAnimation,
        child: ScaleTransition(
          scale: _scaleAnimation,
          child: Center(
            child: Material(
              color: Colors.transparent,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                margin: EdgeInsets.only(
                  left: isSmallScreen ? 12 : 24,
                  right: isSmallScreen ? 12 : 24,
                  top: keyboardHeight > 0 ? topInset + 8 : 0,
                  bottom: keyboardHeight > 0 ? keyboardHeight + 8 : 0,
                ),
                constraints: BoxConstraints(
                  maxWidth: 400,
                  maxHeight: dialogMaxHeight,
                ),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.2),
                      blurRadius: 20,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: EdgeInsets.all(isSmallScreen ? 12 : 20),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [widget.courseColor, widget.courseColor.withValues(alpha: 0.8)],
                        ),
                        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                      ),
                      child: Row(
                        children: [
                          Container(
                            padding: EdgeInsets.all(isSmallScreen ? 6 : 10),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Icon(Icons.add_task, color: Colors.white, size: isSmallScreen ? 18 : 22),
                          ),
                          SizedBox(width: isSmallScreen ? 8 : 14),
                          Expanded(
                            child: Text(
                              '添加任务 - ${widget.course.name}',
                              style: TextStyle(
                                fontSize: isSmallScreen ? 15 : 18,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                          ),
                          GestureDetector(
                            onTap: _closeDialog,
                            child: Container(
                              padding: const EdgeInsets.all(6),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.2),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Icon(Icons.close, color: Colors.white, size: isSmallScreen ? 16 : 18),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: SingleChildScrollView(
                        physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
                        padding: EdgeInsets.all(isSmallScreen ? 12 : 20),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            TextField(
                              contextMenuBuilder: styledEditableContextMenu,
                              controller: widget.nameController,
                              decoration: InputDecoration(
                                labelText: '任务名称',
                                prefixIcon: Icon(Icons.task, color: widget.courseColor.withValues(alpha: 0.7), size: isSmallScreen ? 16 : 20),
                                filled: true,
                                fillColor: Colors.grey.shade50,
                                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: isSmallScreen ? 10 : 14),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide(color: Colors.grey.shade200),
                                ),
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide(color: Colors.grey.shade200),
                                ),
                                focusedBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide(color: widget.courseColor, width: 2),
                                ),
                              ),
                              style: TextStyle(fontSize: isSmallScreen ? 14 : 16),
                            ),
                            SizedBox(height: isSmallScreen ? 10 : 16),
                            Row(
                              children: [
                                Icon(Icons.category_outlined, color: widget.courseColor.withValues(alpha: 0.7), size: isSmallScreen ? 16 : 20),
                                SizedBox(width: isSmallScreen ? 4 : 8),
                                Text(
                                  '任务类型',
                                  style: TextStyle(
                                    fontSize: isSmallScreen ? 11 : 12,
                                    color: Colors.grey.shade600,
                                  ),
                                ),
                              ],
                            ),
                            SizedBox(height: isSmallScreen ? 4 : 8),
                            Container(
                              padding: EdgeInsets.symmetric(horizontal: isSmallScreen ? 8 : 12),
                              decoration: BoxDecoration(
                                color: Colors.grey.shade50,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: Colors.grey.shade200),
                              ),
                              // BlurredDropdown（而非原生 DropdownButton）：原生下拉经子路由
                              // 显示，收起时路由焦点恢复会钻回同对话框内的任务名称输入框，
                              // 导致键盘反复弹出；BlurredDropdown 打开前已做焦点锚点转移
                              child: BlurredDropdown<String>(
                                value: type,
                                isExpanded: true,
                                icon: Icon(Icons.expand_more, color: widget.courseColor, size: isSmallScreen ? 16 : 20),
                                items: ['作业', '考试', '报告', '其他'].map((e) => DropdownMenuItem(
                                  value: e,
                                  child: Text(e, style: TextStyle(fontSize: isSmallScreen ? 14 : 16))
                                )).toList(),
                                onChanged: (v) => setState(() => type = v!),
                              ),
                            ),
                            SizedBox(height: isSmallScreen ? 10 : 16),
                            InkWell(
                              onTap: () async {
                                final date = await showAnimatedDatePicker(
                                  context: context,
                                  initialDate: dueDate,
                                  firstDate: DateTime.now(),
                                  lastDate: DateTime.now().add(const Duration(days: 365)),
                                );
                                if (date != null) {
                                  if (!context.mounted) return;
                                  final time = await show3DTimePicker(
                                    context: context,
                                    initialHour: dueDate.hour,
                                    initialMinute: dueDate.minute,
                                    title: '选择截止时间',
                                  );
                                  if (time != null) {
                                    setState(() {
                                      dueDate = DateTime(date.year, date.month, date.day, time.hour, time.minute);
                                    });
                                  }
                                }
                              },
                              borderRadius: BorderRadius.circular(12),
                              child: Container(
                                padding: EdgeInsets.all(isSmallScreen ? 10 : 16),
                                decoration: BoxDecoration(
                                  color: Colors.grey.shade50,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: Colors.grey.shade200),
                                ),
                                child: Row(
                                  children: [
                                    Icon(Icons.calendar_today, color: widget.courseColor.withValues(alpha: 0.7), size: isSmallScreen ? 16 : 20),
                                    SizedBox(width: isSmallScreen ? 8 : 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text('截止日期', style: TextStyle(fontSize: isSmallScreen ? 11 : 12, color: Colors.grey.shade600)),
                                          Text(intl.DateFormat('yyyy/MM/dd HH:mm').format(dueDate), style: TextStyle(fontWeight: FontWeight.w500, fontSize: isSmallScreen ? 13 : 16)),
                                        ],
                                      ),
                                    ),
                                    Icon(Icons.chevron_right, color: Colors.grey.shade400, size: isSmallScreen ? 16 : 20),
                                  ],
                                ),
                              ),
                            ),
                            SizedBox(height: isSmallScreen ? 10 : 16),
                            Row(
                              children: [
                                Icon(Icons.flag_outlined, color: widget.courseColor.withValues(alpha: 0.7), size: isSmallScreen ? 16 : 20),
                                SizedBox(width: isSmallScreen ? 4 : 8),
                                Text(
                                  '优先级',
                                  style: TextStyle(
                                    fontSize: isSmallScreen ? 11 : 12,
                                    color: Colors.grey.shade600,
                                  ),
                                ),
                              ],
                            ),
                            SizedBox(height: isSmallScreen ? 4 : 8),
                            Row(
                              children: ['高', '中', '低'].map((p) {
                                final isSelected = priority == p;
                                Color priorityColor;
                                if (p == '高') {
                                  priorityColor = Colors.red;
                                } else if (p == '中') priorityColor = Colors.orange;
                                else priorityColor = Colors.green;
                                
                                return Expanded(
                                  child: GestureDetector(
                                    onTap: () => setState(() => priority = p),
                                    child: Container(
                                      margin: EdgeInsets.symmetric(horizontal: isSmallScreen ? 3 : 4),
                                      padding: EdgeInsets.symmetric(vertical: isSmallScreen ? 8 : 10),
                                      decoration: BoxDecoration(
                                        color: isSelected ? priorityColor.withValues(alpha: 0.15) : Colors.grey.shade50,
                                        borderRadius: BorderRadius.circular(10),
                                        border: Border.all(
                                          color: isSelected ? priorityColor : Colors.grey.shade200,
                                          width: isSelected ? 2 : 1,
                                        ),
                                      ),
                                      child: Text(
                                        p,
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          fontSize: isSmallScreen ? 13 : 14,
                                          color: isSelected ? priorityColor : Colors.grey.shade600,
                                          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                        ),
                                      ),
                                    ),
                                  ),
                                );
                              }).toList(),
                            ),
                            SizedBox(height: isSmallScreen ? 10 : 16),
                            TextField(
                              contextMenuBuilder: styledEditableContextMenu,
                              controller: widget.noteController,
                              maxLines: 1,
                              decoration: InputDecoration(
                                labelText: '备注（可选）',
                                prefixIcon: Icon(Icons.note_outlined, color: widget.courseColor.withValues(alpha: 0.7), size: isSmallScreen ? 16 : 20),
                                filled: true,
                                fillColor: Colors.grey.shade50,
                                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: isSmallScreen ? 10 : 14),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide(color: Colors.grey.shade200),
                                ),
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide(color: Colors.grey.shade200),
                                ),
                                focusedBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide(color: widget.courseColor, width: 2),
                                ),
                              ),
                              style: TextStyle(fontSize: isSmallScreen ? 14 : 16),
                            ),
                          ],
                        ),
                      ),
                    ),
                    Container(
                      padding: EdgeInsets.fromLTRB(isSmallScreen ? 12 : 20, 0, isSmallScreen ? 12 : 20, isSmallScreen ? 12 : 20),
                      child: Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: _closeDialog,
                              style: OutlinedButton.styleFrom(
                                padding: EdgeInsets.symmetric(vertical: isSmallScreen ? 10 : 14),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                side: BorderSide(color: Colors.grey.shade300),
                              ),
                              child: Text('取消', style: TextStyle(fontSize: isSmallScreen ? 13 : 14)),
                            ),
                          ),
                          SizedBox(width: isSmallScreen ? 8 : 12),
                          Expanded(
                            flex: 2,
                            child: ElevatedButton(
                              onPressed: () async {
                                if (widget.nameController.text.isEmpty) return;
                                final task = Task(
                                  id: DateTime.now().millisecondsSinceEpoch.toString(),
                                  courseId: widget.course.id,
                                  name: widget.nameController.text,
                                  type: type,
                                  dueDate: dueDate,
                                  priority: priority,
                                  note: widget.noteController.text.isEmpty ? null : widget.noteController.text,
                                );
                                await widget.onSave(task);
                                _closeDialog();
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: widget.courseColor,
                                foregroundColor: Colors.white,
                                padding: EdgeInsets.symmetric(vertical: isSmallScreen ? 10 : 14),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              ),
                              child: Text('添加', style: TextStyle(fontSize: isSmallScreen ? 13 : 15)),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CourseBlurClipper extends CustomClipper<Path> {
  final List<RRect> rRects;

  _CourseBlurClipper(this.rRects);

  @override
  Path getClip(Size size) {
    final path = Path();
    for (final r in rRects) {
      path.addRRect(r);
    }
    return path;
  }

  @override
  bool shouldReclip(_CourseBlurClipper old) => true;
}

/// 翻转进度（打开方向）：位置进度 18%~82% → 翻转 0→1（easeInOutCubic）。
/// **动画中段翻转**（用户最终方案）：位置曲线为对称 easeInOutCubic，
/// 中段正是速度峰值——卡片在中等尺寸（约为源与对话框的几何中间
/// 形态）完成翻面：先从容放大起步（前 18% 位置，课程块「点击后
/// 消失」由渐隐负责），中段 64% 位置区间内翻面对话框，末段从容
/// 微调落定。打开/关闭的阶段顺序与窗口完全镜像对称。
/// 总时长 600ms 不变；翻转窗口占比增大（64% vs 原 40%）使翻转效果
/// 更显著——侧立点仍在动画中点（50%）保证对称性，但翻转过程
/// 更慢更明显
double _morphFlipForward(double morphT) =>
    Curves.easeInOutCubic.transform(((morphT - 0.18) / 0.64).clamp(0.0, 1.0));

/// 翻转进度（关闭方向）：以**原始线性动画值**（时间成正比）为自变量，
/// 窗口 rawT 82%~18%（即时间 18%~82%，**动画中段翻转**——与打开
/// 窗口镜像对称）：前 18% 时间对话框形态从容收缩（S 曲线加速段），
/// 中段 64% 时间在中等尺寸翻回课程块正面（侧立点恰在时间/位置
/// 双重中点 50%），后 18% 时间以课程块形态减速落回源位置。
/// 真课程块只在动画播完（dismissed）才出现（popped future 在 pop
/// 瞬间完成的提前恢复路径已删除），末帧复刻与真块像素一致无缝交接
double _morphFlipReverse(double rawT) =>
    Curves.easeInOutCubic.transform(((rawT - 0.18) / 0.64).clamp(0.0, 1.0));

/// 翻转期壳的投影四角（屏幕坐标，TL/TR/BR/BL 顺时针）：与卡片旋转同数学。
/// 卡片绕竖直轴旋转时投影为透视梯形，孔洞直接取该四边形（此前轴对齐矩形 ×
/// |cos| 只水平收缩不跟随倾斜，卡片前几帧已倾斜而孔洞仍水平——压暗边横穿
/// 卡片/阴影，即用户所见「阴影裁切框没跟随翻转」）。矩阵公式与 _CourseDetailMorph
/// 正/背面严格一致：绕盒中心 rotateY(π·flip) + 透视项 0.001：点 (x, z) →
/// (x·cosθ, −x·sinθ)，投影缩放 1/(1 − 0.001·z)。壳在飞行盒内的 margin
/// 随盒缩放同 _MorphDialogHost 孔洞轮廓反推公式。
List<Offset> _morphFlipQuadCorners({
  required Rect source,
  required Rect shell,
  required Rect whole,
  required double morphT,
  required double flip,
  /// 复刻正面阶段（shell 传 whole）：透视项用卡片局部（未缩放）坐标
  /// 投影——见 project 内注释
  bool cardSpace = false,
}) {
  final flight = Rect.lerp(source, whole, morphT)!;
  final sx = flight.width / whole.width;
  final sy = flight.height / whole.height;
  final ml = (shell.left - whole.left) * sx;
  final mt = (shell.top - whole.top) * sy;
  final mr = (whole.right - shell.right) * sx;
  final mb = (whole.bottom - shell.bottom) * sy;
  final cx = flight.center.dx;
  final cy = flight.center.dy;
  final hw = (flight.width - ml - mr) / 2;
  final hh = (flight.height - mt - mb) / 2;
  // 非对称 margin（键盘避让）下壳中心偏离飞行盒中心：四角整体偏移 (ml-mr)/2、(mt-mb)/2
  final offX = (ml - mr) / 2;
  final offY = (mt - mb) / 2;
  final left = -hw + offX;
  final right = hw + offX;
  final top = -hh + offY;
  final bottom = hh + offY;
  final c = math.cos(math.pi * flip);
  final s = math.sin(math.pi * flip);
  Offset project(double lx, double ly) {
    // cardSpace（复刻正面·整盒卡片）：透视项须用卡片局部未缩放坐标
    // ——渲染矩阵是「外层容器逐轴缩放 × 内层旋转+透视」，齐次除法
    // 发生在缩放之前的卡片局部系（w 只由内层透视行产生）。若沿用
    // 缩放后的屏幕坐标 lx（下方默认路径），透视量被容器缩放折减，
    // 宽屏（sx 明显小于 1）角点偏差可达 ~6px
    if (cardSpace) {
      final qx = lx / sx;
      if (flip <= 0.5) {
        final w = 1.0 - 0.001 * qx * s;
        return Offset(cx + lx * c / w, cy + ly / w);
      }
      final w = 1.0 + 0.001 * qx * s;
      return Offset(cx - lx * c / w, cy + ly / w);
    }
    // 与 _CourseDetailMorph 两面 Transform 矩阵逐项同源：
    // 正面（flip≤0.5）rotateY(π·flip)：z' = −lx·s，w = 1+0.001·z' →
    //   p = 1/(1−0.001·lx·s)，x' = cx + lx·c·p
    // 背面（flip>0.5）rotateY(π·flip−π)：cosφ=−c、sinφ=−s →
    //   x' = cx − lx·c·p，p = 1/(1+0.001·lx·s)
    // 此前正面透视项符号写反（孔洞透视方向与卡片相反，旋转帧不贴合），
    // 背面误用正面公式：flip=1 时孔洞被绕盒中心镜像，键盘避让非对称
    // margin 下整体平移 (ml−mr, mt−mb)——关闭首帧「宽体闪现」与
    // 前几帧不贴合的根源。两面在 flip=0.5 均退化为 cx（侧立）连续。
    if (flip <= 0.5) {
      final p = 1.0 / (1.0 - 0.001 * lx * s);
      return Offset(cx + lx * c * p, cy + ly * p);
    }
    final p = 1.0 / (1.0 + 0.001 * lx * s);
    return Offset(cx - lx * c * p, cy + ly * p);
  }

  return [
    project(left, top), // TL
    project(right, top), // TR
    project(right, bottom), // BR
    project(left, bottom), // BL
  ];
}

/// 课程详情对话框的容器变换动画组件。
/// 打开时对话框从课程块的矩形非线性放大到位，关闭时反向缩回课程块。
class _CourseDetailMorph extends StatefulWidget {
  const _CourseDetailMorph({
    required this.animation,
    required this.sourceRect,
    required this.child,
    this.rawAnimation,
    this.onLaidOut,
    this.targetKey,
    this.sourceWidget,
    this.backdropBlurSigma,
  });

  final Animation<double> animation;
  final Rect? sourceRect;
  final Widget child;

  /// 原始（未缓动）路由动画：值与时间严格成正比，关闭方向的翻转
  /// 窗口以它为自变量（见 _morphFlipReverse 注释）
  final Animation<double>? rawAnimation;

  /// 翻转动画的「正面」：课程块/加号遮罩的视觉复刻。提供时启用卡片
  /// 翻转模式——矩形连续放大同时绕竖直轴翻转，前半程正面（课程块）
  /// 逐渐模糊、褪为白色并翻走，后半程对话框作为「背面」自白色模糊中
  /// 翻入并逐渐清晰；为空时退回缩放 + 淡入淡出。
  final Widget? sourceWidget;

  /// 卡片模糊跟随：设置开启「卡片模糊」（壁纸模式）时传入与网格模糊
  /// 层一致的 sigma（8.0）——morph 卡片正面背后实时模糊背景，半透明
  /// 课程块透出的是虚化背景，起飞/落定帧与真实课程块（覆于网格模糊
  /// 层上）视觉一致；null（关闭模糊/无壁纸）不模糊。课程块的透明度
  /// 由复刻自身的颜色 alpha 跟随设置（transparencyFactor），morph 不
  /// 垫底色不改变透明度
  final double? backdropBlurSigma;

  /// 目标矩形测量完成后回调，回传（**壳矩形**，**整个 child 矩形**）：
  /// 壳矩形（targetKey 测得，不含 child 自身 margin；缺省为整个 child）
  /// 作孔洞插值终点/落定锚点；整个 child 矩形（含 margin）是翻转卡片
  /// 布局盒的飞行终点——孔洞按飞行盒逐帧反推壳轮廓（margin 随盒缩放），
  /// 全程像素级贴壳。键盘避让等布局变化时也会再次回调（矩形有变化时）。
  final ValueChanged<(Rect, Rect)>? onLaidOut;

  /// 挂在对话框壳上的 Key：测壳矩形（不含 child 自身 margin），仅用作
  /// 孔洞锚点（经 onLaidOut 回调给外层）。morph 自身的布局/强制盒
  /// 始终用整个 child 的矩形（含 margin，见 _targetRect 注释）。
  final GlobalKey? targetKey;

  @override
  State<_CourseDetailMorph> createState() => _CourseDetailMorphState();
}

class _CourseDetailMorphState extends State<_CourseDetailMorph> {
  final GlobalKey _contentKey = GlobalKey();

  /// morph 根节点的布局矩形：**整个 child**（含其自身水平/键盘 margin），
  /// 首帧布局完成后测量一次；t≈1 时（transform≈identity）重测以跟进
  /// 键盘避让等布局变化。
  /// 关键约束：背面分支的 SizedBox 强制布局用的也是这个矩形——测量与
  /// 强制必须是同一矩形。若改用壳矩形（不含 margin）当布局盒，壳会被
  /// 自身 margin 挤小，动画完成后 force 重测得到更小的矩形 → 更新 →
  /// 再挤小……每帧 -48px 的无限收缩循环，表现为对话框展开后绕竖直轴
  /// 不停「翻转」收缩（本次修复的 bug）
  Rect? _targetRect;

  /// 壳（GlassDialogShell）矩形（不含 child 自身 margin）：
  /// 仅作外层孔洞的锚点（onLaidOut 回调），让孔洞贴壳而非贴含
  /// margin 的外框
  Rect? _shellRect;

  /// 上一帧动画状态：识别「进入关闭的首帧」做收缩起点重测
  AnimationStatus? _lastStatus;

  Rect? _measureKeyRect(GlobalKey key) {
    final ctx = key.currentContext;
    if (ctx == null) return null;
    final ro = ctx.findRenderObject();
    if (ro is RenderBox && ro.attached && ro.hasSize) {
      return ro.localToGlobal(Offset.zero) & ro.size;
    }
    return null;
  }

  static bool _rectChanged(Rect? a, Rect b) =>
      a == null ||
      (a.center - b.center).distance > 0.5 ||
      (a.width - b.width).abs() > 0.5 ||
      (a.height - b.height).abs() > 0.5;

  /// 打开期首帧测量（_targetRect 为空时）；落定后不再测量（child 已
  /// 自然布局，孔洞由宿主同步实测），关闭起点由 build 内专测
  void _tryMeasureTarget() {
    if (_targetRect != null) return;
    // 布局盒：整个 child（与 SizedBox 强制矩形一致，杜绝测量↔强制
    // 互相反馈的收缩循环）
    final whole = _measureKeyRect(_contentKey);
    if (whole == null) return;
    // 孔洞锚点：壳矩形（不含 margin）；无 targetKey 时退回整个 child
    final shell =
        _measureKeyRect(widget.targetKey ?? _contentKey) ?? whole;
    if (!_rectChanged(_targetRect, whole) &&
        !_rectChanged(_shellRect, shell)) {
      return;
    }
    _targetRect = whole;
    _shellRect = shell;
    // build 期间不可同步触发外层 setState，推迟到帧末（此时动画刚开始、
    // 遮罩透明度极低，孔洞晚一帧出现无感知）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.onLaidOut?.call((_shellRect ?? _targetRect!, _targetRect!));
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.animation,
      builder: (context, child) {
        final t = widget.animation.value;
        final status = widget.animation.status;
        // 从落定态进入关闭的首帧：child 上一帧还是自然布局（morph 落定
        // 后已解除强制盒；键盘弹出过的话实际位置已偏离打开时测的矩形）
        // ——同步重测真实矩形作为收缩起点，杜绝关闭首帧跳变（此后 child
        // 回到强制盒内，矩形固定，不再测量）。仅限「落定→关闭」：动画
        // 中途关闭（快速 pop）时上一帧含非恒等 Transform，localToGlobal
        // 读到的是动画中间态矩形而非布局矩形，实测反而引入跳变——沿用
        // 打开时的矩形（布局盒从未变化，本就无跳变）
        if (status == AnimationStatus.reverse &&
            _lastStatus == AnimationStatus.completed) {
          final whole = _measureKeyRect(_contentKey);
          if (whole != null) {
            _targetRect = whole;
            final shell = _measureKeyRect(widget.targetKey ?? _contentKey);
            if (shell != null) _shellRect = shell;
            // 帧末同步给宿主（宿主侧另有当帧实测，二者一致）
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                widget.onLaidOut?.call((_shellRect ?? _targetRect!, _targetRect!));
              }
            });
          }
        }
        _lastStatus = status;
        // 打开期首帧测量（隐形布局帧之后）；落定后无需持续测量——
        // child 已解除强制盒自然布局，孔洞由宿主同步实测
        _tryMeasureTarget();
        final targetRect = _targetRect;
        final sourceRect = widget.sourceRect;

        // 首帧：先以不可见方式完成布局，下一帧即可测量目标矩形
        if (targetRect == null) {
          return Transform(
            transform: Matrix4.identity(),
            child: Opacity(
              opacity: 0.0,
              child: Transform.scale(
                scale: 1.0,
                alignment: Alignment.center,
                child: child,
              ),
            ),
          );
        }

        // morph 落定（transform 恒等、翻转背面全显、无模糊——与 morph
        // 末帧逐像素等价）：解除强制布局盒，child 自然布局——键盘避让
        // margin 真正生效。此前落定后仍被 SizedBox(targetRect)+expand
        // 冻结在打开瞬间的矩形：键盘弹出时对话框不上移（避让失效），
        // morph 自身也不再重测（build 不跑），孔洞同步冻结（裁切大 bug）。
        // 孔洞改由宿主绘制阶段同步实测壳矩形，逐帧贴壳。
        if (status == AnimationStatus.completed && t >= 1.0) {
          return child!;
        }

        // 拿不到课程块矩形时，退回淡入淡出 + 轻微缩放
        if (sourceRect == null || sourceRect.isEmpty || targetRect.isEmpty) {
          return Opacity(
            opacity: t.clamp(0.0, 1.0).toDouble(),
            child: Transform.scale(
              scale: 0.9 + 0.1 * t,
              alignment: Alignment.center,
              child: child,
            ),
          );
        }

        // 容器矩形：由课程块矩形插值到对话框矩形（t 已包含非线性曲线）
        final rect = Rect.lerp(sourceRect, targetRect, t)!;
        final scaleX = rect.width / targetRect.width;
        final scaleY = rect.height / targetRect.height;
        final containerTransform = Matrix4.identity()
          ..translateByDouble(rect.left - targetRect.left, rect.top - targetRect.top, 0.0, 1.0)
          ..scaleByDouble(scaleX, scaleY, 1.0, 1.0);

        // —— 翻转模式（提供正面复刻）：对话框是课程块的「背面」——
        // 矩形自课程块连续放大到位（严格连贯），同时绕竖直轴翻转：
        // 前半程正面（课程块复刻）逐渐模糊、褪为白色并翻走，
        // 后半程背面（对话框）自白色模糊中翻入、逐渐清晰。
        final sourceWidget = widget.sourceWidget;
        if (sourceWidget != null) {
          // 翻转进度按方向取映射（见 _morphFlipForward/_morphFlipReverse）：
          // 两个方向都在动画中段（中等尺寸、速度峰值）完成翻面，
          // 窗口镜像对称（打开位置 18%~82%，关闭时间 18%~82%）
          final flip = widget.animation.status == AnimationStatus.reverse
              ? _morphFlipReverse(widget.rawAnimation?.value ?? t)
              : _morphFlipForward(t);
          // 卡片圆角随容器进度插值：课程块 5 → 对话框 24，
          // 起止两端分别与真实课程块/对话框壳完全一致
          final cardRadius = 5.0 + (24.0 - 5.0) * t;
          // 拉伸复刻：卡片以**课程块原始尺寸**布局（文字换行、内边距与
          // 真实课程块完全一致），再由 FittedBox(fill) 拉伸铺满卡片盒；
          // t=0 时容器变换恰好把它映射回课程块原位，像素级衔接。
          // 不能用 Transform+SizedBox 拉伸：SizedBox 处于 StackFit.expand
          // 的紧约束下会被覆盖，卡片实际按对话框尺寸布局——宽屏上短课名
          // 单行显示与真实块无异难以察觉，手机窄列（文字宽约 40px）上
          // 复刻呈单行截断的「超宽版」、加号遮罩复刻的加号图标位于布局
          // 中心而不可见（本次修复的 bug）；模糊施加在拉伸之后（卡片
          // 空间），sigma 不被拉伸倍数放大
          final stretchedReplica = FittedBox(
            fit: BoxFit.fill,
            child: SizedBox(
              width: sourceRect.width,
              height: sourceRect.height,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(5),
                child: sourceWidget,
              ),
            ),
          );
          final Widget face;
          if (flip < 0.5) {
            // 正面：课程块内容（含颜色）渐渐模糊、隐入白色卡背。
            // 白色不是盖在上面的遮罩，而是卡片自身的「纸背」底色——
            // 内容淡去后自然露出，像卡片的背面本来就在那里
            final dissolve = (flip / 0.5).clamp(0.0, 1.0).toDouble();
            face = Transform(
              alignment: Alignment.center,
              transform: Matrix4.identity()
                ..setEntry(3, 2, 0.001)
                ..rotateY(math.pi * flip),
              // 布局尺寸必须等于对话框卡片尺寸：morph 根节点的布局尺寸
              // 决定宿主 Center 的锚定位置与旋转枢轴
              child: SizedBox(
                width: targetRect.width,
                height: targetRect.height,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(cardRadius),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // 毛玻璃跟随：开启「卡片模糊」时卡片背后实时模糊
                      // ——半透明课程块透出虚化背景，起飞/落定帧（卡片恰在
                      // 课程块槽位、孔洞内背景未压暗）与真实课程块视觉一致。
                      // sigma 缩放补偿：BackdropFilter 的 sigma 定义在局部
                      // 坐标系，屏幕有效值 = sigma × 祖先 containerTransform
                      // 当帧缩放（scaleX/scaleY）。起飞帧卡片收缩在课程块
                      // 尺寸：宽屏 scaleX≈0.38 时 22×0.38≈8.3 恰好≈网格
                      // 模糊层（8），而小屏长条卡 scaleX≈0.1 时屏幕仅剩
                      // ~2.2，远浅于固定课程块——小屏复刻模糊偏浅的根源。
                      // 按当帧缩放反向补偿（sigma/scale），屏幕有效值恒为
                      // lerp(8→sigma)：起飞/落定帧与固定块（网格层 8）逐
                      // 平台一致，对话框态（t=1）保持 sigma；宽屏原观感
                      // 本就是 22×scale≈8.3→22 的线性过渡，补偿后几乎不变
                      if (widget.backdropBlurSigma != null)
                        BackdropFilter(
                          filter: ImageFilter.blur(
                            sigmaX:
                                (8.0 + (widget.backdropBlurSigma! - 8.0) * t) /
                                    math.max(scaleX, 0.01),
                            sigmaY:
                                (8.0 + (widget.backdropBlurSigma! - 8.0) * t) /
                                    math.max(scaleY, 0.01),
                          ),
                          child: const SizedBox.expand(),
                        ),
                      // 纸背：随 dissolve 淡入——flip=0（起飞/落定帧）
                      // 完全透明，课程块保持设置中的透明度（不垫白）；
                      // 内容褪去时白色「纸背」才浮现，与背面分支起点
                      // （全白）连续
                      Opacity(
                        opacity: dissolve,
                        child: const ColoredBox(color: Colors.white),
                      ),
                      if (dissolve < 0.995)
                        Opacity(
                          opacity: 1.0 - dissolve,
                          // dissolve=0（翻转尚未开始/已经结束）时跳过
                          // ImageFiltered：sigma=0 的 ImageFilter.blur 在
                          // Impeller 上会把内容渲染成空白——复刻「凭空
                          // 消失」、卡片呈现 100% 透明约半秒（直到翻转期
                          // 白纸背浮现）的根源。此前该 bug 被恒不透明的
                          // 白纸背掩盖，纸背改为随 dissolve 淡入后暴露
                          child: dissolve < 0.005
                              ? stretchedReplica
                              : ImageFiltered(
                                  imageFilter: ImageFilter.blur(
                                    sigmaX: 10 * dissolve,
                                    sigmaY: 10 * dissolve,
                                  ),
                                  child: stretchedReplica,
                                ),
                        )
                      else
                        stretchedReplica,
                    ],
                  ),
                ),
              ),
            );
          } else {
            // 背面：对话框内容自白色卡背中模糊浮现、逐渐清晰。
            // 阴影裁切修复：壳阴影（blur 24 + offset 12）绘制在卡片矩形
            // 之外，任何以卡片矩形为界的裁剪都会切出硬边。因此——
            // 只裁「纸背」（纯色，裁剪无损失，且贴合孔洞），对话框
            // 本体完全不裁剪：阴影全程完整，浮现期的模糊羽化在翻转
            // 旋转下呈柔和光晕而非毛边。
            // 注意禁止引入 OverflowBox 之类放宽约束的容器：对话框会
            // 取最大可用尺寸 → 壳实测矩形变大 → morph 以新矩形重建 →
            // 又允许更大……每帧 +96px 的无限增长循环，白色卡片膨胀
            // 铺满全屏且 UI 线程卡死（全屏白屏死机的根源）
            final appear = ((flip - 0.5) / 0.5).clamp(0.0, 1.0).toDouble();
            // 纸背内缩量：整盒 → 壳矩形。此前纸背经 StackFit.expand 撑满
            // 整盒（含对话框自身左右/键盘 margin），比孔洞（贴壳）大一圈：
            // 退出前半段翻转到一定角度后纸背淡入，白色边缘伸出玻璃对话框
            // 之外、透视下近侧边缘进一步放大——「对话框背后跟随移动但
            // 不完全贴合的白色遮罩」的根源。壳/整盒矩形均本组件实测
            // （_shellRect/_targetRect），内插后纸背与壳在同一变换下投影重合。
            EdgeInsets paperInsets = EdgeInsets.zero;
            final paperShell = _shellRect;
            final paperWhole = _targetRect;
            if (paperShell != null && paperWhole != null) {
              paperInsets = EdgeInsets.fromLTRB(
                math.max(0.0, paperShell.left - paperWhole.left),
                math.max(0.0, paperShell.top - paperWhole.top),
                math.max(0.0, paperWhole.right - paperShell.right),
                math.max(0.0, paperWhole.bottom - paperShell.bottom),
              );
            }
            face = Transform(
              alignment: Alignment.center,
              transform: Matrix4.identity()
                ..setEntry(3, 2, 0.001)
                ..rotateY(math.pi * flip - math.pi),
              child: SizedBox(
                width: targetRect.width,
                height: targetRect.height,
                // Clip.none：壳阴影画在卡片矩形之外（DecoratedBox 提到
                // 裁剪外层），Stack 默认 hardEdge 会把越界的阴影整块裁掉
                // ——孔洞外扩再多余量也看不到阴影（阴影裁切的真正根源）
                child: Stack(
                  clipBehavior: Clip.none,
                  fit: StackFit.expand,
                  children: [
                    // 纸背：壳矩形尺寸（= 孔洞，贴壳）+ cardRadius，随浮现退场。
                    // paperInsets 内缩掉对话框自身 margin，白色不再溢出玻璃壳之外
                    if (appear < 0.995)
                      Opacity(
                        opacity: 1.0 - appear,
                        child: Padding(
                          padding: paperInsets,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(cardRadius),
                            child: const ColoredBox(color: Colors.white),
                          ),
                        ),
                      ),
                    // 对话框：不裁剪（阴影完整）；浮现时模糊、落定时清晰
                    if (appear < 0.995)
                      Opacity(
                        opacity: appear,
                        child: ImageFiltered(
                          imageFilter: ImageFilter.blur(
                            sigmaX: 10 * (1 - appear),
                            sigmaY: 10 * (1 - appear),
                          ),
                          child: child,
                        ),
                      )
                    else
                      child!,
                  ],
                ),
              ),
            );
          }
          return Transform(transform: containerTransform, child: face);
        }

        // —— 未提供正面复刻：缩放 + 淡入淡出（原容器变换）——
        // 内容整体等比缩放，避免文字随容器非等比拉伸变形
        final baseScale = math.min(
          sourceRect.width / targetRect.width,
          sourceRect.height / targetRect.height,
        );
        final contentScale = baseScale + (1.0 - baseScale) * t;
        // 打开初期快速淡入；关闭时保持可见、临近课程块才淡出
        final contentOpacity = ((t - 0.05) / 0.25).clamp(0.0, 1.0).toDouble();

        return Transform(
          transform: containerTransform,
          child: Opacity(
            opacity: contentOpacity,
            child: Transform.scale(
              scale: contentScale,
              alignment: Alignment.center,
              child: child,
            ),
          ),
        );
      },
      child: KeyedSubtree(key: _contentKey, child: widget.child),
    );
  }
}

/// morph 路由专用：关闭时长 [reverseDuration] 统一 600ms——保存归位与
/// 取消翻回归位、点击遮罩关闭均与课程卡片 morph（详情路由 600/600）
/// 节奏严格一致（用户反馈 400ms 归位过快）。打开同用 `transitionDuration`
///（600ms）。字段保留：如个别路径需不同关闭节奏，可在 pop 前的 then 回调
/// 中修改（then 先于 reverse 启动，即时生效）。
class _Reverse400MorphRoute<T> extends RawDialogRoute<T> {
  _Reverse400MorphRoute({
    required super.pageBuilder,
    super.barrierDismissible,
    super.barrierColor,
    super.barrierLabel,
    super.transitionDuration = const Duration(milliseconds: 600),
    super.transitionBuilder,
    super.settings,
    this.reverseDuration = const Duration(milliseconds: 600),
  });

  /// 关闭时长（可在 pop 前的 then 回调中按路径修改）
  Duration reverseDuration;

  @override
  Duration get reverseTransitionDuration => reverseDuration;
}

/// 容器变换对话框宿主：自绘带孔洞的压暗遮罩（与「关于」对话框同方案）。
///
/// showGeneralDialog 的 barrierColor 会把整屏（含对话框背后）压暗，
/// BackdropFilter 采样到暗背景导致毛玻璃发灰。这里 barrierColor 置为透明，
/// 由本组件绘制 50% 压暗层，并在 morph 当前矩形处挖一个逐帧同步的圆角孔洞：
/// 孔洞内保留原始亮度背景，对话框壳内 BackdropFilter 采样到的即为未压暗
/// 背景。孔洞矩形与 _CourseDetailMorph 内部使用同一 Rect.lerp 公式（同一
/// animation 值驱动），保证与缩放中的对话框严丝合缝；四周仅压暗不模糊。
class _MorphDialogHost extends StatefulWidget {
  const _MorphDialogHost({
    required this.animation,
    required this.sourceRect,
    required this.child,
    this.shellKey,
    this.sourceWidget,
    this.sourceWidgetListenable,
    this.sourceRectListenable,
    this.backdropBlurSigma,
    this.onSourceHidden,
    this.onLanding,
    this.onDismissed,
  });

  final Animation<double> animation;
  final Rect? sourceRect;
  final Widget child;

  /// 翻转动画的「正面」（课程块/加号遮罩复刻），透传给 morph；
  /// 同时决定孔洞按翻转可见宽度收缩（见 build 内说明）
  final Widget? sourceWidget;

  /// 动态复刻：pop 瞬间（popped future 立即完成，先于 600ms 退出动画）
  /// 宿主可按保存结果切换复刻——
  /// - 保存成功：换成新课程/编辑后课程卡片复刻，关闭动画落定即所见
  ///   即所得（加号遮罩添加课程后收起动画直接渲染新增课程卡片）；
  /// - 置 null：退回「统一对话框淡出」形态（加号遮罩取消添加时不归位
  ///   到加号遮罩，而是整对话框缩放淡出，与其它对话框一致）。
  /// 优先级高于 [sourceWidget]
  final ValueListenable<Widget?>? sourceWidgetListenable;

  /// 动态源矩形：保存成功后课程块的实际矩形可能与打开时不同（加号
  /// 遮罩单格 → 多节课程块；编辑改时长/位置）。pop 后由调用方测量
  /// 新块矩形并更新本 notifier——morph 落定到**实际大小/位置**，
  /// 与真块无缝交接（落定到旧矩形会有大小跳变）。null 值回退到
  /// [sourceRect]（矩形总能取得，无需 null 语义）
  final ValueListenable<Rect?>? sourceRectListenable;

  /// 卡片模糊跟随：设置开启「卡片模糊」（壁纸模式）时为 sigma（当前
  /// 22.0，各调用方统一），透传给 morph——卡片正面背后实时模糊（morph
  /// 内按当帧缩放补偿，屏幕有效值起飞/落定帧与网格模糊层 8 一致），
  /// 效果跟随设置；null 不模糊
  final double? backdropBlurSigma;

  /// 路由首帧（隐形测量帧）结束后回调：此刻隐藏源课程块，
  /// 复刻卡片下一帧可见并与原块同帧交接，无空档闪现。
  /// 若在 showGeneralDialog 之前就隐藏，会早于路由首帧一帧，
  /// 测量帧处课程块位置空一帧（打开闪现的根源）
  final VoidCallback? onSourceHidden;

  /// 关闭动画播完（dismissed，路由尚未移除）时回调：源课程块此刻
  /// 瞬时显现，与末帧复刻卡片（像素一致）同帧交接无空档。动画
  /// 结束前课程块绝不出现（提前出现会与落定中的卡片叠加，割裂）
  final VoidCallback? onLanding;

  /// 关闭动画播完（dismissed，路由尚未移除）即回调清除接管标记：
  /// 课程块已经由 onLanding 瞬时恢复；等到 whenComplete（路由已
  /// 移除）再恢复会有可感知的闪现（关闭闪现的根源）
  final VoidCallback? onDismissed;

  /// 挂在对话框壳（GlassDialogShell）上的 Key：morph 测壳矩形本身
  /// （不含对话框自身 margin）仅用于**孔洞锚定**（避免孔洞被 margin
  /// 撑大）；morph 卡片布局盒用整个 child 的矩形（与强制布局一致，
  /// 避免测量↔强制反馈收缩）。调用方需把同一 Key 传给对话框壳。
  final GlobalKey? shellKey;

  @override
  State<_MorphDialogHost> createState() => _MorphDialogHostState();
}

class _MorphDialogHostState extends State<_MorphDialogHost> {
  late final CurvedAnimation _morphAnimation;

  /// 动画 + 动态复刻/源矩形合并监听：pop 瞬间 notifier 变化立即触发
  /// rebuild（此时路由动画尚未开始 tick，不合并会漏掉首帧切换）
  late final Listenable _listenable = Listenable.merge(
    [
      widget.animation,
      if (widget.sourceWidgetListenable != null) widget.sourceWidgetListenable!,
      if (widget.sourceRectListenable != null) widget.sourceRectListenable!,
    ],
  );

  /// morph 测量到的壳矩形（不含对话框自身 margin）：孔洞落定锚点/
  /// 淡出分支收缩基准；morph 卡片自身的布局盒在 morph 内部用整个
  /// child 的矩形（见 _CourseDetailMorphState._targetRect 注释）
  Rect? _targetRect;

  /// morph 翻转卡片布局盒的飞行终点（整个 child 矩形，含 margin）：
  /// 孔洞飞行期先插值到本矩形得飞行盒，再按盒缩放比例收缩 margin 得
  /// 壳当帧轮廓——此前直接插值到壳矩形，而卡片实际飞向含 margin 的整盒，
  /// 键盘避让的非对称 margin 下孔洞与壳轮廓中后段错位，压暗边横穿壳边/
  /// 阴影，呈现「阴影裁切不跟随卡片」（打开/关闭前几帧尤甚）的根源
  Rect? _wholeTargetRect;

  /// 翻转期孔洞的透视四角（屏幕坐标，顺时针）：与卡片旋转同数学投影，
  /// 每帧 build 重算（非翻转/落定/淡出路径恒为 null 走矩形孔洞）
  List<Offset>? _quadCorners;

  /// onLanding/onDismissed 是否已触发（每次关闭只一次；dispose 兜底
  /// 依据此标记，防路由被强制移除时课程块永久隐藏）
  bool _landed = false;

  /// 关闭起点（reverse 首帧/取消路径首帧）是否已实测壳矩形：
  /// 键盘弹出后壳的实际位置已偏离打开时测的 _targetRect，关闭必须
  /// 从真实位置收缩，否则首帧跳变；每次打开期间复位
  bool _closeOriginMeasured = false;

  /// 上一帧动画状态：识别「落定态进入关闭」的首帧（仅此场景实测——
  /// 动画中途关闭时壳含非恒等 Transform，实测会读到动画中间态矩形）
  AnimationStatus? _lastStatus;

  /// 帧末壳矩形快照：仅兜底循环变化检测用，不参与孔洞计算
  Rect? _lastSyncedShellRect;

  /// 兜底循环占用标志（防 build 与帧末回调双重注册）
  bool _holeSyncScheduled = false;

  /// 同步实测壳（GlassDialogShell）当帧矩形（屏幕坐标）
  Rect? _measureShellNow() {
    final ro = widget.shellKey?.currentContext?.findRenderObject();
    if (ro is RenderBox && ro.attached && ro.hasSize) {
      return ro.localToGlobal(Offset.zero) & ro.size;
    }
    return null;
  }

  /// 兜底重绘循环（持续，同 BouncyDialogHost 方案）：morph 落定后孔洞
  /// 由 clipper 绘制阶段同步实测壳矩形（零帧滞后），但对话框内容尺寸
  /// 变化（CourseDialog 切换周次/字段等）不会触发本组件 build，遮罩
  /// 分支可能收不到重绘调度——每帧帧末比对壳矩形，变化就 setState
  /// 触发重绘。持续运行（不因静止停止），unmount 后自动停止；
  /// morph 动画期间跳过冗余 setState（AnimatedBuilder 已每帧驱动）。
  void _scheduleHoleSync() {
    if (_holeSyncScheduled || !mounted || widget.shellKey == null) return;
    _holeSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _holeSyncScheduled = false;
      if (!mounted) return;
      final ro = widget.shellKey?.currentContext?.findRenderObject();
      if (ro is RenderBox && ro.attached && ro.hasSize) {
        final rect = ro.localToGlobal(Offset.zero) & ro.size;
        if (_lastSyncedShellRect != rect) {
          _lastSyncedShellRect = rect;
          if (!widget.animation.isAnimating) {
            setState(() {});
          }
        }
        _scheduleHoleSync(); // 持续监控（含内容尺寸变化）
      }
    });
  }

  @override
  void initState() {
    super.initState();
    // 位置曲线（对称方案，动画中段翻转的最终形态）：
    // - 翻转模式：打开/关闭都用 easeInOutCubic——同一 S 曲线正放/
    //   倒放，位置-时间轨迹严格镜像对称，中段速度峰值恰与中段翻转
    //   窗口对齐（打开窗口位置 18%~82%，关闭窗口时间 18%~82%）：
    //   打开=从容起步→中段快速放大并翻面→末段减速落定；关闭完全
    //   镜像。总时长 600ms 不变；翻转窗口占比 64%（vs 原 40%）使
    //   翻转效果更显著，侧立点仍在动画中点保证对称
    // - 非翻转模式：保持先快后慢 + 先慢后快（原容器变换手感）
    final isFlipMode = widget.sourceWidget != null;
    _morphAnimation = CurvedAnimation(
      parent: widget.animation,
      curve: isFlipMode ? Curves.easeInOutCubic : Curves.easeOutCubic,
      reverseCurve: isFlipMode ? Curves.easeInOutCubic : Curves.easeInCubic,
    );
    // 路由首帧（隐形测量帧）结束后隐藏源课程块（见 onSourceHidden 注释）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onSourceHidden?.call();
    });
    // 关闭动画播完（路由尚未移除）课程块瞬时显现并清除接管标记
    // （见 _handleAnimationStatus）
    widget.animation.addStatusListener(_handleAnimationStatus);
  }

  void _handleAnimationStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && mounted) {
      // 关闭动画播完（dismissed，路由尚未移除）：此刻课程块才出现——
      // 瞬时显现（_morphBlockFade.duration 为零），与末帧复刻卡片
      // （像素一致）同帧交接无空档；随后清除接管标记
      _landed = true;
      widget.onLanding?.call();
      widget.onDismissed?.call();
    }
  }

  @override
  void dispose() {
    // 兜底：路由被强制移除（dismissed 未触发）时也要恢复课程块，
    // 否则隐藏标记残留、课程块永远消失
    if (!_landed) {
      widget.onLanding?.call();
      widget.onDismissed?.call();
    }
    widget.animation.removeStatusListener(_handleAnimationStatus);
    _morphAnimation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 幂等启动兜底循环（morph 落定后壳静止时自动停止，任何重建源重启）
    _scheduleHoleSync();
    // 注册 MediaQuery 依赖：键盘弹出/收起时 viewInsets 变化触发本组件
    // rebuild → useSyncHole 判定更新 + 同步 clipper 新实例 → markNeedsPaint
    // → paint 时 clipper.getClip 同步实测壳当帧矩形（与 BouncyDialogHost
    // 同方案）。此前 morph 路径不读 MediaQuery，键盘变化时 host build 不
    // 跑（仅靠兜底循环的 setState，壳移动后才被动触发——settled 同步
    // clipper 实例不更新，getClip 不重执行，孔洞冻结）
    MediaQuery.of(context);
    return AnimatedBuilder(
      animation: _listenable,
      builder: (context, child) {
        final t = widget.animation.value;
        // 动态复刻：notifier 存在时以其值为准——**可为 null**（取消路径
        // 的统一淡出）。不能用 `?.value ?? sourceWidget`：值恰为 null 时
        // 会回退到原复刻，淡出分支永远进不去（取消仍归位的根源）
        final Widget? effectiveSource = widget.sourceWidgetListenable != null
            ? widget.sourceWidgetListenable!.value
            : widget.sourceWidget;
        final status = widget.animation.status;
        // —— 取消路径（加号遮罩取消添加）：统一对话框淡出 ——
        // 逐参数复刻 BouncyDialogHost 的关闭公式：scale 1→0.62、
        // dy 0→56、opacity 1→0、压暗按 (1-closeU) 衰减、孔洞贴壳随
        // scale 收缩。pop 瞬间 closeU=0 与 morph 全开末帧完全连续。
        // 时长：本路由关闭 600ms（与课程卡片 morph 一致），closeU 直接用
        // easeInCubic(1-t)——t 按实际时长线性推进，公式无需压缩。
        // 内容失焦模糊：不在宿主侧对整树 ImageFiltered（壳会被糊出
        // 毛边、与锐利孔洞错位成「多重框」），而是由 CourseDialog 在
        // 壳**内部**对内容施加同公式模糊（见 unifiedFadeMode）
        if (effectiveSource == null && widget.sourceWidgetListenable != null) {
          // 关闭（淡出）起点首帧：同步实测壳矩形（键盘弹出过的话壳已
          // 上移，_targetRect 还是打开时的旧位置）——孔洞自真实位置
          // 收缩，与 morph 全开末帧连续
          if (!_closeOriginMeasured) {
            _closeOriginMeasured = true;
            final shell = _measureShellNow();
            if (shell != null) _targetRect = shell;
          }
          final closeU = Curves.easeInCubic.transform(1.0 - t);
          final scale = 1.0 - 0.38 * closeU;
          final dy = 56.0 * closeU;
          final opacity =
              (1.0 - Curves.easeIn.transform(closeU)).clamp(0.0, 1.0);
          Rect? hole;
          var holeRadius = 24.0;
          final target = _targetRect;
          if (target != null) {
            hole = Rect.fromCenter(
              center: target.center + Offset(0, dy),
              width: target.width * scale,
              height: target.height * scale,
            );
            holeRadius = 24.0 * scale;
          }
          return Stack(
            children: [
              Positioned.fill(
                child: IgnorePointer(
                  child: ClipPath(
                    clipper: hole == null
                        ? null
                        : _InvertedRRectClipper(hole, holeRadius),
                    child: ColoredBox(
                      color: Colors.black
                          .withValues(alpha: 0.5 * (1.0 - closeU)),
                    ),
                  ),
                ),
              ),
              Center(
                child: Opacity(
                  opacity: opacity,
                  child: Transform.translate(
                    offset: Offset(0, dy),
                    child: Transform.scale(
                      scale: scale,
                      child: Material(
                        type: MaterialType.transparency,
                        child: child ?? const SizedBox.shrink(),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        }
        // 课程块出现时机：关闭动画**结束前完全不出现**（动画未结束时
        // 课程块提前出现会与落定中的卡片叠加，观感割裂——用户明确
        // 要求）；仅在动画播完（dismissed）时由 _handleAnimationStatus
        // 一次性触发，与末帧复刻（像素一致）瞬时交接
        // 关闭起点（从落定态进入 reverse 首帧）：同步实测壳矩形作收缩
        // 终点——键盘弹出过的话壳已上移避让，打开时测的 target 已过时，
        // 不实测会导致关闭首帧孔洞/卡片自错误位置收缩（跳变）。仅限
        // 「落定→关闭」：动画中途关闭时壳含非恒等 Transform，实测会读
        // 到动画中间态矩形（引入跳变），沿用旧 target 即可（布局盒未变）。
        // 打开期间复位标志。
        if (status == AnimationStatus.reverse &&
            _lastStatus == AnimationStatus.completed &&
            !_closeOriginMeasured) {
          _closeOriginMeasured = true;
          final shell = _measureShellNow();
          if (shell != null) {
            // 键盘避让后壳已位移：按旧壳/整盒的 margin 差把整盒同步平移，
            // 飞行轮廓公式继续与卡片布局盒一致（下一帧 morph 重测会再校正）
            final oldShell = _targetRect;
            final oldWhole = _wholeTargetRect;
            _targetRect = shell;
            _wholeTargetRect = (oldShell != null && oldWhole != null)
                ? Rect.fromLTRB(
                    shell.left - (oldWhole.left - oldShell.left),
                    shell.top - (oldWhole.top - oldShell.top),
                    shell.right + (oldWhole.right - oldShell.right),
                    shell.bottom + (oldWhole.bottom - oldShell.bottom),
                  )
                : shell;
          }
        } else if (status == AnimationStatus.forward) {
          _closeOriginMeasured = false;
        }
        _lastStatus = status;
        // morph 落定：孔洞不再走插值公式（target 是打开时的静态矩形，
        // 不跟随键盘避让）——改由 clipper 在绘制阶段同步实测壳矩形，
        // 逐帧贴壳零帧差；壳移动时兜底循环（_scheduleHoleSync）驱动
        // 遮罩重绘。morph 期间（含关闭收缩）仍用插值公式。
        // 无 shellKey（无从实测）时保持插值公式（settled 即 hole=target）
        final useSyncHole = status == AnimationStatus.completed &&
            t >= 1.0 &&
            widget.shellKey != null;
        // 孔洞矩形：终点锚定 morph 回调的**壳矩形**（不含对话框自身
        // margin），**零外扩**精确贴合卡片/对话框：压暗边缘与卡片边缘
        // 完全重合，藏在不透明卡片之下，任何方向都不露出未压暗的亮边
        // （不能漏出来）。翻转卡片是含 margin 的整体布局盒且不透明白色，
        // 比孔洞（贴壳）大一圈，全程盖住孔洞四周的压暗边界；孔洞圆角
        // 与卡片圆角同公式插值（块 5 → 对话框 24），两端与真实课程块/
        // 对话框壳完全一致。无源矩形（非 morph 场景）时孔洞即对话框
        // 最终矩形
        Rect? hole;
        var holeRadius = 24.0;
        // 孔洞圆角水平切距缩放：翻转帧卡片圆角被 |cosθ| 压缩（见下）
        var holeHScale = 1.0;
        // 复刻正面阶段（打开·前半程）专用：孔洞圆角垂直切距缩放——
        // 卡片圆角经容器变换逐轴压缩，水平由 holeHScale 承担、垂直由
        // 本字段承担。null = 既有正圆角行为（关闭方向/打开后半程不变）
        double? holeVScale;
        // 四边形孔洞的基准半径：复刻阶段=插值 holeRadius（cardRadius，
        // 与卡片可见圆角同源）；对话框阶段=对话框壳固定 24。对话框阶段
        // 此前沿用插值 holeRadius（t<1 时恒 <24）——孔洞圆角比对话框
        // 更方，直角区伸到对话框圆角外的背景上，四角露出未压暗亮牙
        // （与对话框圆角不符的根源；仅修 sx/sy 缩放不改基准半径无效）。
        // 改用 24 后孔洞与对话框圆角严格一致：多压暗的角部条带被白纸背
        // （cardRadius、不透明、绘制于遮罩之上）全程遮盖；侧立点
        // （flip=0.5）四边形退化为竖线、半径无可见影响，两阶段切换
        // 无缝；落定与同步实测（固定 24）连续
        var holeRadiusForQuad = 24.0;
        final target = _targetRect;
        _quadCorners = null; // 仅翻转分支重算；其余路径维持矩形孔洞
        // 动态源矩形：保存成功后按新课程块实际矩形落位（见参数注释），
        // 未更新时回退原矩形
        final source =
            widget.sourceRectListenable?.value ?? widget.sourceRect;
        if (!useSyncHole && target != null) {
          if (source == null || source.isEmpty) {
            hole = target;
            holeRadius = 24.0;
          } else {
            final morphT = _morphAnimation.value;
            // 飞行盒（插值到含 margin 的整盒）与壳当帧轮廓：容器变换按轴
            // 缩放，壳在盒内的 margin 随盒同比例缩放——反推轮廓与翻转卡片
            // 的壳边缘像素级重合（含键盘避让的非对称 margin）；无整盒时退化为直接插值壳矩形。t=0 时轮廓即源矩形，与起飞帧无缝衔接
            holeRadius = 5.0 + (24.0 - 5.0) * morphT;
            final whole = _wholeTargetRect;
            final Rect lerped;
            if (whole != null && whole.width > 0 && whole.height > 0) {
              final flight = Rect.lerp(source, whole, morphT)!;
              final sx = flight.width / whole.width;
              final sy = flight.height / whole.height;
              lerped = Rect.fromLTRB(
                flight.left + (target.left - whole.left) * sx,
                flight.top + (target.top - whole.top) * sy,
                flight.right - (whole.right - target.right) * sx,
                flight.bottom - (whole.bottom - target.bottom) * sy,
              );
            } else {
              lerped = Rect.lerp(source, target, morphT)!;
            }
            if (effectiveSource != null) {
              // 翻转模式：孔洞取卡片旋转的**投影轮廓**（透视四边形）——
              // 与卡片正/背面同一公式的旋转+透视（_morphFlipQuadCorners）。
              // 此前轴对齐矩形 × |cos| 只水平收缩不跟随倾斜：卡片前几帧已倾斜而孔洞仍水平，压暗边横穿卡片/阴影（用户所见裁切不跟随的根源）。
              // 翻转进度与 morph 内同一公式（按方向取正/反向映射）
              final flip = status == AnimationStatus.reverse
                  ? _morphFlipReverse(t)
                  : _morphFlipForward(_morphAnimation.value);
              // 翻转帧圆角跟随：卡片绕竖直轴旋转时其圆角在水平方向被
              // |cosθ| 压缩（竖直方向不受旋转影响），孔洞圆角的水平切距
              // 按同因子压缩——否则翻转中孔洞四角比对话框圆角胖出一圈
              // 未压暗的月牙形亮边（圆角与对话框不贴合的根源）。窗口外
              // flip=0/1 → |cos|=1，与矩形孔洞路径行为一致
              holeHScale = math.cos(math.pi * flip).abs();
              // 圆角适配（两个方向镜像对称的两阶段）：
              // A. 复刻正面阶段（flip<0.5，与 morph 正面分支同一边界：
              //    打开·前半程 与 关闭·末段）：可见卡片是复刻铺满的整盒
              //    卡片，其可见圆角 = 外层 ClipRRect(cardRadius) 与内层
              //    复刻 ClipRRect(5)（经 FittedBox 拉伸）的**交集**——
              //    同盒两圆角中更圆者切得更深、决定边界，即每轴取
              //    **较大者**（t=0 时内层 5px 胜出=真课程块圆角；中段
              //    拉伸后的内层圆角可达 ~20px）。此前误用 min，孔洞圆角
              //    比卡片瘦，卡片圆角外露出未压暗亮牙。孔洞四角同时按
              //    整盒卡片投影（cardSpace 局部透视）。
              // B. 对话框阶段（flip≥0.5：打开·后半程 与 关闭·前半程）：
              //    可见边界是不透明白纸背（壳盒、圆角 cardRadius），它
              //    随容器逐轴缩放——屏幕切距 = holeRadius·sx / ·sy。
              //    此前竖直切距恒为 holeRadius、水平未乘 sx，孔洞圆角
              //    比纸背/对话框胖出一圈四角月牙亮边。落定 sx=sy=1 →
              //    24，与落定同步实测（固定 24）连续。
              // flip=0.5 侧立点两路径同为竖直退化线，切换无缝
              final replicaStage = flip < 0.5;
              if (whole != null && whole.width > 0 && whole.height > 0) {
                final flight = Rect.lerp(source, whole, morphT)!;
                final sx = flight.width / whole.width;
                final sy = flight.height / whole.height;
                _quadCorners = _morphFlipQuadCorners(
                  source: source,
                  shell: replicaStage ? whole : target,
                  whole: whole,
                  morphT: morphT,
                  flip: flip,
                  cardSpace: replicaStage,
                );
                if (replicaStage) {
                  final cosF = math.cos(math.pi * flip).abs();
                  // 外层 ClipRRect(cardRadius)（卡片局部）经容器逐轴缩放
                  // 后的屏幕切距；内层复刻 ClipRRect(5)（课程块局部）经
                  // FittedBox 拉伸（whole/source）再乘容器缩放恰为
                  // flight/source。可见圆角 = 逐轴取**大**（交集边界）
                  final outerH = holeRadius * cosF * sx;
                  final outerV = holeRadius * sy;
                  final innerH = 5.0 * flight.width / source.width * cosF;
                  final innerV = 5.0 * flight.height / source.height;
                  holeHScale = math.max(outerH, innerH) / holeRadius;
                  holeVScale = math.max(outerV, innerV) / holeRadius;
                  holeRadiusForQuad = holeRadius;
                } else {
                  // 对话框阶段：可见边界=对话框壳（固定 24，卡片局部），
                  // 基准半径用 24（见 holeRadiusForQuad 声明处注释），
                  // 切距仅随容器逐轴缩放与翻转 |cos| 压缩
                  holeHScale = math.cos(math.pi * flip).abs() * sx;
                  holeVScale = sy;
                }
              }
              hole = lerped;
            } else {
              hole = lerped;
            }
          }
        }
        return Stack(
          children: [
            // 自绘压暗遮罩（孔洞处不压暗；IgnorePointer 让点击穿透到路由遮罩以关闭）
            Positioned.fill(
              child: IgnorePointer(
                child: ClipPath(
                  // 落定：同步实测壳矩形（键盘避让零帧差跟随）；
                  // morph 期间：插值公式（每帧重建，静态矩形）
                  clipper: useSyncHole
                      ? _InvertedRRectClipper.sync(
                          shellKey: widget.shellKey!,
                          radius: 24.0,
                        )
                      : (_quadCorners != null
                          ? (widget.shellKey != null
                                  // 翻转期绘制阶段实测壳当帧变换的投影四边形，
                                  // 与卡片像素级同步——此前 build 期公式角点在关闭
                                  // 方向概率性滞后卡片 ~50ms 的根治。
                                  // 复刻正面阶段壳不在树中（打开未挂载/关闭翻
                                  // 背面后卸载），实测返回 null 自动落到
                                  // fallbackCorners（整盒卡片公式四角）
                                  ? _InvertedRRectClipper.quadSync(
                                      shellKey: widget.shellKey!,
                                      radius: holeRadiusForQuad,
                                      hScale: holeHScale,
                                      vScale: holeVScale,
                                      fallbackCorners: _quadCorners,
                                    )
                                  : _InvertedRRectClipper.quad(
                                      corners: _quadCorners!,
                                      radius: holeRadiusForQuad,
                                      hScale: holeHScale,
                                      vScale: holeVScale,
                                    ))
                          : (hole == null
                              ? null
                              : _InvertedRRectClipper(hole, holeRadius))),
                  child: ColoredBox(
                    color: Colors.black.withValues(alpha: 0.5 * t),
                  ),
                ),
              ),
            ),
            Center(
              child: Material(
                color: Colors.transparent,
                child: _CourseDetailMorph(
                  animation: _morphAnimation,
                  rawAnimation: widget.animation,
                  sourceRect: source,
                  sourceWidget: effectiveSource,
                  backdropBlurSigma: widget.backdropBlurSigma,
                  targetKey: widget.shellKey,
                  onLaidOut: (rects) {
                    // 键盘避让等布局变化时 morph 会重测并再次回调：
                    // 壳矩形作孔洞锚点，整盒矩形作飞行轮廓反推基准
                    if (mounted) {
                      setState(() {
                        _targetRect = rects.$1;
                        _wholeTargetRect = rects.$2;
                      });
                    }
                  },
                  child: child!,
                ),
              ),
            ),
          ],
        );
      },
      child: widget.child,
    );
  }
}

/// 全屏矩形挖去一个圆角矩形孔洞的裁剪器（圆角随 morph 进度插值，
/// 与翻转卡片的圆角同步，起止两端分别贴合课程块与对话框壳）。
///
/// 四种模式：
/// - 静态（hole 非空）：孔洞矩形与圆角直接给定，morph 插值期间使用，
///   每帧随 build 重建；
/// - 同步（shellKey 非空）：孔洞矩形在绘制阶段（getClip）同步实测壳的
///   当帧真实绘制矩形（localToGlobal 含键盘避让 AnimatedContainer 的
///   内插位置），morph 落定后使用——孔洞与壳零帧差，彻底消除「帧末
///   测量→setState→下一帧生效」的滞后与 viewInsets 稳定后孔洞冻结。
class _InvertedRRectClipper extends CustomClipper<Path> {
  /// 静态模式：孔洞矩形（屏幕坐标，遮罩为全屏 Positioned.fill，
  /// 遮罩局部系与屏幕系一致）
  final Rect? hole;

  /// 孔洞圆角
  final double radius;

  /// 四边形圆角的水平切距缩放：卡片绕竖直轴翻转时其圆角在水平方向被
  /// |cosθ| 压缩（竖直方向不受旋转影响），孔洞圆角须同因子压缩才能
  /// 贴合翻转中的卡片/对话框圆角。1.0 = 不缩放（轴对齐模式不使用）
  final double hScale;

  /// 孔洞圆角垂直切距缩放：翻转两阶段的卡片/纸背圆角经容器变换在
  /// 垂直方向被 sy 压缩，孔洞圆角须同因子变瘦（水平由 hScale 承担，
  /// hScale = 水平切距 / radius）。null = 不缩放（非翻转路径不使用）：
  /// 竖直边用原 radius、轴对齐回退用正圆
  final double? vScale;

  /// 透视四边形模式（翻转期）：孔洞四角（屏幕坐标，顺时针）——
  /// 跟随卡片旋转的投影轮廓（非空时优先于 [hole]）
  final List<Offset>? corners;

  /// 同步模式：壳（GlassDialogShell）的 Key，绘制时反查其实时矩形
  final GlobalKey? shellKey;

  /// 同步四边形模式（.quadSync）标志：绘制阶段实测壳四角投影（区别于
  /// .sync 的轴对齐矩形实测）
  final bool quadSyncMode;

  /// quadSync 实测失败时的公式角点兜底（壳已失活的退场末帧，避免
  /// 全屏压暗闪现）
  final List<Offset>? fallbackCorners;

  _InvertedRRectClipper(this.hole, this.radius)
      : shellKey = null,
        corners = null,
        quadSyncMode = false,
        fallbackCorners = null,
        hScale = 1.0,
        vScale = null;

  /// 翻转模式：透视四边形孔洞（build 期公式角点，无壳 Key 时的回退）
  _InvertedRRectClipper.quad({
    required List<Offset> this.corners,
    required this.radius,
    this.hScale = 1.0,
    this.vScale,
  })  : hole = null,
        shellKey = null,
        quadSyncMode = false,
        fallbackCorners = null;

  /// 同步四边形模式：绘制阶段对壳四角套用其当帧完整变换矩阵（含容器
  /// 缩放/旋转/透视）直接得投影四边形——与卡片像素级同步零帧差。
  /// 此前 build 期静态矩形公式链在关闭方向概率性滞后卡片 ~50ms 的根治。
  /// 与 .sync 的区别：.sync 只取轴对齐包围盒（localToGlobal 两点），
  /// 旋转下是倾斜卡片的外接直立矩形，不贴形。
  _InvertedRRectClipper.quadSync({
    required GlobalKey this.shellKey,
    required this.radius,
    this.hScale = 1.0,
    this.vScale,
    this.fallbackCorners,
  })  : hole = null,
        corners = null,
        quadSyncMode = true;

  const _InvertedRRectClipper.sync({
    required this.shellKey,
    required this.radius,
  })  : hole = null,
        corners = null,
        quadSyncMode = false,
        fallbackCorners = null,
        hScale = 1.0,
        vScale = null;

  /// 安全取壳的 RenderBox：关闭末帧路由移除壳与本遮罩绘制可能同帧，
  /// 壳元素已失活（_ElementLifecycle.inactive），findRenderObject 会断言，
  /// 此处吞掉该帧直接返回 null（本帧不挖洞，下一帧整体随路由退场）
  RenderBox? _shellRenderBox() {
    final ctx = shellKey?.currentContext;
    if (ctx == null) return null;
    try {
      final ro = ctx.findRenderObject();
      if (ro is RenderBox && ro.attached && ro.hasSize) return ro;
    } catch (_) {
      // 失活元素的 findRenderObject 断言（仅 debug 抛出）
    }
    return null;
  }

  Rect? _measureShell() {
    final ro = _shellRenderBox();
    if (ro != null) {
      // 两角点分别过 localToGlobal（含 Transform 祖先当帧动画值），
      // 得到壳的当帧真实绘制矩形，直接作孔洞
      return ro.localToGlobal(Offset.zero) & ro.size;
    }
    return null;
  }

  /// 同步四边形模式专用：壳四角各自过当帧完整变换（含透视除法）投影，
  /// 得旋转/透视下壳的真实轮廓四边形（非轴对齐包围盒）——与卡片同帧同步。
  List<Offset>? _measureQuadCorners() {
    final ro = _shellRenderBox();
    if (ro == null) return null;
    final transform = ro.getTransformTo(null);
    Offset project(Offset local) {
      final x = transform.storage[0] * local.dx +
          transform.storage[4] * local.dy +
          transform.storage[12];
      final y = transform.storage[1] * local.dx +
          transform.storage[5] * local.dy +
          transform.storage[13];
      final w = transform.storage[3] * local.dx +
          transform.storage[7] * local.dy +
          transform.storage[15];
      if (w.abs() < 1e-9) return Offset(x, y);
      return Offset(x / w, y / w);
    }

    final br = ro.size.bottomRight(Offset.zero);
    return [
      project(Offset.zero), // TL
      project(Offset(br.dx, 0)), // TR
      project(br), // BR
      project(Offset(0, br.dy)), // BL
    ];
  }

  /// 四边形四角是否构成轴对齐矩形（flip≈0/1 的投影），是则返回该矩形，
  /// 否则 null。容差 0.5px：公式投影在 flip=0/1 处 sin(π)≈1.2e-16 残留、
  /// 实测角点的亚像素抖动均远小于此；近端点微小偏转时差异也不可察。
  /// 角序正反绕向均兼容（对边平行判定与 min/max 取框不依赖绕向）
  Rect? _axisAlignedRect(List<Offset> cs) {
    if (cs.length != 4) return null;
    const eps = 0.5;
    if ((cs[0].dy - cs[1].dy).abs() > eps) return null;
    if ((cs[1].dx - cs[2].dx).abs() > eps) return null;
    if ((cs[2].dy - cs[3].dy).abs() > eps) return null;
    if ((cs[3].dx - cs[0].dx).abs() > eps) return null;
    return Rect.fromLTRB(
      math.min(cs[0].dx, cs[3].dx),
      math.min(cs[0].dy, cs[1].dy),
      math.max(cs[1].dx, cs[2].dx),
      math.max(cs[2].dy, cs[3].dy),
    );
  }

  @override
  Path getClip(Size size) {
    final full = Path()..addRect(Offset.zero & size);
    if (corners != null || (quadSyncMode && shellKey != null)) {
      final cs = corners ?? _measureQuadCorners() ?? fallbackCorners;
      if (cs == null) {
        // 壳尚未挂载/不可测（首帧）：暂不挖洞（全屏压暗），下一帧起恒可测得
        return full;
      }
      // 透视四边形孔洞（跟随卡片倾斜，含旋转/透视）；投影退化为轴对齐
      // 矩形时（flip≈0/1 卡片摊平：打开末段与关闭首帧）回退正圆弧 RRect——
      // 贝塞尔圆角与对话框 ClipRRect 正圆弧曲率不同，摊平帧会看到孔洞
      // 圆角与壳不适配；旋转中的梯形角点本身被透视变形，两种圆角差异不可察
      final axisRect = _axisAlignedRect(cs);
      if (axisRect != null) {
        // 复刻正面阶段（vScale 非空）：卡片圆角经容器逐轴缩放呈椭圆，
        // 孔洞圆角同取椭圆切距；其余阶段保持正圆（既有行为不变）
        final corner = vScale == null
            ? Radius.circular(radius)
            : Radius.elliptical(radius * hScale, radius * vScale!);
        return Path.combine(
          PathOperation.difference,
          full,
          Path()..addRRect(RRect.fromRectAndRadius(axisRect, corner)),
        );
      }
      return Path.combine(PathOperation.difference, full, _addRoundedQuad(cs));
    }
    final rect = hole ?? _measureShell();
    if (rect == null) {
      return full;
    }
    return Path.combine(
      PathOperation.difference,
      full,
      Path()
        ..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(radius))),
    );
  }

  /// 四边形圆角路径：二次贝塞尔圆角（角点作控制点，两邻边上各取距角点
  /// d 的端点）——任意内角都切向连续且无歧义。此前用 arcToPoint：弧的
  /// 圆心角由弦长反推，端点固定在边上距角点 r 处，只有直角（90°）时弧才
  /// 正确；透视梯形的钝角处弦长趋近 2r，弧被画成半圆外凸（「三个半圆」
  /// bug 的根源）。绕序仍规整为顺时针（翻转后半程透视反转），
  /// 保证 Path.combine 挖洞稳定。
  Path _addRoundedQuad(List<Offset> cs) {
    final path = Path();
    if (cs.length != 4) return path;
    var area2 = 0.0;
    for (var i = 0; i < 4; i++) {
      final a = cs[i];
      final b = cs[(i + 1) % 4];
      area2 += a.dx * b.dy - b.dx * a.dy;
    }
    final pts = area2 > 0 ? cs : cs.reversed.toList();
    Offset toward(Offset from, Offset to, double d) {
      final v = to - from;
      final len = v.distance;
      if (len <= 0) return from;
      return from + v * math.min(d, len / 2) / len;
    }
    // 圆角切距随邻边取向缩放：水平边（卡片上下边）被绕竖直轴的翻转
    // 压缩 |cosθ| 倍（hScale），竖直边不受旋转影响——与卡片圆角经同一
    // 旋转后的屏幕投影一致。此前两边统一用未缩放 radius，翻转帧孔洞
    // 圆角水平方向比对话框圆角胖出一圈未压暗月牙。端点距离仍受
    // 半径与该邻边半长双重约束（退化四边形不越界）。
    // 复刻正面阶段另经容器逐轴缩放：水平 hScale、垂直 vScale
    double cornerDist(Offset from, Offset to) {
      final v = to - from;
      final want = v.dx.abs() >= v.dy.abs()
          ? radius * hScale
          : radius * (vScale ?? 1.0);
      return math.min(want, v.distance / 2);
    }
    for (var i = 0; i < 4; i++) {
      final corner = pts[i];
      final prev = pts[(i + 3) % 4];
      final next = pts[(i + 1) % 4];
      final start = toward(corner, prev, cornerDist(corner, prev));
      final end = toward(corner, next, cornerDist(corner, next));
      if (i == 0) {
        path.moveTo(start.dx, start.dy);
      } else {
        path.lineTo(start.dx, start.dy);
      }
      path.quadraticBezierTo(corner.dx, corner.dy, end.dx, end.dy);
    }
    path.close();
    return path;
  }

  @override
  bool shouldReclip(_InvertedRRectClipper oldClipper) => true;
}

/// 长按课程块后弹出的操作菜单。
/// 主菜单（编辑/删除）在课程块上方向上弹出；点击编辑后子菜单向下弹出。
class _CourseBlockActionMenu extends StatefulWidget {
  const _CourseBlockActionMenu({
    super.key,
    required this.anchorRect,
    required this.onDismiss,
    required this.onClosed,
    required this.onEditCurrent,
    required this.onAddSameSlot,
    required this.onDelete,
  });

  final Rect anchorRect;
  final VoidCallback onDismiss;
  /// 收起动画播放完毕后回调（由父级移除浮层）
  final VoidCallback onClosed;
  final VoidCallback onEditCurrent;
  final VoidCallback onAddSameSlot;
  final VoidCallback onDelete;

  @override
  State<_CourseBlockActionMenu> createState() => _CourseBlockActionMenuState();
}

class _CourseBlockActionMenuState extends State<_CourseBlockActionMenu>
    with TickerProviderStateMixin {
  late final AnimationController _mainController;
  late final AnimationController _subController;

  static const double _menuWidth = 200.0;
  static const double _mainMenuHeight = 52.0;
  static const double _subMenuItemHeight = 44.0;
  static const double _subMenuHeight = _subMenuItemHeight * 2 + 12.0;
  static const double _gap = 8.0;
  static const double _edgeMargin = 8.0;
  static const double _ringStroke = 2.0;

  bool _subMenuOpen = false;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _mainController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 340),
      reverseDuration: const Duration(milliseconds: 240),
    );
    _subController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
      reverseDuration: const Duration(milliseconds: 220),
    );
    _subController.addStatusListener((status) {
      if (status == AnimationStatus.dismissed && mounted) {
        setState(() {});
      }
    });
    // 主菜单收起动画结束后通知父级移除浮层
    _mainController.addStatusListener((status) {
      if (status == AnimationStatus.dismissed && _closing && mounted) {
        widget.onClosed();
      }
    });
    _mainController.forward();
  }

  @override
  void dispose() {
    _mainController.dispose();
    _subController.dispose();
    super.dispose();
  }

  /// 收起菜单：反向播放弹出动画（子菜单与主菜单同时收回）
  void close() {
    if (_closing) return;
    _closing = true;
    setState(() {});
    _subController.reverse();
    _mainController.reverse();
  }

  void _toggleSubMenu() {
    if (_closing) return;
    setState(() => _subMenuOpen = !_subMenuOpen);
    if (_subMenuOpen) {
      _subController.forward();
    } else {
      _subController.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;

    // 主菜单优先显示在课程块上方，空间不足时落到课程块下方
    final double mainLeft = (widget.anchorRect.center.dx - _menuWidth / 2)
        .clamp(_edgeMargin, math.max(_edgeMargin, screenSize.width - _menuWidth - _edgeMargin));
    double mainTop = widget.anchorRect.top - _mainMenuHeight - _gap;
    final bool showAbove = mainTop >= _edgeMargin;
    if (!showAbove) {
      mainTop = widget.anchorRect.bottom + _gap;
    }

    // 子菜单位于主菜单下方（向下弹出），越界时收回到屏幕内
    double subTop = mainTop + _mainMenuHeight + _gap;
    if (subTop + _subMenuHeight > screenSize.height - _edgeMargin) {
      subTop = math.max(_edgeMargin, screenSize.height - _subMenuHeight - _edgeMargin);
    }

    final bool subMenuVisible =
        _subMenuOpen || _subController.status != AnimationStatus.dismissed;

    return Stack(
      children: [
        // 全屏透明屏障：点击空白处关闭菜单
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onDismiss,
            child: const SizedBox.expand(),
          ),
        ),
        // 选中课程块的浅蓝色描边环：绘制在课程块外侧，不占用块内空间，随菜单淡入淡出
        Positioned(
          left: widget.anchorRect.left - _ringStroke,
          top: widget.anchorRect.top - _ringStroke,
          width: widget.anchorRect.width + _ringStroke * 2,
          height: widget.anchorRect.height + _ringStroke * 2,
          child: IgnorePointer(
            child: AnimatedBuilder(
              animation: _mainController,
              builder: (context, child) {
                final tFade = CurvedAnimation(
                  parent: _mainController,
                  curve: Curves.easeOut,
                  reverseCurve: Curves.easeIn,
                ).value;
                return Opacity(
                  opacity: tFade,
                  child: Transform.scale(
                    scale: 0.94 + 0.06 * tFade,
                    child: child,
                  ),
                );
              },
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(7),
                  border: Border.all(
                    color: const Color(0xFF64B5F6),
                    width: _ringStroke,
                  ),
                ),
              ),
            ),
          ),
        ),
        // 主菜单：向上（或向下）灵动弹出
        Positioned(
          left: mainLeft,
          top: mainTop,
          width: _menuWidth,
          child: IgnorePointer(
            ignoring: _closing,
            child: AnimatedBuilder(
              animation: _mainController,
              builder: (context, child) {
                final t = CurvedAnimation(
                  parent: _mainController,
                  curve: Curves.easeOutBack,
                  reverseCurve: Curves.easeInCubic,
                ).value;
                final tFade = CurvedAnimation(
                  parent: _mainController,
                  curve: Curves.easeOut,
                  reverseCurve: Curves.easeIn,
                ).value;
                // 从课程块方向滑入 / 收回
                final double slide = (1.0 - tFade) * 16.0;
                return Opacity(
                  opacity: tFade,
                  child: Transform.translate(
                    offset: Offset(0, showAbove ? slide : -slide),
                    child: Transform.scale(
                      scale: 0.72 + 0.28 * t,
                      alignment: showAbove ? Alignment.bottomCenter : Alignment.topCenter,
                      child: child,
                    ),
                  ),
                );
              },
              child: _buildMainMenu(),
            ),
          ),
        ),
        // 子菜单：向下灵动弹出
        if (subMenuVisible)
          Positioned(
            left: mainLeft,
            top: subTop,
            width: _menuWidth,
            child: IgnorePointer(
              ignoring: _closing || !_subMenuOpen,
              child: AnimatedBuilder(
                animation: _subController,
                builder: (context, child) {
                  final t = CurvedAnimation(
                    parent: _subController,
                    curve: Curves.easeOutBack,
                    reverseCurve: Curves.easeInCubic,
                  ).value;
                  final tFade = CurvedAnimation(
                    parent: _subController,
                    curve: Curves.easeOut,
                    reverseCurve: Curves.easeIn,
                  ).value;
                  // 从主菜单方向（上方）向下展开 / 收回
                  final double slide = -(1.0 - tFade) * 14.0;
                  return Opacity(
                    opacity: tFade,
                    child: Transform.translate(
                      offset: Offset(0, slide),
                      child: Transform.scale(
                        scale: 0.82 + 0.18 * t,
                        alignment: Alignment.topCenter,
                        child: child,
                      ),
                    ),
                  );
                },
                child: _buildSubMenu(),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildMainMenu() {
    return _menuGlassShell(
      child: SizedBox(
        height: _mainMenuHeight,
        child: Row(
          children: [
            Expanded(
              child: _menuButton(
                icon: Icons.edit_outlined,
                label: '编辑',
                color: const Color(0xFF3D7EFF),
                onTap: _toggleSubMenu,
              ),
            ),
            Container(width: 1, height: 24, color: Colors.grey.withValues(alpha: 0.25)),
            Expanded(
              child: _menuButton(
                icon: Icons.delete_outline,
                label: '删除',
                color: const Color(0xFFE5484D),
                onTap: widget.onDelete,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSubMenu() {
    return _menuGlassShell(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
          _subMenuItem(
            icon: Icons.edit_outlined,
            label: '编辑当前课程',
            onTap: widget.onEditCurrent,
          ),
          _subMenuItem(
            icon: Icons.add_circle_outline,
            label: '添加同时段课程',
            onTap: widget.onAddSameSlot,
          ),
        ],
        ),
      ),
    );
  }

  /// 菜单外壳：半透明白底 + 高斯模糊（毛玻璃），Material 提供默认文本样式避免黄色下划线
  Widget _menuGlassShell({required Widget child}) {
    return Material(
      type: MaterialType.transparency,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.16),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.72),
                border: Border.all(color: Colors.white.withValues(alpha: 0.5)),
              ),
              child: child,
            ),
          ),
        ),
      ),
    );
  }

  Widget _menuButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: SizedBox(
          height: _mainMenuHeight,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: color,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _subMenuItem({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: SizedBox(
          height: _subMenuItemHeight,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Icon(icon, size: 18, color: const Color(0xFF4A90E2)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 14, color: Colors.grey.shade800),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
