import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import '../main.dart' show appVersion;
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:video_player/video_player.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../dialogs/ai_consent_dialog.dart';
import '../utils/storage.dart';
import 'timetable_screen.dart';
import '../widgets/animated_calendar.dart';
import '../widgets/glass_dialog.dart';
import 'ai_assistant_screen.dart';
import '../widgets/toast_notification.dart';
import '../widgets/time_picker_dialog.dart';
import '../services/auth_service.dart';
import '../services/wallpaper_storage_service.dart';
import '../services/cloud_sync_service.dart';
import '../services/glm_service.dart';
import '../services/notification_service.dart';
import '../services/update_service.dart';
import '../widgets/blur_selection_menu.dart';
import 'package:url_launcher/url_launcher.dart';

enum _CloudSyncAction {
  syncFromCloud,
  uploadLocalToCloud,
  skip,
}

enum _CustomVisionMode {
  auto,
  enabled,
  disabled,
}

/// 更新阶段（更新对话框）
enum _UpdatePhase {
  checking, // 检查中
  available, // 发现新版本
  upToDate, // 已是最新
  error, // 检查失败
  downloading, // 下载中
  downloaded, // 下载完成
  downloadFailed, // 下载失败
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
  bool _customVisionManualOverride = false;
  bool _customVisionEnabled = false;
  String? _wallpaperPath;
  int _wallpaperOpacity = 100;
  bool _wallpaperEnabled = false;
  bool _wallpaperBlurEnabled = false;
  bool _reduceMotionEnabled = false;

  // 减弱动态效果问号提示：气泡锚点 key 与 Overlay 挂载状态
  final GlobalKey _reduceMotionHelpKey = GlobalKey();
  OverlayEntry? _reduceMotionTipEntry;
  bool _reduceMotionTipVisible = false;

  /// 显示非本周课程（默认开启）：关闭后课表不以灰色卡片显示非本周课程
  bool _showInactiveCourses = true;

  _CustomVisionMode get _customVisionMode {
    if (!_customVisionManualOverride) {
      return _CustomVisionMode.auto;
    }
    return _customVisionEnabled ? _CustomVisionMode.enabled : _CustomVisionMode.disabled;
  }

  static String _customVisionModeLabel(_CustomVisionMode mode) {
    switch (mode) {
      case _CustomVisionMode.auto:
        return '自动';
      case _CustomVisionMode.enabled:
        return '开启';
      case _CustomVisionMode.disabled:
        return '关闭';
    }
  }

  Future<void> _applyCustomVisionMode(_CustomVisionMode mode) async {
    final manualOverride = mode != _CustomVisionMode.auto;
    final supportsVision = mode == _CustomVisionMode.enabled;
    await AIService.instance.setCustomVisionManualOverride(
      enabled: manualOverride,
      supportsVision: supportsVision,
    );
    if (!mounted) return;
    setState(() {
      _customVisionManualOverride = manualOverride;
      _customVisionEnabled = supportsVision;
    });
  }

  Widget _buildCustomVisionModeDropdown({
    required _CustomVisionMode value,
    required ValueChanged<_CustomVisionMode> onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        // 灰描边仅减弱动态时显示：正常模式白底经毛玻璃本就有边界
        border: Border.all(
          color: _reduceMotionEnabled ? Colors.grey.shade300 : Colors.white.withValues(alpha: 0.4),
        ),
      ),
      // BlurredDropdown（而非原生 DropdownButton）：原生下拉经子路由显示，
      // 收起时路由焦点恢复会钻回同对话框内的输入框导致键盘反复弹出；
      // BlurredDropdown 打开前已做焦点锚点转移，且与全局毛玻璃风格一致
      child: BlurredDropdown<_CustomVisionMode>(
        value: value,
        icon: const Icon(Icons.expand_more, size: 18, color: Color(0xFF4A90E2)),
        items: _CustomVisionMode.values
            .map((mode) => DropdownMenuItem<_CustomVisionMode>(
                  value: mode,
                  child: Text(
                    _customVisionModeLabel(mode),
                    style: const TextStyle(fontSize: 13),
                  ),
                ))
            .toList(),
        onChanged: (next) {
          if (next != null) {
            onChanged(next);
          }
        },
      ),
    );
  }

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
    if (mounted) {
      setState(() {
        _reduceMotionEnabled = reduceMotion;
        _showInactiveCourses = showInactive;
      });
    } else {
      _reduceMotionEnabled = reduceMotion;
      _showInactiveCourses = showInactive;
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
                            const Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  '课表壁纸',
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                    color: Color(0xFF1A1A2E),
                                  ),
                                ),
                                SizedBox(width: 6),
                                // 带圈问号：点击向下弹出编辑操作说明气泡
                                _TitleHelpIcon(text: '长按壁纸可编辑，再次点按退出编辑。'),
                              ],
                            ),
                            const SizedBox(height: 16),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.4),
                                borderRadius: BorderRadius.circular(10),
                                // 灰描边仅减弱动态时显示（半透明白底与壳背景融合）
                                border: _reduceMotionEnabled
                                    ? Border.all(color: Colors.grey.shade300)
                                    : null,
                              ),
                              child: Row(
                                children: [
                                  const Expanded(
                                    child: Text(
                                      '自定义壁纸',
                                      style: TextStyle(fontSize: 15, color: Color(0xFF1A1A2E)),
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
                              child: ListView.builder(
                                scrollDirection: Axis.horizontal,
                                physics: const BouncingScrollPhysics(),
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
                                      margin: EdgeInsets.only(right: isBeingDeleted ? 0 : 12),
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
                                          prefs.setStringList('wallpaper_recent_paths', dialogPaths);
                                          if (_wallpaperPath != null && !dialogPaths.contains(_wallpaperPath)) {
                                            _wallpaperPath = null;
                                            prefs.remove('wallpaper_path');
                                          }
                                          setDialogState(() {});
                                        },
                                        child: GestureDetector(
                                          onTap: () {
                                            if (dialogDeleteMode) {
                                              setDialogState(() { dialogDeleteMode = false; });
                                              return;
                                            }
                                            if (!localEnabled) return;
                                            () async {
                                              newWallpaperSelected = true;
                                              await prefs.setString('wallpaper_path', path);
                                              final ext = path.toLowerCase().split('.').last;
                                              final isVideo = ['mp4', 'mov', 'avi', 'mkv', 'webm', '3gp'].contains(ext);
                                              await prefs.setString('wallpaper_type', isVideo ? 'video' : 'image');
                                              if (!_wallpaperEnabled) {
                                                await prefs.setBool('wallpaper_enabled', true);
                                                localEnabled = true;
                                                setState(() {
                                                  _wallpaperEnabled = true;
                                                });
                                              }
                                              setState(() {
                                                _wallpaperPath = path;
                                              });
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
  final ext = file.path.toLowerCase().split('.').last;
  final isVid = ['mp4', 'mov', 'avi', 'mkv', 'webm', '3gp'].contains(ext);
  if (isVid) {
    return _VideoThumbnail(path: file.path);
  }
  return Image.file(file, fit: BoxFit.cover);
})
                                                      : Container(
                                                          color: Colors.white.withValues(alpha: 0.4),
                                                          child: Icon(Icons.broken_image, color: Colors.grey.shade400),
                                                        ),
                                                  Container(
                                                    decoration: BoxDecoration(
                                                      borderRadius: BorderRadius.circular(12),
                                                      border: Border.all(
                                                        color: isActive && localEnabled
                                                            ? const Color(0xFF4A90E2)
                                                            : Colors.white.withValues(alpha: 0.4),
                                                        width: isActive && localEnabled ? 2.5 : 1,
                                                      ),
                                                    ),
                                                  ),
                                                  if (!localEnabled)
                                                    Container(
                                                      color: Colors.white.withValues(alpha: 0.4),
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
                                                            color: Colors.black.withValues(alpha: 0.5),
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
                                            setDialogState(() { dialogDeleteMode = false; });
                                            return;
                                          }
                                          if (!localEnabled) return;
                                          () async {
                                            final result = await FilePicker.platform.pickFiles(
                                              type: FileType.media,
                                            );
                                            if (result != null && result.files.single.path != null) {
                                              // 持久化到应用内部目录，防止清理缓存后壁纸失效
                                              final filePath = await WallpaperStorageService.persistWallpaper(result.files.single.path!);
                                              final extension = filePath.toLowerCase().split('.').last;
                                              final isVideo = ['mp4', 'mov', 'avi', 'mkv', 'webm', '3gp'].contains(extension);
                                              await prefs.setString('wallpaper_type', isVideo ? 'video' : 'image');
                                              newWallpaperSelected = true;
                                              dialogPaths.insert(0, filePath);
                                              if (dialogPaths.length > 5) {
                                                dialogPaths.removeLast();
                                              }
                                              await prefs.setStringList('wallpaper_recent_paths', dialogPaths);
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
                                                color: Colors.white.withValues(alpha: 0.4),
                                                child: Column(
                                                  mainAxisAlignment: MainAxisAlignment.center,
                                                  children: [
                                                    Icon(Icons.add, color: Colors.grey.shade500, size: 32),
                                                    const SizedBox(height: 4),
                                                    Text('添加图片/视频', style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
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
                                                        ? Colors.grey.shade300
                                                        : Colors.white.withValues(alpha: 0.4),
                                                  ),
                                                ),
                                              ),
                                              if (!localEnabled)
                                                Container(
                                                  color: Colors.white.withValues(alpha: 0.4),
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
                                      side: BorderSide(color: Colors.grey.shade300),
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
                            const Text(
                              '背景透明度',
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
                                          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                          color: isSelected ? const Color(0xFF4A90E2) : Colors.grey.shade600,
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
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.4),
                                  borderRadius: BorderRadius.circular(10),
                                  // 灰描边仅减弱动态时显示（半透明白底与壳背景融合）
                                  border: _reduceMotionEnabled
                                      ? Border.all(color: Colors.grey.shade300)
                                      : null,
                                ),
                                child: Row(
                                  children: [
                                    const Expanded(
                                      child: Text(
                                        '卡片模糊',
                                        style: TextStyle(fontSize: 15, color: Color(0xFF1A1A2E)),
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
                                      side: BorderSide(color: Colors.grey.shade300),
                                    ),
                                    child: const Text('取消'),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: ElevatedButton(
                                    onPressed: () async {
                                      final prefs = await SharedPreferences.getInstance();
                                      await prefs.setInt('wallpaper_opacity', selectedOpacity);
                                      await prefs.setBool('wallpaper_blur_enabled', localBlur);
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
    final customVisionManualOverride = prefs.getBool('custom_api_vision_manual_override') ?? false;
    final customVisionEnabled = prefs.getBool('custom_api_vision_manual_value') ?? false;

    // AI配置项小字：按当前提供商显示具体模型信息
    String aiConfigDetail = '开启AI后可用';
    if (providerStr == 'builtin') {
      final node = prefs.getInt('builtin_node') ?? 1;
      aiConfigDetail = '内置模型节点$node';
    } else if (providerStr == 'agnes') {
      final model = prefs.getString('agnes_model') ?? 'agnes-2.0-flash';
      aiConfigDetail = model == 'agnes-2.5-flash' ? 'Agnes 2.5 Flash' : 'Agnes 2.0 Flash';
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
    final settings = await NotificationService.instance.getTaskNotificationSettings();
    if (!mounted) return;
    setState(() {
      _taskNotificationEnabled = settings.enabled;
      _notifyLeadDays = settings.days;
      _notifyLeadHours = settings.hours;
      _notifyLeadMinutes = settings.minutes;
      _notificationCopyStyle = settings.style;
    });
  }

  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.of(context).padding.top;
    
    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FC),
      body: Stack(
        children: [
          NotificationListener<ScrollNotification>(
            // 滚动设置页时收回问号提示气泡，避免气泡与锚点错位
            onNotification: (notification) {
              if (_reduceMotionTipEntry != null &&
                  (notification is ScrollStartNotification ||
                      notification is ScrollUpdateNotification)) {
                _removeReduceMotionTip();
              }
              return false;
            },
            child: CustomScrollView(
            physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
            slivers: [
              SliverPadding(
                padding: EdgeInsets.only(top: topPadding + 56),
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
                          _buildSettingsItem(
                            icon: Icons.calendar_today_outlined,
                            title: '开学日期',
                            subtitle: '${_semesterStartDate.year}年${_semesterStartDate.month}月${_semesterStartDate.day}日',
                            onTap: _selectSemesterStartDate,
                          ),
                          _buildDivider(),
                          _buildSettingsItem(
                            icon: Icons.date_range_outlined,
                            title: '学期周数',
                            subtitle: '$_semesterWeeks 周',
                            onTap: _selectSemesterWeeks,
                          ),
                          _buildDivider(),
                          _buildSettingsItem(
                            icon: Icons.view_week_outlined,
                            title: '当前周次',
                            trailing: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                              decoration: BoxDecoration(
                                color: StorageService.isHoliday()
                                    ? Colors.grey.withValues(alpha: 0.15)
                                    : const Color(0xFF4A90E2).withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                StorageService.isBeforeSemesterStart()
                                    ? '未开始'
                                    : StorageService.getCurrentWeek() > _semesterWeeks
                                        ? '已结束'
                                        : '第 ${StorageService.getCurrentWeek()} 周',
                                style: TextStyle(
                                  color: StorageService.isHoliday()
                                      ? Colors.grey.shade600
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
                          _buildSettingsItem(
                            icon: Icons.access_time_outlined,
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
                            icon: Icons.event_busy_outlined,
                            title: '显示非本周课程',
                            trailing: Switch(
                              value: _showInactiveCourses,
                              activeThumbColor: const Color(0xFF4A90E2),
                              onChanged: (v) async {
                                HapticFeedback.selectionClick();
                                final prefs = await SharedPreferences.getInstance();
                                await prefs.setBool('show_inactive_courses', v);
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
                                icon: Icons.code_rounded,
                                title: '电子邮箱登录',
                                subtitle: auth.isAuthenticated 
                                    ? '已登录 (${auth.userName ?? auth.userEmail ?? "用户"})'
                                  : ((auth.userName ?? auth.userEmail) != null
                                    ? '已退出（上次登录：${auth.userName ?? auth.userEmail}）'
                                    : '登录以同步数据'),
                                trailing: auth.isAuthenticated 
                                    ? TextButton(
                                        onPressed: () => _showLogoutDialog(auth),
                                        child: const Text('退出', style: TextStyle(color: Colors.red)),
                                      )
                                    : null,
                                onTap: auth.isAuthenticated ? null : () => _showEmailLoginDialog(auth),
                              );
                            },
                          ),
                          _buildDivider(),
                          _buildSettingsItem(
                            icon: Icons.notifications_active_outlined,
                            title: '任务临期通知',
                            trailing: Switch(
                              value: _taskNotificationEnabled,
                              onChanged: (value) async {
                                HapticFeedback.selectionClick();

                                if (value) {
                                  final granted = await NotificationService.instance.requestNotificationPermission();
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

                                await NotificationService.instance.saveTaskNotificationSettings(
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
                                  await NotificationService.instance.rescheduleTaskNotifications(StorageService.getTasks());
                                  if (mounted) {
                                    toastNotification.show(context, '任务临期通知已开启', type: ToastType.success);
                                  }
                                } else {
                                  await NotificationService.instance.cancelAllTaskNotifications();
                                  if (mounted) {
                                    toastNotification.show(context, '任务临期通知已关闭', type: ToastType.info);
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
                                    key: const ValueKey('notify-options-visible'),
                                    children: [
                                      _buildDivider(),
                                      _buildSettingsItem(
                                        icon: Icons.timer_outlined,
                                        title: '提前提醒时间',
                                        subtitle: NotificationService.instance
                                            .formatLeadTimeText(_notifyLeadDays, _notifyLeadHours, _notifyLeadMinutes),
                                        onTap: _showNotificationLeadTimeDialog,
                                      ),
                                      _buildDivider(),
                                      _buildSettingsItem(
                                        icon: Icons.style_outlined,
                                        title: '通知文案风格',
                                        subtitle: NotificationService.instance.copyStyleLabel(_notificationCopyStyle),
                                        onTap: _showNotificationCopyStyleDialog,
                                      ),
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
                          _buildSettingsItem(
                            icon: Icons.psychology_outlined,
                            title: 'AI 功能',
                            trailing: Switch(
                              value: _aiEnabled,
                              onChanged: (value) async {
                                HapticFeedback.selectionClick();
                                if (value) {
                                  if (!_aiConsentAccepted) {
                                    final accepted = await _showAIConsentDialog();
                                    if (!accepted) return;
                                  }
                                  final hasConfig = await _hasAnyAIConfig();
                                  if (!hasConfig) {
                                    await _showDeveloperOptionsDialog();
                                  }
                                  final recheckConfig = await _hasAnyAIConfig();
                                  final prefs = await SharedPreferences.getInstance();
                                  if (recheckConfig) {
                                    await prefs.setBool('ai_enabled', true);
                                    if (mounted) setState(() { _aiEnabled = true; });
                                  } else {
                                    await prefs.setBool('ai_enabled', false);
                                    if (mounted) {
                                      setState(() { _aiEnabled = false; });
                                      toastNotification.show(context, '未配置API，AI功能已关闭', type: ToastType.info);
                                    }
                                  }
                                } else {
                                  final prefs = await SharedPreferences.getInstance();
                                  await prefs.setBool('ai_enabled', false);
                                  if (mounted) setState(() { _aiEnabled = false; });
                                }
                              },
                              activeThumbColor: const Color(0xFF4A90E2),
                            ),
                          ),
                          _buildDivider(),
                          _buildSettingsItem(
                            icon: Icons.settings_outlined,
                            title: 'AI配置',
                            // 小字按当前提供商显示具体模型（节点/模型名），
                            // 未开启时提示开启后可用
                            subtitle: _aiEnabled ? _aiConfigDetail : '开启AI后可用',
                            onTap: _aiEnabled ? () => _showDeveloperOptionsDialog() : null,
                          ),
                        ]),
                        const SizedBox(height: 24),
                        _buildSectionTitle('个性化'),
                        const SizedBox(height: 12),
                        _buildSettingsGroup([
                          _buildSettingsItem(
                            icon: Icons.image_outlined,
                            title: '课表壁纸',
                            subtitle: _wallpaperEnabled && _wallpaperPath != null
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
                            subtitle: _wallpaperEnabled ? '$_wallpaperOpacity%' : '开启壁纸功能后可用',
                            onTap: _wallpaperEnabled ? _selectWallpaperOpacity : null,
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
                                    color: Colors.grey.shade500,
                                  ),
                                ),
                              ],
                            ),
                            trailing: Switch(
                              value: _reduceMotionEnabled,
                              activeThumbColor: const Color(0xFF4A90E2),
                              onChanged: (v) async {
                                HapticFeedback.selectionClick();
                                final prefs = await SharedPreferences.getInstance();
                                await prefs.setBool('reduce_motion_enabled', v);
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
                        _buildSectionTitle('数据管理'),
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
          _buildPinnedHeader(topPadding),
        ],
      ),
    );
  }

  Widget _buildPinnedHeader(double topPadding) {
    return Positioned(
      left: 0,
      right: 0,
      top: 0,
      child: ClipRRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFFF8F9FC).withValues(alpha: 0.75),
              border: Border(
                bottom: BorderSide(color: Colors.grey.shade200, width: 0.5),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(height: topPadding),
                const SizedBox(
                  height: 56,
                  child: Center(
                    child: Text(
                      '设置',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF1A1A2E),
                      ),
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

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.bold,
          color: Color(0xFF1A1A2E),
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

  Widget _buildSettingsGroup(List<Widget> items) {
    return Card(
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      child: Column(
        children: items,
      ),
    );
  }

  Widget _buildSettingsItem({
    required IconData icon,
    String? title,
    Widget? titleWidget,
    String? subtitle,
    Widget? trailing,
    bool isDestructive = false,
    VoidCallback? onTap,
  }) {
    return ListTile(
      leading: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: isDestructive
              ? Colors.red.withValues(alpha: 0.1)
              : const Color(0xFF4A90E2).withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(
          icon,
          color: isDestructive ? Colors.red : const Color(0xFF4A90E2),
          size: 20,
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
      trailing: trailing ?? Icon(
        Icons.chevron_right,
        color: Colors.grey.shade400,
      ),
      onTap: onTap,
    );
  }

  Widget _buildDivider() {
    return Divider(
      height: 1,
      indent: 56,
      color: Colors.grey.shade200,
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

  Future<void> _showDeveloperOptionsDialog() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    int agnesNode = prefs.getInt('agnes_node') ?? 1;
    int builtinNode = prefs.getInt('builtin_node') ?? 1;
    return showBouncyDialog(
      context: context,
      barrierLabel: 'AI功能配置',
      shellPadding: const EdgeInsets.all(24),
      shellBoxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.2),
          blurRadius: 20,
          offset: const Offset(0, 10),
        ),
      ],
      avoidKeyboard: true,
      // 壳总宽/总高约束含壳内边距（与旧版壳外 Container(constraints:) 一致）；
      // 键盘弹出时动态压缩最大高度，闭包内 MediaQuery 依赖使宿主自动重建
      shellConstraintsBuilder: (context) {
        final mediaQuery = MediaQuery.of(context);
        final keyboardHeight = mediaQuery.viewInsets.bottom;
        final topInset = mediaQuery.padding.top;
        final screenHeight = mediaQuery.size.height;
        const baseMaxHeight = 555.0;
        double dialogMaxHeight = baseMaxHeight;
        final availableHeight = screenHeight - topInset - keyboardHeight - 24;
        if (availableHeight < dialogMaxHeight) {
          dialogMaxHeight = availableHeight;
        }
        dialogMaxHeight = dialogMaxHeight.clamp(280.0, baseMaxHeight).toDouble();
        return BoxConstraints(maxWidth: 400, maxHeight: dialogMaxHeight);
      },
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              children: [
                                Container(
                                  width: 48,
                                  height: 48,
                                  decoration: BoxDecoration(
                                    color: Colors.grey.shade800,
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: const Icon(
                                    Icons.code,
                                    size: 24,
                                    color: Colors.white,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                const Text(
                                  'AI功能配置',
                                  style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '选择或配置AI服务提供商',
                              style: TextStyle(
                                fontSize: 13,
                                color: Colors.grey.shade600,
                              ),
                            ),
                            const SizedBox(height: 20),
                            Expanded(
                              child: ScrollConfiguration(
                                behavior: ScrollConfiguration.of(context).copyWith(
                                  physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
                                ),
                                child: SingleChildScrollView(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      const SizedBox(height: 8),
                                      // 内置模型（限时免费）：与推荐选项相互独立，
                                      // 选中任意节点即切换到内置模型
                                      _buildBuiltinModelCard(
                                        node: builtinNode,
                                        isBuiltinActive: _isBuiltinProvider,
                                        onNodeSelected: (node) async {
                                          await prefs.setInt('builtin_node', node);
                                          await prefs.setString('ai_provider', 'builtin');
                                          await prefs.setBool('fast_mode_enabled', false);
                                          await prefs.setBool('ai_enabled', true);
                                          // 同步后端服务的节点状态（路由按节点选 endpoint）
                                          await AIService.instance.setBuiltinNode(node);
                                          AIAssistantScreenState.markNeedsRefresh();
                                          await _loadAIConfig();
                                          setDialogState(() {
                                            builtinNode = node;
                                          });
                                        },
                                      ),
                                      const SizedBox(height: 24),
                                      Row(
                                        children: [
                                          Expanded(
                                            child: Container(
                                              height: 1,
                                              color: Colors.white.withValues(alpha: 0.4),
                                            ),
                                          ),
                                          Padding(
                                            padding: const EdgeInsets.symmetric(horizontal: 12),
                                            child: Text(
                                              '推荐选项',
                                              style: TextStyle(
                                                fontSize: 12,
                                                color: Colors.grey.shade500,
                                              ),
                                            ),
                                          ),
                                          Expanded(
                                            child: Container(
                                              height: 1,
                                              color: Colors.white.withValues(alpha: 0.4),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 16),
                                      _buildRecommendedOption(
                                        title: 'Agnes AI',
                                        subtitle: '输入Agnes AI密钥（免费使用），开箱即用',
                                        iconAsset: 'assets/icon/agnes_icon.png',
                                        color: const Color(0xFF4A90E2),
                                        isSelected: _providerConfigured && _isAgnesProvider,
                                        onTap: () async {
                                          await _showAgnesConfigDialog();
                                          // 保存后立即重载：更新设置项小字与选中态
                                          await _loadAIConfig();
                                          if (mounted) {
                                            setDialogState(() {});
                                          }
                                        },
                                      ),
                                      const SizedBox(height: 12),
                                      _buildCustomAPIOption(
                                        title: '自定义 OpenAI 兼容 API',
                                        subtitle: '输入您的API地址和密钥',
                                        icon: Icons.api,
                                        isSelected: _providerConfigured && _isCustomProvider,
                                        onTap: () async {
                                          await _showCustomAPIDialog();
                                          // 保存后立即重载：更新设置项小字与选中态
                                          await _loadAIConfig();
                                          if (mounted) {
                                            setDialogState(() {});
                                          }
                                        },
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 20),
                            SizedBox(
                              width: double.infinity,
                              child: TextButton(
                                onPressed: () => Navigator.pop(context),
                                style: TextButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(vertical: 14),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                    side: BorderSide(color: Colors.grey.shade300),
                                  ),
                                ),
                                child: const Text('关闭'),
                              ),
                            ),
                          ],
                        );
          },
        );
      },
    );
  }

  Widget _buildCustomAPIOption({
    required String title,
    required String subtitle,
    required IconData icon,
    bool isSelected = false,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF4A90E2).withValues(alpha: 0.1) : Colors.white.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            // 未选中描边：减弱动态时改浅灰（白描边与近实底壳背景融合）
            color: isSelected
                ? const Color(0xFF4A90E2)
                : (_reduceMotionEnabled ? Colors.grey.shade300 : Colors.white.withValues(alpha: 0.4)),
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: isSelected
                    ? const Color(0xFF4A90E2).withValues(alpha: 0.2)
                    : Colors.white.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                icon,
                size: 20,
                color: isSelected ? const Color(0xFF4A90E2) : Colors.grey.shade700,
              ),
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
                      color: isSelected ? const Color(0xFF4A90E2) : null,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey.shade600,
                    ),
                  ),
                ],
              ),
            ),
            isSelected
                ? const Icon(Icons.check_circle, color: Color(0xFF4A90E2), size: 20)
                : Icon(Icons.chevron_right, color: Colors.grey.shade400),
          ],
        ),
      ),
    );
  }

  Widget _buildRecommendedOption({
    required String title,
    required String subtitle,
    IconData? icon,
    String? iconAsset,
    required Color color,
    required bool isSelected,
    required VoidCallback onTap,
    bool disabled = false,
  }) {
    return GestureDetector(
      onTap: disabled ? null : onTap,
      child: Opacity(
        opacity: disabled ? 0.5 : 1.0,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: isSelected ? color.withValues(alpha: 0.1) : Colors.white.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              // 未选中描边：减弱动态时改浅灰（白描边与近实底壳背景融合）
              color: isSelected
                  ? color
                  : (_reduceMotionEnabled ? Colors.grey.shade300 : Colors.white.withValues(alpha: 0.4)),
              width: isSelected ? 2 : 1,
            ),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: iconAsset != null
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: Image.asset(
                          iconAsset,
                          width: 20,
                          height: 20,
                          fit: BoxFit.cover,
                        ),
                      )
                    : Icon(icon, size: 20, color: color),
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
                        color: isSelected ? color : null,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ],
                ),
              ),
              // 未选中时显示与自定义API同款箭头
              if (isSelected)
                Icon(Icons.check_circle, color: color, size: 20)
              else
                Icon(Icons.chevron_right, color: Colors.grey.shade400),
          ],
        ),
      ),
      ),
    );
  }

  /// 内置模型（限时免费）卡片：右侧统一样式下拉切换节点 1-4。
  /// 与推荐选项相互独立：未启用时选项框显示"未使用"且菜单无对勾，
  /// 选中任意节点即切换到内置模型（推荐选项随之取消勾选）
  Widget _buildBuiltinModelCard({
    required int node,
    required bool isBuiltinActive,
    required ValueChanged<int> onNodeSelected,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF4A90E2).withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: const Color(0xFF4A90E2).withValues(alpha: 0.4),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      '内置模型',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 6),
                    // 限时免费标签：浅蓝底胶囊，稍深蓝小字
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFE3F0FB),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: const Color(0xFF3B82C4).withValues(alpha: 0.45),
                        ),
                      ),
                      child: const Text(
                        '限时免费',
                        style: TextStyle(
                          fontSize: 10,
                          color: Color(0xFF3B82C4),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  '高峰时段可能响应缓慢或无响应',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey.shade600,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Container(
            // 固定宽度（收起态选项框）：菜单宽度由下方 menuWidth 单独指定
            width: 128,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              // 灰描边仅减弱动态时显示：正常模式白底经毛玻璃本就有边界
              border: Border.all(
                color: _reduceMotionEnabled ? Colors.grey.shade300 : Colors.white.withValues(alpha: 0.4),
              ),
            ),
            // BlurredDropdown（而非原生 DropdownButton）：与全局毛玻璃风格统一的下拉菜单
            child: BlurredDropdown<int>(
              prefixIcon: const Icon(Icons.hub_outlined, size: 16, color: Color(0xFF4A90E2)),
              // 未启用时 value 为 null：无匹配项 → 按钮显示"未使用"、菜单不打勾
              value: isBuiltinActive ? node : null,
              isExpanded: true,
              // 菜单独立定宽（与对话页徽章节点菜单同宽 120，
              // "节点 X" + 问号图标 + 勾号槽不换行）
              menuWidth: 120,
              hint: const Text(
                '未使用',
                style: TextStyle(fontSize: 13, color: Colors.grey),
              ),
              icon: const Icon(Icons.expand_more, size: 18, color: Color(0xFF4A90E2)),
              items: [
                for (var i = 1; i <= 4; i++)
                  DropdownMenuItem<int>(
                    value: i,
                    child: Text(
                      '节点 $i',
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
              ],
              onChanged: (next) {
                if (next != null) {
                  onNodeSelected(next);
                }
              },
              // 节点 3/4 右侧问号图标的提示文案
              infoMessages: const {
                3: '节点3延迟较高，请优先使用节点1、2。',
                4: '节点4延迟较高，请优先使用节点1、2。',
              },
            ),
          ),
        ],
      ),
    );
  }

  /// Agnes AI 配置弹窗：密钥输入 + 模型下拉（Agnes 2.0 Flash / Agnes 2.5 Flash）
  Future<void> _showAgnesConfigDialog() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final controller = TextEditingController(text: prefs.getString('agnes_api_key') ?? '');
    // 显示名 → 实际模型名映射（后台实际使用的模型标识）
    const defaultModel = 'agnes-2.0-flash';
    String selectedModel = prefs.getString('agnes_model') ?? defaultModel;
    if (selectedModel != 'agnes-2.0-flash' && selectedModel != 'agnes-2.5-flash') {
      selectedModel = defaultModel;
    }
    // 思考强度：与自定义API同款（空 = 直接回答）
    String reasoningEffort = prefs.getString('agnes_reasoning_effort') ?? '';

    await showBouncyDialog(
      context: context,
      barrierLabel: 'Agnes AI 配置',
      shellPadding: const EdgeInsets.all(24),
      shellBoxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.2),
          blurRadius: 20,
          offset: const Offset(0, 10),
        ),
      ],
      avoidKeyboard: true,
      // 壳总宽/总高约束含壳内边距（与旧版壳外 Container(constraints:) 一致）
      shellConstraintsBuilder: (context) {
        final mediaQuery = MediaQuery.of(context);
        final keyboardHeight = mediaQuery.viewInsets.bottom;
        final topInset = mediaQuery.padding.top;
        final screenHeight = mediaQuery.size.height;
        const baseMaxHeight = 560.0;
        double dialogMaxHeight = baseMaxHeight;
        final availableHeight = screenHeight - topInset - keyboardHeight - 24;
        if (availableHeight < dialogMaxHeight) {
          dialogMaxHeight = availableHeight;
        }
        dialogMaxHeight = dialogMaxHeight.clamp(300.0, baseMaxHeight).toDouble();
        return BoxConstraints(maxWidth: 420, maxHeight: dialogMaxHeight);
      },
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text(
                        'Agnes AI 配置',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(width: 6),
                      // 带圈问号：点击向右弹出推荐说明气泡
                      _AgnesHelpIcon(reduceMotion: _reduceMotionEnabled),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '免费密钥申请地址：https://www.agnes-ai.cn/',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      color: Colors.grey.shade600,
                    ),
                  ),
                  const SizedBox(height: 20),
                  TextField(
                    contextMenuBuilder: styledEditableContextMenu,
                    controller: controller,
                    decoration: InputDecoration(
                      hintText: '请输入 Agnes AI API Key',
                      filled: true,
                      fillColor: Colors.white.withValues(alpha: 0.4),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: _reduceMotionEnabled ? Colors.grey.shade300 : Colors.white.withValues(alpha: 0.4)),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: _reduceMotionEnabled ? Colors.grey.shade300 : Colors.white.withValues(alpha: 0.4)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: Color(0xFF4A90E2)),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Text(
                        '模型',
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.grey.shade700,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            // 灰描边仅减弱动态时显示：正常模式白底经毛玻璃本就有边界
                            border: Border.all(
                              color: _reduceMotionEnabled ? Colors.grey.shade300 : Colors.white.withValues(alpha: 0.4),
                            ),
                          ),
                          // BlurredDropdown：与全局毛玻璃风格统一的下拉菜单
                          child: BlurredDropdown<String>(
                            value: selectedModel,
                            isExpanded: true,
                            icon: const Icon(Icons.expand_more, size: 18, color: Color(0xFF4A90E2)),
                            items: const [
                              DropdownMenuItem(
                                value: 'agnes-2.0-flash',
                                child: Text(
                                  'Agnes 2.0 Flash',
                                  style: TextStyle(fontSize: 13),
                                ),
                              ),
                              DropdownMenuItem(
                                value: 'agnes-2.5-flash',
                                child: Text(
                                  'Agnes 2.5 Flash',
                                  style: TextStyle(fontSize: 13),
                                ),
                              ),
                            ],
                            onChanged: (next) {
                              if (next != null) {
                                setDialogState(() {
                                  selectedModel = next;
                                });
                              }
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  // 思考强度：与自定义API同款滑动选项卡（1:1复刻）
                  const Text('思考强度', style: TextStyle(fontSize: 13, color: Colors.black87)),
                  const SizedBox(height: 8),
                  SegmentedSelector<String>(
                    items: const [
                      SegmentItem(label: '直接回答', value: ''),
                      SegmentItem(label: 'Low', value: 'low'),
                      SegmentItem(label: 'Medium', value: 'medium'),
                      SegmentItem(label: 'High', value: 'high'),
                    ],
                    activeValue: reasoningEffort.isEmpty ? '' : reasoningEffort,
                    onChanged: (v) {
                      setDialogState(() {
                        reasoningEffort = v;
                      });
                    },
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Expanded(
                        child: TextButton(
                          onPressed: () => Navigator.pop(context),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                              side: BorderSide(color: Colors.grey.shade300),
                            ),
                          ),
                          child: const Text('取消'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: () async {
                            final apiKey = controller.text.trim();

                            if (apiKey.isEmpty) {
                              toastNotification.show(context, '请填写 Agnes AI API Key', type: ToastType.error);
                              return;
                            }

                            await prefs.setString('agnes_api_key', apiKey);
                            await prefs.setString('agnes_model', selectedModel);
                            await prefs.setString('agnes_reasoning_effort', reasoningEffort);
                            await prefs.setString('ai_provider', 'agnes');
                            AIAssistantScreenState.markNeedsRefresh();
                            await prefs.setBool('fast_mode_enabled', false);
                            await prefs.setBool('ai_enabled', true);
                            AIService.instance.setAgnesConfig(apiKey, selectedModel);

                            if (mounted) {
                              Navigator.pop(context);
                              setState(() {
                                _isAgnesProvider = true;
                                _isCustomProvider = false;
                                _isBuiltinProvider = false;
                                _fastModeEnabled = false;
                                _providerConfigured = true;
                                _aiEnabled = true;
                              });
                              toastNotification.show(context, '已切换到Agnes AI模型', type: ToastType.success);
                            }
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.grey.shade800,
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
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _showCustomAPIDialog() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final urlController = TextEditingController(text: prefs.getString('custom_api_url') ?? '');
    final keyController = TextEditingController(text: prefs.getString('custom_api_key') ?? '');
    final modelController = TextEditingController(text: prefs.getString('custom_api_model') ?? 'gpt-4o-mini');
    bool manualVisionOverride = prefs.getBool('custom_api_vision_manual_override') ?? false;
    bool manualVisionEnabled = prefs.getBool('custom_api_vision_manual_value') ?? false;
    String reasoningEffort = prefs.getString('custom_api_reasoning_effort') ?? '';
    bool webSearchEnabled = prefs.getBool('web_search_enabled') ?? false;

    await showCustomAPIConfigDialog(
      context: context,
      urlController: urlController,
      keyController: keyController,
      modelController: modelController,
      manualVisionOverride: manualVisionOverride,
      manualVisionEnabled: manualVisionEnabled,
      reasoningEffort: reasoningEffort,
      webSearchEnabled: webSearchEnabled,
      onVisionUpdated: (override, enabled) {
        manualVisionOverride = override;
        manualVisionEnabled = enabled;
      },
      onReasoningUpdated: (effort) {
        reasoningEffort = effort;
      },
      onWebSearchUpdated: (enabled) {
        webSearchEnabled = enabled;
      },
      onSave: () async {
        if (urlController.text.trim().isEmpty ||
            keyController.text.trim().isEmpty) {
          toastNotification.show(context, '请填写API地址和密钥', type: ToastType.error);
          return;
        }

        await prefs.setString('custom_api_url', urlController.text.trim());
        await prefs.setString('custom_api_key', keyController.text.trim());
        await prefs.setString('custom_api_model', modelController.text.trim());
        await prefs.setString('ai_provider', 'custom');
                            AIAssistantScreenState.markNeedsRefresh();
        await prefs.setBool('fast_mode_enabled', false);
        await prefs.setBool('ai_enabled', true);

        await prefs.setString('custom_api_reasoning_effort', reasoningEffort.isNotEmpty ? reasoningEffort : '');

        await prefs.setBool('web_search_enabled', webSearchEnabled);

        AIService.instance.setCustomApiConfig(
          apiUrl: urlController.text.trim(),
          apiKey: keyController.text.trim(),
          model: modelController.text.trim(),
        );
        await AIService.instance.setCustomVisionManualOverride(
          enabled: manualVisionOverride,
          supportsVision: manualVisionEnabled,
        );
        await AIService.instance.setCustomReasoningEffort(
          reasoningEffort.isNotEmpty ? reasoningEffort : null,
        );

        if (mounted) {
          Navigator.pop(context);
          setState(() {
            _isCustomProvider = true;
            _isAgnesProvider = false;
            _isBuiltinProvider = false;
            _providerConfigured = true;
            _aiEnabled = true;
            _fastModeEnabled = false;
            _customVisionManualOverride = manualVisionOverride;
            _customVisionEnabled = manualVisionEnabled;
          });
          toastNotification.show(context, '自定义API已保存', type: ToastType.success);
        }
      },
    );
  }

  static Future<void> showCustomAPIConfigDialog({
    required BuildContext context,
    required TextEditingController urlController,
    required TextEditingController keyController,
    required TextEditingController modelController,
    required bool manualVisionOverride,
    required bool manualVisionEnabled,
    required String reasoningEffort,
    required bool webSearchEnabled,
    required void Function(bool override, bool enabled) onVisionUpdated,
    required void Function(String effort) onReasoningUpdated,
    required void Function(bool enabled) onWebSearchUpdated,
    required VoidCallback onSave,
  }) async {
    bool localOverride = manualVisionOverride;
    bool localEnabled = manualVisionEnabled;
    String localReasoning = reasoningEffort;
    bool localWebSearch = webSearchEnabled;

    await showBouncyDialog(
      context: context,
      barrierLabel: '自定义API',
      shellPadding: const EdgeInsets.all(24),
      shellBoxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.2),
          blurRadius: 20,
          offset: const Offset(0, 10),
        ),
      ],
      avoidKeyboard: true,
      // 壳总宽/总高约束含壳内边距（与旧版壳外 Container(constraints:) 一致）
      shellConstraintsBuilder: (context) {
        final mediaQuery = MediaQuery.of(context);
        final keyboardHeight = mediaQuery.viewInsets.bottom;
        final topInset = mediaQuery.padding.top;
        final screenHeight = mediaQuery.size.height;
        const baseMaxHeight = 650.0;
        double dialogMaxHeight = baseMaxHeight;
        final availableHeight = screenHeight - topInset - keyboardHeight - 24;
        if (availableHeight < dialogMaxHeight) {
          dialogMaxHeight = availableHeight;
        }
        dialogMaxHeight = dialogMaxHeight.clamp(320.0, baseMaxHeight).toDouble();
        return BoxConstraints(maxWidth: 420, maxHeight: dialogMaxHeight);
      },
      builder: (context) {
        return StatefulBuilder(
            builder: (context, setDialogState) {
              return SingleChildScrollView(
                child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                '自定义 OpenAI 兼容 API',
                                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                '支持OpenAI格式的API接口',
                                style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
                              ),
                              const SizedBox(height: 20),
                              TextField(
                                contextMenuBuilder: styledEditableContextMenu,
                                controller: urlController,
                                decoration: InputDecoration(
                                  labelText: 'API 地址',
                                  hintText: 'https://api.example.com/v1/chat/completions',
                                  filled: true,
                                  fillColor: Colors.white.withValues(alpha: 0.4),
                                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                                ),
                              ),
                              const SizedBox(height: 12),
                              TextField(
                                contextMenuBuilder: styledEditableContextMenu,
                                controller: keyController,
                                decoration: InputDecoration(
                                  labelText: 'API Key',
                                  hintText: '请输入API密钥',
                                  filled: true,
                                  fillColor: Colors.white.withValues(alpha: 0.4),
                                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                                ),
                              ),
                              const SizedBox(height: 12),
                              TextField(
                                contextMenuBuilder: styledEditableContextMenu,
                                controller: modelController,
                                decoration: InputDecoration(
                                  labelText: '模型名称',
                                  hintText: 'gpt-4o-mini',
                                  filled: true,
                                  fillColor: Colors.white.withValues(alpha: 0.4),
                                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                                ),
                              ),
                              const SizedBox(height: 12),
                              const Text('视觉能力支持', style: TextStyle(fontSize: 13, color: Colors.black87)),
                              const SizedBox(height: 8),
                              SegmentedSelector<_CustomVisionMode>(
                                items: const [
                                  SegmentItem(label: '自动', value: _CustomVisionMode.auto),
                                  SegmentItem(label: '开启', value: _CustomVisionMode.enabled),
                                  SegmentItem(label: '关闭', value: _CustomVisionMode.disabled),
                                ],
                                activeValue: !localOverride
                                    ? _CustomVisionMode.auto
                                    : (localEnabled ? _CustomVisionMode.enabled : _CustomVisionMode.disabled),
                                onChanged: (mode) {
                                  setDialogState(() {
                                    if (mode == _CustomVisionMode.auto) {
                                      localOverride = false;
                                      localEnabled = false;
                                    } else {
                                      localOverride = true;
                                      localEnabled = mode == _CustomVisionMode.enabled;
                                    }
                                    onVisionUpdated(localOverride, localEnabled);
                                  });
                                },
                              ),
                              const SizedBox(height: 16),
                              const Text('思考强度', style: TextStyle(fontSize: 13, color: Colors.black87)),
                              const SizedBox(height: 8),
                              SegmentedSelector<String>(
                                items: const [
                                  SegmentItem(label: '直接回答', value: ''),
                                  SegmentItem(label: 'Low', value: 'low'),
                                  SegmentItem(label: 'Medium', value: 'medium'),
                                  SegmentItem(label: 'High', value: 'high'),
                                ],
                                activeValue: localReasoning.isEmpty ? '' : localReasoning,
                                onChanged: (v) {
                                  setDialogState(() {
                                    localReasoning = v;
                                    onReasoningUpdated(v);
                                  });
                                },
                              ),
                              const SizedBox(height: 16),
                              Row(
                                children: [
                                  const Text('联网搜索', style: TextStyle(fontSize: 13, color: Colors.black87)),
                                  const Spacer(),
                                  SizedBox(
                                    height: 28,
                                    child: Switch(
                                      value: localWebSearch,
                                      activeTrackColor: Colors.grey.shade700,
                                      onChanged: (v) {
                                        HapticFeedback.selectionClick();
                                        setDialogState(() {
                                          localWebSearch = v;
                                          onWebSearchUpdated(v);
                                        });
                                      },
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 20),
                              Row(
                                children: [
                                  Expanded(
                                    child: TextButton(
                                      onPressed: () => Navigator.pop(context),
                                      style: TextButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(vertical: 14),
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(12),
                                          side: BorderSide(color: Colors.grey.shade300),
                                        ),
                                      ),
                                      child: const Text('取消'),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: ElevatedButton(
                                      onPressed: onSave,
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: Colors.grey.shade800,
                                        foregroundColor: Colors.white,
                                        padding: const EdgeInsets.symmetric(vertical: 14),
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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
          );
      },
    );
  }
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
    final FixedExtentScrollController scrollController = FixedExtentScrollController(initialItem: selectedWeeks - 1);
    
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
                            const Text(
                              '学期周数',
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
    final FixedExtentScrollController scrollController = FixedExtentScrollController(initialItem: selectedPeriods - 1);
    
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
                            const Text(
                              '每日节数',
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

  Future<void> _showTimeSlotsDialog() async {
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
                              ],
                            ),
                            const SizedBox(height: 16),
                            Expanded(
                              child: SingleChildScrollView(
                                physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: List.generate(_timeSlots.length, (index) {
                                    final slot = _timeSlots[index];
                                    return Container(
                                      margin: const EdgeInsets.only(bottom: 8),
                                      padding: const EdgeInsets.all(12),
                                      decoration: BoxDecoration(
                                        color: Colors.white.withValues(alpha: 0.4),
                                        borderRadius: BorderRadius.circular(10),
                                        // 灰描边仅减弱动态时显示：正常模式恢复白描边
                                        border: Border.all(
                                          color: _reduceMotionEnabled
                                              ? Colors.grey.shade300
                                              : Colors.white.withValues(alpha: 0.4),
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
                                                  colors: [Color(0xFF4A90E2), Color(0xFF5BA0F2)],
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
                                                    setDialogState(() {});
                                                  },
                                                ),
                                                const Padding(
                                                  padding: EdgeInsets.symmetric(horizontal: 8),
                                                  child: Text('—'),
                                                ),
                                                _buildTimeField(
                                                  value: slot['end']!,
                                                  onChanged: (v) {
                                                    _timeSlots[index]['end'] = v;
                                                    setDialogState(() {});
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
                                        side: BorderSide(color: Colors.grey.shade300),
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
                                      if (mounted) {
                                        setState(() {});
                                      }
                                      Navigator.pop(context);
                                      toastNotification.show(context, '时间段已保存', type: ToastType.success);
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
          color: Colors.white.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(8),
          // 灰描边仅减弱动态时显示：正常模式恢复白描边
          border: Border.all(
            color: _reduceMotionEnabled
                ? Colors.grey.shade300
                : Colors.white.withValues(alpha: 0.4),
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
      await NotificationService.instance.rescheduleTaskNotifications(StorageService.getTasks());
    }

    if (mounted) {
      toastNotification.show(context, '提醒时间已更新', type: ToastType.success);
    }
  }

  Future<void> _showNotificationCopyStyleDialog() async {
    var tempStyle = _notificationCopyStyle;

    final selectedStyle = await _showUnifiedNotificationDialog<NotificationCopyStyle>(
      title: '选择通知文案风格',
      contentBuilder: (setDialogState) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: NotificationCopyStyle.values
              .map(
                (style) {
                  final isSelected = style == tempStyle;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Material(
                      color: Colors.transparent,
                      borderRadius: BorderRadius.circular(12),
                      clipBehavior: Clip.antiAlias,
                      child: Ink(
                        decoration: BoxDecoration(
                          color: isSelected
                              ? const Color(0xFF4A90E2).withValues(alpha: 0.12)
                              : Colors.white.withValues(alpha: 0.4),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: isSelected ? const Color(0xFF4A90E2) : Colors.white.withValues(alpha: 0.4),
                            width: isSelected ? 1.5 : 1,
                          ),
                        ),
                        child: InkWell(
                          onTap: () {
                            setDialogState(() {
                              tempStyle = style;
                            });
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        NotificationService.instance.copyStyleLabel(style),
                                        style: TextStyle(
                                          fontWeight: FontWeight.w600,
                                          color: isSelected ? const Color(0xFF4A90E2) : const Color(0xFF333333),
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        NotificationService.instance.copyStyleDescription(style),
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Colors.grey.shade600,
                                        ),
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Icon(
                                  isSelected ? Icons.check_circle : Icons.radio_button_unchecked,
                                  color: isSelected ? const Color(0xFF4A90E2) : Colors.grey.shade500,
                                  size: 20,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              )
              .toList(),
        );
      },
      actionsBuilder: (dialogContext, _) {
        return [
          Expanded(
            child: TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(color: Colors.grey.shade300),
                ),
              ),
              child: const Text('取消'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: ElevatedButton(
              onPressed: () => Navigator.pop(dialogContext, tempStyle),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF4A90E2),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: const Text('保存'),
            ),
          ),
        ];
      },
    );

    if (selectedStyle == null || selectedStyle == _notificationCopyStyle) {
      return;
    }

    await NotificationService.instance.saveTaskNotificationSettings(
      enabled: _taskNotificationEnabled,
      days: _notifyLeadDays,
      hours: _notifyLeadHours,
      minutes: _notifyLeadMinutes,
      style: selectedStyle,
    );

    if (!mounted) return;

    setState(() {
      _notificationCopyStyle = selectedStyle;
    });

    if (_taskNotificationEnabled) {
      await NotificationService.instance.rescheduleTaskNotifications(StorageService.getTasks());
    }

    if (mounted) {
      toastNotification.show(
        context,
        '已切换为${NotificationService.instance.copyStyleLabel(selectedStyle)}文案风格',
        type: ToastType.success,
      );
    }
  }

  Future<T?> _showUnifiedNotificationDialog<T>({
    required String title,
    required Widget Function(StateSetter setDialogState) contentBuilder,
    required List<Widget> Function(BuildContext dialogContext, StateSetter setDialogState)
        actionsBuilder,
  }) {
    return showBouncyDialog<T>(
      context: context,
      barrierLabel: title,
      shellPadding: const EdgeInsets.all(20),
      // 壳总宽含壳内边距（与旧版壳外 Container(constraints:) 一致）
      shellMaxWidth: 420,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          return Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                            Text(
                              title,
                              style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 16),
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxHeight: 320),
                              child: SingleChildScrollView(
                                child: contentBuilder(setDialogState),
                              ),
                            ),
                            const SizedBox(height: 18),
                            Row(
                              children: actionsBuilder(dialogContext, setDialogState),
                            ),
              ],
            );
        },
      ),
    );
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
              color: Colors.grey.shade600,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'AI驱动的学习与日程管理平台',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              color: Colors.grey.shade700,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Copyright©2026 - CourseHub项目组',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              color: Colors.grey.shade500,
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
                    _showUpdateDialog();
                  },
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(color: Colors.grey.shade300),
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

  /// 更新对话框：检查 → 发现新版本 → 下载 → 安装在同一对话框内完成。
  /// 各阶段共用固定壳尺寸（宽 360 × 内容高 380），不随内容变化，
  /// 内容垂直居中，切换阶段无尺寸跳变。
  void _showUpdateDialog() {
    _UpdatePhase phase = _UpdatePhase.checking;
    AppUpdateInfo? updateInfo;
    String? checkError;
    CancelToken? downloadToken;
    int receivedBytes = 0;
    int totalBytes = 0;
    String? apkPath;
    // 自动检查只触发一次：防止检查完成后 setState 重建 builder 再次
    // 调用 startCheck 造成「检查 → 结果 → 又检查」死循环
    bool autoCheckStarted = false;
    // 请求进行中标志：不能用 phase == checking 判断（phase 初始值即为
    // checking，会导致打开对话框时的首次自动检查被防重入拦截、请求
    // 根本发不出去，转圈永不结束）
    bool isChecking = false;

    // 对话框可能已被关闭（外部点击），setDialogState 需容错
    void Function(VoidCallback)? setDs;
    void safeSetState(VoidCallback fn) {
      try {
        setDs?.call(fn);
      } catch (_) {}
    }

    // 阶段切换过渡（与登录对话框副标题同款动效）：旧内容模糊淡出，
    // 新内容自模糊中清晰淡入，交叉过渡不跳变；
    // 「减弱动态效果」开启时退化为单纯淡入淡出（无模糊、无缩放）
    Widget blurSwitch(Widget child) => AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          transitionBuilder: (child, animation) {
            if (_reduceMotionEnabled) {
              return FadeTransition(opacity: animation, child: child);
            }
            return FadeTransition(
              opacity: animation,
              child: AnimatedBuilder(
                animation: animation,
                builder: (context, grandChild) => ImageFiltered(
                  imageFilter: ImageFilter.blur(
                    sigmaX: 6 * (1.0 - animation.value),
                    sigmaY: 6 * (1.0 - animation.value),
                  ),
                  child: Transform.scale(
                    scale: 0.92 + 0.08 * animation.value,
                    child: grandChild,
                  ),
                ),
                child: child,
              ),
            );
          },
          // Stack 尺寸只由新内容决定（旧内容仅水平约束、垂直居中悬浮，
          // 不参与定尺寸）：新内容一进来整块布局就落到最终位置，图标/
          // 标题不会因旧的高内容淡出期间还撑着布局而先高后低地跳动
          layoutBuilder: (currentChild, previousChildren) => Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none,
            children: [
              for (final Widget child in previousChildren)
                Positioned(left: 0, right: 0, child: child),
              if (currentChild != null) currentChild,
            ],
          ),
          child: child,
        );

    Future<void> startCheck() async {
      if (isChecking) return;
      isChecking = true;
      safeSetState(() => phase = _UpdatePhase.checking);
      final result = await UpdateService.checkForUpdate(appVersion);
      isChecking = false;
      safeSetState(() {
        if (result.error != null) {
          phase = _UpdatePhase.error;
          checkError = result.error;
        } else if (result.hasUpdate) {
          phase = _UpdatePhase.available;
          updateInfo = result.info;
        } else {
          phase = _UpdatePhase.upToDate;
        }
      });
    }

    Future<void> startDownload() async {
      final info = updateInfo;
      if (info == null) return;
      // 本地已有该版本的完整安装包（上次下载/安装残留）：跳过下载，
      // 直接进入「下载完成」
      final String? localPath = await UpdateService.findLocalInstaller(info);
      if (localPath != null) {
        safeSetState(() {
          apkPath = localPath;
          phase = _UpdatePhase.downloaded;
        });
        return;
      }
      downloadToken = CancelToken();
      safeSetState(() {
        phase = _UpdatePhase.downloading;
        receivedBytes = 0;
        totalBytes = 0;
      });
      // 进度回调节流：约 10 次/秒刷新 UI
      DateTime lastUi = DateTime.now();
      final path = await UpdateService.downloadApk(
        info,
        cancelToken: downloadToken,
        onProgress: (received, total) {
          final now = DateTime.now();
          final finished = total > 0 && received >= total;
          if (!finished && now.difference(lastUi).inMilliseconds < 100) {
            return;
          }
          lastUi = now;
          safeSetState(() {
            receivedBytes = received;
            totalBytes = total;
          });
        },
      );
      safeSetState(() {
        if (path == null) {
          // 用户手动取消：静默回到「发现新版本」，不作为失败提示
          if (downloadToken?.isCancelled ?? false) {
            phase = _UpdatePhase.available;
          } else {
            phase = _UpdatePhase.downloadFailed;
          }
        } else {
          phase = _UpdatePhase.downloaded;
          apkPath = path;
        }
      });
    }

    Future<void> install() async {
      if (apkPath == null) return;
      final String path = apkPath!;
      // Android 拉起系统 APK 安装器；桌面平台按扩展名直接运行安装包
      final bool ok = Platform.isAndroid
          ? await UpdateService.installApk(path)
          : await UpdateService.launchInstaller(path);
      if (!ok && mounted) {
        toastNotification.show(context, '无法启动安装器，请手动安装',
            type: ToastType.error);
        return;
      }
      // 安装器已成功拉起：自动清理本地安装包（Android 的安装包正被系统
      // 安装器读取，不删；桌面安装包可能仍被安装进程占用，由服务端
      // 延迟重试删除）。不 await，后台静默清理。
      if (!Platform.isAndroid) {
        UpdateService.deleteInstallerLater(path);
      }
    }

    // 统一次按钮：灰描边 TextButton（与关于对话框「检查更新」及全应用对话框一致）
    Widget buildSecondaryButton(String text, VoidCallback? onPressed) {
      return Expanded(
        child: TextButton(
          onPressed: onPressed,
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: Colors.grey.shade300),
            ),
          ),
          child: Text(text),
        ),
      );
    }

    // 统一主按钮：蓝色 ElevatedButton
    Widget buildPrimaryButton(String text, VoidCallback? onPressed) {
      return Expanded(
        child: ElevatedButton(
          onPressed: onPressed,
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF4A90E2),
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          child: Text(text),
        ),
      );
    }

    showBouncyDialog(
      context: context,
      barrierLabel: '检查更新',
      shellPadding: const EdgeInsets.all(24),
      shellWidth: 360,
      reduceMotion: _reduceMotionEnabled,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          // 捕获 setState 引用（供异步回调容错刷新）
          setDs = setDialogState;
          // 打开即开始检查（仅首次；重试由按钮显式触发）
          if (!autoCheckStarted) {
            autoCheckStarted = true;
            startCheck();
          }

          // 阶段性内容（图标 + 标题 + 正文）
          Widget icon;
          String title;
          List<Widget> body;
          List<Widget> actions;

          switch (phase) {
            case _UpdatePhase.checking:
              icon = const SizedBox(
                width: 64,
                height: 64,
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: CircularProgressIndicator(
                    color: Color(0xFF4A90E2),
                    strokeWidth: 3,
                  ),
                ),
              );
              title = '检查更新';
              body = [
                Text(
                  '正在检查更新…',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey.shade600,
                  ),
                ),
              ];
              actions = [];

            case _UpdatePhase.upToDate:
              icon = Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: Colors.green.withValues(alpha: 0.9),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(
                  Icons.check_circle_rounded,
                  size: 36,
                  color: Colors.white,
                ),
              );
              title = '已是最新版本';
              body = [
                Text(
                  '当前版本 v$appVersion',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey.shade600,
                  ),
                ),
              ];
              actions = [
                buildPrimaryButton('确定', () => Navigator.pop(context)),
              ];

            case _UpdatePhase.error:
              icon = Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(
                  Icons.cloud_off_rounded,
                  size: 36,
                  color: Colors.white,
                ),
              );
              title = '检查更新失败';
              body = [
                Text(
                  checkError ?? '网络连接失败',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey.shade600,
                  ),
                ),
              ];
              actions = [
                buildSecondaryButton('关闭', () => Navigator.pop(context)),
                buildPrimaryButton('重试', startCheck),
              ];

            case _UpdatePhase.available:
              final info = updateInfo!;
              icon = Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: const Color(0xFF4A90E2),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(
                  Icons.system_update_alt_rounded,
                  size: 32,
                  color: Colors.white,
                ),
              );
              title = '发现新版本';
              body = [
                // 版本信息卡片：当前版本 / 最新版本
                Container(
                  width: double.infinity,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade50,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.grey.shade200),
                  ),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Text(
                            '当前版本',
                            style: TextStyle(
                              fontSize: 13,
                              color: Colors.grey.shade500,
                            ),
                          ),
                          const Spacer(),
                          Text(
                            'v$appVersion',
                            style: TextStyle(
                              fontSize: 13,
                              color: Colors.grey.shade600,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Text(
                            '最新版本',
                            style: TextStyle(
                              fontSize: 13,
                              color: Colors.grey.shade500,
                            ),
                          ),
                          const Spacer(),
                          Text(
                            'v${info.version}',
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF4A90E2),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                // 更新说明（可选，超过两行限高滚动 + 触底回弹）
                if (info.notes != null && info.notes!.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Container(
                    width: double.infinity,
                    // 两行文字高度：13px × 1.6 行高 × 2 行
                    constraints: const BoxConstraints(maxHeight: 42),
                    child: SingleChildScrollView(
                      physics: const BouncingScrollPhysics(
                        parent: AlwaysScrollableScrollPhysics(),
                      ),
                      child: Text(
                        info.notes!,
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.grey.shade600,
                          height: 1.6,
                        ),
                      ),
                    ),
                  ),
                ],
              ];
              actions = [
                buildSecondaryButton('取消', () => Navigator.pop(context)),
                buildPrimaryButton('下载更新', startDownload),
              ];

            case _UpdatePhase.downloading:
              final info = updateInfo!;
              final progress =
                  totalBytes > 0 ? receivedBytes / totalBytes : null;
              final receivedMb =
                  (receivedBytes / 1024 / 1024).toStringAsFixed(1);
              final totalMb = totalBytes > 0
                  ? (totalBytes / 1024 / 1024).toStringAsFixed(1)
                  : null;
              icon = Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: const Color(0xFF4A90E2),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(
                  Icons.download_rounded,
                  size: 32,
                  color: Colors.white,
                ),
              );
              title = '正在下载 v${info.version}';
              body = [
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 8,
                    backgroundColor: Colors.grey.shade200,
                    valueColor:
                        const AlwaysStoppedAnimation(Color(0xFF4A90E2)),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  totalMb != null
                      ? '$receivedMb MB / $totalMb MB${progress != null ? ' · ${(progress * 100).toInt()}%' : ''}'
                      : '已下载 $receivedMb MB',
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.grey.shade600,
                  ),
                ),
              ];
              actions = [
                buildSecondaryButton('取消下载', () {
                  downloadToken?.cancel();
                  // 取消后回到「发现新版本」，可重新下载
                  setDialogState(() => phase = _UpdatePhase.available);
                }),
              ];

            case _UpdatePhase.downloaded:
              final info = updateInfo!;
              icon = Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: Colors.green.withValues(alpha: 0.9),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(
                  Icons.check_circle_rounded,
                  size: 36,
                  color: Colors.white,
                ),
              );
              title = '下载完成';
              if (Platform.isAndroid) {
                body = [
                  Text(
                    'v${info.version} 已下载完成，\n安装完成后旧版本数据将自动保留。',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey.shade600,
                      height: 1.5,
                    ),
                  ),
                ];
                actions = [
                  buildSecondaryButton('以后再说', () => Navigator.pop(context)),
                  buildPrimaryButton('立即安装', install),
                ];
              } else {
                // 桌面平台：显示下载路径，可在文件管理器中定位
                body = [
                  Text(
                    'v${info.version} 已下载完成。',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey.shade600,
                      height: 1.5,
                    ),
                  ),
                  if (apkPath != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      apkPath!,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade500,
                      ),
                    ),
                  ],
                ];
                actions = [
                  buildSecondaryButton('关闭', () => Navigator.pop(context)),
                  buildPrimaryButton('安装', install),
                ];
              }

            case _UpdatePhase.downloadFailed:
              icon = Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(
                  Icons.error_outline_rounded,
                  size: 36,
                  color: Colors.white,
                ),
              );
              title = '下载失败';
              body = [
                Text(
                  '下载中断或网络不稳定，请重试。',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey.shade600,
                  ),
                ),
              ];
              actions = [
                buildSecondaryButton('关闭', () => Navigator.pop(context)),
                buildPrimaryButton('重试下载', startDownload),
              ];
          }

          // 固定尺寸：各阶段共用同一壳尺寸，不随内容变化。
          // 内容区居中，按钮固定在底部（与内容多寡无关，位置恒定）。
          // 图标/标题/正文/按钮四类元素均以阶段为 key 走模糊淡出淡入；
          // 布局尺寸由 layoutBuilder 固定跟随新内容，动画全程在最终位置
          // 进行，不会因新旧内容高度差产生位移
          return SizedBox(
            width: double.infinity,
            height: 300,
            child: Column(
              children: [
                // 内容区：弹性占位，剩余空间上下均分使内容视觉居中
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      blurSwitch(
                        KeyedSubtree(
                          key: ValueKey<_UpdatePhase>(phase),
                          child: icon,
                        ),
                      ),
                      const SizedBox(height: 16),
                      blurSwitch(
                        KeyedSubtree(
                          key: ValueKey<_UpdatePhase>(phase),
                          child: Text(
                            title,
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      blurSwitch(
                        KeyedSubtree(
                          key: ValueKey<_UpdatePhase>(phase),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: body,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                // 按钮区：固定在底部
                blurSwitch(
                  KeyedSubtree(
                    key: ValueKey<_UpdatePhase>(phase),
                    child: Row(
                      children: [
                        for (int i = 0; i < actions.length; i++) ...[
                          if (i > 0) const SizedBox(width: 12),
                          actions[i],
                        ],
                      ],
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
                            color: Colors.grey.shade600,
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
                                    side: BorderSide(color: Colors.grey.shade300),
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

  void _showEmailLoginDialog(AuthService auth) {
    final emailController = TextEditingController(text: auth.userEmail ?? '');
    final passwordController = TextEditingController();
    final confirmPasswordController = TextEditingController();
    bool isRegisterMode = false;
    bool isSubmitting = false;
    bool obscurePassword = true;
    bool obscureConfirmPassword = true;
    
    showBouncyDialog(
      context: context,
      barrierLabel: '电子邮箱登录',
      shellPadding: const EdgeInsets.all(24),
      shellBoxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.2),
          blurRadius: 20,
          offset: const Offset(0, 10),
        ),
      ],
      avoidKeyboard: true,
      // 壳总宽/总高约束含壳内边距（与旧版壳外 Container(constraints:) 一致）；
      // 键盘弹出时动态压缩最大高度，闭包内 MediaQuery 依赖使宿主自动重建
      shellConstraintsBuilder: (context) {
        final mediaQuery = MediaQuery.of(context);
        final keyboardHeight = mediaQuery.viewInsets.bottom;
        final topInset = mediaQuery.padding.top;
        final screenHeight = mediaQuery.size.height;
        // 注册模式比登录多一个确认密码字段，取消按钮必须完整露出、无需
        // 翻页：基础最大高度按注册模式内容取值（壳实际尺寸仍随内容收缩）
        const baseMaxHeight = 620.0;
        double dialogMaxHeight = baseMaxHeight;
        final availableHeight = screenHeight - topInset - keyboardHeight - 24;
        if (availableHeight < dialogMaxHeight) {
          dialogMaxHeight = availableHeight;
        }
        dialogMaxHeight = dialogMaxHeight.clamp(260.0, baseMaxHeight).toDouble();
        return BoxConstraints(maxWidth: 420, maxHeight: dialogMaxHeight);
      },
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final email = emailController.text.trim();
            final password = passwordController.text;
            final confirmPassword = confirmPasswordController.text;
            final isEmailValid = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email);
            final isPasswordValid = AuthService.isStrongPassword(password);
            final canSubmit = !isSubmitting &&
                isEmailValid &&
              isPasswordValid &&
                (!isRegisterMode || confirmPassword == password);

            Future<void> submit() async {
              if (!canSubmit) return;

              setDialogState(() {
                isSubmitting = true;
              });

              final success = isRegisterMode
                  ? await auth.registerWithEmailPassword(email, password)
                  : await auth.signInWithEmailPassword(email, password);
              if (!mounted) return;

              setDialogState(() {
                isSubmitting = false;
              });

              if (success) {
                if (Navigator.of(context).canPop()) {
                  Navigator.pop(context);
                }
                toastNotification.show(
                  this.context,
                  isRegisterMode ? '注册并登录成功' : '登录成功',
                  type: ToastType.success,
                );
                await _handlePostLoginSync();
              } else {
                toastNotification.show(
                  context,
                  auth.error ?? (isRegisterMode ? '注册失败，请稍后重试' : '登录失败，请检查邮箱和密码'),
                  type: ToastType.error,
                );
              }
            }

            // 登录/注册切换的高度过渡由确认密码框的占位展开动画驱动
            // （_FieldSlotAppear，下方元素与对话框高度逐帧同步），错误
            // 文案出现/消失的高度变化由各输入框自身的 AnimatedSize 平滑
            return SingleChildScrollView(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Opacity(
                                      opacity: 0.82,
                                      child: Container(
                                        width: 64,
                                        height: 64,
                                        decoration: BoxDecoration(
                                          color: const Color(0xFF4A90E2),
                                          borderRadius: BorderRadius.circular(16),
                                        ),
                                        child: const Icon(
                                          Icons.email_rounded,
                                          size: 32,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ),
                              const SizedBox(height: 16),
                              const Text(
                                '邮箱账号',
                                style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 8),
                              // 登录/注册副标题切换：模糊淡出淡入（与确认密码框的
                              // 模糊动效呼应），新旧文案交叉过渡不跳变
                              AnimatedSwitcher(
                                duration: const Duration(milliseconds: 220),
                                switchInCurve: Curves.easeOut,
                                switchOutCurve: Curves.easeIn,
                                transitionBuilder: (child, animation) => FadeTransition(
                                  opacity: animation,
                                  child: AnimatedBuilder(
                                    animation: animation,
                                    builder: (context, grandChild) => ImageFiltered(
                                      imageFilter: ImageFilter.blur(
                                        sigmaX: 6 * (1.0 - animation.value),
                                        sigmaY: 6 * (1.0 - animation.value),
                                      ),
                                      child: Transform.scale(
                                        scale: 0.92 + 0.08 * animation.value,
                                        child: grandChild,
                                      ),
                                    ),
                                    child: child,
                                  ),
                                ),
                                child: Text(
                                  isRegisterMode
                                      ? '使用邮箱和密码创建账号'
                                      : '使用邮箱和密码登录',
                                  key: ValueKey<bool>(isRegisterMode),
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: Colors.grey.shade600,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 20),
                              // AnimatedSize：错误文案出现/消失时输入框高度平滑过渡
                              AnimatedSize(
                                duration: const Duration(milliseconds: 180),
                                curve: Curves.easeOut,
                                alignment: Alignment.topCenter,
                                child: TextField(
                                  contextMenuBuilder: styledEditableContextMenu,
                                  controller: emailController,
                                  keyboardType: TextInputType.emailAddress,
                                  enabled: !isSubmitting,
                                  onChanged: (_) => setDialogState(() {}),
                                  decoration: InputDecoration(
                                    hintText: '请输入邮箱地址',
                                    errorText: email.isEmpty || isEmailValid ? null : '邮箱格式不正确',
                                    prefixIcon: const Icon(Icons.email_outlined),
                                    filled: true,
                                    fillColor: Colors.white.withValues(alpha: 0.4),
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 12),
                              AnimatedSize(
                                duration: const Duration(milliseconds: 180),
                                curve: Curves.easeOut,
                                alignment: Alignment.topCenter,
                                child: TextField(
                                  contextMenuBuilder: styledEditableContextMenu,
                                  controller: passwordController,
                                  keyboardType: TextInputType.visiblePassword,
                                  obscureText: obscurePassword,
                                  enabled: !isSubmitting,
                                  onChanged: (_) => setDialogState(() {}),
                                  decoration: InputDecoration(
                                    hintText: '请输入密码',
                                    errorText: password.isEmpty || isPasswordValid ? null : '密码需至少8位，且包含字母和数字',
                                    prefixIcon: const Icon(Icons.lock_outline_rounded),
                                    suffixIcon: IconButton(
                                      onPressed: () {
                                        setDialogState(() {
                                          obscurePassword = !obscurePassword;
                                        });
                                      },
                                      icon: Icon(obscurePassword ? Icons.visibility_off : Icons.visibility),
                                    ),
                                    filled: true,
                                    fillColor: Colors.white.withValues(alpha: 0.4),
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                                  ),
                                ),
                              ),
                              // 确认密码框常驻树内，由占位展开+模糊淡入动画
                              // 控制显隐（动画组件复刻课表切换对话框新增课表）
                              _FieldSlotAppear(
                                visible: isRegisterMode,
                                child: Padding(
                                  padding: const EdgeInsets.only(top: 12),
                                  child: AnimatedSize(
                                    duration: const Duration(milliseconds: 180),
                                    curve: Curves.easeOut,
                                    alignment: Alignment.topCenter,
                                    child: TextField(
                                    contextMenuBuilder: styledEditableContextMenu,
                                    controller: confirmPasswordController,
                                    keyboardType: TextInputType.visiblePassword,
                                    obscureText: obscureConfirmPassword,
                                    enabled: !isSubmitting,
                                    onChanged: (_) => setDialogState(() {}),
                                    decoration: InputDecoration(
                                        hintText: '请再次输入密码',
                                        errorText: confirmPassword.isEmpty || confirmPassword == password ? null : '两次密码输入不一致',
                                        prefixIcon: const Icon(Icons.lock_reset_rounded),
                                        suffixIcon: IconButton(
                                          onPressed: () {
                                            setDialogState(() {
                                              obscureConfirmPassword = !obscureConfirmPassword;
                                            });
                                          },
                                          icon: Icon(obscureConfirmPassword ? Icons.visibility_off : Icons.visibility),
                                        ),
                                        filled: true,
                                        fillColor: Colors.white.withValues(alpha: 0.4),
                                        border: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(12),
                                        ),
                                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 20),
                              SizedBox(
                                width: double.infinity,
                                child: ElevatedButton.icon(
                                  onPressed: canSubmit ? submit : null,
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFF4A90E2),
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(vertical: 14),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                  ),
                                  icon: Icon(isRegisterMode ? Icons.person_add_alt_1_rounded : Icons.login_rounded),
                                  label: Text(isSubmitting ? '处理中...' : (isRegisterMode ? '注册并登录' : '登录')),
                                ),
                              ),
                              const SizedBox(height: 8),
                              TextButton(
                                onPressed: isSubmitting
                                    ? null
                                    : () {
                                        setDialogState(() {
                                          isRegisterMode = !isRegisterMode;
                                        });
                                        auth.clearError();
                                      },
                                child: Text(isRegisterMode ? '已有账号？去登录' : '没有账号？去注册'),
                              ),
                              const SizedBox(height: 8),
                              // 与设置页其他对话框的取消按钮统一样式
                              // （默认主题色文字 + 灰描边）
                              SizedBox(
                                width: double.infinity,
                                child: TextButton(
                                  onPressed: isSubmitting
                                      ? null
                                      : () => Navigator.pop(context),
                                  style: TextButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(vertical: 14),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      side: BorderSide(color: Colors.grey.shade300),
                                    ),
                                  ),
                                  child: const Text('取消'),
                                ),
                              ),
                            ],
                          ),
                        );
          },
        );
      },
    ).whenComplete(() {
      // 弹窗退出动画（约 150ms）期间 TextField 仍会重建，
      // 立即 dispose 会触发 "TextEditingController used after being disposed"，
      // 因此延迟到动画结束后再释放
      Future<void>.delayed(const Duration(milliseconds: 300), () {
        emailController.dispose();
        passwordController.dispose();
        confirmPasswordController.dispose();
      });
    });
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

      final selectedIds = await _showLocalTimetableUploadSelectorDialog(localTimetables);
      if (!mounted || selectedIds == null || selectedIds.isEmpty) {
        return;
      }

      final selectedPayload = StorageService.exportSelectedDataByTimetableIds(selectedIds);
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

    final timetableNames = StorageService.getCloudBackupTimetableNames(cloudBackup.payload);
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

    final mode = await _showCloudImportModeDialog(cloudBackup.updatedAt, selectedTimetable);
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

  Future<List<String>?> _showLocalTimetableUploadSelectorDialog(List<TimetableInfo> timetables) {
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
                                color: Colors.grey.shade600,
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
                                  physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
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
                                        subtitle: '创建于 ${_formatDateTime(timetable.createdAt)}',
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
                                        side: BorderSide(color: Colors.grey.shade300),
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
                                        : () => Navigator.pop(dialogContext, selectedIds.toList()),
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
                            color: Colors.grey.shade600,
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
                                    side: BorderSide(color: Colors.grey.shade300),
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
                            color: Colors.grey.shade600,
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
                          onTap: () => Navigator.pop(dialogContext, _CloudSyncAction.syncFromCloud),
                        ),
                        const SizedBox(height: 10),
                        _buildAccountSyncActionTile(
                          icon: Icons.cloud_upload_rounded,
                          color: const Color(0xFF4A90E2),
                          title: '本地覆盖云端',
                          subtitle: '使用当前本地数据覆盖云端备份',
                          onTap: () => Navigator.pop(dialogContext, _CloudSyncAction.uploadLocalToCloud),
                        ),
                        const SizedBox(height: 16),
                        SizedBox(
                          width: double.infinity,
                          child: TextButton(
                            onPressed: () => Navigator.pop(dialogContext, _CloudSyncAction.skip),
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                                side: BorderSide(color: Colors.grey.shade300),
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
                            color: Colors.grey.shade600,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Flexible(
                          child: ScrollConfiguration(
                            behavior: ScrollConfiguration.of(dialogContext).copyWith(
                              physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
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
                                side: BorderSide(color: Colors.grey.shade300),
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

  Future<ImportMode?> _showCloudImportModeDialog(DateTime? updatedAt, String timetableName) {
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
                            color: Colors.grey.shade700,
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
                            color: Colors.grey.shade600,
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
                                side: BorderSide(color: Colors.grey.shade300),
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
                          color: Colors.grey.shade600,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: Colors.grey.shade400),
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
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: selected ? selectedColor.withValues(alpha: 0.12) : Colors.white.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? selectedColor : Colors.white.withValues(alpha: 0.4),
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
                  color: selected ? selectedColor : Colors.grey.shade400,
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
                      color: selected ? selectedColor : Colors.black87,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey.shade600,
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
                            color: Colors.grey.shade600,
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
                                    side: BorderSide(color: Colors.grey.shade300),
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
                                          toastNotification.show(context, '已退出登录', type: ToastType.info);
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

class SegmentItem<T> {
  final String label;
  final T value;
  const SegmentItem({required this.label, required this.value});
}

class SegmentedSelector<T> extends StatefulWidget {
  final List<SegmentItem<T>> items;
  final T activeValue;
  final ValueChanged<T> onChanged;

  const SegmentedSelector({super.key, 
    required this.items,
    required this.activeValue,
    required this.onChanged,
  });

  @override
  State<SegmentedSelector<T>> createState() => _SegmentedSelectorState<T>();
}

class _SegmentedSelectorState<T> extends State<SegmentedSelector<T>> {
  double _dragOffset = 0;
  bool _isDragging = false;
  bool _isLongPressing = false;
  Duration _textAnimDuration = const Duration(milliseconds: 250);

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final totalWidth = constraints.maxWidth;
        final n = widget.items.length;
        final internalWidth = totalWidth - 2;
        final segmentW = internalWidth / n;
        final activeIdx = widget.items.indexWhere((item) => item.value == widget.activeValue);
        if (activeIdx < 0) return const SizedBox.shrink();

        final effectiveIdx = _isDragging
            ? (activeIdx + _dragOffset / segmentW).clamp(0.0, (n - 1).toDouble())
            : activeIdx.toDouble();
        final left = 2.0 + effectiveIdx * segmentW;
        final visualActiveIdx = _isDragging ? effectiveIdx.round().clamp(0, n - 1) : activeIdx;
        final labels = widget.items.map((e) => e.label).toList();

        return GestureDetector(
          onTapUp: (details) {
            final tapX = details.localPosition.dx - 1;
            if (tapX < 0 || tapX >= internalWidth) return;
            final tappedIdx = (tapX / segmentW).floor().clamp(0, n - 1);
            if (tappedIdx == activeIdx) return;
            HapticFeedback.selectionClick();
            widget.onChanged(widget.items[tappedIdx].value);
          },
          onHorizontalDragStart: (_) {
            setState(() {
              _isDragging = true;
              _isLongPressing = true;
              _dragOffset = 0;
            });
          },
          onHorizontalDragUpdate: (details) {
            setState(() {
              _dragOffset += details.delta.dx;
              final minOffset = -activeIdx * segmentW;
              final maxOffset = (n - 1 - activeIdx) * segmentW;
              _dragOffset = _dragOffset.clamp(minOffset, maxOffset);
            });
          },
          onHorizontalDragEnd: (details) {
            setState(() {
              _isDragging = false;
              _isLongPressing = false;
            });
            _textAnimDuration = Duration.zero;
            if (mounted) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) {
                  setState(() => _textAnimDuration = const Duration(milliseconds: 250));
                }
              });
            }
            final velocity = details.primaryVelocity ?? 0;
            final extra = velocity > 0 ? -segmentW / 3 : velocity < 0 ? segmentW / 3 : 0.0;
            final totalOffset = _dragOffset + extra;
            int targetIdx = (activeIdx + totalOffset / segmentW).round().clamp(0, n - 1);
            _dragOffset = 0;
            if (targetIdx != activeIdx) {
              HapticFeedback.selectionClick();
              widget.onChanged(widget.items[targetIdx].value);
            }
          },
          onHorizontalDragCancel: () {
            setState(() {
              _isDragging = false;
              _isLongPressing = false;
              _dragOffset = 0;
            });
          },
          onLongPressStart: (_) {
            setState(() => _isLongPressing = true);
          },
          onLongPressEnd: (_) {
            setState(() => _isLongPressing = false);
          },
          child: Container(
            height: 40,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.grey.shade300, width: 1),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(9),
              child: Stack(
                children: [
                  AnimatedPositioned(
                    duration: _isDragging ? Duration.zero : const Duration(milliseconds: 250),
                    curve: Curves.easeInOut,
                    left: left,
                    top: 2,
                    bottom: 2,
                    child: AnimatedScale(
                      scale: (_isDragging || _isLongPressing) ? 1.04 : 1.0,
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeInOut,
                      child: Container(
                        width: segmentW - 4,
                        decoration: BoxDecoration(
                          color: Colors.grey.shade800,
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  ),
                  if (_isDragging)
                    Row(
                      children: labels.map((label) => Expanded(
                        child: Center(
                          child: AnimatedDefaultTextStyle(
                            duration: Duration.zero,
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.normal, color: Colors.black87),
                            child: Text(label),
                          ),
                        ),
                      )).toList(),
                    ),
                  if (_isDragging)
                    Positioned.fill(
                      child: ShaderMask(
                        shaderCallback: (bounds) {
                          final relLeft = (left / bounds.width).clamp(0.0, 1.0);
                          const edge = 0.015;
                          final relStart = (relLeft - edge).clamp(0.0, 1.0);
                          final relEnd = ((left + segmentW - 4) / bounds.width).clamp(0.0, 1.0);
                          final relStop = (relEnd + edge).clamp(0.0, 1.0);
                          return LinearGradient(
                            begin: Alignment.centerLeft,
                            end: Alignment.centerRight,
                            colors: const [
                              Colors.transparent,
                              Colors.transparent,
                              Colors.white,
                              Colors.white,
                              Colors.transparent,
                              Colors.transparent,
                            ],
                            stops: [0.0, relStart, relLeft, relEnd, relStop, 1.0],
                          ).createShader(bounds);
                        },
                        blendMode: BlendMode.dstIn,
                        child: Row(
                          children: labels.map((label) => Expanded(
                            child: Center(
                              child: AnimatedDefaultTextStyle(
                                duration: Duration.zero,
                                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.normal, color: Colors.white),
                                child: Text(label),
                              ),
                            ),
                          )).toList(),
                        ),
                      ),
                    ),
                  if (!_isDragging)
                    Row(
                      children: labels.asMap().entries.map((entry) {
                        return Expanded(
                          child: Center(
                            child: AnimatedDefaultTextStyle(
                              duration: _textAnimDuration,
                              curve: Curves.easeInOut,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.normal,
                                color: entry.key == visualActiveIdx ? Colors.white : Colors.black87,
                              ),
                              child: Text(entry.value),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildBaseTextRow(List<String> labels, Color color, FontWeight weight) {
    return Row(
      children: labels.map((label) => Expanded(
        child: Center(
          child: Text(label, style: TextStyle(fontSize: 13, fontWeight: weight, color: color)),
        ),
      )).toList(),
    );
  }
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
    if (_initialized && _controller != null && _controller!.value.isInitialized) {
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
              child: const Icon(Icons.play_arrow, color: Colors.white, size: 18),
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
          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white54),
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
    final maxTipWidth =
        MediaQuery.of(context).size.width - widget.left - 16;
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
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.grey.shade300),
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
                color: Colors.grey.shade600,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 登录对话框确认密码框的两段式出现动画（复刻课表切换对话框「新增课表」）：
/// 1) 占位展开 200ms easeInCubic：内容不可见，占位高度逐帧展开，下方
///    元素连贯位移、对话框高度同步增长；
/// 2) 出现 220ms easeOutCubic：由中心模糊扩大淡入
///    （sigma 14→0 + scale 0.55→1 + 淡入）。
/// 收起（注册切回登录）时逆序播放。单个控制器用 Interval 切分两阶段，
/// expand 到 200/420 后保持 1，appear 在 200/420 前恒为 0。
class _FieldSlotAppear extends StatefulWidget {
  final bool visible;
  final Widget child;

  const _FieldSlotAppear({required this.visible, required this.child});

  @override
  State<_FieldSlotAppear> createState() => _FieldSlotAppearState();
}

class _FieldSlotAppearState extends State<_FieldSlotAppear>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
    value: widget.visible ? 1.0 : 0.0,
  );

  static const double _expandFraction = 200 / 420;

  // 阶段一：占位展开（0 ~ 200/420）；阶段二：出现（200/420 ~ 1）
  late final Animatable<double> _expandChain = CurveTween(
    curve: const Interval(0.0, _expandFraction, curve: Curves.easeInCubic),
  );
  late final Animatable<double> _appearChain = CurveTween(
    curve: const Interval(_expandFraction, 1.0, curve: Curves.easeOutCubic),
  );

  @override
  void didUpdateWidget(covariant _FieldSlotAppear oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible == oldWidget.visible) return;
    if (widget.visible) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final expand = _expandChain.transform(_controller.value);
        final appear = _appearChain.transform(_controller.value);
        return SizeTransition(
          sizeFactor: AlwaysStoppedAnimation(expand.clamp(0.0, 1.0)),
          axisAlignment: -1.0,
          child: Opacity(
            opacity: appear.clamp(0.0, 1.0),
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(
                sigmaX: 14 * (1.0 - appear),
                sigmaY: 14 * (1.0 - appear),
              ),
              child: Transform.scale(
                scale: 0.55 + 0.45 * appear,
                child: child,
              ),
            ),
          ),
        );
      },
      child: widget.child,
    );
  }
}

/// Agnes AI 配置对话框标题问号：点击向下弹出推荐说明气泡
/// （样式与动画同问号提示框），点击空白处收回
class _AgnesHelpIcon extends StatefulWidget {
  final bool reduceMotion;

  const _AgnesHelpIcon({required this.reduceMotion});

  @override
  State<_AgnesHelpIcon> createState() => _AgnesHelpIconState();
}

class _AgnesHelpIconState extends State<_AgnesHelpIcon> {
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
    // 气泡固定 300 宽（窄屏收缩至屏幕宽减 32），左缘对齐问号左侧并
    // 夹在屏幕内（左右各留 16px 边距）
    final tipWidth = (screenWidth - 32).clamp(120.0, 300.0).toDouble();
    final left = (iconPos.dx - 12)
        .clamp(16.0, (screenWidth - tipWidth - 16).clamp(16.0, double.infinity))
        .toDouble();
    // 气泡顶边位于问号图标下方 6px（向下弹出）
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
          _AgnesHelpTip(
            visible: _tipVisible,
            left: left,
            top: top,
            width: tipWidth,
            reduceMotion: widget.reduceMotion,
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
        color: Colors.grey.shade500,
      ),
    );
  }
}

/// 标题问号（向下弹出通用版）：点击在问号下方弹出说明气泡
/// （样式与动画同问号提示框），点击空白处收回
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
        color: Colors.grey.shade500,
      ),
    );
  }
}

/// Agnes AI 推荐说明气泡：自问号下方向下弹出，收回时向上缩回
class _AgnesHelpTip extends StatefulWidget {
  final bool visible;
  final double left;
  final double top;
  final double width;
  final bool reduceMotion;
  final VoidCallback? onDismissed;

  const _AgnesHelpTip({
    required this.visible,
    required this.left,
    required this.top,
    required this.width,
    required this.reduceMotion,
    this.onDismissed,
  });

  @override
  State<_AgnesHelpTip> createState() => _AgnesHelpTipState();
}

class _AgnesHelpTipState extends State<_AgnesHelpTip>
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
  void didUpdateWidget(covariant _AgnesHelpTip oldWidget) {
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

  Future<void> _openUrl() async {
    final uri = Uri.parse('https://www.agnes-ai.cn/');
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
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
                // 顶部对齐缩放：视觉上自问号处向下展开/向上收起
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
            width: widget.width,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.grey.shade300),
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
                  '为什么推荐使用此供应商？',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey.shade700,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Agnes AI现面向全球用户针对部分模型提供免费API，经测试这些模型足以发挥出CourseHub的全部Agent能力。在使用过程中，我们推荐您将思考强度设置为Medium。',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey.shade600,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '您可在如下网址注册一个账号获取API并开始免费使用CourseHub的所有功能。',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey.shade600,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 4),
                GestureDetector(
                  onTap: _openUrl,
                  child: const Text(
                    'https://www.agnes-ai.cn/',
                    style: TextStyle(
                      fontSize: 12,
                      color: Color(0xFF4A90E2),
                      decoration: TextDecoration.underline,
                      decorationColor: Color(0xFF4A90E2),
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
    final tipWidth = screenSize.width - 32 < 280
        ? screenSize.width - 32
        : 280.0;
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
          color: Colors.grey.shade500,
          decoration: TextDecoration.underline,
          decorationColor: Colors.grey.shade500,
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
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.grey.shade300),
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
                    color: Colors.grey.shade600,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 8),
                // 点击复制邮箱
                GestureDetector(
                  onTap: () {
                    Clipboard.setData(const ClipboardData(text: 'zwt70@outlook.com'));
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
                      color: Colors.grey.shade600,
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
                      color: Colors.grey.shade600,
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
