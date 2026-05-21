import 'dart:io';
import 'dart:ui' show ImageFilter, ImageByteFormat, instantiateImageCodec, lerpDouble, Canvas, Rect;
import 'dart:ui' as ui;
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart' as intl;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/course.dart';
import '../models/task.dart';
import '../utils/storage.dart';
import '../dialogs/course_dialog.dart';
import '../widgets/toast_notification.dart';
import '../widgets/time_picker_dialog.dart';
import '../widgets/animated_calendar.dart';

class TimetableScreen extends StatefulWidget {
  final Function(bool) onScrollDirectionChanged;
  
  const TimetableScreen({super.key, required this.onScrollDirectionChanged});

  @override
  State<TimetableScreen> createState() => TimetableScreenState();
}

class TimetableScreenState extends State<TimetableScreen> with TickerProviderStateMixin {
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
  ui.Image? _preBlurredImage;
  final Map<int, double> _pageScrollOffsets = {};

  @override
  void initState() {
    super.initState();
    _loadData();
    _previousWeek = _currentWeek;
    _pageOffset = (_currentWeek - 1).toDouble();
    
    _pageController = PageController(initialPage: _currentWeek - 1);
    _pageController.addListener(_onPageScroll);
  }

  void _onPageScroll() {
    if (_pageController.hasClients) {
      final page = _pageController.page;
      if (page != null && page.isFinite) {
        setState(() {
          _pageOffset = page.clamp(0.0, double.infinity);
        });
      }
    }
  }

  @override
  void dispose() {
    _pageController.removeListener(_onPageScroll);
    _pageController.dispose();
    _preBlurredImage?.dispose();
    super.dispose();
  }

  void _loadData() {
    _courses = StorageService.getCourses();
    _timeSlots = StorageService.getTimeSlots();
    _dailyPeriods = StorageService.getDailyPeriods();
    _semesterStartDate = StorageService.getSemesterStartDate();
    _currentWeek = StorageService.getCurrentWeek();
    _loadWallpaper();
  }

  Future<void> _loadWallpaper() async {
    final prefs = await SharedPreferences.getInstance();
    final path = prefs.getString('wallpaper_path');
    final opacity = prefs.getInt('wallpaper_opacity') ?? 100;
    final enabled = prefs.getBool('wallpaper_enabled') ?? false;
    final blur = prefs.getBool('wallpaper_blur_enabled') ?? false;
    bool isLight = true;
    if (enabled && path != null) {
      isLight = await _analyzeWallpaperBrightness(path);
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
    if (enabled && blur && path != null) {
      _preBlurWallpaper(path);
    } else {
      _preBlurredImage?.dispose();
      _preBlurredImage = null;
    }
  }

  Future<void> _preBlurWallpaper(String imagePath) async {
    try {
      final file = File(imagePath);
      if (!file.existsSync()) return;
      final bytes = await file.readAsBytes();
      final codec = await instantiateImageCodec(bytes);
      final frameInfo = await codec.getNextFrame();
      final original = frameInfo.image;
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      final rect = Rect.fromLTWH(0, 0, original.width.toDouble(), original.height.toDouble());
      canvas.saveLayer(rect, Paint()..imageFilter = ImageFilter.blur(sigmaX: 8, sigmaY: 8));
      canvas.drawImage(original, Offset.zero, Paint());
      canvas.restore();
      final picture = recorder.endRecording();
      final blurred = await picture.toImage(original.width, original.height);
      original.dispose();
      _preBlurredImage?.dispose();
      _preBlurredImage = blurred;
      if (mounted) setState(() {});
    } catch (_) {}
  }

  Future<bool> _analyzeWallpaperBrightness(String imagePath) async {
    try {
      final file = File(imagePath);
      if (!file.existsSync()) return true;
      final bytes = await file.readAsBytes();
      final codec = await instantiateImageCodec(bytes, targetWidth: 100);
      final frameInfo = await codec.getNextFrame();
      final image = frameInfo.image;
      final byteData = await image.toByteData(format: ImageByteFormat.rawRgba);
      if (byteData == null) return true;
      final pixels = byteData.buffer.asUint8List();
      double totalLuminance = 0;
      int sampleCount = 0;
      for (int i = 0; i < pixels.length - 3; i += 40) {
        final r = pixels[i];
        final g = pixels[i + 1];
        final b = pixels[i + 2];
        final a = pixels[i + 3];
        if (a < 128) continue;
        totalLuminance += 0.299 * r + 0.587 * g + 0.114 * b;
        sampleCount++;
      }
      if (sampleCount == 0) return true;
      final avgLuminance = totalLuminance / sampleCount;
      image.dispose();
      return avgLuminance > 128;
    } catch (_) {
      return true;
    }
  }

  void refreshData() {
    _loadData();
    _loadWallpaper();
    _pageOffset = (_currentWeek - 1).toDouble();
    if (mounted) {
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

  void _showTimetableSwitcher() {
    var timetables = StorageService.getTimetables();
    String currentId = StorageService.currentTimetableId;
    final TextEditingController nameController = TextEditingController();
    String? editingId;
    final TextEditingController editController = TextEditingController();

    void showTimetableTip(String message, {ToastType type = ToastType.info}) {
      if (!mounted) return;
      toastNotification.show(context, message, type: type);
    }
    
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: '切换课表',
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
                        margin: EdgeInsets.only(
                          top: keyboardHeight > 0 ? topInset + 8 : 0,
                          bottom: keyboardHeight > 0 ? keyboardHeight + 8 : 0,
                        ),
                        width: 320,
                        constraints: BoxConstraints(maxHeight: dialogMaxHeight),
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
                                  
                                  return Container(
                                    margin: const EdgeInsets.only(bottom: 8),
                                    decoration: BoxDecoration(
                                      color: isSelected 
                                          ? const Color(0xFF4A90E2).withValues(alpha: 0.1)
                                          : Colors.grey.shade50,
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                        color: isSelected 
                                            ? const Color(0xFF4A90E2) 
                                            : Colors.grey.shade200,
                                      ),
                                    ),
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
                                          color: isSelected ? null : Colors.grey.shade200,
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
                                                      child: PopupMenuButton<String>(
                                                        icon: Icon(Icons.more_vert, color: Colors.grey.shade400, size: 20),
                                                        onOpened: () {
                                                          HapticFeedback.selectionClick();
                                                        },
                                                        shape: RoundedRectangleBorder(
                                                          borderRadius: BorderRadius.circular(16),
                                                        ),
                                                        color: Colors.white,
                                                        elevation: 8,
                                                        onSelected: (value) async {
                                                          if (value == 'rename') {
                                                            editController.text = timetable.name;
                                                            setDialogState(() {
                                                              editingId = timetable.id;
                                                            });
                                                          } else if (value == 'delete') {
                                                            final deletedName = timetable.name;
                                                            await StorageService.deleteTimetable(timetable.id);
                                                            currentId = StorageService.currentTimetableId;
                                                            _loadData();
                                                            setDialogState(() {
                                                              timetables = StorageService.getTimetables();
                                                              editingId = null;
                                                            });
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
                                                            showTimetableTip('课表已删除：$deletedName');
                                                          }
                                                        },
                                                        itemBuilder: (context) => [
                                                          const PopupMenuItem(
                                                            value: 'rename',
                                                            child: Row(
                                                              children: [
                                                                Icon(Icons.edit_outlined, color: Color(0xFF4A90E2), size: 18),
                                                                SizedBox(width: 8),
                                                                Text('重命名'),
                                                              ],
                                                            ),
                                                          ),
                                                          const PopupMenuItem(
                                                            value: 'delete',
                                                            child: Row(
                                                              children: [
                                                                Icon(Icons.delete_outline, color: Colors.red, size: 18),
                                                                SizedBox(width: 8),
                                                                Text('删除课表', style: TextStyle(color: Colors.red)),
                                                              ],
                                                            ),
                                                          ),
                                                        ],
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
                                  );
                                },
                              ),
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              controller: nameController,
                              decoration: InputDecoration(
                                hintText: '新建课表名称',
                                hintStyle: TextStyle(color: Colors.grey.shade400, fontSize: 14),
                                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
                                      Navigator.pop(context);
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
                                  Navigator.pop(context);
                                }
                              },
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

  DateTime _getDateForDay(int dayIndex) {
    final startOfWeek = _semesterStartDate.add(Duration(days: (_currentWeek - 1) * 7));
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
    const timeColumnWidth = 40.0;
    final topPadding = MediaQuery.of(context).padding.top;
    final hasWallpaper = _wallpaperEnabled && _wallpaperPath != null && File(_wallpaperPath!).existsSync();
    
    return Scaffold(
      backgroundColor: hasWallpaper ? Colors.black : const Color(0xFFF8F9FC),
      body: Stack(
        children: [
          _buildPageView(),
          _buildPinnedHeader(topPadding, timeColumnWidth, hasWallpaper: hasWallpaper),
        ],
      ),
    );
  }

  Widget _buildPinnedHeader(double topPadding, double timeColumnWidth, {bool hasWallpaper = false}) {
    return Positioned(
      left: 0,
      right: 0,
      top: 0,
      child: ClipRRect(
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
                _buildDateHeaderRow(timeColumnWidth, hasWallpaper: hasWallpaper, wallpaperIsLight: _wallpaperIsLight),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildWeekSelectorRow() {
    final totalWeeks = StorageService.getSemesterWeeks();
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
              onPressed: _currentWeek > 1 ? () => _navigateWeek(-1) : null,
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
              child: _buildAnimatedWeekNumber(totalWeeks, headerTextColor),
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
              onPressed: _currentWeek < totalWeeks ? () => _navigateWeek(1) : null,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAnimatedWeekNumber(int totalWeeks, Color textColor) {
    final integerPart = _pageOffset.floor();
    final fractionalPart = _pageOffset - integerPart;
    
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
    final currentWeekIndex = _pageOffset.floor();
    final fractionalPart = (_pageOffset - currentWeekIndex).clamp(0.0, 1.0);
    
    final currentStartOfWeek = _semesterStartDate.add(Duration(days: currentWeekIndex * 7));
    final nextStartOfWeek = _semesterStartDate.add(Duration(days: (currentWeekIndex + 1) * 7));
    
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
    final int totalWeeks = StorageService.getSemesterWeeks();
    final FixedExtentScrollController scrollController = FixedExtentScrollController(initialItem: selectedWeek - 1);
    
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: '选择周数',
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
                                          StorageService.setCurrentWeek(selectedWeek);
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
    final newWeek = _currentWeek + delta;
    if (newWeek >= 1 && newWeek <= StorageService.getSemesterWeeks()) {
      _pageController.animateToPage(
        newWeek - 1,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeInOut,
      );
    }
  }

  Widget _buildPageView() {
    final totalWeeks = StorageService.getSemesterWeeks();
    final hasWallpaper = _wallpaperEnabled && _wallpaperPath != null && File(_wallpaperPath!).existsSync();
    return Stack(
      children: [
        if (hasWallpaper)
          Positioned.fill(
            child: Image.file(
              File(_wallpaperPath!),
              fit: BoxFit.cover,
              filterQuality: FilterQuality.none,
            ),
          ),
        PageView.builder(
          controller: _pageController,
          itemCount: totalWeeks,
          onPageChanged: (index) {
            setState(() {
              _previousWeek = _currentWeek;
              _currentWeek = index + 1;
            });
          },
          itemBuilder: (context, index) {
            return _buildTimetableForWeek(index + 1, hasWallpaper: hasWallpaper);
          },
        ),
      ],
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

    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
          if (notification is ScrollUpdateNotification) {
            _pageScrollOffsets[week] = notification.metrics.pixels;
            setState(() {});
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
  }) {
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
  }

  Widget _buildGridLines(double cellHeight, int dayIndex, int week) {
    return Column(
      children: List.generate(_dailyPeriods, (period) {
        return GestureDetector(
          onTap: () => _showCourseDialogForSlot(dayIndex, period),
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

  List<Widget> _buildCourseWidgets(int dayIndex, double cellHeight, int week, {
    bool hasWallpaper = false,
    double transparencyFactor = 1.0,
    double scrollOffset = 0.0,
    double screenWidth = 0.0,
    double headerHeight = 0.0,
    double timeColumnWidth = 40.0,
  }) {
    final widgets = <Widget>[];
    final dayColumnWidth = (screenWidth - timeColumnWidth) / 7;

    for (int period = 0; period < _dailyPeriods; period++) {
      final sameStartCourses = _courses.where((c) {
        return c.day == dayIndex && c.time == period;
      }).toList();

      if (sameStartCourses.isEmpty) {
        continue;
      }

      final activeCourses = sameStartCourses.where((c) => _shouldShowCourse(c, week)).toList();
      final isInactiveInCurrentWeek = activeCourses.isEmpty;
        final course = isInactiveInCurrentWeek
          ? sameStartCourses.reduce((a, b) => a.duration >= b.duration ? a : b)
          : activeCourses.first;

      final hasAlternativeCourses = sameStartCourses.length > 1;

      final blurImageOffset = hasWallpaper && _wallpaperBlurEnabled && _preBlurredImage != null
          ? Offset(
              -(timeColumnWidth + dayColumnWidth * dayIndex + 2),
              -(headerHeight + cellHeight * period + 2 - scrollOffset),
            )
          : Offset.zero;

      widgets.add(
        Positioned(
          top: period * cellHeight + 2,
          left: 2,
          right: 2,
          height: course.duration * cellHeight - 4,
          child: _buildCourseCell(
            course,
            hasAlternativeCourses: hasAlternativeCourses,
            isInactiveInCurrentWeek: isInactiveInCurrentWeek,
            hasWallpaper: hasWallpaper,
            transparencyFactor: transparencyFactor,
            showBlurredBg: hasWallpaper && _wallpaperBlurEnabled && _preBlurredImage != null,
            blurImageOffset: blurImageOffset,
            weekForBlur: week,
          ),
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
    bool showBlurredBg = false,
    Offset blurImageOffset = Offset.zero,
    int weekForBlur = 0,
  }) {
    final t = transparencyFactor;
    final courseColor = _parseColor(course.color);
    final displayColor = courseColor;
    
    Widget card;
    if (!isInactiveInCurrentWeek) {
      final effectiveT = hasWallpaper ? t : 0.4;
      final lightColor = _lighten(displayColor, 0.55);
      final bgAlpha = lerpDouble(1.0, 0.25, effectiveT)!;
      final bgAlpha2 = lerpDouble(1.0, 0.18, effectiveT)!;
      final backgroundStart = lightColor.withValues(alpha: bgAlpha);
      final backgroundEnd = lightColor.withValues(alpha: bgAlpha2);
      final titleColor = displayColor;
      final metaColor = displayColor;
      final triangleColor = displayColor;
      final borderColor = displayColor.withValues(alpha: lerpDouble(0.2, 0.06, effectiveT)!);
      
      card = GestureDetector(
        onTap: () => _showCourseDetail(course),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [backgroundStart, backgroundEnd],
            ),
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
                    right: 0, bottom: 0,
                    child: SizedBox(width: 12, height: 12, child: CustomPaint(painter: _CornerTrianglePainter(color: triangleColor))),
                  ),
              ],
            ),
          ),
        ),
      );
    } else {
    final inactiveT = hasWallpaper ? t : 0.4;
    final backgroundStart = const Color(0xFFF4F5F7).withValues(alpha: lerpDouble(1.0, 0.25, inactiveT)!);
    final backgroundEnd = const Color(0xFFEDEFF2).withValues(alpha: lerpDouble(1.0, 0.18, inactiveT)!);
    final titleColor = const Color(0xFF8C939C).withValues(alpha: lerpDouble(1.0, 0.7, inactiveT)!);
    final metaColor = const Color(0xFFA2A8B0).withValues(alpha: lerpDouble(1.0, 0.6, inactiveT)!);
    final triangleColor = const Color(0xFFCDD2D9).withValues(alpha: lerpDouble(1.0, 0.65, inactiveT)!);
    
    card = GestureDetector(
      onTap: () => _showCourseDetail(course),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              backgroundStart,
              backgroundEnd,
            ],
          ),
          border: isInactiveInCurrentWeek
              ? Border.all(color: const Color(0xFFDDE1E6).withValues(alpha: lerpDouble(0.85, 0.7, inactiveT)!))
              : null,
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
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: titleColor,
                      height: 1.15,
                    ),
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (course.location != null && course.location!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Text(
                        '@${course.location!}',
                        style: TextStyle(
                          fontSize: 9,
                          color: metaColor,
                          height: 1.1,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  if (course.teacher != null && course.teacher!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Text(
                        course.teacher!,
                        style: TextStyle(
                          fontSize: 9,
                          color: metaColor,
                          height: 1.1,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
              ),
              if (hasAlternativeCourses)
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: SizedBox(
                    width: 12,
                    height: 12,
                    child: CustomPaint(
                      painter: _CornerTrianglePainter(
                        color: triangleColor,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    }
    if (showBlurredBg && _preBlurredImage != null) {
      final screenSize = MediaQuery.of(context).size;
      return AnimatedBuilder(
        animation: _pageController,
        builder: (context, child) {
          final pageNow = (_pageController.page ?? (_currentWeek - 1).toDouble())
              .clamp(0.0, double.infinity);
          final transitionX = (weekForBlur - 1 - pageNow) * screenSize.width;
          return ClipRRect(
            borderRadius: BorderRadius.circular(5),
            child: Stack(
              children: [
                Positioned.fill(
                  child: OverflowBox(
                    alignment: Alignment.topLeft,
                    maxWidth: double.infinity,
                    maxHeight: double.infinity,
                    child: Transform.translate(
                      offset: blurImageOffset + Offset(-transitionX, 0),
                      child: SizedBox(
                        width: screenSize.width,
                        height: screenSize.height,
                        child: RawImage(
                          image: _preBlurredImage,
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned.fill(child: card),
              ],
            ),
          );
        },
      );
    }
    return card;
  }

  void _showCourseDetail(Course course) {
    final slotCourses = _courses
        .where((c) => c.day == course.day && c.time == course.time)
        .toList();
    if (slotCourses.isEmpty) {
      return;
    }

    slotCourses.sort((a, b) {
      final aRank = _shouldShowCourse(a, _currentWeek) ? 0 : 1;
      final bRank = _shouldShowCourse(b, _currentWeek) ? 0 : 1;
      if (aRank != bRank) return aRank - bRank;
      return a.name.compareTo(b.name);
    });

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

    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: '课程详情',
      barrierColor: Colors.black.withValues(alpha: 0.5),
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (context, animation, secondaryAnimation) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final currentCourse = slotCourses[currentPage];
            final courseColor = _parseColor(currentCourse.color);
            final dialogTasks = _getDialogTasksForCourse(currentCourse);
            final slideSign = currentPage >= previousPage ? 1.0 : -1.0;
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
                        duration: const Duration(milliseconds: 260),
                        curve: Curves.easeInOutCubic,
                        margin: const EdgeInsets.symmetric(horizontal: 24),
                        constraints: BoxConstraints(maxWidth: 420, maxHeight: dynamicMaxHeight),
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
                            AnimatedContainer(
                              duration: const Duration(milliseconds: 320),
                              curve: Curves.easeInOutCubic,
                              height: headerHeight,
                              padding: const EdgeInsets.all(20),
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  colors: [
                                    courseColor.withValues(alpha: 0.24),
                                    courseColor.withValues(alpha: 0.08),
                                  ],
                                ),
                                borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                              ),
                              child: Row(
                                children: [
                                  AnimatedSwitcher(
                                    duration: const Duration(milliseconds: 260),
                                    switchInCurve: Curves.easeOut,
                                    switchOutCurve: Curves.easeIn,
                                    transitionBuilder: (child, anim) {
                                      return FadeTransition(
                                        opacity: anim,
                                        child: SlideTransition(
                                          position: Tween<Offset>(
                                            begin: Offset(-0.12 * slideSign, 0),
                                            end: Offset.zero,
                                          ).animate(anim),
                                          child: child,
                                        ),
                                      );
                                    },
                                    layoutBuilder: (currentChild, previousChildren) {
                                      return currentChild ?? const SizedBox.shrink();
                                    },
                                    child: Container(
                                      key: ValueKey('course_icon_${currentCourse.id}'),
                                      width: iconBoxSize,
                                      height: iconBoxSize,
                                      decoration: BoxDecoration(
                                        color: courseColor.withValues(alpha: 0.2),
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: Icon(
                                        Icons.book,
                                        color: courseColor,
                                        size: iconGlyphSize,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 16),
                                  Expanded(
                                    child: AnimatedSwitcher(
                                      duration: const Duration(milliseconds: 220),
                                      switchInCurve: Curves.easeOut,
                                      switchOutCurve: Curves.easeIn,
                                      transitionBuilder: (child, anim) {
                                        return FadeTransition(
                                          opacity: anim,
                                          child: SlideTransition(
                                            position: Tween<Offset>(
                                              begin: Offset(0.08 * slideSign, 0),
                                              end: Offset.zero,
                                            ).animate(anim),
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
                                  AnimatedSwitcher(
                                    duration: const Duration(milliseconds: 260),
                                    switchInCurve: Curves.easeOut,
                                    switchOutCurve: Curves.easeIn,
                                    transitionBuilder: (child, anim) {
                                      return FadeTransition(
                                        opacity: anim,
                                        child: SlideTransition(
                                          position: Tween<Offset>(
                                            begin: Offset(0.12 * slideSign, 0),
                                            end: Offset.zero,
                                          ).animate(anim),
                                          child: child,
                                        ),
                                      );
                                    },
                                    layoutBuilder: (currentChild, previousChildren) {
                                      return currentChild ?? const SizedBox.shrink();
                                    },
                                    child: GestureDetector(
                                      key: ValueKey('close_btn_${currentCourse.id}'),
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
                                  ),
                                ],
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
                                                : Colors.grey.shade300,
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
                                      onPressed: () async {
                                        final currentTasks = _getDialogTasksForCourse(currentCourse);
                                        final confirmed = await showGeneralDialog<bool>(
                                          context: context,
                                          barrierDismissible: true,
                                          barrierLabel: '确认删除',
                                          barrierColor: Colors.black.withValues(alpha: 0.5),
                                          transitionDuration: const Duration(milliseconds: 250),
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
                                                        constraints: const BoxConstraints(maxWidth: 340),
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
                                                                '确定要删除课程"${currentCourse.name}"吗？\n相关任务也会被删除。',
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
                                                                          color: Colors.grey.shade100,
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
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            );
                                          },
                                        );
                                        if (confirmed == true) {
                                          for (final task in currentTasks) {
                                            await StorageService.deleteTask(task.id);
                                          }
                                          await StorageService.deleteCourse(currentCourse.id);
                                          Navigator.pop(context);
                                          _loadData();
                                          setState(() {});
                                          WidgetsBinding.instance.addPostFrameCallback((_) {
                                            toastNotification.show(context, '课程已删除', type: ToastType.error);
                                          });
                                        }
                                      },
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
      clearRetainedCompletedTasks();
      pageController.dispose();
    });
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
                  child: Container(
                    width: menuWidth,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.15),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
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
        color: isCompleted ? Colors.grey.shade100 : Colors.grey.shade50,
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
                            ? Colors.grey.shade200 
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
            PopupMenuButton<String>(
              icon: Icon(Icons.more_vert, color: Colors.grey.shade400, size: 20),
              onOpened: () {
                HapticFeedback.selectionClick();
              },
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              color: Colors.white,
              elevation: 8,
              onSelected: (value) async {
                if (value == 'edit') {
                  await Future.delayed(const Duration(milliseconds: 200));
                  _showEditTaskDialog(task, setDialogState);
                } else if (value == 'delete') {
                  await StorageService.deleteTask(task.id);
                  setDialogState(() {});
                  _loadData();
                  setState(() {});
                  toastNotification.show(context, '任务已删除', type: ToastType.error);
                }
              },
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: 'edit',
                  child: Row(
                    children: [
                      Icon(Icons.edit_outlined, color: Color(0xFF4A90E2), size: 18),
                      SizedBox(width: 8),
                      Text('编辑'),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: 'delete',
                  child: Row(
                    children: [
                      Icon(Icons.delete_outline, color: Colors.red, size: 18),
                      SizedBox(width: 8),
                      Text('删除', style: TextStyle(color: Colors.red)),
                    ],
                  ),
                ),
              ],
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
    
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: '添加任务',
      barrierColor: Colors.black.withValues(alpha: 0.5),
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (context, animation, secondaryAnimation) {
        return StatefulBuilder(
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
                          left: isSmallScreen ? 16 : 24,
                          right: isSmallScreen ? 16 : 24,
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
                              padding: EdgeInsets.all(isSmallScreen ? 16 : 20),
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  colors: [courseColor, courseColor.withValues(alpha: 0.8)],
                                ),
                                borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
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
                            Expanded(
                              child: SingleChildScrollView(
                                physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
                                padding: EdgeInsets.all(isSmallScreen ? 16 : 20),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    TextField(
                                      controller: nameController,
                                      decoration: InputDecoration(
                                        labelText: '任务名称',
                                        prefixIcon: Icon(Icons.task, color: courseColor.withValues(alpha: 0.7)),
                                        filled: true,
                                        fillColor: Colors.grey.shade50,
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
                                        color: Colors.grey.shade50,
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(color: Colors.grey.shade200),
                                      ),
                                      child: DropdownButtonHideUnderline(
                                        child: DropdownButton<String>(
                                          value: type,
                                          isExpanded: true,
                                          icon: Icon(Icons.expand_more, color: courseColor),
                                          dropdownColor: Colors.white,
                                          borderRadius: BorderRadius.circular(16),
                                          items: ['作业', '考试', '报告', '其他'].map((e) => DropdownMenuItem(
                                            value: e,
                                            child: Text(e),
                                          )).toList(),
                                          onChanged: (v) => setState(() => type = v!),
                                        ),
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
                                          color: Colors.grey.shade50,
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
                                      controller: noteController,
                                      maxLines: 1,
                                      decoration: InputDecoration(
                                        labelText: '备注（可选）',
                                        prefixIcon: Icon(Icons.note_outlined, color: courseColor.withValues(alpha: 0.7)),
                                        filled: true,
                                        fillColor: Colors.grey.shade50,
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
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
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
    
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: '编辑任务',
      barrierColor: Colors.black.withValues(alpha: 0.5),
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (context, animation, secondaryAnimation) {
        return StatefulBuilder(
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
                          left: isSmallScreen ? 16 : 24,
                          right: isSmallScreen ? 16 : 24,
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
                              padding: EdgeInsets.all(isSmallScreen ? 16 : 20),
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  colors: [courseColor, courseColor.withValues(alpha: 0.8)],
                                ),
                                borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
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
                            Expanded(
                              child: SingleChildScrollView(
                                physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
                                padding: EdgeInsets.all(isSmallScreen ? 16 : 20),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    TextField(
                                      controller: nameController,
                                      decoration: InputDecoration(
                                        labelText: '任务名称',
                                        prefixIcon: Icon(Icons.task, color: courseColor.withValues(alpha: 0.7), size: isSmallScreen ? 18 : 20),
                                        filled: true,
                                        fillColor: Colors.grey.shade50,
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
                                        color: Colors.grey.shade50,
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(color: Colors.grey.shade200),
                                      ),
                                      child: DropdownButtonHideUnderline(
                                        child: DropdownButton<String>(
                                          value: type,
                                          isExpanded: true,
                                          icon: Icon(Icons.expand_more, color: courseColor, size: isSmallScreen ? 18 : 20),
                                          dropdownColor: Colors.white,
                                          borderRadius: BorderRadius.circular(16),
                                          items: ['作业', '考试', '报告', '其他'].map((e) => DropdownMenuItem(
                                            value: e, 
                                            child: Text(e, style: TextStyle(fontSize: isSmallScreen ? 14 : 16))
                                          )).toList(),
                                          onChanged: (v) => setState(() => type = v!),
                                        ),
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
                                          color: Colors.grey.shade50,
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
                                    SizedBox(height: isSmallScreen ? 12 : 16),
                                    TextField(
                                      controller: noteController,
                                      maxLines: 1,
                                      decoration: InputDecoration(
                                        labelText: '备注（可选）',
                                        prefixIcon: Icon(Icons.note_outlined, color: courseColor.withValues(alpha: 0.7), size: isSmallScreen ? 18 : 20),
                                        filled: true,
                                        fillColor: Colors.grey.shade50,
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
                                        Navigator.pop(context);
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
        color: Colors.grey.shade50,
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
              color: Colors.grey.shade200,
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
    
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: '选择课程',
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
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 24),
                    constraints: BoxConstraints(
                      maxWidth: 360, 
                      maxHeight: screenHeight * 0.6
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
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [const Color(0xFF4A90E2), const Color(0xFF5BA0F2)],
                            ),
                            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
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
                                    color: Colors.grey.shade50,
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
                ),
              ),
            ),
          ),
        );
      },
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
  }) {
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: '课程对话框',
      barrierColor: Colors.black.withValues(alpha: 0.5),
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (context, animation, secondaryAnimation) {
        return BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
          child: Center(
            child: Material(
              color: Colors.transparent,
              child: CourseDialog(
                course: course,
                selectedDay: selectedDay ?? course?.day ?? DateTime.now().weekday - 1,
                selectedPeriod: selectedPeriod ?? course?.time,
                initialFocusSection: initialFocusSection,
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
    ).then((_) {
      _loadData();
      setState(() {});
    });
  }

  void _showCourseDialogForSlot(int day, int period) {
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: '课程对话框',
      barrierColor: Colors.black.withValues(alpha: 0.5),
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (context, animation, secondaryAnimation) {
        return BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
          child: Center(
            child: Material(
              color: Colors.transparent,
              child: CourseDialog(
                selectedDay: day,
                selectedPeriod: period,
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
    ).then((_) {
      _loadData();
      setState(() {});
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
  DateTime dueDate;
  String type;
  String priority;
  final TextEditingController noteController;
  final Function(Task) onSave;

  _TaskDialog({
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

  @override
  void initState() {
    super.initState();
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
                              child: DropdownButtonHideUnderline(
                                child: DropdownButton<String>(
                                  value: widget.type,
                                  isExpanded: true,
                                  icon: Icon(Icons.expand_more, color: widget.courseColor, size: isSmallScreen ? 16 : 20),
                                  dropdownColor: Colors.white,
                                  borderRadius: BorderRadius.circular(16),
                                  items: ['作业', '考试', '报告', '其他'].map((e) => DropdownMenuItem(
                                    value: e,
                                    child: Text(e, style: TextStyle(fontSize: isSmallScreen ? 14 : 16))
                                  )).toList(),
                                  onChanged: (v) => setState(() => widget.type = v!),
                                ),
                              ),
                            ),
                            SizedBox(height: isSmallScreen ? 10 : 16),
                            InkWell(
                              onTap: () async {
                                final date = await showAnimatedDatePicker(
                                  context: context,
                                  initialDate: widget.dueDate,
                                  firstDate: DateTime.now(),
                                  lastDate: DateTime.now().add(const Duration(days: 365)),
                                );
                                if (date != null) {
                                  final time = await show3DTimePicker(
                                    context: context,
                                    initialHour: widget.dueDate.hour,
                                    initialMinute: widget.dueDate.minute,
                                    title: '选择截止时间',
                                  );
                                  if (time != null) {
                                    setState(() {
                                      widget.dueDate = DateTime(date.year, date.month, date.day, time.hour, time.minute);
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
                                          Text(intl.DateFormat('yyyy/MM/dd HH:mm').format(widget.dueDate), style: TextStyle(fontWeight: FontWeight.w500, fontSize: isSmallScreen ? 13 : 16)),
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
                                final isSelected = widget.priority == p;
                                Color priorityColor;
                                if (p == '高') {
                                  priorityColor = Colors.red;
                                } else if (p == '中') priorityColor = Colors.orange;
                                else priorityColor = Colors.green;
                                
                                return Expanded(
                                  child: GestureDetector(
                                    onTap: () => setState(() => widget.priority = p),
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
                                  type: widget.type,
                                  dueDate: widget.dueDate,
                                  priority: widget.priority,
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
