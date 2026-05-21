import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../dialogs/ai_consent_dialog.dart';
import '../utils/storage.dart';
import '../widgets/animated_calendar.dart';
import '../widgets/toast_notification.dart';
import '../widgets/time_picker_dialog.dart';
import '../services/auth_service.dart';
import '../services/cloud_sync_service.dart';
import '../services/glm_service.dart';
import '../services/notification_service.dart';

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
  AIProvider _aiProvider = AIProvider.hunyuan;
  bool _aiEnabled = false;
  bool _aiConsentAccepted = false;
  bool _fastModeEnabled = false;
  bool _isCustomProvider = false;
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
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<_CustomVisionMode>(
          value: value,
          isDense: true,
          borderRadius: BorderRadius.circular(12),
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
  }

  Future<void> _selectWallpaperImage() async {
    final prefs = await SharedPreferences.getInstance();
    final recentPaths = prefs.getStringList('wallpaper_recent_paths') ?? [];
    bool localEnabled = _wallpaperEnabled;

    final dialogPaths = List<String>.from(recentPaths);
    bool dialogDeleteMode = false;
    int? deletingIndex;
    bool newWallpaperSelected = false;

    await showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: '课表壁纸',
      barrierColor: Colors.black.withValues(alpha: 0.5),
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (context, animation, secondaryAnimation) {
        return BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
          child: Center(
            child: Material(
              color: Colors.transparent,
              child: FadeTransition(
                opacity: animation,
                child: ScaleTransition(
                  scale: Tween<double>(begin: 0.9, end: 1.0).animate(
                    CurvedAnimation(parent: animation, curve: Curves.easeOut),
                  ),
                  child: StatefulBuilder(
                    builder: (builderCtx, setDialogState) {
                      return Container(
                        width: 320,
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.1),
                              blurRadius: 20,
                              offset: const Offset(0, 10),
                            ),
                          ],
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text(
                              '课表壁纸',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF1A1A2E),
                              ),
                            ),
                            const SizedBox(height: 16),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              decoration: BoxDecoration(
                                color: Colors.grey.shade50,
                                borderRadius: BorderRadius.circular(10),
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
                                    activeColor: const Color(0xFF4A90E2),
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
                                                      ? Image.file(file, fit: BoxFit.cover)
                                                      : Container(
                                                          color: Colors.grey.shade100,
                                                          child: Icon(Icons.broken_image, color: Colors.grey.shade400),
                                                        ),
                                                  Container(
                                                    decoration: BoxDecoration(
                                                      borderRadius: BorderRadius.circular(12),
                                                      border: Border.all(
                                                        color: isActive && localEnabled
                                                            ? const Color(0xFF4A90E2)
                                                            : Colors.grey.shade300,
                                                        width: isActive && localEnabled ? 2.5 : 1,
                                                      ),
                                                    ),
                                                  ),
                                                  if (!localEnabled)
                                                    Container(
                                                      color: Colors.white.withValues(alpha: 0.6),
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
                                            final ImagePicker picker = ImagePicker();
                                            final XFile? image = await picker.pickImage(
                                              source: ImageSource.gallery,
                                              maxWidth: 1920,
                                              imageQuality: 90,
                                            );
                                            if (image != null) {
                                              newWallpaperSelected = true;
                                              dialogPaths.insert(0, image.path);
                                              if (dialogPaths.length > 5) {
                                                dialogPaths.removeLast();
                                              }
                                              await prefs.setStringList('wallpaper_recent_paths', dialogPaths);
                                              await prefs.setString('wallpaper_path', image.path);
                                              if (!_wallpaperEnabled) {
                                                await prefs.setBool('wallpaper_enabled', true);
                                                localEnabled = true;
                                                setState(() {
                                                  _wallpaperEnabled = true;
                                                });
                                              }
                                              setState(() {
                                                _wallpaperPath = image.path;
                                              });
                                              setDialogState(() {});
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
                                                color: Colors.grey.shade100,
                                                child: Column(
                                                  mainAxisAlignment: MainAxisAlignment.center,
                                                  children: [
                                                    Icon(Icons.add, color: Colors.grey.shade500, size: 32),
                                                    const SizedBox(height: 4),
                                                    Text('添加图片', style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
                                                  ],
                                                ),
                                              ),
                                              Container(
                                                decoration: BoxDecoration(
                                                  borderRadius: BorderRadius.circular(12),
                                                  border: Border.all(color: Colors.grey.shade300),
                                                ),
                                              ),
                                              if (!localEnabled)
                                                Container(
                                                  color: Colors.white.withValues(alpha: 0.6),
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
                              ],
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
    if (!newWallpaperSelected && _wallpaperPath == null) {
      _wallpaperEnabled = false;
      await prefs.setBool('wallpaper_enabled', false);
      if (mounted) setState(() {});
    }
  }

  void _selectWallpaperOpacity() {
    int selectedOpacity = _wallpaperOpacity;
    bool localBlur = _wallpaperBlurEnabled;
    final scrollController = FixedExtentScrollController(
      initialItem: (selectedOpacity - 50) ~/ 5,
    );

    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: '背景透明度',
      barrierColor: Colors.black.withValues(alpha: 0.5),
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (context, animation, secondaryAnimation) {
        return BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
          child: Center(
            child: Material(
              color: Colors.transparent,
              child: FadeTransition(
                opacity: animation,
                child: ScaleTransition(
                  scale: Tween<double>(begin: 0.9, end: 1.0).animate(
                    CurvedAnimation(parent: animation, curve: Curves.easeOut),
                  ),
                  child: StatefulBuilder(
                    builder: (context, setDialogState) {
                      return Container(
                        width: 280,
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.1),
                              blurRadius: 20,
                              offset: const Offset(0, 10),
                            ),
                          ],
                        ),
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
                            const SizedBox(height: 12),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              decoration: BoxDecoration(
                                color: Colors.grey.shade50,
                                borderRadius: BorderRadius.circular(10),
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
                                    activeColor: const Color(0xFF4A90E2),
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
                                    onPressed: () async {
                                      final prefs = await SharedPreferences.getInstance();
                                      await prefs.setInt('wallpaper_opacity', selectedOpacity);
                                      await prefs.setBool('wallpaper_blur_enabled', localBlur);
                                      setState(() {
                                        _wallpaperOpacity = selectedOpacity;
                                        _wallpaperBlurEnabled = localBlur;
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
                ),
              ),
            ),
          ),
        );
      },
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
      _providerConfigured = providerStr != null && providerStr.isNotEmpty;
      if (providerStr == 'glm') {
        _aiProvider = AIProvider.glm;
        _isCustomProvider = false;
      } else if (providerStr == 'doubao') {
        _aiProvider = AIProvider.hunyuan;
        _isCustomProvider = false;
      } else if (providerStr == 'custom') {
        _aiProvider = AIProvider.custom;
        _isCustomProvider = true;
      } else {
        _aiProvider = AIProvider.hunyuan;
        _isCustomProvider = false;
      }
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
          CustomScrollView(
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
                            subtitle: '第 ${StorageService.getCurrentWeek()} 周',
                            trailing: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                              decoration: BoxDecoration(
                                color: const Color(0xFF4A90E2).withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                '第 ${StorageService.getCurrentWeek()} 周',
                                style: const TextStyle(
                                  color: Color(0xFF4A90E2),
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
                            subtitle: '点击编辑每节课时间',
                            onTap: _showTimeSlotsDialog,
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
                            subtitle: _taskNotificationEnabled
                                ? '已开启'
                                : '开启后可接收任务截止提醒',
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
                              activeColor: const Color(0xFF4A90E2),
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
                            subtitle: _aiEnabled 
                                ? '已启动' 
                                : '点击启动AI服务',
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
                              activeColor: const Color(0xFF4A90E2),
                            ),
                          ),
                          _buildDivider(),
                          _buildSettingsItem(
                            icon: Icons.settings_outlined,
                            title: 'AI配置',
                            subtitle: _aiEnabled
                                ? '选择或配置AI服务提供商'
                                : '开启AI后可用',
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
                        ]),
                        const SizedBox(height: 24),
                        _buildSectionTitle('数据管理'),
                        const SizedBox(height: 12),
                        _buildSettingsGroup([
                          _buildSettingsItem(
                            icon: Icons.info_outline,
                            title: '关于',
                            subtitle: 'CourseHub v1.0.5',
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
    required String title,
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
      title: Text(
        title,
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

    if (provider == 'hunyuan') {
      final id = prefs.getString('tencent_secret_id') ?? '';
      final key = prefs.getString('tencent_secret_key') ?? '';
      return id.isNotEmpty && key.isNotEmpty;
    }
    if (provider == 'glm') {
      final key = prefs.getString('glm_api_key') ?? '';
      return key.isNotEmpty;
    }
    if (provider == 'custom') {
      final url = prefs.getString('custom_api_url') ?? '';
      final key = prefs.getString('custom_api_key') ?? '';
      return url.isNotEmpty && key.isNotEmpty;
    }
    return false;
  }

  Future<void> _showDeveloperOptionsDialog() {
    return showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'AI功能配置',
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (context, animation, secondaryAnimation) {
        final mediaQuery = MediaQuery.of(context);
        final keyboardHeight = mediaQuery.viewInsets.bottom;
        final topInset = mediaQuery.padding.top;
        final screenHeight = mediaQuery.size.height;
        const baseMaxHeight = 600.0;
        double dialogMaxHeight = baseMaxHeight;
        final availableHeight = screenHeight - topInset - keyboardHeight - 24;
        if (availableHeight < dialogMaxHeight) {
          dialogMaxHeight = availableHeight;
        }
        dialogMaxHeight = dialogMaxHeight.clamp(280.0, baseMaxHeight).toDouble();

        return BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
          child: Center(
            child: Material(
              color: Colors.transparent,
              child: FadeTransition(
                opacity: animation,
                child: ScaleTransition(
                  scale: Tween<double>(begin: 0.9, end: 1.0).animate(
                    CurvedAnimation(parent: animation, curve: Curves.easeOut),
                  ),
                  child: StatefulBuilder(
                    builder: (context, setDialogState) {
                      return AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        curve: Curves.easeOut,
                        margin: EdgeInsets.only(
                          left: 24,
                          right: 24,
                          top: keyboardHeight > 0 ? topInset + 8 : 0,
                          bottom: keyboardHeight > 0 ? keyboardHeight + 8 : 0,
                        ),
                        padding: const EdgeInsets.all(24),
                        constraints: BoxConstraints(maxWidth: 400, maxHeight: dialogMaxHeight),
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
                                      Row(
                                        children: [
                                          Expanded(
                                            child: Container(
                                              height: 1,
                                              color: Colors.grey.shade200,
                                            ),
                                          ),
                                          Padding(
                                            padding: const EdgeInsets.symmetric(horizontal: 12),
                                            child: Text(
                                              '自定义API',
                                              style: TextStyle(
                                                fontSize: 12,
                                                color: Colors.grey.shade500,
                                              ),
                                            ),
                                          ),
                                          Expanded(
                                            child: Container(
                                              height: 1,
                                              color: Colors.grey.shade200,
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 16),
                                      _buildCustomAPIOption(
                                        title: '自定义 OpenAI 兼容 API',
                                        subtitle: '输入您的API地址和密钥',
                                        icon: Icons.api,
                                        isSelected: _providerConfigured && _isCustomProvider,
                                        onTap: () async {
                                          await _showCustomAPIDialog();
                                          if (mounted) {
                                            setDialogState(() {});
                                          }
                                        },
                                      ),
                                      const SizedBox(height: 24),
                                      Row(
                                        children: [
                                          Expanded(
                                            child: Container(
                                              height: 1,
                                              color: Colors.grey.shade200,
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
                                              color: Colors.grey.shade200,
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 16),
                                      _buildRecommendedOption(
                                        title: '混元 Lite',
                                        subtitle: '腾讯云，速度快，完全免费',
                                        icon: Icons.cloud_outlined,
                                        color: Colors.green,
                                        isSelected: _providerConfigured && _aiProvider == AIProvider.hunyuan,
                                        onTap: () async {
                                          await _showHunyuanConfigDialog();
                                          if (mounted) {
                                            setDialogState(() {});
                                          }
                                        },
                                      ),
                                      const SizedBox(height: 12),
                                      _buildRecommendedOption(
                                        title: 'GLM-4.7-Flash',
                                        subtitle: '智谱AI，完全免费',
                                        icon: Icons.auto_awesome,
                                        color: Colors.purple,
                                        isSelected: _providerConfigured && _aiProvider == AIProvider.glm,
                                        onTap: () async {
                                          await _showGLMApiDialog();
                                          if (mounted) {
                                            setDialogState(() {});
                                          }
                                        },
                                      ),
                                      const SizedBox(height: 12),
                                      _buildRecommendedOption(
                                        title: '火山引擎模型包',
                                        subtitle: '由于算力短缺目前暂不开放',
                                        icon: Icons.local_fire_department_outlined,
                                        color: Colors.grey,
                                        isSelected: false,
                                        disabled: true,
                                        onTap: () {},
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
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
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
          color: isSelected ? const Color(0xFF4A90E2).withValues(alpha: 0.1) : Colors.grey.shade50,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? const Color(0xFF4A90E2) : Colors.grey.shade200,
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
                    : Colors.grey.shade200,
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
    required IconData icon,
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
            color: isSelected ? color.withValues(alpha: 0.1) : Colors.grey.shade50,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isSelected ? color : Colors.grey.shade200,
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
                child: Icon(icon, size: 20, color: color),
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
              if (isSelected)
              Icon(Icons.check_circle, color: color, size: 20),
          ],
        ),
      ),
      ),
    );
  }

  Future<void> _showCustomAPIDialog() async {
    final prefs = await SharedPreferences.getInstance();
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
            _aiProvider = AIProvider.custom;
            _isCustomProvider = true;
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

    await showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: '自定义API',
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (context, animation, secondaryAnimation) {
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

        return BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
          child: Center(
            child: Material(
              color: Colors.transparent,
              child: FadeTransition(
                opacity: animation,
                child: ScaleTransition(
                  scale: Tween<double>(begin: 0.9, end: 1.0).animate(
                    CurvedAnimation(parent: animation, curve: Curves.easeOut),
                  ),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOut,
                    margin: EdgeInsets.only(
                      left: 24,
                      right: 24,
                      top: keyboardHeight > 0 ? topInset + 8 : 0,
                      bottom: keyboardHeight > 0 ? keyboardHeight + 8 : 0,
                    ),
                    padding: const EdgeInsets.all(24),
                    constraints: BoxConstraints(maxWidth: 420, maxHeight: dialogMaxHeight),
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
                    child: StatefulBuilder(
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
                                controller: urlController,
                                decoration: InputDecoration(
                                  labelText: 'API 地址',
                                  hintText: 'https://api.example.com/v1/chat/completions',
                                  filled: true,
                                  fillColor: Colors.grey.shade50,
                                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                                ),
                              ),
                              const SizedBox(height: 12),
                              TextField(
                                controller: keyController,
                                decoration: InputDecoration(
                                  labelText: 'API Key',
                                  hintText: '请输入API密钥',
                                  filled: true,
                                  fillColor: Colors.grey.shade50,
                                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                                ),
                              ),
                              const SizedBox(height: 12),
                              TextField(
                                controller: modelController,
                                decoration: InputDecoration(
                                  labelText: '模型名称',
                                  hintText: 'gpt-4o-mini',
                                  filled: true,
                                  fillColor: Colors.grey.shade50,
                                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                                ),
                              ),
                              const SizedBox(height: 12),
                              const Text('视觉能力支持', style: TextStyle(fontSize: 13, color: Colors.black87)),
                              const SizedBox(height: 8),
                              _SegmentedSelector<_CustomVisionMode>(
                                items: const [
                                  _SegmentItem(label: '自动', value: _CustomVisionMode.auto),
                                  _SegmentItem(label: '开启', value: _CustomVisionMode.enabled),
                                  _SegmentItem(label: '关闭', value: _CustomVisionMode.disabled),
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
                              _SegmentedSelector<String>(
                                items: const [
                                  _SegmentItem(label: '直接回答', value: ''),
                                  _SegmentItem(label: 'Low', value: 'low'),
                                  _SegmentItem(label: 'Medium', value: 'medium'),
                                  _SegmentItem(label: 'High', value: 'high'),
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
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _showHunyuanConfigDialog() async {
    final prefs = await SharedPreferences.getInstance();

    final secretIdController = TextEditingController(
      text: prefs.getString('tencent_secret_id') ?? '',
    );
    final secretKeyController = TextEditingController(
      text: prefs.getString('tencent_secret_key') ?? '',
    );

    await showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: '混元配置',
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (context, animation, secondaryAnimation) {
        final mediaQuery = MediaQuery.of(context);
        final keyboardHeight = mediaQuery.viewInsets.bottom;
        final topInset = mediaQuery.padding.top;
        final screenHeight = mediaQuery.size.height;
        const baseMaxHeight = 620.0;
        double dialogMaxHeight = baseMaxHeight;
        final availableHeight = screenHeight - topInset - keyboardHeight - 24;
        if (availableHeight < dialogMaxHeight) {
          dialogMaxHeight = availableHeight;
        }
        dialogMaxHeight = dialogMaxHeight.clamp(320.0, baseMaxHeight).toDouble();

        return BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
          child: Center(
            child: Material(
              color: Colors.transparent,
              child: FadeTransition(
                opacity: animation,
                child: ScaleTransition(
                  scale: Tween<double>(begin: 0.9, end: 1.0).animate(
                    CurvedAnimation(parent: animation, curve: Curves.easeOut),
                  ),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOut,
                    margin: EdgeInsets.only(
                      left: 24,
                      right: 24,
                      top: keyboardHeight > 0 ? topInset + 8 : 0,
                      bottom: keyboardHeight > 0 ? keyboardHeight + 8 : 0,
                    ),
                    padding: const EdgeInsets.all(24),
                    constraints: BoxConstraints(maxWidth: 420, maxHeight: dialogMaxHeight),
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
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 64,
                            height: 64,
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(
                                colors: [Color(0xFF00C853), Color(0xFF69F0AE)],
                              ),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: const Icon(
                              Icons.cloud_outlined,
                              size: 32,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(height: 16),
                          const Text(
                            '混元 Secret 配置',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '腾讯云密钥获取地址：\nhttps://console.cloud.tencent.com',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 13,
                              color: Colors.grey.shade600,
                            ),
                          ),
                          const SizedBox(height: 20),
                          TextField(
                            controller: secretIdController,
                            decoration: InputDecoration(
                              labelText: 'SecretId',
                              hintText: '请输入腾讯云 SecretId',
                              filled: true,
                              fillColor: Colors.grey.shade50,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: secretKeyController,
                            obscureText: true,
                            decoration: InputDecoration(
                              labelText: 'SecretKey',
                              hintText: '请输入腾讯云 SecretKey',
                              filled: true,
                              fillColor: Colors.grey.shade50,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
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
                                    final secretId = secretIdController.text.trim();
                                    final secretKey = secretKeyController.text.trim();

                                    if (secretId.isEmpty || secretKey.isEmpty) {
                                      toastNotification.show(context, '请填写 SecretId 和 SecretKey', type: ToastType.error);
                                      return;
                                    }

                                    await prefs.setString('tencent_secret_id', secretId);
                                    await prefs.setString('tencent_secret_key', secretKey);
                                    await prefs.remove('hunyuan_api_key');
                                    await prefs.setString('ai_provider', 'hunyuan');
                                    await prefs.setBool('fast_mode_enabled', false);
                                    await prefs.setBool('ai_enabled', true);

                                    AIService.instance.setHunyuanCredentials(secretId, secretKey);

                                    if (mounted) {
                                      Navigator.pop(context);
                                      setState(() {
                                        _aiProvider = AIProvider.hunyuan;
                                        _isCustomProvider = false;
                                        _fastModeEnabled = false;
                                        _providerConfigured = true;
                                        _aiEnabled = true;
                                      });
                                      toastNotification.show(context, '已切换到混元模型', type: ToastType.success);
                                    }
                                  },
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.green,
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
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _selectDoubaoProvider() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('ai_provider', 'doubao');
    AIService.instance.setDoubaoProvider();
    
    final random = DateTime.now().millisecondsSinceEpoch % 6;
    final models = ['GLM-4.7', 'DeepSeek-V3.2', 'Doubao-Seed-v2.0-lite', 'DeepSeek-v3', 'Doubao-Seed-2.0-mini', 'DeepSeek-v3.1'];
    final selectedModel = models[random];
    await prefs.setString('selected_model', selectedModel);
    
    setState(() {
      _aiProvider = AIProvider.doubao;
      _isCustomProvider = false;
    });
    if (mounted) {
      Navigator.pop(context);
      toastNotification.show(context, '已选择火山引擎模型库', type: ToastType.info);
    }
  }

  Future<void> _showGLMApiDialog() async {
    final prefs = await SharedPreferences.getInstance();
    final controller = TextEditingController(text: prefs.getString('glm_api_key') ?? '');

    await showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'GLM API Key',
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (context, animation, secondaryAnimation) {
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

        return BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
          child: Center(
            child: Material(
              color: Colors.transparent,
              child: FadeTransition(
                opacity: animation,
                child: ScaleTransition(
                  scale: Tween<double>(begin: 0.9, end: 1.0).animate(
                    CurvedAnimation(parent: animation, curve: Curves.easeOut),
                  ),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOut,
                    margin: EdgeInsets.only(
                      left: 24,
                      right: 24,
                      top: keyboardHeight > 0 ? topInset + 8 : 0,
                      bottom: keyboardHeight > 0 ? keyboardHeight + 8 : 0,
                    ),
                    padding: const EdgeInsets.all(24),
                    constraints: BoxConstraints(maxWidth: 420, maxHeight: dialogMaxHeight),
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
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                        Container(
                          width: 64,
                          height: 64,
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [Color(0xFF9C27B0), Color(0xFFBA68C8)],
                            ),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: const Icon(
                            Icons.auto_awesome,
                            size: 32,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 16),
                        const Text(
                          'GLM-4.7-Flash 配置',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'GLM API Key 获取地址：\nhttps://open.bigmodel.cn',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 13,
                            color: Colors.grey.shade600,
                          ),
                        ),
                        const SizedBox(height: 20),
                        TextField(
                          controller: controller,
                          decoration: InputDecoration(
                            hintText: '请输入API Key',
                            filled: true,
                            fillColor: Colors.grey.shade50,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(color: Colors.grey.shade300),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(color: Colors.grey.shade300),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: const BorderSide(color: Color(0xFF9C27B0)),
                            ),
                          ),
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
                                    toastNotification.show(context, '请填写 GLM API Key', type: ToastType.error);
                                    return;
                                  }

                                  await prefs.setString('glm_api_key', apiKey);
                                  await prefs.setString('ai_provider', 'glm');
                                  await prefs.setBool('fast_mode_enabled', false);
                                  await prefs.setBool('ai_enabled', true);
                                  AIService.instance.setGLMApiKey(apiKey);

                                  if (mounted) {
                                      Navigator.pop(context);
                                      setState(() {
                                        _aiProvider = AIProvider.glm;
                                        _isCustomProvider = false;
                                        _fastModeEnabled = false;
                                        _providerConfigured = true;
                                        _aiEnabled = true;
                                      });
                                      toastNotification.show(context, '已切换到GLM模型', type: ToastType.success);
                                    }
                                  },
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF9C27B0),
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
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _selectSemesterStartDate() async {
    await showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: '选择日期',
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (context, animation, secondaryAnimation) {
        final screenWidth = MediaQuery.of(context).size.width;
        final dialogWidth = screenWidth > 400 ? 360.0 : screenWidth * 0.9;
        
        return BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
          child: Center(
            child: Material(
              color: Colors.transparent,
              child: FadeTransition(
                opacity: animation,
                child: ScaleTransition(
                  scale: Tween<double>(begin: 0.9, end: 1.0).animate(
                    CurvedAnimation(parent: animation, curve: Curves.easeOut),
                  ),
                  child: Container(
                    width: dialogWidth,
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
                    child: AnimatedCalendarDatePicker(
                      initialDate: _semesterStartDate,
                      firstDate: DateTime(2020),
                      lastDate: DateTime(2030),
                      onDateChanged: (date) async {
                        await StorageService.setSemesterStartDate(date);
                        setState(() {
                          _semesterStartDate = date;
                        });
                        Navigator.pop(context);
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _selectSemesterWeeks() async {
    int selectedWeeks = _semesterWeeks;
    final FixedExtentScrollController scrollController = FixedExtentScrollController(initialItem: selectedWeeks - 1);
    
    await showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: '学期周数',
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (context, animation, secondaryAnimation) {
        return BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
          child: Center(
            child: Material(
              color: Colors.transparent,
              child: FadeTransition(
                opacity: animation,
                child: ScaleTransition(
                  scale: Tween<double>(begin: 0.9, end: 1.0).animate(
                    CurvedAnimation(parent: animation, curve: Curves.easeOut),
                  ),
                  child: StatefulBuilder(
                    builder: (context, setDialogState) {
                      return Container(
                        width: 280,
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.1),
                              blurRadius: 20,
                              offset: const Offset(0, 10),
                            ),
                          ],
                        ),
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
                ),
              ),
            ),
          ),
        );
      },
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        return FadeTransition(
          opacity: animation,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.9, end: 1.0).animate(
              CurvedAnimation(parent: animation, curve: Curves.easeOut),
            ),
            child: child,
          ),
        );
      },
    );
  }

  Future<void> _selectDailyPeriods() async {
    int selectedPeriods = _dailyPeriods;
    final FixedExtentScrollController scrollController = FixedExtentScrollController(initialItem: selectedPeriods - 1);
    
    await showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: '每日节数',
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (context, animation, secondaryAnimation) {
        return BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
          child: Center(
            child: Material(
              color: Colors.transparent,
              child: FadeTransition(
                opacity: animation,
                child: ScaleTransition(
                  scale: Tween<double>(begin: 0.9, end: 1.0).animate(
                    CurvedAnimation(parent: animation, curve: Curves.easeOut),
                  ),
                  child: StatefulBuilder(
                    builder: (context, setDialogState) {
                      return Container(
                        width: 280,
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.1),
                              blurRadius: 20,
                              offset: const Offset(0, 10),
                            ),
                          ],
                        ),
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
                ),
              ),
            ),
          ),
        );
      },
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        return FadeTransition(
          opacity: animation,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.9, end: 1.0).animate(
              CurvedAnimation(parent: animation, curve: Curves.easeOut),
            ),
            child: child,
          ),
        );
      },
    );
  }

  Future<void> _showTimeSlotsDialog() async {
    await showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: '时间段设置',
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (context, animation, secondaryAnimation) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
              child: Center(
                child: Material(
                  color: Colors.transparent,
                  child: FadeTransition(
                    opacity: animation,
                    child: ScaleTransition(
                      scale: Tween<double>(begin: 0.9, end: 1.0).animate(
                        CurvedAnimation(parent: animation, curve: Curves.easeOut),
                      ),
                      child: Container(
                        margin: const EdgeInsets.symmetric(horizontal: 24),
                        padding: const EdgeInsets.all(24),
                        constraints: const BoxConstraints(maxWidth: 400, maxHeight: 500),
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
                                        color: Colors.grey.shade50,
                                        borderRadius: BorderRadius.circular(10),
                                        border: Border.all(color: Colors.grey.shade200),
                                      ),
                                      child: Row(
                                        children: [
                                          Container(
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
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
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
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.grey.shade300),
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
                              : Colors.grey.shade100,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: isSelected ? const Color(0xFF4A90E2) : Colors.grey.shade300,
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
    return showGeneralDialog<T>(
      context: context,
      barrierDismissible: true,
      barrierLabel: title,
      barrierColor: Colors.black.withValues(alpha: 0.45),
      transitionDuration: const Duration(milliseconds: 260),
      pageBuilder: (dialogContext, animation, secondaryAnimation) {
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            return BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
              child: Center(
                child: Material(
                  color: Colors.transparent,
                  child: FadeTransition(
                    opacity: animation,
                    child: ScaleTransition(
                      scale: Tween<double>(begin: 0.92, end: 1.0).animate(
                        CurvedAnimation(parent: animation, curve: Curves.easeOut),
                      ),
                      child: Container(
                        margin: const EdgeInsets.symmetric(horizontal: 24),
                        padding: const EdgeInsets.all(20),
                        constraints: const BoxConstraints(maxWidth: 420),
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
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showAboutDialog() {
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: '关于',
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (context, animation, secondaryAnimation) {
        return BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
          child: Center(
            child: Material(
              color: Colors.transparent,
              child: FadeTransition(
                opacity: animation,
                child: ScaleTransition(
                  scale: Tween<double>(begin: 0.9, end: 1.0).animate(
                    CurvedAnimation(parent: animation, curve: Curves.easeOut),
                  ),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 24),
                    padding: const EdgeInsets.all(24),
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
                          'v1.0.5',
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
                        const SizedBox(height: 24),
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
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _clearAllData() async {
    final confirmed = await showGeneralDialog<bool>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '清除数据',
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (context, animation, secondaryAnimation) {
        return BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
          child: Center(
            child: Material(
              color: Colors.transparent,
              child: FadeTransition(
                opacity: animation,
                child: ScaleTransition(
                  scale: Tween<double>(begin: 0.9, end: 1.0).animate(
                    CurvedAnimation(parent: animation, curve: Curves.easeOut),
                  ),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 24),
                    padding: const EdgeInsets.all(24),
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
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: Colors.red.shade50,
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
                  ),
                ),
              ),
            ),
          ),
        );
      },
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
    
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: '电子邮箱登录',
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (context, animation, secondaryAnimation) {
        final mediaQuery = MediaQuery.of(context);
        final keyboardHeight = mediaQuery.viewInsets.bottom;
        final topInset = mediaQuery.padding.top;
        final screenHeight = mediaQuery.size.height;
        const baseMaxHeight = 500.0;
        double dialogMaxHeight = baseMaxHeight;
        final availableHeight = screenHeight - topInset - keyboardHeight - 24;
        if (availableHeight < dialogMaxHeight) {
          dialogMaxHeight = availableHeight;
        }
        dialogMaxHeight = dialogMaxHeight.clamp(260.0, baseMaxHeight).toDouble();

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

            return BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
              child: Center(
                child: Material(
                  color: Colors.transparent,
                  child: FadeTransition(
                    opacity: animation,
                    child: ScaleTransition(
                      scale: Tween<double>(begin: 0.9, end: 1.0).animate(
                        CurvedAnimation(parent: animation, curve: Curves.easeOut),
                      ),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        curve: Curves.easeOut,
                        margin: EdgeInsets.only(
                          left: 24,
                          right: 24,
                          top: keyboardHeight > 0 ? topInset + 8 : 0,
                          bottom: keyboardHeight > 0 ? keyboardHeight + 8 : 0,
                        ),
                        constraints: BoxConstraints(maxWidth: 420, maxHeight: dialogMaxHeight),
                        padding: const EdgeInsets.all(24),
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
                        child: SingleChildScrollView(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
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
                              const SizedBox(height: 16),
                              const Text(
                                '邮箱账号',
                                style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                isRegisterMode
                                    ? '使用邮箱和密码创建账号'
                                    : '使用邮箱和密码登录',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 14,
                                  color: Colors.grey.shade600,
                                ),
                              ),
                              const SizedBox(height: 20),
                              TextField(
                                controller: emailController,
                                keyboardType: TextInputType.emailAddress,
                                enabled: !isSubmitting,
                                onChanged: (_) => setDialogState(() {}),
                                decoration: InputDecoration(
                                  hintText: '请输入邮箱地址',
                                  errorText: email.isEmpty || isEmailValid ? null : '邮箱格式不正确',
                                  prefixIcon: const Icon(Icons.email_outlined),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                                ),
                              ),
                              const SizedBox(height: 12),
                              TextField(
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
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                                ),
                              ),
                              if (isRegisterMode) ...[
                                const SizedBox(height: 12),
                                TextField(
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
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                                  ),
                                ),
                              ],
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
                              TextButton(
                                onPressed: isSubmitting ? null : () => Navigator.pop(context),
                                child: Text(
                                  '取消',
                                  style: TextStyle(color: Colors.grey.shade600),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    ).whenComplete(() {
      emailController.dispose();
      passwordController.dispose();
      confirmPasswordController.dispose();
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
    return showGeneralDialog<List<String>>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '选择上传课表',
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (dialogContext, animation, secondaryAnimation) {
        final selectedIds = timetables.map((t) => t.id).toSet();

        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            return BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
              child: Center(
                child: Material(
                  color: Colors.transparent,
                  child: FadeTransition(
                    opacity: animation,
                    child: ScaleTransition(
                      scale: Tween<double>(begin: 0.9, end: 1.0).animate(
                        CurvedAnimation(parent: animation, curve: Curves.easeOut),
                      ),
                      child: Container(
                        margin: const EdgeInsets.symmetric(horizontal: 24),
                        padding: const EdgeInsets.all(24),
                        constraints: const BoxConstraints(maxWidth: 420, maxHeight: 560),
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
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<bool?> _showUploadToCloudDialog() {
    return showGeneralDialog<bool>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '云端暂无备份',
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (dialogContext, animation, secondaryAnimation) {
        return BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
          child: Center(
            child: Material(
              color: Colors.transparent,
              child: FadeTransition(
                opacity: animation,
                child: ScaleTransition(
                  scale: Tween<double>(begin: 0.9, end: 1.0).animate(
                    CurvedAnimation(parent: animation, curve: Curves.easeOut),
                  ),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 24),
                    padding: const EdgeInsets.all(24),
                    constraints: const BoxConstraints(maxWidth: 400),
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
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<_CloudSyncAction?> _showCloudSyncChoiceDialog(DateTime? updatedAt) {
    return showGeneralDialog<_CloudSyncAction>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '检测到云端数据',
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (dialogContext, animation, secondaryAnimation) {
        return BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
          child: Center(
            child: Material(
              color: Colors.transparent,
              child: FadeTransition(
                opacity: animation,
                child: ScaleTransition(
                  scale: Tween<double>(begin: 0.9, end: 1.0).animate(
                    CurvedAnimation(parent: animation, curve: Curves.easeOut),
                  ),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 24),
                    padding: const EdgeInsets.all(24),
                    constraints: const BoxConstraints(maxWidth: 420),
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
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<String?> _showCloudTimetableSelectorDialog(
    List<String> timetableNames, {
    DateTime? updatedAt,
  }) {
    return showGeneralDialog<String>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '选择要同步的课表',
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (dialogContext, animation, secondaryAnimation) {
        return BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
          child: Center(
            child: Material(
              color: Colors.transparent,
              child: FadeTransition(
                opacity: animation,
                child: ScaleTransition(
                  scale: Tween<double>(begin: 0.9, end: 1.0).animate(
                    CurvedAnimation(parent: animation, curve: Curves.easeOut),
                  ),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 24),
                    padding: const EdgeInsets.all(24),
                    constraints: const BoxConstraints(maxWidth: 420, maxHeight: 520),
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
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<ImportMode?> _showCloudImportModeDialog(DateTime? updatedAt, String timetableName) {
    return showGeneralDialog<ImportMode>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '选择同步方式',
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (dialogContext, animation, secondaryAnimation) {
        return BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
          child: Center(
            child: Material(
              color: Colors.transparent,
              child: FadeTransition(
                opacity: animation,
                child: ScaleTransition(
                  scale: Tween<double>(begin: 0.9, end: 1.0).animate(
                    CurvedAnimation(parent: animation, curve: Curves.easeOut),
                  ),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 24),
                    padding: const EdgeInsets.all(24),
                    constraints: const BoxConstraints(maxWidth: 420),
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
                    ),
                  ),
                ),
              ),
            ),
          ),
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
          color: selected ? selectedColor.withValues(alpha: 0.12) : Colors.grey.shade50,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? selectedColor : Colors.grey.shade300,
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
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: '退出登录',
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (context, animation, secondaryAnimation) {
        return BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
          child: Center(
            child: Material(
              color: Colors.transparent,
              child: FadeTransition(
                opacity: animation,
                child: ScaleTransition(
                  scale: Tween<double>(begin: 0.9, end: 1.0).animate(
                    CurvedAnimation(parent: animation, curve: Curves.easeOut),
                  ),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 24),
                    padding: const EdgeInsets.all(24),
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
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: Colors.orange.shade50,
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
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SegmentItem<T> {
  final String label;
  final T value;
  const _SegmentItem({required this.label, required this.value});
}

class _SegmentedSelector<T> extends StatefulWidget {
  final List<_SegmentItem<T>> items;
  final T activeValue;
  final ValueChanged<T> onChanged;

  const _SegmentedSelector({
    required this.items,
    required this.activeValue,
    required this.onChanged,
  });

  @override
  State<_SegmentedSelector<T>> createState() => _SegmentedSelectorState<T>();
}

class _SegmentedSelectorState<T> extends State<_SegmentedSelector<T>> {
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
              color: Colors.grey.shade100,
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
                          final edge = 0.015;
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
