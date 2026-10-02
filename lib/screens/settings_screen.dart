import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import '../main.dart' show appVersion;
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:gal/gal.dart';
import 'package:video_player/video_player.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../dialogs/ai_consent_dialog.dart';
import '../dialogs/update_dialog.dart';
import '../dialogs/email_login_dialog.dart';
import '../dialogs/ai_config_dialog.dart';
import '../config/ai_feature_flags.dart';
import '../utils/storage.dart';
import 'timetable_screen.dart';
import '../widgets/animated_calendar.dart';
import '../widgets/glass_dialog.dart';
import '../widgets/segmented_selector.dart';
import '../widgets/fading_edge_list.dart';
import 'ai_assistant_screen.dart';
import '../widgets/toast_notification.dart';
import '../widgets/time_picker_dialog.dart';
import '../services/auth_service.dart';
import '../services/donor_service.dart';
import '../services/wallpaper_storage_service.dart';
import '../services/cloud_sync_service.dart';
import '../services/glm_service.dart';
import '../services/live_update_service.dart';
import '../services/notification_service.dart';
import '../widgets/blur_selection_menu.dart';
import 'package:url_launcher/url_launcher.dart';
import '../widgets/app_text_field.dart';
import '../widgets/gradient_blur_header.dart';
import '../theme/app_theme.dart';
import '../theme/theme_controller.dart';

enum _CloudSyncAction {
  syncFromCloud,
  uploadLocalToCloud,
  skip,
}

class SettingsScreen extends StatefulWidget {
  final bool autoShowAIConfig;
  const SettingsScreen({super.key, this.autoShowAIConfig = false});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late List<Map<String, String>> _timeSlots;
  late DateTime _semesterStartDate;
  late int _semesterWeeks;
  late int _dailyPeriods;
  bool _aiEnabled = false;
  // AI配置项小字：按当前提供商显示具体模型（节点/模型名）
  String _aiConfigDetail = '开启AI后可用';
  // AI 功能下的两个子开关（从属总开关，总开关关闭时不展示）：
  // 未写入偏好时视为开启，即首次配置正常默认为开
  bool _aiAutoTaskAnalysis = true;
  bool _aiAutoScheduleAnalysis = true;
  bool _aiConsentAccepted = false;
  bool _fastModeEnabled = false;
  bool _isCustomProvider = false;
  bool _isAgnesProvider = false;
  bool _isBuiltinProvider = false;
  bool _providerConfigured = false;
  bool _taskNotificationEnabled = false;
  int _notifyLeadDays = 0;
  int _notifyLeadHours = 2;
  int _notifyLeadMinutes = 0;
  NotificationCopyStyle _notificationCopyStyle = NotificationCopyStyle.casual;
  // 课程实时提醒（安卓 16 实时活动）：仅安卓有这条通道，其他平台整行不出现
  bool _liveUpdateAvailable = false;
  bool _liveUpdateEnabled = false;
  int _liveLeadMinutes = LiveUpdateService.defaultLeadMinutes;
  bool _customVisionManualOverride = false;
  bool _customVisionEnabled = false;
  String? _wallpaperPath;
  int _wallpaperOpacity = 100;
  bool _wallpaperEnabled = false;
  bool _wallpaperBlurEnabled = false;
  bool _reduceMotionEnabled = false;

  /// 自动检查软件升级：启动时静默检查更新并提示新版本
  bool _autoUpdateCheckEnabled = true;

  // 减弱动态效果问号提示：气泡锚点 key 与 Overlay 挂载状态
  final GlobalKey _reduceMotionHelpKey = GlobalKey();
  OverlayEntry? _reduceMotionTipEntry;
  bool _reduceMotionTipVisible = false;

  // 自动检查更新问号提示：气泡锚点 key 与 Overlay 挂载状态（同上）
  final GlobalKey _autoUpdateHelpKey = GlobalKey();
  OverlayEntry? _autoUpdateTipEntry;
  bool _autoUpdateTipVisible = false;

  // 主列表滚动控制器：RawScrollbar 需与 CustomScrollView 共用专属控制器，
  // 否则指示条落到多 position 的 PrimaryScrollController 上会永不显示
  final ScrollController _scrollController = ScrollController();

  /// 显示非本周课程（默认开启）：关闭后课表不以灰色卡片显示非本周课程
  bool _showInactiveCourses = true;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _loadAIConfig().then((_) {
      if (widget.autoShowAIConfig && mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _showDeveloperOptionsDialog();
        });
      }
    });
    _loadNotificationConfig();
  }

  @override
  void dispose() {
    // 页面销毁时移除问号提示气泡，避免 Overlay 泄漏
    _reduceMotionTipEntry?.remove();
    _reduceMotionTipEntry = null;
    _autoUpdateTipEntry?.remove();
    _autoUpdateTipEntry = null;
    _scrollController.dispose();
    super.dispose();
  }

  void _loadSettings() {
    _timeSlots = StorageService.getTimeSlots();
    _semesterStartDate = StorageService.getSemesterStartDate();
    _semesterWeeks = StorageService.getSemesterWeeks();
    _dailyPeriods = StorageService.getDailyPeriods();
    _loadWallpaperSettings();
  }

  Future<void> _loadWallpaperSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _wallpaperPath = prefs.getString('wallpaper_path');
    _wallpaperOpacity = prefs.getInt('wallpaper_opacity') ?? 100;
    _wallpaperEnabled = prefs.getBool('wallpaper_enabled') ?? false;
    _wallpaperBlurEnabled = prefs.getBool('wallpaper_blur_enabled') ?? false;
    final reduceMotion = prefs.getBool('reduce_motion_enabled') ?? false;
    final showInactive = prefs.getBool('show_inactive_courses') ?? true;
    final autoUpdateCheck = prefs.getBool('auto_update_check') ?? true;
    if (mounted) {
      setState(() {
        _reduceMotionEnabled = reduceMotion;
        _showInactiveCourses = showInactive;
        _autoUpdateCheckEnabled = autoUpdateCheck;
      });
    } else {
      _reduceMotionEnabled = reduceMotion;
      _showInactiveCourses = showInactive;
      _autoUpdateCheckEnabled = autoUpdateCheck;
    }
  }

  Future<void> _selectWallpaperImage() async {
    final prefs = await SharedPreferences.getInstance();
    final recentPaths = prefs.getStringList('wallpaper_recent_paths') ?? [];
    if (!mounted) return;
    bool localEnabled = _wallpaperEnabled;

    final dialogPaths = List<String>.from(recentPaths);
    bool dialogDeleteMode = false;
    int? deletingIndex;
    bool newWallpaperSelected = false;

    await showBouncyDialog(
      context: context,
      barrierLabel: '课表壁纸',
      shellPadding: const EdgeInsets.all(20),
      // 壳总宽含壳内边距（与旧版 SizedBox(width:) 包壳一致）
      shellWidth: 320,
      margin: EdgeInsets.zero,
      builder: (context) => StatefulBuilder(
        builder: (builderCtx, setDialogState) {
          return SizedBox(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      '课表壁纸',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: AppColors.of(context).textPrimary,
                      ),
                    ),
                    SizedBox(width: 6),
                    // 带圈问号：点击向下弹出编辑操作说明气泡
                    _TitleHelpIcon(text: '长按壁纸可编辑，再次点按退出编辑。'),
                  ],
                ),
                const SizedBox(height: 16),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: AppColors.of(context).panel(0.4),
                    borderRadius: BorderRadius.circular(10),
                    // 灰描边仅减弱动态时显示（半透明白底与壳背景融合）
                    border: _reduceMotionEnabled
                        ? Border.all(color: AppColors.of(context).borderWeak)
                        : null,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '自定义壁纸',
                          style: TextStyle(
                              fontSize: 15,
                              color: AppColors.of(context).textPrimary),
                        ),
                      ),
                      Switch(
                        value: localEnabled,
                        activeThumbColor: const Color(0xFF4A90E2),
                        onChanged: (v) async {
                          HapticFeedback.selectionClick();
                          await prefs.setBool('wallpaper_enabled', v);
                          if (v && _wallpaperOpacity == 100) {
                            _wallpaperOpacity = 90;
                            await prefs.setInt('wallpaper_opacity', 90);
                          }
                          setDialogState(() {
                            localEnabled = v;
                          });
                          setState(() {
                            _wallpaperEnabled = v;
                          });
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  height: 100,
                  // 壁纸多了横向溢出：右缘淡出提示还能滑（同最近使用横滑行）
                  child: FadingEdgeList(
                    scrollDirection: Axis.horizontal,
                    physics: const BouncingScrollPhysics(),
                    // 缩略图宽 100，淡出带取 20 避免整图被糊掉
                    fadeExtent: 20,
                    itemCount: dialogPaths.length + 1,
                    itemBuilder: (_, index) {
                      if (index < dialogPaths.length) {
                        final path = dialogPaths[index];
                        final file = File(path);
                        final isActive = path == _wallpaperPath;
                        final isBeingDeleted = deletingIndex == index;
                        return AnimatedContainer(
                          key: ValueKey(path),
                          duration: const Duration(milliseconds: 350),
                          curve: Curves.easeInOut,
                          width: isBeingDeleted ? 0 : 100,
                          margin:
                              EdgeInsets.only(right: isBeingDeleted ? 0 : 12),
                          child: AnimatedOpacity(
                            duration: const Duration(milliseconds: 350),
                            opacity: isBeingDeleted ? 0 : 1,
                            onEnd: () {
                              if (!isBeingDeleted) return;
                              // 同步删除持久目录中的物理文件
                              WallpaperStorageService.deleteWallpaperFile(path);
                              dialogPaths.removeAt(index);
                              if (dialogPaths.isEmpty) {
                                dialogDeleteMode = false;
                                deletingIndex = null;
                              }
                              deletingIndex = null;
                              prefs.setStringList(
                                  'wallpaper_recent_paths', dialogPaths);
                              if (_wallpaperPath != null &&
                                  !dialogPaths.contains(_wallpaperPath)) {
                                _wallpaperPath = null;
                                prefs.remove('wallpaper_path');
                                // 当前壁纸被删除：同步刷新预载单例
                                unawaited(WallpaperPreload.instance.reload());
                              }
                              setDialogState(() {});
                            },
                            child: GestureDetector(
                              onTap: () {
                                if (dialogDeleteMode) {
                                  setDialogState(() {
                                    dialogDeleteMode = false;
                                  });
                                  return;
                                }
                                if (!localEnabled) return;
                                () async {
                                  newWallpaperSelected = true;
                                  await prefs.setString('wallpaper_path', path);
                                  final ext =
                                      path.toLowerCase().split('.').last;
                                  final isVideo = [
                                    'mp4',
                                    'mov',
                                    'avi',
                                    'mkv',
                                    'webm',
                                    '3gp'
                                  ].contains(ext);
                                  await prefs.setString('wallpaper_type',
                                      isVideo ? 'video' : 'image');
                                  if (!_wallpaperEnabled) {
                                    await prefs.setBool(
                                        'wallpaper_enabled', true);
                                    localEnabled = true;
                                    setState(() {
                                      _wallpaperEnabled = true;
                                    });
                                  }
                                  setState(() {
                                    _wallpaperPath = path;
                                  });
                                  // 刷新首帧预载单例（原因同导入新壁纸处）
                                  unawaited(WallpaperPreload.instance.reload());
                                  setDialogState(() {});
                                  // 切换到动态壁纸时提示功耗
                                  if (isVideo && mounted) {
                                    toastNotification.show(
                                      context,
                                      '视频壁纸会带来更高的功耗',
                                      type: ToastType.info,
                                    );
                                  }
                                }();
                              },
                              onLongPress: () {
                                setDialogState(() {
                                  dialogDeleteMode = !dialogDeleteMode;
                                  deletingIndex = null;
                                });
                              },
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: SizedBox(
                                  width: 100,
                                  height: 100,
                                  child: Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      file.existsSync()
                                          ? Builder(builder: (context) {
                                              final ext = file.path
                                                  .toLowerCase()
                                                  .split('.')
                                                  .last;
                                              final isVid = [
                                                'mp4',
                                                'mov',
                                                'avi',
                                                'mkv',
                                                'webm',
                                                '3gp'
                                              ].contains(ext);
                                              if (isVid) {
                                                return _VideoThumbnail(
                                                    path: file.path);
                                              }
                                              return Image.file(file,
                                                  fit: BoxFit.cover);
                                            })
                                          : Container(
                                              color: AppColors.of(context)
                                                  .panel(0.4),
                                              child: Icon(Icons.broken_image,
                                                  color: AppColors.of(context)
                                                      .textTertiary),
                                            ),
                                      Container(
                                        decoration: BoxDecoration(
                                          borderRadius:
                                              BorderRadius.circular(12),
                                          border: Border.all(
                                            color: isActive && localEnabled
                                                ? const Color(0xFF4A90E2)
                                                : AppColors.of(context)
                                                    .panel(0.4),
                                            width: isActive && localEnabled
                                                ? 2.5
                                                : 1,
                                          ),
                                        ),
                                      ),
                                      if (!localEnabled)
                                        Container(
                                          color:
                                              AppColors.of(context).panel(0.4),
                                        ),
                                      if (dialogDeleteMode)
                                        Positioned(
                                          top: 4,
                                          right: 4,
                                          child: GestureDetector(
                                            onTap: () {
                                              setDialogState(() {
                                                deletingIndex = index;
                                              });
                                            },
                                            child: Container(
                                              width: 22,
                                              height: 22,
                                              decoration: BoxDecoration(
                                                color: Colors.black
                                                    .withValues(alpha: 0.5),
                                                shape: BoxShape.circle,
                                              ),
                                              child: const Icon(
                                                Icons.close,
                                                color: Colors.white,
                                                size: 14,
                                              ),
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        );
                      }
                      return GestureDetector(
                        onTap: () {
                          if (dialogDeleteMode) {
                            setDialogState(() {
                              dialogDeleteMode = false;
                            });
                            return;
                          }
                          if (!localEnabled) return;
                          () async {
                            final result = await FilePicker.platform.pickFiles(
                              type: FileType.media,
                            );
                            if (result != null &&
                                result.files.single.path != null) {
                              // 持久化到应用内部目录，防止清理缓存后壁纸失效
                              final filePath = await WallpaperStorageService
                                  .persistWallpaper(result.files.single.path!);
                              final extension =
                                  filePath.toLowerCase().split('.').last;
                              final isVideo = [
                                'mp4',
                                'mov',
                                'avi',
                                'mkv',
                                'webm',
                                '3gp'
                              ].contains(extension);
                              await prefs.setString('wallpaper_type',
                                  isVideo ? 'video' : 'image');
                              newWallpaperSelected = true;
                              dialogPaths.insert(0, filePath);
                              if (dialogPaths.length > 5) {
                                dialogPaths.removeLast();
                              }
                              await prefs.setStringList(
                                  'wallpaper_recent_paths', dialogPaths);
                              await prefs.setString('wallpaper_path', filePath);
                              if (!_wallpaperEnabled) {
                                await prefs.setBool('wallpaper_enabled', true);
                                localEnabled = true;
                                setState(() {
                                  _wallpaperEnabled = true;
                                });
                              }
                              setState(() {
                                _wallpaperPath = filePath;
                              });
                              // 刷新首帧预载单例：保证不杀进程的
                              // 再次进入首帧也是新壁纸
                              unawaited(WallpaperPreload.instance.reload());
                              setDialogState(() {});
                              // 切换到动态壁纸时提示功耗
                              if (isVideo && mounted) {
                                toastNotification.show(
                                  context,
                                  '视频壁纸会带来更高的功耗',
                                  type: ToastType.info,
                                );
                              }
                            }
                          }();
                        },
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: SizedBox(
                            width: 100,
                            height: 100,
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                Container(
                                  color: AppColors.of(context).panel(0.4),
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(Icons.add,
                                          color: AppColors.of(context)
                                              .textTertiary,
                                          size: 32),
                                      const SizedBox(height: 4),
                                      Text('添加图片/视频',
                                          style: TextStyle(
                                              fontSize: 12,
                                              color: AppColors.of(context)
                                                  .textTertiary)),
                                    ],
                                  ),
                                ),
                                Container(
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(12),
                                    // 减弱动态效果壳为不透明白底，白色描边不可见，
                                    // 改用浅灰细边（与其他磁贴同款）
                                    border: Border.all(
                                      color: _reduceMotionEnabled
                                          ? AppColors.of(context).borderWeak
                                          : AppColors.of(context).panel(0.4),
                                    ),
                                  ),
                                ),
                                if (!localEnabled)
                                  Container(
                                    color: AppColors.of(context).panel(0.4),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(builderCtx),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                          side: BorderSide(
                              color: AppColors.of(context).borderWeak),
                        ),
                        child: const Text('取消'),
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
    if (!newWallpaperSelected && _wallpaperPath == null) {
      _wallpaperEnabled = false;
      await prefs.setBool('wallpaper_enabled', false);
      if (mounted) setState(() {});
    }
    // 壁纸设置可能变更，标记课表页需要在切回时刷新壁纸
    TimetableScreenState.markNeedsRefresh();
  }

  void _selectWallpaperOpacity() {
    int selectedOpacity = _wallpaperOpacity;
    bool localBlur = _wallpaperBlurEnabled;
    final scrollController = FixedExtentScrollController(
      initialItem: (selectedOpacity - 50) ~/ 5,
    );

    showBouncyDialog(
      context: context,
      barrierLabel: '背景透明度',
      shellPadding: const EdgeInsets.all(20),
      // 壳总宽含壳内边距（与旧版 SizedBox(width:) 包壳一致）
      shellWidth: 280,
      margin: EdgeInsets.zero,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return SizedBox(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '背景透明度',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: AppColors.of(context).textPrimary,
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
                        selectedOpacity = 50 + index * 5;
                      });
                    },
                    childDelegate: ListWheelChildBuilderDelegate(
                      childCount: 11,
                      builder: (context, index) {
                        final opacity = 50 + index * 5;
                        final isSelected = opacity == selectedOpacity;
                        return Container(
                          alignment: Alignment.center,
                          child: Text(
                            '$opacity%',
                            style: TextStyle(
                              fontSize: isSelected ? 18 : 16,
                              fontWeight: isSelected
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                              color: isSelected
                                  ? const Color(0xFF4A90E2)
                                  : AppColors.of(context).textSecondary,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                // 减弱动态效果开启时：卡片模糊强制关闭，选项隐藏
                if (!_reduceMotionEnabled) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: AppColors.of(context).panel(0.4),
                      borderRadius: BorderRadius.circular(10),
                      // 灰描边仅减弱动态时显示（半透明白底与壳背景融合）
                      border: _reduceMotionEnabled
                          ? Border.all(color: AppColors.of(context).borderWeak)
                          : null,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '卡片模糊',
                            style: TextStyle(
                                fontSize: 15,
                                color: AppColors.of(context).textPrimary),
                          ),
                        ),
                        Switch(
                          value: localBlur,
                          activeThumbColor: const Color(0xFF4A90E2),
                          onChanged: (v) {
                            HapticFeedback.selectionClick();
                            setDialogState(() {
                              localBlur = v;
                            });
                          },
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(context),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                          side: BorderSide(
                              color: AppColors.of(context).borderWeak),
                        ),
                        child: const Text('取消'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () async {
                          final prefs = await SharedPreferences.getInstance();
                          await prefs.setInt(
                              'wallpaper_opacity', selectedOpacity);
                          await prefs.setBool(
                              'wallpaper_blur_enabled', localBlur);
                          setState(() {
                            _wallpaperOpacity = selectedOpacity;
                            _wallpaperBlurEnabled = localBlur;
                          });
                          // 透明度/模糊变更，标记课表页刷新
                          TimetableScreenState.markNeedsRefresh();
                          if (mounted) Navigator.pop(context);
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF4A90E2),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        child: const Text('保存'),
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

  Future<void> _loadAIConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final providerStr = prefs.getString('ai_provider');
    var aiEnabled = prefs.getBool('ai_enabled') ?? false;
    final consentAccepted = prefs.getBool('ai_consent_accepted') ?? false;
    final fastModeEnabled = prefs.getBool('fast_mode_enabled') ?? false;
    final customVisionManualOverride =
        prefs.getBool('custom_api_vision_manual_override') ?? false;
    final customVisionEnabled =
        prefs.getBool('custom_api_vision_manual_value') ?? false;
    // 子开关读同步缓存（启动时已预热，切换时由 setter 就地更新），
    // 与待办页/对话页用的是同一份值
    final autoTaskAnalysis = AIAutoAnalysisFlags.taskEnabled;
    final autoScheduleAnalysis = AIAutoAnalysisFlags.scheduleEnabled;

    // AI配置项小字：按当前提供商显示具体模型信息
    String aiConfigDetail = '开启AI后可用';
    if (providerStr == 'builtin') {
      final node = prefs.getInt('builtin_node') ?? 1;
      aiConfigDetail = '内置模型节点$node';
    } else if (providerStr == 'agnes') {
      final model = prefs.getString('agnes_model') ?? 'agnes-2.0-flash';
      aiConfigDetail =
          model == 'agnes-2.5-flash' ? 'Agnes 2.5 Flash' : 'Agnes 2.0 Flash';
    } else if (providerStr == 'custom') {
      final model = (prefs.getString('custom_api_model') ?? '').trim();
      aiConfigDetail = model.isNotEmpty ? model : '自定义 API';
    }
    await AIService.instance.loadConfig();

    // If AI is enabled but no API is configured, auto-disable
    if (aiEnabled) {
      final hasConfig = await _hasAnyAIConfig();
      if (!hasConfig) {
        aiEnabled = false;
        await prefs.setBool('ai_enabled', false);
      }
    }

    setState(() {
      _aiEnabled = aiEnabled;
      _aiAutoTaskAnalysis = autoTaskAnalysis;
      _aiAutoScheduleAnalysis = autoScheduleAnalysis;
      _aiConsentAccepted = consentAccepted;
      _fastModeEnabled = fastModeEnabled;
      _customVisionManualOverride = customVisionManualOverride;
      _customVisionEnabled = customVisionEnabled;
      _aiConfigDetail = aiConfigDetail;
      _providerConfigured = providerStr != null && providerStr.isNotEmpty;
      _isAgnesProvider = providerStr == 'agnes';
      _isBuiltinProvider = providerStr == 'builtin';
      _isCustomProvider = providerStr == 'custom';
    });
  }

  Future<void> _loadNotificationConfig() async {
    final settings =
        await NotificationService.instance.getTaskNotificationSettings();
    final liveSettings = await LiveUpdateService.instance.getSettings();
    if (!mounted) return;
    setState(() {
      _taskNotificationEnabled = settings.enabled;
      _notifyLeadDays = settings.days;
      _notifyLeadHours = settings.hours;
      _notifyLeadMinutes = settings.minutes;
      _notificationCopyStyle = settings.style;
      _liveUpdateAvailable = LiveUpdateService.instance.platformSupported;
      _liveUpdateEnabled = liveSettings.enabled;
      _liveLeadMinutes = liveSettings.leadMinutes;
    });
  }

  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.of(context).padding.top;

    return Scaffold(
      backgroundColor: Theme.of(context).brightness == Brightness.dark
          ? AppPalette.dark.scaffold
          : const Color(0xFFF8F9FC),
      body: Stack(
        children: [
          NotificationListener<ScrollNotification>(
            // 滚动设置页时收回问号提示气泡，避免气泡与锚点错位
            onNotification: (notification) {
              if (notification is ScrollStartNotification ||
                  notification is ScrollUpdateNotification) {
                if (_reduceMotionTipEntry != null) {
                  _removeReduceMotionTip();
                }
                if (_autoUpdateTipEntry != null) {
                  _removeAutoUpdateTip();
                }
              }
              return false;
            },
            child: RawScrollbar(
              // 必须显式接线专属控制器：若落到 PrimaryScrollController（多
              // position 共享），SDK 的 _shouldUpdatePainter 会拒收通知，
              // 指示条滑动时也永远不出现
              controller: _scrollController,
              // 与对话页同款：指示条顶点=标题栏模糊起始线，四角圆润
              padding: EdgeInsets.only(top: topPadding + 62),
              radius: const Radius.circular(4),
              thickness: 4,
              thumbColor:
                  AppColors.of(context).textTertiary.withValues(alpha: 0.6),
              child: CustomScrollView(
                controller: _scrollController,
                physics: const BouncingScrollPhysics(
                    parent: AlwaysScrollableScrollPhysics()),
                slivers: [
                  SliverPadding(
                    padding: EdgeInsets.only(top: topPadding + 62),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 140),
                    sliver: SliverList(
                      delegate: SliverChildListDelegate([
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _buildSectionTitle('学期设置'),
                            const SizedBox(height: 12),
                            _buildSettingsGroup([
                              // 图标语义区分：开学日期=单日标记（event），
                              // 学期周数=周视图日历，当前周次=当前位置旗标
                              _buildSettingsItem(
                                icon: Icons.event_outlined,
                                title: '开学日期',
                                subtitle:
                                    '${_semesterStartDate.year}年${_semesterStartDate.month}月${_semesterStartDate.day}日',
                                onTap: _selectSemesterStartDate,
                              ),
                              _buildDivider(),
                              _buildSettingsItem(
                                icon: Icons.calendar_view_week_outlined,
                                title: '学期周数',
                                subtitle: '$_semesterWeeks 周',
                                onTap: _selectSemesterWeeks,
                              ),
                              _buildDivider(),
                              _buildSettingsItem(
                                icon: Icons.flag_outlined,
                                title: '当前周次',
                                trailing: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 6),
                                  decoration: BoxDecoration(
                                    color: StorageService.isHoliday()
                                        ? AppColors.of(context).chipIdle
                                        : const Color(0xFF4A90E2)
                                            .withValues(alpha: 0.1),
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: Text(
                                    StorageService.isBeforeSemesterStart()
                                        ? '未开始'
                                        : StorageService.getCurrentWeek() >
                                                _semesterWeeks
                                            ? '已结束'
                                            : '第 ${StorageService.getCurrentWeek()} 周',
                                    style: TextStyle(
                                      color: StorageService.isHoliday()
                                          ? AppColors.of(context).textSecondary
                                          : const Color(0xFF4A90E2),
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ),
                            ]),
                            const SizedBox(height: 24),
                            _buildSectionTitle('课程时间'),
                            const SizedBox(height: 12),
                            _buildSettingsGroup([
                              // 每日节数是数量概念：编号列表；时钟只留给
                              // 时间段设置，避免两行同为表盘图标
                              _buildSettingsItem(
                                icon: Icons.format_list_numbered_outlined,
                                title: '每日节数',
                                subtitle: '$_dailyPeriods 节',
                                onTap: _selectDailyPeriods,
                              ),
                              _buildDivider(),
                              _buildSettingsItem(
                                icon: Icons.schedule_outlined,
                                title: '时间段设置',
                                onTap: _showTimeSlotsDialog,
                              ),
                              _buildDivider(),
                              _buildSettingsItem(
                                icon: Icons.visibility_outlined,
                                title: '显示非本周课程',
                                trailing: Switch(
                                  value: _showInactiveCourses,
                                  activeThumbColor: const Color(0xFF4A90E2),
                                  onChanged: (v) async {
                                    HapticFeedback.selectionClick();
                                    final prefs =
                                        await SharedPreferences.getInstance();
                                    await prefs.setBool(
                                        'show_inactive_courses', v);
                                    setState(() {
                                      _showInactiveCourses = v;
                                    });
                                    // 切换后标记课表页刷新（灰色卡片显隐）
                                    TimetableScreenState.markNeedsRefresh();
                                  },
                                ),
                              ),
                            ]),
                            const SizedBox(height: 24),
                            _buildSectionTitle('账户与通知'),
                            const SizedBox(height: 12),
                            _buildSettingsGroup([
                              Consumer<AuthService>(
                                builder: (context, auth, child) {
                                  return _buildSettingsItem(
                                    icon: Icons.mail_outline,
                                    title: '电子邮箱登录',
                                    subtitle: auth.isAuthenticated
                                        ? '已登录 (${auth.userName ?? auth.userEmail ?? "用户"})'
                                        : ((auth.userName ?? auth.userEmail) !=
                                                null
                                            ? '已退出（上次登录：${auth.userName ?? auth.userEmail}）'
                                            : '登录以同步数据'),
                                    trailing: auth.isAuthenticated
                                        ? TextButton(
                                            onPressed: () =>
                                                _showLogoutDialog(auth),
                                            child: const Text('退出',
                                                style: TextStyle(
                                                    color: Colors.red)),
                                          )
                                        : null,
                                    onTap: auth.isAuthenticated
                                        ? null
                                        : () => _showEmailLoginDialog(auth),
                                  );
                                },
                              ),
                              _buildDivider(),
                              // 课程实时提醒：安卓 16 起系统会把这条 promoted-ongoing
                              // 通知渲染成状态栏胶囊（超级岛/流体云同源）。其他平台
                              // 没有这条通道，整块不出现而不是留一个无效开关
                              if (_liveUpdateAvailable) ...[
                                _buildSettingsItem(
                                  // 胶囊形（顶部圆角长条 + 下方短柄）直读"状态栏胶囊"；
                                  // dynamic_feed 那对叠放的卡片看不出这个意思。
                                  // 本页已用过的图形（铃铛/日历/时钟/芯片/齿轮…）
                                  // 均不与之重复
                                  icon: Icons.pin_invoke_outlined,
                                  title: '实时课程提醒',
                                  trailing: Switch(
                                    value: _liveUpdateEnabled,
                                    activeThumbColor: const Color(0xFF4A90E2),
                                    onChanged: (value) async {
                                      HapticFeedback.selectionClick();

                                      if (value) {
                                        final granted = await NotificationService
                                            .instance
                                            .requestNotificationPermission();
                                        if (!granted) {
                                          if (!mounted) return;
                                          toastNotification.show(
                                            context,
                                            '通知权限未开启，无法显示实时课程提醒',
                                            type: ToastType.error,
                                          );
                                          return;
                                        }
                                      }

                                      await LiveUpdateService.instance
                                          .saveSettings(
                                        enabled: value,
                                        leadMinutes: _liveLeadMinutes,
                                      );

                                      if (!mounted) return;
                                      setState(() {
                                        _liveUpdateEnabled = value;
                                      });
                                      toastNotification.show(
                                        context,
                                        value
                                            ? '实时课程提醒已开启'
                                            : '实时课程提醒已关闭',
                                        type: value
                                            ? ToastType.success
                                            : ToastType.info,
                                      );
                                    },
                                  ),
                                ),
                                AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 280),
                                  switchInCurve: Curves.easeOutCubic,
                                  switchOutCurve: Curves.easeInCubic,
                                  transitionBuilder: (child, animation) {
                                    return FadeTransition(
                                      opacity: animation,
                                      child: SizeTransition(
                                        sizeFactor: animation,
                                        axisAlignment: -1,
                                        child: child,
                                      ),
                                    );
                                  },
                                  child: _liveUpdateEnabled
                                      ? Column(
                                          key: const ValueKey(
                                              'live-update-options-visible'),
                                          children: [
                                            // 子项与父项合成一块：组内不插分隔条，
                                            // 竖干从父项底边直接接下来
                                            _buildBranchRow(
                                              title: '课前通知时间',
                                              trailing: _buildBranchValueTrailing(
                                                  LiveUpdateService.instance
                                                      .formatLeadText(
                                                          _liveLeadMinutes)),
                                              onTap: _showLiveLeadChoiceDialog,
                                              // 本组末子：竖干到此收口，不再往下接
                                              stemEndsAtBranch: true,
                                            ),
                                          ],
                                        )
                                      : const SizedBox.shrink(
                                          key: ValueKey(
                                              'live-update-options-hidden'),
                                        ),
                                ),
                                _buildDivider(),
                              ],
                              _buildSettingsItem(
                                icon: Icons.notifications_active_outlined,
                                title: '任务临期通知',
                                trailing: Switch(
                                  value: _taskNotificationEnabled,
                                  onChanged: (value) async {
                                    HapticFeedback.selectionClick();

                                    if (value) {
                                      final granted = await NotificationService
                                          .instance
                                          .requestNotificationPermission();
                                      if (!granted) {
                                        if (!mounted) return;
                                        toastNotification.show(
                                          context,
                                          '通知权限未开启，无法启动任务提醒',
                                          type: ToastType.error,
                                        );
                                        return;
                                      }
                                    }

                                    await NotificationService.instance
                                        .saveTaskNotificationSettings(
                                      enabled: value,
                                      days: _notifyLeadDays,
                                      hours: _notifyLeadHours,
                                      minutes: _notifyLeadMinutes,
                                      style: _notificationCopyStyle,
                                    );

                                    if (!mounted) return;
                                    setState(() {
                                      _taskNotificationEnabled = value;
                                    });

                                    if (value) {
                                      await NotificationService.instance
                                          .rescheduleTaskNotifications(
                                              StorageService.getTasks());
                                      if (mounted) {
                                        toastNotification.show(
                                            context, '任务临期通知已开启',
                                            type: ToastType.success);
                                      }
                                    } else {
                                      await NotificationService.instance
                                          .cancelAllTaskNotifications();
                                      if (mounted) {
                                        toastNotification.show(
                                            context, '任务临期通知已关闭',
                                            type: ToastType.info);
                                      }
                                    }
                                  },
                                  activeThumbColor: const Color(0xFF4A90E2),
                                ),
                              ),
                              AnimatedSwitcher(
                                duration: const Duration(milliseconds: 280),
                                switchInCurve: Curves.easeOutCubic,
                                switchOutCurve: Curves.easeInCubic,
                                transitionBuilder: (child, animation) {
                                  return FadeTransition(
                                    opacity: animation,
                                    child: SizeTransition(
                                      sizeFactor: animation,
                                      axisAlignment: -1,
                                      child: child,
                                    ),
                                  );
                                },
                                child: _taskNotificationEnabled
                                    ? Column(
                                        key: const ValueKey(
                                            'notify-options-visible'),
                                        children: [
                                          // 两个子项合成一块，组内不插分隔条
                                          _buildBranchRow(
                                            title: '提前提醒时间',
                                            trailing: _buildBranchValueTrailing(
                                                NotificationService.instance
                                                    .formatLeadTimeText(
                                                        _notifyLeadDays,
                                                        _notifyLeadHours,
                                                        _notifyLeadMinutes)),
                                            onTap:
                                                _showNotificationLeadTimeDialog,
                                            // 竖干往下接「通知文案风格」
                                            stemEndsAtBranch: false,
                                          ),
                                          _buildBranchRow(
                                            title: '通知文案风格',
                                            trailing:
                                                _buildCopyStyleSelector(),
                                            // 本组末子：竖干到分支口即止
                                            stemEndsAtBranch: true,
                                          ),
                                          // 本组是卡片最后一项，而滑块正好 40 高
                                          // 把分支行撑满——不加这点底部留白，
                                          // 滑块下缘就贴着卡片边
                                          const SizedBox(height: 9),
                                        ],
                                      )
                                    : const SizedBox.shrink(
                                        key: ValueKey('notify-options-hidden'),
                                      ),
                              ),
                            ]),
                            const SizedBox(height: 24),
                            _buildSectionTitle('AI设置'),
                            const SizedBox(height: 12),
                            _buildSettingsGroup([
                              // 芯片（AI 算力）表意 AI 功能；星芒已让给导航栏
                              // 「对话」图标，避免同屏出现两个相同图形
                              _buildSettingsItem(
                                icon: Icons.memory_outlined,
                                title: 'AI 功能',
                                trailing: Switch(
                                  value: _aiEnabled,
                                  onChanged: (value) async {
                                    HapticFeedback.selectionClick();
                                    if (value) {
                                      if (!_aiConsentAccepted) {
                                        final accepted =
                                            await _showAIConsentDialog();
                                        if (!accepted) return;
                                      }
                                      final hasConfig = await _hasAnyAIConfig();
                                      if (!hasConfig) {
                                        await _showDeveloperOptionsDialog();
                                      }
                                      final recheckConfig =
                                          await _hasAnyAIConfig();
                                      final prefs =
                                          await SharedPreferences.getInstance();
                                      if (recheckConfig) {
                                        await prefs.setBool('ai_enabled', true);
                                        if (mounted)
                                          setState(() {
                                            _aiEnabled = true;
                                          });
                                      } else {
                                        await prefs.setBool(
                                            'ai_enabled', false);
                                        if (mounted) {
                                          setState(() {
                                            _aiEnabled = false;
                                          });
                                          toastNotification.show(
                                              context, '未配置API，AI功能已关闭',
                                              type: ToastType.info);
                                        }
                                      }
                                    } else {
                                      final prefs =
                                          await SharedPreferences.getInstance();
                                      await prefs.setBool('ai_enabled', false);
                                      if (mounted)
                                        setState(() {
                                          _aiEnabled = false;
                                        });
                                    }
                                  },
                                  activeThumbColor: const Color(0xFF4A90E2),
                                ),
                              ),
                              // 总开关打开后才出现两个子项（与「任务临期通知」
                              // 的展开方式一致：淡入 + 高度展开）
                              AnimatedSwitcher(
                                duration: const Duration(milliseconds: 280),
                                switchInCurve: Curves.easeOutCubic,
                                switchOutCurve: Curves.easeInCubic,
                                transitionBuilder: (child, animation) {
                                  return FadeTransition(
                                    opacity: animation,
                                    child: SizeTransition(
                                      sizeFactor: animation,
                                      axisAlignment: -1,
                                      child: child,
                                    ),
                                  );
                                },
                                child: _aiEnabled
                                    ? Column(
                                        key: const ValueKey(
                                            'ai-sub-options-visible'),
                                        children: [
                                          _buildAISubItem(
                                            title: '自动任务分析',
                                            value: _aiAutoTaskAnalysis,
                                            // 竖干贯穿本行以衔接下一子项
                                            stemEndsAtBranch: false,
                                            onChanged: (value) async {
                                              HapticFeedback.selectionClick();
                                              await AIAutoAnalysisFlags
                                                  .setTaskEnabled(value);
                                              if (value &&
                                                  _isBuiltinProvider &&
                                                  mounted) {
                                                // 内置模型走公共额度：开自动
                                                // 分析会无感消耗，提醒一次
                                                toastNotification.show(
                                                  context,
                                                  '开启后用量消耗更快',
                                                  type: ToastType.info,
                                                );
                                              }
                                              if (mounted)
                                                setState(() {
                                                  _aiAutoTaskAnalysis = value;
                                                });
                                            },
                                          ),
                                          _buildAISubItem(
                                            title: '自动课表分析',
                                            value: _aiAutoScheduleAnalysis,
                                            // 末行竖干只画到分支口，不再向下延伸
                                            stemEndsAtBranch: true,
                                            onChanged: (value) async {
                                              HapticFeedback.selectionClick();
                                              await AIAutoAnalysisFlags
                                                  .setScheduleEnabled(value);
                                              if (value &&
                                                  _isBuiltinProvider &&
                                                  mounted) {
                                                toastNotification.show(
                                                  context,
                                                  '开启后用量消耗更快',
                                                  type: ToastType.info,
                                                );
                                              }
                                              if (mounted)
                                                setState(() {
                                                  _aiAutoScheduleAnalysis =
                                                      value;
                                                });
                                            },
                                          ),
                                        ],
                                      )
                                    : const SizedBox.shrink(
                                        key: ValueKey('ai-sub-options-hidden'),
                                      ),
                              ),
                              _buildDivider(),
                              // 齿轮表示「AI 配置」；导航栏「设置」已改用调节滑杆，
                              // 避免同屏出现两个 tune 图标
                              _buildSettingsItem(
                                icon: Icons.settings_outlined,
                                title: 'AI配置',
                                // 小字按当前提供商显示具体模型（节点/模型名），
                                // 未开启时提示开启后可用
                                subtitle:
                                    _aiEnabled ? _aiConfigDetail : '开启AI后可用',
                                onTap: _aiEnabled
                                    ? () => _showDeveloperOptionsDialog()
                                    : null,
                              ),
                            ]),
                            const SizedBox(height: 24),
                            _buildSectionTitle('个性化'),
                            const SizedBox(height: 12),
                            _buildSettingsGroup([
                              _buildSettingsItem(
                                // 左侧图标随当前生效模式切换：深色月亮 / 浅色太阳
                                icon: AppColors.isDark(context)
                                    ? Icons.dark_mode
                                    : Icons.light_mode,
                                title: '界面风格',
                                trailing: _buildThemeModeSelector(),
                              ),
                              _buildDivider(),
                              _buildSettingsItem(
                                icon: Icons.image_outlined,
                                title: '课表壁纸',
                                subtitle:
                                    _wallpaperEnabled && _wallpaperPath != null
                                        ? '已启用'
                                        : _wallpaperPath != null
                                            ? '未启用'
                                            : '选择图片作为课表背景',
                                onTap: _selectWallpaperImage,
                              ),
                              _buildDivider(),
                              _buildSettingsItem(
                                icon: Icons.opacity_outlined,
                                title: '背景透明度',
                                subtitle: _wallpaperEnabled
                                    ? '$_wallpaperOpacity%'
                                    : '开启壁纸功能后可用',
                                onTap: _wallpaperEnabled
                                    ? _selectWallpaperOpacity
                                    : null,
                              ),
                              _buildDivider(),
                              _buildSettingsItem(
                                icon: Icons.motion_photos_off_outlined,
                                titleWidget: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Text(
                                      '减弱动态效果',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    // 带圈问号（同节点菜单）：点击向下弹出说明气泡
                                    GestureDetector(
                                      key: _reduceMotionHelpKey,
                                      behavior: HitTestBehavior.opaque,
                                      onTap: _toggleReduceMotionTip,
                                      child: Icon(
                                        Icons.help_outline,
                                        size: 15,
                                        color:
                                            AppColors.of(context).textTertiary,
                                      ),
                                    ),
                                  ],
                                ),
                                trailing: Switch(
                                  value: _reduceMotionEnabled,
                                  activeThumbColor: const Color(0xFF4A90E2),
                                  onChanged: (v) async {
                                    HapticFeedback.selectionClick();
                                    final prefs =
                                        await SharedPreferences.getInstance();
                                    await prefs.setBool(
                                        'reduce_motion_enabled', v);
                                    ReduceMotionFlag.refresh();
                                    setState(() {
                                      _reduceMotionEnabled = v;
                                    });
                                    // 减弱动态切换：标记课表页刷新（morph 改统一
                                    // 对话框、卡片模糊强制开关）
                                    TimetableScreenState.markNeedsRefresh();
                                  },
                                ),
                              ),
                            ]),
                            const SizedBox(height: 24),
                            // 本栏收纳「应用自身信息 + 支持开发者 + 维护类操作」：
                            // 关于 / 打赏支持 / 自动检查更新 / 清除所有数据
                            _buildSectionTitle('关于与支持'),
                            const SizedBox(height: 12),
                            _buildSettingsGroup([
                              _buildSettingsItem(
                                icon: Icons.info_outline,
                                title: '关于',
                                subtitle: 'CourseHub v$appVersion',
                                onTap: _showAboutDialog,
                              ),
                              _buildDivider(),
                              _buildSettingsItem(
                                icon: Icons.volunteer_activism_outlined,
                                title: '打赏支持',
                                onTap: _showDonationDialog,
                              ),
                              _buildDivider(),
                              _buildSettingsItem(
                                icon: Icons.arrow_circle_up_outlined,
                                titleWidget: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Text(
                                      '自动检查更新',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    // 带圈问号（同减弱动态效果）：点击向下弹出说明气泡
                                    GestureDetector(
                                      key: _autoUpdateHelpKey,
                                      behavior: HitTestBehavior.opaque,
                                      onTap: _toggleAutoUpdateTip,
                                      child: Icon(
                                        Icons.help_outline,
                                        size: 15,
                                        color:
                                            AppColors.of(context).textTertiary,
                                      ),
                                    ),
                                  ],
                                ),
                                trailing: Switch(
                                  value: _autoUpdateCheckEnabled,
                                  activeThumbColor: const Color(0xFF4A90E2),
                                  onChanged: (v) async {
                                    HapticFeedback.selectionClick();
                                    final prefs =
                                        await SharedPreferences.getInstance();
                                    await prefs.setBool('auto_update_check', v);
                                    setState(() {
                                      _autoUpdateCheckEnabled = v;
                                    });
                                  },
                                ),
                              ),
                              _buildDivider(),
                              _buildSettingsItem(
                                icon: Icons.delete_outline,
                                title: '清除所有数据',
                                subtitle: '删除所有课程和设置',
                                isDestructive: true,
                                onTap: _clearAllData,
                              ),
                            ]),
                          ],
                        ),
                      ]),
                    ),
                  ),
                ],
              ),
            ),
          ),
          _buildPinnedHeader(topPadding),
        ],
      ),
    );
  }

  Widget _buildPinnedHeader(double topPadding) {
    // 无界渐变标题栏：模糊与雾化自顶部向底缘衰减归零，无分隔线无硬边；
    // 「减弱动态效果」开启时退化为无模糊的纯雾化渐变（内容 ghost 透出）
    return Positioned(
      left: 0,
      right: 0,
      top: 0,
      child: GradientBlurHeader(
        topPadding: topPadding,
        title: '设置',
        // 雾面曲线整体下移 6px（绘制区不越出标题栏，减弱模式同样
        // 生效）：同高度浓度=原上移 6px 处，标题下方一行可读性↑
        blurCurveShift: 6,
        // 标题栏本体增高 6px：内容区起始位置随之下移（列表顶部偏移
        // 已同步 +6），底部坡面多出 6px 渐变空间
        layoutBottomExtend: 6,
        reduceMotion: _reduceMotionEnabled,
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.bold,
          color: AppColors.of(context).textPrimary,
        ),
      ),
    );
  }

  // 减弱动态效果问号提示：点击问号在标题下方弹出说明气泡
  // （样式与动画同对话页节点菜单的问号提示），点击空白处或滚动页面时收回
  void _toggleReduceMotionTip() {
    if (_reduceMotionTipEntry != null) {
      _removeReduceMotionTip();
      return;
    }
    final iconContext = _reduceMotionHelpKey.currentContext;
    final iconBox = iconContext?.findRenderObject() as RenderBox?;
    if (iconBox == null) return;
    final iconPos = iconBox.localToGlobal(Offset.zero);
    final iconSize = iconBox.size;
    final screenWidth = MediaQuery.of(context).size.width;
    // 气泡左缘大致对齐标题文字，整体夹在屏幕内（右侧留 16px 边距）
    final left = (iconPos.dx - 60)
        .clamp(16.0, (screenWidth - 316).clamp(16.0, double.infinity))
        .toDouble();
    final top = iconPos.dy + iconSize.height + 6;
    _reduceMotionTipVisible = true;
    _reduceMotionTipEntry = OverlayEntry(
      builder: (context) => Stack(
        children: [
          // 透明屏障：点击气泡以外的任意处收回
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _removeReduceMotionTip,
            ),
          ),
          _SettingsInfoTip(
            visible: _reduceMotionTipVisible,
            text: '移除部分动画和视觉效果。如遇卡顿，建议开启此项。',
            left: left,
            top: top,
            onDismissed: () {
              _reduceMotionTipEntry?.remove();
              _reduceMotionTipEntry = null;
            },
          ),
        ],
      ),
    );
    Overlay.of(context).insert(_reduceMotionTipEntry!);
  }

  void _removeReduceMotionTip() {
    if (_reduceMotionTipEntry == null) return;
    // 翻转 visible 触发收回动画，动画完成后由 onDismissed 移除 entry
    _reduceMotionTipVisible = false;
    _reduceMotionTipEntry!.markNeedsBuild();
  }

  // 自动检查更新问号提示：同减弱动态效果，点击问号在标题下方
  // 弹出说明气泡，点击空白处或滚动页面时收回；两处气泡互斥
  void _toggleAutoUpdateTip() {
    if (_autoUpdateTipEntry != null) {
      _removeAutoUpdateTip();
      return;
    }
    // 互斥：先收回另一处气泡，避免两个气泡同时悬浮
    if (_reduceMotionTipEntry != null) {
      _removeReduceMotionTip();
    }
    final iconContext = _autoUpdateHelpKey.currentContext;
    final iconBox = iconContext?.findRenderObject() as RenderBox?;
    if (iconBox == null) return;
    final iconPos = iconBox.localToGlobal(Offset.zero);
    final iconSize = iconBox.size;
    final screenWidth = MediaQuery.of(context).size.width;
    // 气泡左缘大致对齐标题文字，整体夹在屏幕内（右侧留 16px 边距）
    final left = (iconPos.dx - 60)
        .clamp(16.0, (screenWidth - 316).clamp(16.0, double.infinity))
        .toDouble();
    final top = iconPos.dy + iconSize.height + 6;
    _autoUpdateTipVisible = true;
    _autoUpdateTipEntry = OverlayEntry(
      builder: (context) => Stack(
        children: [
          // 透明屏障：点击气泡以外的任意处收回
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _removeAutoUpdateTip,
            ),
          ),
          _SettingsInfoTip(
            visible: _autoUpdateTipVisible,
            text: '关闭后不再自动推送更新提示，您仍可通过关于→检查更新获取新版本。',
            left: left,
            top: top,
            onDismissed: () {
              _autoUpdateTipEntry?.remove();
              _autoUpdateTipEntry = null;
            },
          ),
        ],
      ),
    );
    Overlay.of(context).insert(_autoUpdateTipEntry!);
  }

  void _removeAutoUpdateTip() {
    if (_autoUpdateTipEntry == null) return;
    // 翻转 visible 触发收回动画，动画完成后由 onDismissed 移除 entry
    _autoUpdateTipVisible = false;
    _autoUpdateTipEntry!.markNeedsBuild();
  }

  Widget _buildSettingsGroup(List<Widget> items) {
    return Card(
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: AppColors.of(context).borderWeak),
      ),
      child: Column(
        children: items,
      ),
    );
  }

  Widget _buildSettingsItem({
    IconData? icon,
    String? title,
    Widget? titleWidget,
    String? subtitle,
    Widget? trailing,
    bool isDestructive = false,
    VoidCallback? onTap,
  }) {
    // 行内边距与图标底座参照系统设置收紧：默认 16px 左右内边距 + 36px
    // 底座会把带开关/滑块的行标题挤成省略号，这里整体让出文字宽度
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 12),
      horizontalTitleGap: 12,
      // icon 为 null = 不带图标的行（左侧分支线由 [_buildBranchRow] 的
      // Stack 画）：仍占一个与图标底座等宽的空位，标题左缘保持 54 不动
      leading: icon == null
          ? const SizedBox(width: 30)
          : Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: isDestructive
                    ? Colors.red.withValues(alpha: 0.1)
                    : const Color(0xFF4A90E2).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                icon,
                color: isDestructive ? Colors.red : const Color(0xFF4A90E2),
                size: 18,
              ),
            ),
      title: titleWidget ??
          Text(
            title!,
            style: TextStyle(
              fontWeight: FontWeight.w500,
              color: isDestructive ? Colors.red : null,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
      subtitle: subtitle != null
          ? Text(
              subtitle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            )
          : null,
      trailing: trailing ??
          Icon(
            Icons.chevron_right,
            color: AppColors.of(context).textTertiary,
          ),
      onTap: onTap,
    );
  }

  Widget _buildDivider() {
    return Divider(
      height: 1,
      // 与行内文字左缘对齐：contentPadding 12 + 图标底座 30 + 标题间距 12
      indent: 54,
      color: AppColors.of(context).borderWeak,
    );
  }

  /// 树状分支子项行的通用骨架：左侧 38 宽的分支连接区 + 标题 + 右侧控件。
  /// 「AI 功能」下的勾选圈子项与「实时课程提醒」「任务临期通知」下的
  /// 跳转/滑块子项共用同一套标题字号（14/w500）与行高（36），
  /// 只在右侧控件和点击语义上分叉。
  ///
  /// 分支区不再写死高度：改用 Stack 让竖干 top/bottom 拉满，行高交给内容
  /// 决定（minHeight 36；右侧放 40 高的分段滑块时整行跟着长，竖干同步变高，
  /// 与下一行的竖口仍接得上）。
  ///
  /// 竖干不能塞进 ListTile 的 leading：leading 拿到的是松约束，没有自带
  /// 尺寸的 CustomPaint 会被压成 0 高（实测 Size(38, 0)），竖干就在行间断掉；
  /// 套 IntrinsicHeight 也救不回来，还会把两行小字的行高从 100 量成 80。
  ///
  /// 分支区几何与 [_buildDivider] 的 indent 对齐：page x 12..50、竖干 x=27，
  /// 标题左缘 54（12 左边距 + 38 分支区 + 4 间距）。
  Widget _buildBranchRow({
    required String title,
    required bool stemEndsAtBranch,
    required Widget trailing,
    VoidCallback? onTap,
  }) {
    final colors = AppColors.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // 整行可点；无跳转语义的行（右侧是控件本身）传 null，
      // 子项在右侧控件里各自处理手势
      onTap: onTap,
      child: Stack(
        children: [
          Positioned(
            left: 12,
            top: 0,
            bottom: 0,
            width: 38,
            child: CustomPaint(
              painter: _BranchConnectorPainter(
                // 分支线比分隔线重一档、比正文轻：深浅色下都能看清但不抢眼
                color: colors.textTertiary.withValues(alpha: 0.5),
                stemEndsAtBranch: stemEndsAtBranch,
              ),
            ),
          ),
          // 分支区的占位仍留在行内：Row 需要它把标题顶到 x=54
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 36),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  const SizedBox(width: 38),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      title,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: colors.textPrimary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  trailing,
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 分支子项的「当前值 + 箭头」尾部：值原本挂在标题下的 subtitle，
  /// 子项统一压成单行后挪到 > 左侧紧贴箭头显示。
  Widget _buildBranchValueTrailing(String value) {
    final colors = AppColors.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            value,
            style: TextStyle(
              fontSize: 13,
              color: colors.textSecondary,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Icon(
          Icons.chevron_right,
          color: colors.textTertiary,
        ),
      ],
    );
  }

  /// 「AI 功能」下的子选项行：不带图标底座，左侧改画一段树状分支连接线，
  /// 右侧用勾选圈（比父项的 Switch 轻一档），从属关系一眼可辨。
  /// 标题、行高与 [_buildBranchRow] 一致，这里只提供勾选圈尾部与点击语义。
  Widget _buildAISubItem({
    required String title,
    required bool value,
    required bool stemEndsAtBranch,
    required ValueChanged<bool> onChanged,
  }) {
    return _buildBranchRow(
      title: title,
      stemEndsAtBranch: stemEndsAtBranch,
      trailing: _buildAISubCheck(value: value),
      // 整行可点，与勾选圈本身等效（子行没有二级页面，没有跳转语义）
      onTap: () => onChanged(!value),
    );
  }

  /// 子选项的勾选圈：勾选 = 蓝色主题实心 + 白色对勾 + 一圈高光描边，
  /// 未勾选 = 灰色空心圈。比父项的 Switch 明显轻一档，
  /// 避免子项和总开关在视觉重量上打架。
  ///
  /// 外层套一个与父项 Switch 盒子同宽（60）的居中区，使圆心与开关中心同轴
  /// ——否则 22 的圈靠右对齐会比开关中心右偏一截。
  ///
  /// 启用时对勾走「淡入 + 描边逐段画出」，两层同 duration 同 curve 叠在
  /// 一起（见 [_CheckMarkPainter]）；圈圈本身尺寸恒定
  /// （槽位常驻，不把勾选状态表达成位移）。
  /// 点击由 [_buildAISubItem] 的整行手势接管，这里不再自带手势，
  /// 以免一次点击被两层识别者各消费一次。
  Widget _buildAISubCheck({required bool value}) {
    const accent = Color(0xFF4A90E2);
    const reveal = Duration(milliseconds: 240);
    final ringColor = value ? accent : AppColors.of(context).textTertiary;
    return SizedBox(
      width: 60,
      child: Center(
        // 高光描边：勾选时外圈浮出一圈半透明主题色环；容器尺寸恒定，
        // 透明↔着色不会推动布局。
        // 30 = 22 本体 + 2×(1.5 描边 + 2.5 留白)：Container 的子区同时被
        // border 和 padding 各内缩一次，所以外框必须把两层都算进去，
        // 否则本体只有 19（实测 28/3/1.5 那版被压到 16）。
        child: AnimatedContainer(
          duration: reveal,
          curve: Curves.easeOutCubic,
          width: 30,
          height: 30,
          padding: const EdgeInsets.all(2.5),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color:
                  value ? accent.withValues(alpha: 0.32) : Colors.transparent,
              width: 1.5,
            ),
          ),
          child: AnimatedContainer(
            duration: reveal,
            curve: Curves.easeOutCubic,
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: value ? accent : Colors.transparent,
              border: Border.all(color: ringColor, width: 1.5),
            ),
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0.0, end: value ? 1.0 : 0.0),
              duration: reveal,
              curve: Curves.easeOutCubic,
              builder: (context, t, _) =>
                  CustomPaint(painter: _CheckMarkPainter(progress: t)),
            ),
          ),
        ),
      ),
    );
  }

  /// 「个性化 → 界面风格」三段可拖动滑块：浅色 / 深色 / 跟随
  /// （复用与思考强度/视觉能力支持同款的 SegmentedSelector）。
  /// 宽度按三段两字标签收缩（150），给标题让位，避免「界面风格」截断
  Widget _buildThemeModeSelector() {
    return SizedBox(
      width: 150,
      child: SegmentedSelector<ThemeMode>(
        whiteKnobInLight: true,
        items: const [
          SegmentItem(label: '浅色', value: ThemeMode.light),
          SegmentItem(label: '深色', value: ThemeMode.dark),
          SegmentItem(label: '跟随', value: ThemeMode.system),
        ],
        activeValue: context.watch<ThemeController>().mode,
        onChanged: (mode) {
          // 震动由 SegmentedSelector 内部统一发一次轻点选反馈，这里不再叠加
          ThemeController.instance.setMode(mode);
        },
      ),
    );
  }

  /// 「任务通知 → 通知文案风格」三段可拖动滑块（轻松 / 严肃 / 鸡血），
  /// 与「界面风格」同款控件、同款白色把手
  Widget _buildCopyStyleSelector() {
    return SizedBox(
      width: 150,
      child: SegmentedSelector<NotificationCopyStyle>(
        whiteKnobInLight: true,
        items: const [
          SegmentItem(label: '轻松', value: NotificationCopyStyle.casual),
          SegmentItem(label: '严肃', value: NotificationCopyStyle.serious),
          SegmentItem(label: '鸡血', value: NotificationCopyStyle.motivational),
        ],
        activeValue: _notificationCopyStyle,
        onChanged: _applyNotificationCopyStyle,
      ),
    );
  }

  Future<bool> _showAIConsentDialog() async {
    final accepted = await AIConsentDialog.show(context);
    if (!mounted || !accepted) return false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('ai_consent_accepted', true);
    setState(() {
      _aiConsentAccepted = true;
    });
    return true;
  }

  Future<bool> _hasAnyAIConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final provider = prefs.getString('ai_provider') ?? '';

    // Agnes AI：需要配置密钥
    if (provider == 'agnes') {
      final key = prefs.getString('agnes_api_key') ?? '';
      return key.isNotEmpty;
    }
    // 内置模型（限时免费）：无需密钥
    if (provider == 'builtin') {
      return true;
    }
    if (provider == 'custom') {
      final url = prefs.getString('custom_api_url') ?? '';
      final key = prefs.getString('custom_api_key') ?? '';
      return url.isNotEmpty && key.isNotEmpty;
    }
    return false;
  }

  /// AI 配置：三个阶段（主菜单 / Agnes / 自定义 API）融合在同一个对话框内，
  /// 实现收在 `dialogs/ai_config_dialog.dart`。这里只负责打开，并在保存后
  /// 刷新设置页自身的展示（「AI配置」项小字与开关状态）
  Future<void> _showDeveloperOptionsDialog() async {
    await showAIConfigDialog(
      context,
      onConfigSaved: () async {
        await _loadAIConfig();
      },
    );
  }

  /// 内置模型（限时免费）卡片：右侧统一样式下拉切换节点 1-4。
  /// 与推荐选项相互独立：未启用时选项框显示"未使用"且菜单无对勾，
  /// 选中任意节点即切换到内置模型（推荐选项随之取消勾选）
  Future<void> _selectSemesterStartDate() async {
    await showBouncyDialog(
      context: context,
      barrierLabel: '选择日期',
      shellPadding: EdgeInsets.zero,
      margin: EdgeInsets.zero,
      builder: (context) {
        final screenWidth = MediaQuery.of(context).size.width;
        final dialogWidth = screenWidth > 400 ? 360.0 : screenWidth * 0.9;
        return SizedBox(
          width: dialogWidth,
          child: AnimatedCalendarDatePicker(
            initialDate: _semesterStartDate,
            firstDate: DateTime(2020),
            lastDate: DateTime(2030),
            onDateChanged: (date) async {
              await StorageService.setSemesterStartDate(date);
              if (!context.mounted) return;
              setState(() {
                _semesterStartDate = date;
              });
              Navigator.pop(context);
            },
          ),
        );
      },
    );
  }

  Future<void> _selectSemesterWeeks() async {
    int selectedWeeks = _semesterWeeks;
    final FixedExtentScrollController scrollController =
        FixedExtentScrollController(initialItem: selectedWeeks - 1);

    await showBouncyDialog(
      context: context,
      barrierLabel: '学期周数',
      shellPadding: const EdgeInsets.all(20),
      // 壳总宽含壳内边距（与旧版 SizedBox(width:) 包壳一致）
      shellWidth: 280,
      margin: EdgeInsets.zero,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return SizedBox(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '学期周数',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: AppColors.of(context).textPrimary,
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
                        selectedWeeks = index + 1;
                      });
                    },
                    childDelegate: ListWheelChildBuilderDelegate(
                      childCount: 30,
                      builder: (context, index) {
                        final week = index + 1;
                        final isSelected = week == selectedWeeks;
                        return Container(
                          alignment: Alignment.center,
                          child: Text(
                            '$week 周',
                            style: TextStyle(
                              fontSize: isSelected ? 18 : 16,
                              fontWeight: isSelected
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                              color: isSelected
                                  ? const Color(0xFF4A90E2)
                                  : AppColors.of(context).textSecondary,
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
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                          side: BorderSide(
                              color: AppColors.of(context).borderWeak),
                        ),
                        child: const Text('取消'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () async {
                          await StorageService.setSemesterWeeks(selectedWeeks);
                          setState(() {
                            _semesterWeeks = selectedWeeks;
                          });
                          if (mounted) Navigator.pop(context);
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF4A90E2),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        child: const Text('保存'),
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

  Future<void> _selectDailyPeriods() async {
    int selectedPeriods = _dailyPeriods;
    final FixedExtentScrollController scrollController =
        FixedExtentScrollController(initialItem: selectedPeriods - 1);

    await showBouncyDialog(
      context: context,
      barrierLabel: '每日节数',
      shellPadding: const EdgeInsets.all(20),
      // 壳总宽含壳内边距（与旧版 SizedBox(width:) 包壳一致）
      shellWidth: 280,
      margin: EdgeInsets.zero,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return SizedBox(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '每日节数',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: AppColors.of(context).textPrimary,
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
                        selectedPeriods = index + 1;
                      });
                    },
                    childDelegate: ListWheelChildBuilderDelegate(
                      childCount: 20,
                      builder: (context, index) {
                        final periods = index + 1;
                        final isSelected = periods == selectedPeriods;
                        return Container(
                          alignment: Alignment.center,
                          child: Text(
                            '$periods 节',
                            style: TextStyle(
                              fontSize: isSelected ? 18 : 16,
                              fontWeight: isSelected
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                              color: isSelected
                                  ? const Color(0xFF4A90E2)
                                  : AppColors.of(context).textSecondary,
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
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                          side: BorderSide(
                              color: AppColors.of(context).borderWeak),
                        ),
                        child: const Text('取消'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () async {
                          await StorageService.setDailyPeriods(selectedPeriods);
                          while (_timeSlots.length < selectedPeriods) {
                            _timeSlots.add({'start': '00:00', 'end': '00:00'});
                          }
                          if (_timeSlots.length > selectedPeriods) {
                            _timeSlots = _timeSlots.sublist(0, selectedPeriods);
                          }
                          await StorageService.setTimeSlots(_timeSlots);
                          setState(() {
                            _dailyPeriods = selectedPeriods;
                          });
                          if (mounted) Navigator.pop(context);
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF4A90E2),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        child: const Text('保存'),
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

  /// 时间段预设（定义见 StorageService.timeSlotPresets）：预设1（12 节）/
  /// 预设2（13 节，每节 45 分钟）。选择预设整体覆盖时间段列表；手动编辑
  /// 任意一节后脱离预设态
  static const Map<String, List<Map<String, String>>> _timeSlotPresets =
      StorageService.timeSlotPresets;

  Future<void> _showTimeSlotsDialog() async {
    // 选择状态全局持久化：切换课表后仍回显上次选择；用户保存过自定义
    // 配置时，下拉列表新增「自定义」项（全局配置，所有课表可读取套用）
    String? selectedPreset;
    final savedSelection = StorageService.getTimePresetSelection();
    final hasCustomSlots =
        StorageService.getCustomTimeSlots()?.isNotEmpty ?? false;
    if (savedSelection == '预设1' || savedSelection == '预设2') {
      selectedPreset = savedSelection;
    } else if (savedSelection == '自定义' && hasCustomSlots) {
      selectedPreset = '自定义';
    }
    await showBouncyDialog(
      context: context,
      barrierLabel: '时间段设置',
      shellPadding: const EdgeInsets.all(24),
      // 壳总宽/总高约束含壳内边距（与旧版壳外 Container(constraints:) 一致）
      shellMaxWidth: 400,
      shellMaxHeight: 500,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF4A90E2).withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.schedule_outlined,
                      color: Color(0xFF4A90E2),
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Text(
                    '时间段设置',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  // 预设时间段选项框（参考 AI 配置页内置模型选项）：
                  // 选择预设整体覆盖列表；手动编辑任一节后脱离
                  // 预设态，回显「自定义」；保存过的自定义配置
                  // 会作为「自定义」项进入下拉列表（全局共享）。
                  // 宽度固定预留四字宽，选中态不随文字长短变化
                  Container(
                    width: 100,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(
                      color: AppColors.of(context).panel(0.4),
                      borderRadius: BorderRadius.circular(12),
                      border:
                          Border.all(color: AppColors.of(context).borderWeak),
                    ),
                    child: BlurredDropdown<String>(
                      value: selectedPreset,
                      isExpanded: true,
                      hint: Text(
                        '自定义',
                        style: TextStyle(
                          fontSize: 14,
                          color: AppColors.of(context).textSecondary,
                        ),
                      ),
                      icon: const Icon(
                        Icons.expand_more,
                        color: Color(0xFF4A90E2),
                        size: 18,
                      ),
                      menuWidth: 150,
                      items: [
                        ...['预设1', '预设2'].map(
                          (e) => DropdownMenuItem(
                            value: e,
                            child: Text(
                              e,
                              style: const TextStyle(fontSize: 14),
                            ),
                          ),
                        ),
                        if (hasCustomSlots)
                          const DropdownMenuItem(
                            value: '自定义',
                            child: Text(
                              '自定义',
                              style: TextStyle(fontSize: 14),
                            ),
                          ),
                      ],
                      onChanged: (v) {
                        if (v == null) return;
                        setDialogState(() {
                          selectedPreset = v;
                          if (v == '自定义') {
                            final custom = StorageService.getCustomTimeSlots();
                            if (custom != null && custom.isNotEmpty) {
                              _timeSlots = custom
                                  .map((e) => Map<String, String>.from(e))
                                  .toList();
                            }
                          } else {
                            _timeSlots = _timeSlotPresets[v]!
                                .map((e) => Map<String, String>.from(e))
                                .toList();
                          }
                        });
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Expanded(
                // 节次多于可视高度时上下边缘淡出：滚到中间时两端渐隐，
                // 提示列表里还有节次（原先直接截断，看不出下面还有）
                child: FadingEdgeBox(
                  axis: Axis.vertical,
                  physics: const BouncingScrollPhysics(
                      parent: AlwaysScrollableScrollPhysics()),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: List.generate(_timeSlots.length, (index) {
                      final slot = _timeSlots[index];
                      return Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppColors.of(context).panel(0.4),
                          borderRadius: BorderRadius.circular(10),
                          // 非减弱动态：与右上角预设选择框一致
                          // 的浅灰描边（shade200）；减弱动态维持
                          // shade300 不变
                          border: Border.all(
                            color: _reduceMotionEnabled
                                ? AppColors.of(context).borderWeak
                                : AppColors.of(context).borderWeak,
                          ),
                        ),
                        child: Row(
                          children: [
                            Opacity(
                              opacity: 0.82,
                              child: Container(
                                width: 32,
                                height: 32,
                                decoration: BoxDecoration(
                                  gradient: const LinearGradient(
                                    colors: [
                                      Color(0xFF4A90E2),
                                      Color(0xFF5BA0F2)
                                    ],
                                  ),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Center(
                                  child: Text(
                                    '${index + 1}',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Row(
                                children: [
                                  _buildTimeField(
                                    value: slot['start']!,
                                    onChanged: (v) {
                                      _timeSlots[index]['start'] = v;
                                      // 手动编辑后脱离预设态，
                                      // 选项框回显占位文案
                                      setDialogState(
                                          () => selectedPreset = null);
                                    },
                                  ),
                                  const Padding(
                                    padding:
                                        EdgeInsets.symmetric(horizontal: 8),
                                    child: Text('—'),
                                  ),
                                  _buildTimeField(
                                    value: slot['end']!,
                                    onChanged: (v) {
                                      _timeSlots[index]['end'] = v;
                                      // 手动编辑后脱离预设态，
                                      // 选项框回显占位文案
                                      setDialogState(
                                          () => selectedPreset = null);
                                    },
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    }),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.pop(context),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: BorderSide(
                              color: AppColors.of(context).borderWeak),
                        ),
                      ),
                      child: const Text('取消'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () async {
                        await StorageService.setTimeSlots(_timeSlots);
                        // 每日节数与时间段数量保持一致
                        // （应用预设会改变数量：预设1=12 / 预设2=13）
                        await StorageService.setDailyPeriods(_timeSlots.length);
                        // 选择状态与自定义配置全局持久化（跨课表共享）：
                        // 非预设态保存即写入自定义配置，下拉列表从此
                        // 多出「自定义」项供所有课表套用；预设态仅记录选择
                        if (selectedPreset == null) {
                          await StorageService.setCustomTimeSlots(_timeSlots);
                          await StorageService.setTimePresetSelection('自定义');
                        } else {
                          await StorageService.setTimePresetSelection(
                              selectedPreset!);
                        }
                        if (mounted) {
                          setState(() {});
                        }
                        Navigator.pop(context);
                        toastNotification.show(context, '时间段已保存',
                            type: ToastType.success);
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF4A90E2),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text('保存'),
                    ),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildTimeField({
    required String value,
    required Function(String) onChanged,
  }) {
    return GestureDetector(
      onTap: () async {
        final parts = value.split(':');
        final result = await show3DTimePicker(
          context: context,
          initialHour: int.parse(parts[0]),
          initialMinute: int.parse(parts[1]),
          title: '选择时间',
        );
        if (result != null) {
          onChanged(result.formatted);
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.of(context).panel(0.4),
          borderRadius: BorderRadius.circular(8),
          // 非减弱动态：与右上角预设选择框一致的浅灰描边（shade200）；
          // 减弱动态维持 shade300 不变
          border: Border.all(
            color: _reduceMotionEnabled
                ? AppColors.of(context).borderWeak
                : AppColors.of(context).borderWeak,
          ),
        ),
        child: Text(
          value,
          style: const TextStyle(fontWeight: FontWeight.w500),
        ),
      ),
    );
  }

  Future<void> _showNotificationLeadTimeDialog() async {
    final result = await show3DLeadTimePicker(
      context: context,
      initialDays: _notifyLeadDays,
      initialHours: _notifyLeadHours,
      initialMinutes: _notifyLeadMinutes,
      maxDays: 30,
      title: '设置提前提醒时间',
    );

    if (result == null) return;

    await NotificationService.instance.saveTaskNotificationSettings(
      enabled: _taskNotificationEnabled,
      days: result.days,
      hours: result.hours,
      minutes: result.minutes,
      style: _notificationCopyStyle,
    );

    if (!mounted) return;

    setState(() {
      _notifyLeadDays = result.days;
      _notifyLeadHours = result.hours;
      _notifyLeadMinutes = result.minutes;
    });

    if (_taskNotificationEnabled) {
      await NotificationService.instance
          .rescheduleTaskNotifications(StorageService.getTasks());
    }

    if (mounted) {
      toastNotification.show(context, '提醒时间已更新', type: ToastType.success);
    }
  }

  /// 「课前通知时间」：只允许 7 个固定档位（0 档读作"仅上课时通知"），用与
  /// 「每日节数」同款的三维滚轮单选，不给自由取值。saveSettings 内部已让原生
  /// 重排课前/上课/下课三个闹钟，无需再手动刷新
  Future<void> _showLiveLeadChoiceDialog() async {
    const choices = LiveUpdateService.leadChoices;
    var selected = LiveUpdateService.snapLead(_liveLeadMinutes);
    final scrollController = FixedExtentScrollController(
      initialItem: choices.indexOf(selected),
    );

    await showBouncyDialog(
      context: context,
      barrierLabel: '课前通知时间',
      shellPadding: const EdgeInsets.all(20),
      shellWidth: 280,
      margin: EdgeInsets.zero,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return SizedBox(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '课前通知时间',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: AppColors.of(context).textPrimary,
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
                        selected = choices[index];
                      });
                    },
                    childDelegate: ListWheelChildBuilderDelegate(
                      childCount: choices.length,
                      builder: (context, index) {
                        final minutes = choices[index];
                        final isSelected = minutes == selected;
                        return Container(
                          alignment: Alignment.center,
                          child: Text(
                            LiveUpdateService.instance
                                .formatLeadText(minutes),
                            style: TextStyle(
                              fontSize: isSelected ? 18 : 16,
                              fontWeight: isSelected
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                              color: isSelected
                                  ? const Color(0xFF4A90E2)
                                  : AppColors.of(context).textSecondary,
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
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                          side: BorderSide(
                              color: AppColors.of(context).borderWeak),
                        ),
                        child: const Text('取消'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () async {
                          await LiveUpdateService.instance.saveSettings(
                            enabled: _liveUpdateEnabled,
                            leadMinutes: selected,
                          );
                          if (!mounted) return;
                          setState(() {
                            _liveLeadMinutes = selected;
                          });
                          if (mounted) Navigator.pop(context);
                          if (mounted) {
                            toastNotification.show(
                              context,
                              '课前通知时间已更新',
                              type: ToastType.success,
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
                        child: const Text('保存'),
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

  /// 通知文案风格滑块切换：即时持久化并按新文案重排已调度提醒
  Future<void> _applyNotificationCopyStyle(NotificationCopyStyle style) async {
    if (style == _notificationCopyStyle) return;

    await NotificationService.instance.saveTaskNotificationSettings(
      enabled: _taskNotificationEnabled,
      days: _notifyLeadDays,
      hours: _notifyLeadHours,
      minutes: _notifyLeadMinutes,
      style: style,
    );

    if (!mounted) return;

    setState(() {
      _notificationCopyStyle = style;
    });

    if (_taskNotificationEnabled) {
      await NotificationService.instance
          .rescheduleTaskNotifications(StorageService.getTasks());
    }
  }

  /// 关于对话框（独立）
  void _showAboutDialog() {
    // 关于式弹性对话框：孔洞遮罩（四周压暗、对话框背后白净毛玻璃）+
    // 果冻回弹开闭 + 内容聚焦/化开动画（见 BouncyDialogHost）
    showBouncyDialog(
      context: context,
      barrierLabel: '关于',
      shellPadding: const EdgeInsets.all(24),
      // 减弱动态效果（当前仅对关于对话框生效）：
      // 壳背景仅半透明无模糊、开闭动画不变、移除内容模糊淡入淡出
      reduceMotion: _reduceMotionEnabled,
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Image.asset(
              'assets/coursehub_logo.jpg',
              width: 64,
              height: 64,
              fit: BoxFit.cover,
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'CourseHub',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'v$appVersion',
            style: TextStyle(
              fontSize: 14,
              color: AppColors.of(context).textSecondary,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'AI驱动的学习与日程管理平台',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              color: AppColors.of(context).textSecondary,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Copyright©2026 - CourseHub项目组',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              color: AppColors.of(context).textTertiary,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 6),
          // 联系开发者：点击后向上弹出联系提示气泡
          const _AboutContactLink(),
          const SizedBox(height: 18),
          Row(
            children: [
              // 检查更新：统一灰描边次按钮（确定按钮左侧）
              Expanded(
                child: TextButton(
                  onPressed: () {
                    Navigator.pop(context);
                    showUpdateDialog(context);
                  },
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(color: AppColors.of(context).borderWeak),
                    ),
                  ),
                  child: const Text('检查更新'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(context),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF4A90E2),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
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
  }

  /// 打赏支持对话框：顶部说明文案 → 微信打赏码 → 打赏者名单。
  ///
  /// 打赏码来自 assets/donate/wechat_qr.jpg，长按即把原图存进系统相册
  /// （见 _DonateQrCode）。内容区固定高度、内部可下滑，底部「确定」按钮不随内容滚动。
  void _showDonationDialog() {
    showBouncyDialog(
      context: context,
      barrierLabel: '打赏支持',
      shellPadding: const EdgeInsets.all(24),
      builder: (context) {
        // 0.76：单列打赏码（200）+ 名单在 360x800 一屏内放齐，避免默认就要下滑
        final dialogHeight = MediaQuery.of(context).size.height * 0.76;
        return SizedBox(
          height: dialogHeight,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Center(
                        child: Text(
                          '打赏支持',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        '您的打赏将用于CourseHub的开发测试以及服务器的运行和维护。'
                        '是否打赏不会影响到软件功能的使用。'
                        'CourseHub诚挚感谢每一份支持与信任！',
                        style: TextStyle(
                          fontSize: 14,
                          color: AppColors.of(context).textSecondary,
                          height: 1.6,
                        ),
                      ),
                      const SizedBox(height: 20),
                      const Center(
                        child: _DonateQrCode(
                          label: '微信',
                          assetPath: 'assets/donate/wechat_qr.jpg',
                        ),
                      ),
                      const SizedBox(height: 22),
                      const _DonationSupporterList(),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(context),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF4A90E2),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text('确定'),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _clearAllData() async {
    final confirmed = await showBouncyDialog<bool>(
      context: context,
      barrierLabel: '清除数据',
      shellPadding: const EdgeInsets.all(24),
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.red.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(
              Icons.warning_amber_rounded,
              color: Colors.red.shade400,
              size: 40,
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            '清除数据',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '确定要删除所有数据吗？\n此操作不可恢复。',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              color: AppColors.of(context).textSecondary,
            ),
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(color: AppColors.of(context).borderWeak),
                    ),
                  ),
                  child: const Text('取消'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(context, true),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text('删除'),
                ),
              ),
            ],
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await StorageService.clearAllData();
      _loadSettings();
      if (mounted) {
        toastNotification.show(context, '数据已清除', type: ToastType.success);
      }
    }
  }

  /// 邮箱登录 / 注册对话框：表单实现统一收在
  /// `dialogs/email_login_dialog.dart`，这里只负责弹出 + 登录后的云端同步
  void _showEmailLoginDialog(AuthService auth) {
    showEmailLoginDialog(
      context,
      afterSuccess: (_) async {
        await _handlePostLoginSync();
      },
    );
  }

  Future<void> _handlePostLoginSync() async {
    final cloudSync = CloudSyncService.instance;
    final cloudBackup = await cloudSync.fetchBackup();

    if (!mounted) return;

    if (cloudBackup == null && cloudSync.lastError != null) {
      toastNotification.show(
        context,
        cloudSync.lastError!,
        type: ToastType.error,
      );
      return;
    }

    if (cloudBackup == null) {
      final localData = StorageService.exportAllDataByTimetableName();
      if (!_hasSyncableLocalData(localData)) {
        return;
      }

      final shouldUpload = await _showUploadToCloudDialog();
      if (!mounted || shouldUpload != true) {
        return;
      }

      final localTimetables = StorageService.getTimetables();
      if (localTimetables.isEmpty) {
        toastNotification.show(context, '当前没有可上传的课表', type: ToastType.info);
        return;
      }

      final selectedIds =
          await _showLocalTimetableUploadSelectorDialog(localTimetables);
      if (!mounted || selectedIds == null || selectedIds.isEmpty) {
        return;
      }

      final selectedPayload =
          StorageService.exportSelectedDataByTimetableIds(selectedIds);
      if (!_hasSyncableLocalData(selectedPayload)) {
        toastNotification.show(context, '所选课表没有可上传的数据', type: ToastType.info);
        return;
      }

      await _uploadLocalDataToCloud(
        localData: selectedPayload,
        successMessage: '已上传 ${selectedIds.length} 个课表到云端',
      );
      return;
    }

    final action = await _showCloudSyncChoiceDialog(cloudBackup.updatedAt);
    if (!mounted || action == null || action == _CloudSyncAction.skip) {
      return;
    }

    if (action == _CloudSyncAction.uploadLocalToCloud) {
      await _uploadLocalDataToCloud();
      return;
    }

    if (action != _CloudSyncAction.syncFromCloud) {
      return;
    }

    final timetableNames =
        StorageService.getCloudBackupTimetableNames(cloudBackup.payload);
    if (timetableNames.isEmpty) {
      toastNotification.show(context, '云端备份中未找到可同步课表', type: ToastType.error);
      return;
    }

    final selectedTimetable = await _showCloudTimetableSelectorDialog(
      timetableNames,
      updatedAt: cloudBackup.updatedAt,
    );
    if (!mounted || selectedTimetable == null) {
      return;
    }

    final mode = await _showCloudImportModeDialog(
        cloudBackup.updatedAt, selectedTimetable);
    if (!mounted || mode == null) {
      return;
    }

    final selectedPayload = StorageService.getCloudBackupTimetableData(
      cloudBackup.payload,
      selectedTimetable,
    );
    if (selectedPayload == null) {
      toastNotification.show(context, '选中的课表数据不存在或已损坏', type: ToastType.error);
      return;
    }

    final result = await StorageService.importData(selectedPayload, mode: mode);

    if (!mounted) return;

    if (!result.success) {
      toastNotification.show(
        context,
        result.errorMessage ?? '从云端同步失败，请稍后再试',
        type: ToastType.error,
      );
      return;
    }

    _loadSettings();
    setState(() {});
    toastNotification.show(
      context,
      mode == ImportMode.replace
          ? '已用“$selectedTimetable”覆盖当前课表：${result.summary}'
          : '已将“$selectedTimetable”合并到本地：${result.summary}',
      type: ToastType.success,
    );
  }

  Future<void> _uploadLocalDataToCloud({
    Map<String, dynamic>? localData,
    bool showSuccessToast = true,
    String? successMessage,
  }) async {
    final cloudSync = CloudSyncService.instance;
    final data = localData ?? StorageService.exportAllDataByTimetableName();
    final success = await cloudSync.uploadBackup(data);

    if (!mounted) return;

    if (success) {
      if (showSuccessToast) {
        toastNotification.show(
          context,
          successMessage ?? '本地数据已上传到云端',
          type: ToastType.success,
        );
      }
      return;
    }

    toastNotification.show(
      context,
      cloudSync.lastError ?? '上传云端备份失败，请稍后重试',
      type: ToastType.error,
    );
  }

  bool _hasSyncableLocalData(Map<String, dynamic> data) {
    final courses = data['courses'];
    final tasks = data['tasks'];
    final timetables = data['timetables'];
    final namedTimetables = data['namedTimetables'];
    return (courses is List && courses.isNotEmpty) ||
        (tasks is List && tasks.isNotEmpty) ||
        (timetables is List && timetables.isNotEmpty) ||
        (namedTimetables is Map && namedTimetables.isNotEmpty);
  }

  Future<List<String>?> _showLocalTimetableUploadSelectorDialog(
      List<TimetableInfo> timetables) {
    return showBouncyDialog<List<String>>(
      context: context,
      barrierLabel: '选择上传课表',
      shellPadding: const EdgeInsets.all(24),
      // 壳总宽/总高约束含壳内边距（与旧版壳外 Container(constraints:) 一致）
      shellMaxWidth: 420,
      shellMaxHeight: 560,
      builder: (dialogContext) {
        final selectedIds = timetables.map((t) => t.id).toSet();

        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Opacity(
                  opacity: 0.82,
                  child: Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF4A90E2), Color(0xFF5BA0F2)],
                      ),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Icon(
                      Icons.library_add_check_rounded,
                      size: 32,
                      color: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  '选择要上传的课表',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '可多选，未选中的课表不会上传',
                  style: TextStyle(
                    fontSize: 13,
                    color: AppColors.of(context).textSecondary,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    TextButton(
                      onPressed: () {
                        setDialogState(() {
                          selectedIds
                            ..clear()
                            ..addAll(timetables.map((t) => t.id));
                        });
                      },
                      child: const Text('全选'),
                    ),
                    TextButton(
                      onPressed: () {
                        setDialogState(() {
                          selectedIds.clear();
                        });
                      },
                      child: const Text('清空'),
                    ),
                  ],
                ),
                Flexible(
                  child: ScrollConfiguration(
                    behavior: ScrollConfiguration.of(dialogContext).copyWith(
                      physics: const BouncingScrollPhysics(
                          parent: AlwaysScrollableScrollPhysics()),
                    ),
                    child: ListView.builder(
                      itemCount: timetables.length,
                      itemBuilder: (context, index) {
                        final timetable = timetables[index];
                        final selected = selectedIds.contains(timetable.id);
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: _buildSelectableTimetableTile(
                            title: timetable.name,
                            subtitle:
                                '创建于 ${_formatDateTime(timetable.createdAt)}',
                            selected: selected,
                            onTap: () {
                              setDialogState(() {
                                if (selected) {
                                  selectedIds.remove(timetable.id);
                                } else {
                                  selectedIds.add(timetable.id);
                                }
                              });
                            },
                          ),
                        );
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        onPressed: () => Navigator.pop(dialogContext),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                            side: BorderSide(
                                color: AppColors.of(context).borderWeak),
                          ),
                        ),
                        child: const Text('取消'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: selectedIds.isEmpty
                            ? null
                            : () => Navigator.pop(
                                dialogContext, selectedIds.toList()),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF4A90E2),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: const Text('上传选中课表'),
                      ),
                    ),
                  ],
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<bool?> _showUploadToCloudDialog() {
    return showBouncyDialog<bool>(
      context: context,
      barrierLabel: '云端暂无备份',
      shellPadding: const EdgeInsets.all(24),
      // 壳总宽约束含壳内边距（与旧版壳外 ConstrainedBox(constraints:) 一致）
      shellMaxWidth: 400,
      builder: (dialogContext) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Opacity(
              opacity: 0.82,
              child: Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF4A90E2), Color(0xFF5BA0F2)],
                  ),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(
                  Icons.cloud_upload_rounded,
                  size: 32,
                  color: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              '云端暂无备份',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '检测到当前设备有本地数据，是否立即上传到云端用于后续同步？',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: AppColors.of(context).textSecondary,
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: () => Navigator.pop(dialogContext, false),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side:
                            BorderSide(color: AppColors.of(context).borderWeak),
                      ),
                    ),
                    child: const Text('暂不上传'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () => Navigator.pop(dialogContext, true),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF4A90E2),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text('上传到云端'),
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  Future<_CloudSyncAction?> _showCloudSyncChoiceDialog(DateTime? updatedAt) {
    return showBouncyDialog<_CloudSyncAction>(
      context: context,
      barrierLabel: '检测到云端数据',
      shellPadding: const EdgeInsets.all(24),
      // 壳总宽约束含壳内边距（与旧版壳外 ConstrainedBox(constraints:) 一致）
      shellMaxWidth: 420,
      builder: (dialogContext) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Opacity(
              opacity: 0.82,
              child: Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF4A90E2), Color(0xFF5BA0F2)],
                  ),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(
                  Icons.cloud_done_rounded,
                  size: 32,
                  color: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              '检测到云端数据',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '云端最后更新时间：${_formatDateTime(updatedAt)}',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: AppColors.of(context).textSecondary,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 20),
            _buildAccountSyncActionTile(
              icon: Icons.cloud_download_rounded,
              color: Colors.green,
              title: '从云端同步到本地',
              subtitle: '先选课表，再选合并或覆盖模式',
              onTap: () =>
                  Navigator.pop(dialogContext, _CloudSyncAction.syncFromCloud),
            ),
            const SizedBox(height: 10),
            _buildAccountSyncActionTile(
              icon: Icons.cloud_upload_rounded,
              color: const Color(0xFF4A90E2),
              title: '本地覆盖云端',
              subtitle: '使用当前本地数据覆盖云端备份',
              onTap: () => Navigator.pop(
                  dialogContext, _CloudSyncAction.uploadLocalToCloud),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: () =>
                    Navigator.pop(dialogContext, _CloudSyncAction.skip),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(color: AppColors.of(context).borderWeak),
                  ),
                ),
                child: const Text('稍后再说'),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<String?> _showCloudTimetableSelectorDialog(
    List<String> timetableNames, {
    DateTime? updatedAt,
  }) {
    return showBouncyDialog<String>(
      context: context,
      barrierLabel: '选择要同步的课表',
      shellPadding: const EdgeInsets.all(24),
      // 壳总宽/总高约束含壳内边距（与旧版壳外 ConstrainedBox(constraints:) 一致）
      shellMaxWidth: 420,
      shellMaxHeight: 520,
      builder: (dialogContext) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Opacity(
              opacity: 0.82,
              child: Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF4A90E2), Color(0xFF5BA0F2)],
                  ),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(
                  Icons.list_alt_rounded,
                  size: 32,
                  color: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              '选择要同步的课表',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '云端更新时间：${_formatDateTime(updatedAt)}',
              style: TextStyle(
                fontSize: 13,
                color: AppColors.of(context).textSecondary,
              ),
            ),
            const SizedBox(height: 16),
            Flexible(
              child: ScrollConfiguration(
                behavior: ScrollConfiguration.of(dialogContext).copyWith(
                  physics: const BouncingScrollPhysics(
                      parent: AlwaysScrollableScrollPhysics()),
                ),
                child: SingleChildScrollView(
                  child: Column(
                    children: timetableNames
                        .map(
                          (name) => Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: _buildAccountSyncActionTile(
                              icon: Icons.calendar_month_rounded,
                              color: const Color(0xFF4A90E2),
                              title: name,
                              subtitle: '同步此课表到当前设备',
                              onTap: () => Navigator.pop(dialogContext, name),
                            ),
                          ),
                        )
                        .toList(),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(color: AppColors.of(context).borderWeak),
                  ),
                ),
                child: const Text('取消'),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<ImportMode?> _showCloudImportModeDialog(
      DateTime? updatedAt, String timetableName) {
    return showBouncyDialog<ImportMode>(
      context: context,
      barrierLabel: '选择同步方式',
      shellPadding: const EdgeInsets.all(24),
      // 壳总宽约束含壳内边距（与旧版壳外 ConstrainedBox(constraints:) 一致）
      shellMaxWidth: 420,
      builder: (dialogContext) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Opacity(
              opacity: 0.82,
              child: Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF4A90E2), Color(0xFF5BA0F2)],
                  ),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(
                  Icons.settings_suggest_rounded,
                  size: 32,
                  color: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              '选择同步方式',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '已选择课表：$timetableName',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: AppColors.of(context).textSecondary,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 4),
            Text(
              '云端更新时间：${_formatDateTime(updatedAt)}',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: AppColors.of(context).textSecondary,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 20),
            _buildAccountSyncActionTile(
              icon: Icons.merge_type,
              color: Colors.green,
              title: '合并到本地',
              subtitle: '保留本地数据并补充云端数据',
              onTap: () => Navigator.pop(dialogContext, ImportMode.merge),
            ),
            const SizedBox(height: 10),
            _buildAccountSyncActionTile(
              icon: Icons.system_update_alt_rounded,
              color: Colors.orange,
              title: '云端覆盖本地',
              subtitle: '清空当前课表后导入该云端课表',
              onTap: () => Navigator.pop(dialogContext, ImportMode.replace),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(color: AppColors.of(context).borderWeak),
                  ),
                ),
                child: const Text('取消'),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildAccountSyncActionTile({
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: Ink(
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.2)),
        ),
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, color: color, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: color,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.of(context).textSecondary,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right,
                    color: AppColors.of(context).textTertiary),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSelectableTimetableTile({
    required String title,
    required String subtitle,
    required bool selected,
    required VoidCallback onTap,
    Color selectedColor = const Color(0xFF4A90E2),
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: AnimatedContainer(
        key: ValueKey(Theme.of(context).brightness),
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: selected
              ? selectedColor.withValues(alpha: 0.12)
              : AppColors.of(context).panel(0.4),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? selectedColor : AppColors.of(context).panel(0.4),
            width: selected ? 1.6 : 1.0,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: selected ? selectedColor : Colors.transparent,
                borderRadius: BorderRadius.circular(7),
                border: Border.all(
                  color: selected
                      ? selectedColor
                      : AppColors.of(context).textTertiary,
                ),
              ),
              child: selected
                  ? const Icon(Icons.check, size: 16, color: Colors.white)
                  : null,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: selected
                          ? selectedColor
                          : AppColors.of(context).textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.of(context).textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDateTime(DateTime? time) {
    if (time == null) {
      return '未知';
    }
    final local = time.toLocal();
    return '${local.year}-${_twoDigits(local.month)}-${_twoDigits(local.day)} ${_twoDigits(local.hour)}:${_twoDigits(local.minute)}';
  }

  String _twoDigits(int value) {
    return value.toString().padLeft(2, '0');
  }

  void _showLogoutDialog(AuthService auth) {
    showBouncyDialog(
      context: context,
      barrierLabel: '退出登录',
      shellPadding: const EdgeInsets.all(24),
      builder: (context) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(
                Icons.logout_rounded,
                color: Colors.orange.shade400,
                size: 40,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              '退出登录',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '退出后本地数据仍保留，云端数据不会删除',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: AppColors.of(context).textSecondary,
              ),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: () => Navigator.pop(context),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side:
                            BorderSide(color: AppColors.of(context).borderWeak),
                      ),
                    ),
                    child: const Text('取消'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: auth.isLoading
                        ? null
                        : () async {
                            Navigator.pop(context);
                            await auth.signOut();
                            if (mounted) {
                              toastNotification.show(context, '已退出登录',
                                  type: ToastType.info);
                            }
                          },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.orange,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: Text(auth.isLoading ? '退出中...' : '确认退出'),
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// 子选项左侧的树状分支连接线（├ / └）：竖干贴着父项图标底座的中线落下，
/// 以圆角拐出横臂指向子项标题。逐行各画各的，相邻行的竖干首尾相接，
/// 因此中间行必须一路画到行底，只有末行画到拐角起弧处即止。
class _BranchConnectorPainter extends CustomPainter {
  const _BranchConnectorPainter({
    required this.color,
    required this.stemEndsAtBranch,
  });

  final Color color;

  /// true = 末行（└）：竖干到分支口停止；false = 中间行（├）：贯穿整行
  final bool stemEndsAtBranch;

  /// 竖干所在的 x：父项 contentPadding 12 + 图标底座一半 15，减去本行
  /// 已有的 12 左边距，即分支区内的 15
  static const double _stemX = 15;

  /// 肘部圆角半径
  static const double _radius = 6;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    final branchY = size.height / 2;
    // 起弧点：竖干上、比横臂高出一个半径的位置
    final elbowTop = branchY - _radius;

    // 竖干：末行到起弧处即止，中间行贯穿整行以衔接下一行
    canvas.drawLine(
      const Offset(_stemX, 0),
      Offset(_stemX, stemEndsAtBranch ? elbowTop : size.height),
      paint,
    );

    // 横臂：自竖干以圆角拐出。圆心在 (stemX + r, elbowTop)，
    // 其正西点即起弧点、正南点即横臂所在高度
    final arm = Path()
      ..moveTo(_stemX, elbowTop)
      ..arcTo(
        Rect.fromCircle(
          center: Offset(_stemX + _radius, elbowTop),
          radius: _radius,
        ),
        math.pi,
        -math.pi / 2,
        false,
      )
      ..lineTo(size.width, branchY);
    canvas.drawPath(arm, paint);
  }

  @override
  bool shouldRepaint(_BranchConnectorPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.stemEndsAtBranch != stemEndsAtBranch;
}

/// 勾选圈里的对勾：在淡入之外再叠一层「沿路径逐段描出」的打勾动画，
/// 两者共用同一个 progress（同 duration 同 curve 由外层 TweenAnimationBuilder 给）。
///
/// 顶点按盒子尺寸归一化（CustomPaint 拿到的是圈的去边内容区，
/// 不写死像素），路径只有两段直线，逐帧重建 metrics 的开销可以忽略。
class _CheckMarkPainter extends CustomPainter {
  const _CheckMarkPainter({required this.progress});

  /// 0 = 完全不可见，1 = 描满且不透明
  final double progress;

  static const List<Offset> _unit = [
    Offset(0.22, 0.52),
    Offset(0.42, 0.70),
    Offset(0.78, 0.34),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0 || size.isEmpty) return;
    final path = Path()
      ..moveTo(_unit[0].dx * size.width, _unit[0].dy * size.height)
      ..lineTo(_unit[1].dx * size.width, _unit[1].dy * size.height)
      ..lineTo(_unit[2].dx * size.width, _unit[2].dy * size.height);
    final t = progress.clamp(0.0, 1.0);
    final metric = path.computeMetrics().first;
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: t)
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    // 本 SDK 的 PathMetric 用 extractPath(start, end) 取子路径
    canvas.drawPath(
      metric.extractPath(0, metric.length * t),
      paint,
    );
  }

  @override
  bool shouldRepaint(_CheckMarkPainter oldDelegate) =>
      oldDelegate.progress != progress;
}

class _VideoThumbnail extends StatefulWidget {
  final String path;
  const _VideoThumbnail({required this.path});

  // 全局缓存：path -> controller，避免每次打开对话框都重新初始化视频播放器
  static final Map<String, VideoPlayerController> _cache = {};

  static void disposeAll() {
    for (final c in _cache.values) {
      c.dispose();
    }
    _cache.clear();
  }

  @override
  State<_VideoThumbnail> createState() => _VideoThumbnailState();
}

class _VideoThumbnailState extends State<_VideoThumbnail> {
  VideoPlayerController? _controller;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    final cached = _VideoThumbnail._cache[widget.path];
    if (cached != null) {
      _controller = cached;
      if (_controller!.value.isInitialized) {
        _initialized = true;
        _controller!.pause();
      } else {
        _controller!.addListener(_onControllerUpdate);
      }
    } else {
      _controller = VideoPlayerController.file(File(widget.path));
      _VideoThumbnail._cache[widget.path] = _controller!;
      _controller!.initialize().then((_) {
        _controller!.seekTo(Duration.zero);
        _controller!.pause();
        if (mounted) setState(() => _initialized = true);
      });
    }
  }

  void _onControllerUpdate() {
    if (_controller != null && _controller!.value.isInitialized && mounted) {
      _controller!.removeListener(_onControllerUpdate);
      _controller!.seekTo(Duration.zero);
      _controller!.pause();
      setState(() => _initialized = true);
    }
  }

  @override
  void dispose() {
    // 不释放 controller，保留在缓存中供下次复用
    _controller?.removeListener(_onControllerUpdate);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_initialized &&
        _controller != null &&
        _controller!.value.isInitialized) {
      final videoW = _controller!.value.size.width;
      final videoH = _controller!.value.size.height;
      return Stack(
        fit: StackFit.expand,
        children: [
          ClipRect(
            child: FittedBox(
              fit: BoxFit.cover,
              alignment: Alignment.center,
              child: SizedBox(
                width: videoW,
                height: videoH,
                child: VideoPlayer(_controller!),
              ),
            ),
          ),
          // 播放图标覆盖层，表明这是视频
          Center(
            child: Container(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.35),
                shape: BoxShape.circle,
              ),
              padding: const EdgeInsets.all(6),
              child:
                  const Icon(Icons.play_arrow, color: Colors.white, size: 18),
            ),
          ),
        ],
      );
    }
    return Container(
      color: Colors.black,
      child: const Center(
        child: SizedBox(
          width: 16,
          height: 16,
          child:
              CircularProgressIndicator(strokeWidth: 2, color: Colors.white54),
        ),
      ),
    );
  }
}

/// 设置项问号提示气泡：自问号图标处向下弹出（下滑出 + 淡入），
/// 收回时向上缩回图标处并淡出；样式与动画曲线同菜单问号提示
/// （easeOutBack 弹出 / easeInCubic 收回，220ms）
class _SettingsInfoTip extends StatefulWidget {
  final bool visible;
  final String text;
  final double left;
  final double top;
  final VoidCallback? onDismissed;

  const _SettingsInfoTip({
    required this.visible,
    required this.text,
    required this.left,
    required this.top,
    this.onDismissed,
  });

  @override
  State<_SettingsInfoTip> createState() => _SettingsInfoTipState();
}

class _SettingsInfoTipState extends State<_SettingsInfoTip>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );

  // 与菜单问号提示同款曲线：弹出轻微回弹，收回缩回锚点处
  late final CurvedAnimation _curved = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutBack,
    reverseCurve: Curves.easeInCubic,
  );

  @override
  void initState() {
    super.initState();
    if (widget.visible) {
      _controller.forward();
    }
  }

  @override
  void didUpdateWidget(covariant _SettingsInfoTip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible == oldWidget.visible) return;
    if (widget.visible) {
      _controller.forward();
    } else {
      _controller.reverse().whenCompleteOrCancel(() {
        if (mounted) widget.onDismissed?.call();
      });
    }
  }

  @override
  void dispose() {
    _curved.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 智能换行：气泡自问号处向右展开，最大宽度不超过屏幕宽度
    // 减去左偏移和 16px 右边距，窄屏时长文字自动折行
    final maxTipWidth = MediaQuery.of(context).size.width - widget.left - 16;
    return Positioned(
      left: widget.left,
      top: widget.top,
      child: AnimatedBuilder(
        animation: _curved,
        builder: (context, child) {
          final t = _curved.value;
          return Opacity(
            // easeOutBack 会过冲超过 1.0，透明度需夹取
            opacity: t.clamp(0.0, 1.0),
            child: Transform.translate(
              // 自问号图标处（上方）向下滑出；收回时向上缩回图标处
              offset: Offset(0, -14 * (1 - t)),
              child: Transform.scale(
                // 顶部对齐缩放：视觉上自图标处向下展开/向上收起（同菜单问号动效）
                scale: 0.85 + 0.15 * t,
                alignment: Alignment.topCenter,
                child: child,
              ),
            ),
          );
        },
        child: Material(
          color: Colors.transparent,
          child: Container(
            constraints: BoxConstraints(maxWidth: maxTipWidth),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.of(context).surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.of(context).borderWeak),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.15),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Text(
              widget.text,
              style: TextStyle(
                fontSize: 12,
                color: AppColors.of(context).textSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TitleHelpIcon extends StatefulWidget {
  final String text;

  const _TitleHelpIcon({required this.text});

  @override
  State<_TitleHelpIcon> createState() => _TitleHelpIconState();
}

class _TitleHelpIconState extends State<_TitleHelpIcon> {
  final GlobalKey _iconKey = GlobalKey();
  OverlayEntry? _tipEntry;
  bool _tipVisible = false;

  void _toggleTip() {
    if (_tipEntry != null) {
      _removeTip();
      return;
    }
    final iconBox = _iconKey.currentContext?.findRenderObject() as RenderBox?;
    if (iconBox == null) return;
    final iconPos = iconBox.localToGlobal(Offset.zero);
    final iconSize = iconBox.size;
    final screenWidth = MediaQuery.of(context).size.width;
    // 气泡左缘大致对齐问号左侧，整体夹在屏幕内（右侧留 16px 边距）
    final left = (iconPos.dx - 12)
        .clamp(16.0, (screenWidth - 216).clamp(16.0, double.infinity))
        .toDouble();
    final top = iconPos.dy + iconSize.height + 6;
    _tipVisible = true;
    _tipEntry = OverlayEntry(
      builder: (context) => Stack(
        children: [
          // 透明屏障：点击气泡以外的任意处收回
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _removeTip,
            ),
          ),
          _SettingsInfoTip(
            visible: _tipVisible,
            text: widget.text,
            left: left,
            top: top,
            onDismissed: () {
              _tipEntry?.remove();
              _tipEntry = null;
            },
          ),
        ],
      ),
    );
    Overlay.of(context).insert(_tipEntry!);
  }

  void _removeTip() {
    if (_tipEntry == null) return;
    // 翻转 visible 触发收回动画，动画完成后由 onDismissed 移除 entry
    _tipVisible = false;
    _tipEntry!.markNeedsBuild();
  }

  @override
  void dispose() {
    // 对话框关闭时同步移除气泡
    _tipEntry?.remove();
    _tipEntry = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: _iconKey,
      behavior: HitTestBehavior.opaque,
      onTap: _toggleTip,
      child: Icon(
        Icons.help_outline,
        size: 16,
        color: AppColors.of(context).textTertiary,
      ),
    );
  }
}

/// Agnes AI 推荐说明气泡：自问号下方向下弹出，收回时向上缩回
/// 关于对话框「联系开发者」链接：点击后向上弹出联系提示气泡
/// （样式与动画参考减弱动态效果问号提示框），点击空白处收回
class _AboutContactLink extends StatefulWidget {
  const _AboutContactLink();

  @override
  State<_AboutContactLink> createState() => _AboutContactLinkState();
}

class _AboutContactLinkState extends State<_AboutContactLink> {
  final GlobalKey _linkKey = GlobalKey();
  OverlayEntry? _tipEntry;
  bool _tipVisible = false;

  void _toggleTip() {
    if (_tipEntry != null) {
      _removeTip();
      return;
    }
    final linkBox = _linkKey.currentContext?.findRenderObject() as RenderBox?;
    if (linkBox == null) return;
    final linkPos = linkBox.localToGlobal(Offset.zero);
    final linkCenter = linkPos.dx + linkBox.size.width / 2;
    final screenSize = MediaQuery.of(context).size;
    // 气泡宽度固定 280（窄屏收缩），水平居中于链接文字并夹在屏幕内
    final tipWidth =
        screenSize.width - 32 < 280 ? screenSize.width - 32 : 280.0;
    final left = (linkCenter - tipWidth / 2)
        .clamp(
          16.0,
          (screenSize.width - tipWidth - 16).clamp(16.0, double.infinity),
        )
        .toDouble();
    // 气泡底缘位于链接文字上方 8px（向上弹出）
    final bottom = screenSize.height - linkPos.dy + 8;
    _tipVisible = true;
    _tipEntry = OverlayEntry(
      builder: (context) => Stack(
        children: [
          // 透明屏障：点击气泡以外的任意处收回
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _removeTip,
            ),
          ),
          _AboutContactTip(
            visible: _tipVisible,
            left: left,
            bottom: bottom,
            width: tipWidth,
            onDismissed: () {
              _tipEntry?.remove();
              _tipEntry = null;
            },
          ),
        ],
      ),
    );
    Overlay.of(context).insert(_tipEntry!);
  }

  void _removeTip() {
    if (_tipEntry == null) return;
    // 翻转 visible 触发收回动画，动画完成后由 onDismissed 移除 entry
    _tipVisible = false;
    _tipEntry!.markNeedsBuild();
  }

  @override
  void dispose() {
    // 对话框关闭时同步移除气泡
    _tipEntry?.remove();
    _tipEntry = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: _linkKey,
      onTap: _toggleTip,
      behavior: HitTestBehavior.opaque,
      child: Text(
        '联系开发者',
        style: TextStyle(
          fontSize: 12,
          color: AppColors.of(context).textTertiary,
          decoration: TextDecoration.underline,
          decorationColor: AppColors.of(context).textTertiary,
        ),
      ),
    );
  }
}

/// 联系开发者提示气泡：自链接文字处向上弹出，收回时向下缩回
class _AboutContactTip extends StatefulWidget {
  final bool visible;
  final double left;
  final double bottom;
  final double width;
  final VoidCallback? onDismissed;

  const _AboutContactTip({
    required this.visible,
    required this.left,
    required this.bottom,
    required this.width,
    this.onDismissed,
  });

  @override
  State<_AboutContactTip> createState() => _AboutContactTipState();
}

class _AboutContactTipState extends State<_AboutContactTip>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );

  // 与问号提示同款曲线：弹出轻微回弹，收回缩回锚点处
  late final CurvedAnimation _curved = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutBack,
    reverseCurve: Curves.easeInCubic,
  );

  @override
  void initState() {
    super.initState();
    if (widget.visible) {
      _controller.forward();
    }
  }

  @override
  void didUpdateWidget(covariant _AboutContactTip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible == oldWidget.visible) return;
    if (widget.visible) {
      _controller.forward();
    } else {
      _controller.reverse().whenCompleteOrCancel(() {
        if (mounted) widget.onDismissed?.call();
      });
    }
  }

  @override
  void dispose() {
    _curved.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: widget.left,
      bottom: widget.bottom,
      child: AnimatedBuilder(
        animation: _curved,
        builder: (context, child) {
          final t = _curved.value;
          return Opacity(
            // easeOutBack 会过冲超过 1.0，透明度需夹取
            opacity: t.clamp(0.0, 1.0),
            child: Transform.translate(
              // 自链接文字处（下方）向上弹出；收回时向下缩回链接处
              offset: Offset(0, 14 * (1 - t)),
              child: Transform.scale(
                // 底部对齐缩放：视觉上自链接处向上展开/向下收起
                scale: 0.85 + 0.15 * t,
                alignment: Alignment.bottomCenter,
                child: child,
              ),
            ),
          );
        },
        child: Material(
          color: Colors.transparent,
          child: Container(
            width: widget.width,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.of(context).surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.of(context).borderWeak),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.15),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '如在使用中遇到问题，想要反馈Bug、获取新功能，甚至成为我们的一员，欢迎通过如下方式联系我：',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.of(context).textSecondary,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 8),
                // 点击复制邮箱
                GestureDetector(
                  onTap: () {
                    Clipboard.setData(
                        const ClipboardData(text: 'zwt70@outlook.com'));
                    HapticFeedback.selectionClick();
                    toastNotification.show(
                      context,
                      '邮箱已复制',
                      type: ToastType.success,
                    );
                  },
                  child: Text(
                    '邮箱：zwt70@outlook.com',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.of(context).textSecondary,
                      height: 1.5,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                // 点击复制QQ号
                GestureDetector(
                  onTap: () {
                    Clipboard.setData(const ClipboardData(text: '1831657335'));
                    HapticFeedback.selectionClick();
                    toastNotification.show(
                      context,
                      'QQ号已复制',
                      type: ToastType.success,
                    );
                  },
                  child: Text(
                    'QQ：1831657335',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.of(context).textSecondary,
                      height: 1.5,
                    ),
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

/// 打赏码：展示 assets/donate/ 下的微信收款码，长按把原图保存到系统相册。
///
/// 保存走 gal：Android 由 MediaStore 写入「图片/CourseHub」，Android 10+ 免权限，
/// Android 6~9 首次会申请写存储权限（清单里以 maxSdkVersion=28 声明）；iOS 与
/// 桌面端写入系统图片目录。资源缺失时由 errorBuilder 回落为占位框。
class _DonateQrCode extends StatefulWidget {
  const _DonateQrCode({required this.label, required this.assetPath});

  final String label;
  final String assetPath;

  @override
  State<_DonateQrCode> createState() => _DonateQrCodeState();
}

class _DonateQrCodeState extends State<_DonateQrCode> {
  /// 保存中标记，兼作重复长按的去抖：gal 每次写入都新建文件（同名自动追加序号），
  /// 连点会在相册里留下一串重复的打赏码
  bool _saving = false;

  Future<void> _saveToAlbum() async {
    if (_saving) return;
    setState(() => _saving = true);
    HapticFeedback.mediumImpact();

    String? failure;
    try {
      // Android 6~9 需写存储权限（首次弹系统框）；Android 10+ 恒为已授权，不打扰
      if (!await Gal.hasAccess() && !await Gal.requestAccess()) {
        failure = '未授予存储权限，无法保存';
      } else {
        final byteData = await rootBundle.load(widget.assetPath);
        await Gal.putImageBytes(
          byteData.buffer.asUint8List(),
          album: 'CourseHub',
          name: 'coursehub_donate_qr',
        );
      }
    } on GalException catch (e) {
      failure = switch (e.type) {
        GalExceptionType.accessDenied => '未授予相册权限，无法保存',
        GalExceptionType.notEnoughSpace => '存储空间不足，保存失败',
        _ => '保存失败，请稍后重试',
      };
      debugPrint('[donate] gal 保存失败: $e');
    } catch (e) {
      failure = '保存失败，请稍后重试';
      debugPrint('[donate] 读取打赏码失败: $e');
    }

    if (!mounted) return;
    setState(() => _saving = false);
    toastNotification.show(
      context,
      failure ?? '打赏码已保存到相册',
      type: failure == null ? ToastType.success : ToastType.error,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onLongPress: _saveToAlbum,
          behavior: HitTestBehavior.opaque,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 150),
            opacity: _saving ? 0.6 : 1,
            child: SizedBox(
              width: 200,
              height: 200,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Container(
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      color: AppColors.of(context).surfaceAlt,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                          color: AppColors.of(context).borderWeak),
                    ),
                    // contain：打赏码不可被裁切，非正方形素材留白而非切边
                    child: Image.asset(
                      widget.assetPath,
                      fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) => Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.qr_code_2,
                              size: 40,
                              color: AppColors.of(context).textTertiary),
                          const SizedBox(height: 6),
                          Text(
                            '打赏码待放置',
                            style: TextStyle(
                                fontSize: 11,
                                color: AppColors.of(context).textTertiary),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (_saving)
                    Center(
                      child: SizedBox(
                        width: 26,
                        height: 26,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.4,
                          color: AppColors.of(context).textSecondary,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          widget.label,
          style: TextStyle(
              fontSize: 13, color: AppColors.of(context).textSecondary),
        ),
        const SizedBox(height: 4),
        Text(
          '长按二维码可保存到相册',
          style: TextStyle(
              fontSize: 11, color: AppColors.of(context).textTertiary),
        ),
      ],
    );
  }
}

/// 打赏者名单区块：左侧微信打赏 ID，右侧打赏金额（￥xx.xx）。
/// 名单来自 CloudBase 静态托管的 donors.json（DonorService），
/// 拉取失败回落本地缓存，从未成功过显示空态。
class _DonationSupporterList extends StatefulWidget {
  const _DonationSupporterList();

  @override
  State<_DonationSupporterList> createState() =>
      _DonationSupporterListState();
}

class _DonationSupporterListState extends State<_DonationSupporterList> {
  List<DonationRecord>? _donors;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // 24 小时内最多刷新一次云端名单，窗口内展示本地缓存（流量优化）
    final donors = await DonorService.fetchDonorsForDisplay();
    if (!mounted) return;
    setState(() => _donors = donors);
  }

  @override
  Widget build(BuildContext context) {
    final donors = _donors ?? const <DonationRecord>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '打赏者名单',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.bold,
            color: AppColors.of(context).textPrimary,
          ),
        ),
        const SizedBox(height: 12),
        if (donors.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 18),
            decoration: BoxDecoration(
              color: AppColors.of(context).surfaceAlt,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.of(context).borderWeak),
            ),
            child: Text(
              '还没有打赏记录，你的支持会出现在这里',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 13, color: AppColors.of(context).textTertiary),
            ),
          )
        else
          Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.of(context).borderWeak),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (int i = 0; i < donors.length; i++) ...[
                  if (i > 0)
                    Divider(height: 1, color: AppColors.of(context).borderWeak),
                  _DonationRecordRow(record: donors[i]),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

class _DonationRecordRow extends StatelessWidget {
  const _DonationRecordRow({required this.record});

  final DonationRecord record;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              record.wechatId,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 14, color: AppColors.of(context).textPrimary),
            ),
          ),
          Text(
            '￥${record.amount.toStringAsFixed(2)}',
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: Color(0xFF4A90E2),
            ),
          ),
        ],
      ),
    );
  }
}
