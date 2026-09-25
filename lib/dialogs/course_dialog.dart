import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import '../models/course.dart';
import '../utils/course_color_palette.dart';
import '../utils/storage.dart';
import '../widgets/glass_dialog.dart';
import '../widgets/toast_notification.dart';
import '../widgets/blur_selection_menu.dart';
import '../widgets/app_text_field.dart';
import '../theme/app_theme.dart';

enum CourseEditFocusSection {
  basicInfo,
  time,
  weeks,
  color,
}

class CourseDialog extends StatefulWidget {
  final Course? course;
  final int selectedDay;
  final int? selectedPeriod;
  final bool saveOnConfirm;
  final CourseEditFocusSection? initialFocusSection;

  /// 传入时对对话框壳背后做局部高斯模糊（GlassDialogShell.blurSigma，
  /// 含提亮层，毛玻璃白净不发灰）。默认 null 不模糊。
  final double? backgroundBlurSigma;

  /// 由宿主（如 _MorphDialogHost）传入并挂到壳上，用于精确测量壳矩形
  /// （不含对话框自身的水平/键盘 margin），孔洞与 morph 锚定都用它。
  final GlobalKey? shellKey;

  /// hosted 模式：由 showBouncyDialog 宿主提供壳/边距/键盘避让，
  /// 本组件不再自绘 GlassDialogShell 与外层 margin（避免双重壳）。
  final bool hosted;

  /// 统一淡出模式（加号遮罩取消添加）：由 morph 宿主在 pop-cancel
  /// 瞬间置 true。配合 [routeAnimation] 在淡出期间对壳**内**内容施加
  /// 递增模糊（sigma 0→10，与 BouncyDialogHost 关闭公式一致）——壳
  /// 本身保持锐利（整树模糊会糊出壳毛边、与孔洞边缘错位成多重框）
  final ValueNotifier<bool>? unifiedFadeMode;

  /// 路由原始动画：统一淡出期间驱动壳内内容模糊（非淡出期不生效）
  final Animation<double>? routeAnimation;

  const CourseDialog({
    super.key,
    this.course,
    required this.selectedDay,
    this.selectedPeriod,
    this.saveOnConfirm = true,
    this.initialFocusSection,
    this.backgroundBlurSigma,
    this.shellKey,
    this.hosted = false,
    this.unifiedFadeMode,
    this.routeAnimation,
  });

  static Future<Course?> show({
    required BuildContext context,
    Course? course,
    required int selectedDay,
    int? selectedPeriod,
    bool saveOnConfirm = true,
    CourseEditFocusSection? initialFocusSection,
  }) {
    // 关于式弹性对话框（孔洞遮罩 + 果冻开闭 + 内容聚焦动画）；
    // hosted 模式下壳/边距/键盘避让由 BouncyDialogHost 提供
    final isSmallScreen = MediaQuery.of(context).size.height < 700;
    return showBouncyDialog<Course>(
      context: context,
      barrierLabel: '课程编辑',
      avoidKeyboard: true,
      margin: EdgeInsets.symmetric(horizontal: isSmallScreen ? 12 : 24),
      shellPadding: EdgeInsets.zero,
      // 紧凑阴影：收缩阴影伸展范围（约 16px+4 偏移），保证阴影
      // 可见区域明显小于对话框本体，不再「阴影大于对话框」
      shellBoxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.15),
          blurRadius: 10,
          offset: const Offset(0, 4),
        ),
      ],
      builder: (context) => CourseDialog(
        course: course,
        selectedDay: selectedDay,
        selectedPeriod: selectedPeriod,
        saveOnConfirm: saveOnConfirm,
        initialFocusSection: initialFocusSection,
        hosted: true,
      ),
    );
  }

  @override
  State<CourseDialog> createState() => _CourseDialogState();
}

class _CourseDialogState extends State<CourseDialog> {
  final _formKey = GlobalKey<FormState>();
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _basicInfoSectionKey = GlobalKey();
  final GlobalKey _timeSectionKey = GlobalKey();
  final GlobalKey _weeksSectionKey = GlobalKey();
  final GlobalKey _colorSectionKey = GlobalKey();
  late TextEditingController _nameController;
  late TextEditingController _teacherController;
  late TextEditingController _locationController;
  late int _selectedDay;
  late int _selectedStartTime;
  late int _selectedDuration;
  late Color _selectedColor;

  /// 进入对话框时的初始颜色：判断颜色是否被修改过（决定
  /// "应用到同名课程"选项是否弹出）
  late Color _originalColor;

  /// "应用到同名课程"开关，颜色修改后弹出的选项中默认选中
  bool _applyToSameNameCourses = true;
  late Set<int> _selectedWeeks;
  CourseEditFocusSection? _highlightedSection;
  Timer? _highlightTimer;

  List<Map<String, String>> _timeSlots = [];

  /// 课程对话框色板：去掉末位棕色（#6D4C41），该格由自定义颜色轮替代。
  /// 完整 15 色仍保留在 CourseColorPalette 供 AI 识别导入等场景使用。
  final List<Color> _colorOptions =
      CourseColorPalette.primaryColors.sublist(0, CourseColorPalette.primaryColors.length - 1);

  /// 自定义模式是否正在被拖动（用于滑块的按压缩放反馈）
  bool _isDraggingBar = false;

  /// 自定义模式下色条位置的缓存。色相是环形量（360°≡0°），从颜色反推
  /// 位置时最右端会塌缩成 0 导致滑块跳到最左，因此拖动期间以该值为准；
  /// 选预设色时置空，回落到按色相反推。
  double? _customBarFraction;

  /// 滑块当前位置：优先用拖动缓存，否则由当前颜色色相反推
  double get _barHandleFraction =>
      _customBarFraction ?? _colorBarFraction(_selectedColor);

  /// 真彩色条的优化 HSL 色阶（色相, 饱和度, 亮度）。饱和度/亮度收敛在
  /// 预设色板同一档（低饱和的紫/蓝略降饱和，黄/橙压亮防发白），
  /// 任意位置取色都保持白字课表卡片的对比度与底板可视程度，
  /// 同时也避开 CourseColorPalette.normalizeHexColor 的"过浅拒收"阈值。
  static const List<(double, double, double)> _barHslStops = [
    (0, 0.72, 0.52),
    (30, 0.85, 0.50),
    (50, 0.90, 0.47),
    (90, 0.62, 0.42),
    (145, 0.62, 0.42),
    (170, 0.68, 0.42),
    (192, 0.95, 0.38),
    (215, 0.70, 0.58),
    (255, 0.55, 0.55),
    (285, 0.45, 0.53),
    (320, 0.70, 0.50),
    (340, 0.78, 0.50),
    (360, 0.72, 0.52),
  ];

  /// 在优化色阶上按 0-1 位置取色（HSL 插值）
  Color _barColorAt(double fraction) {
    final pos = fraction.clamp(0.0, 1.0) * 360.0;
    for (var i = 0; i < _barHslStops.length - 1; i++) {
      final (h0, s0, l0) = _barHslStops[i];
      final (h1, s1, l1) = _barHslStops[i + 1];
      if (pos <= h1) {
        final t = (pos - h0) / (h1 - h0);
        return HSLColor.fromAHSL(
          1.0,
          h0 + (h1 - h0) * t,
          s0 + (s1 - s0) * t,
          l0 + (l1 - l0) * t,
        ).toColor();
      }
    }
    return HSLColor.fromAHSL(1.0, 0, _barHslStops.first.$2, _barHslStops.first.$3).toColor();
  }

  /// 颜色映射到色条位置（按色相 0-360 → 0-1）
  double _colorBarFraction(Color color) => HSLColor.fromColor(color).hue / 360.0;

  /// 按色条横向坐标取色并进入自定义模式
  void _updateBarColor(double dx, double trackWidth) {
    if (trackWidth <= 0) return;
    final fraction = (dx / trackWidth).clamp(0.0, 1.0);
    final next = _barColorAt(fraction);
    if (next.toARGB32() != _selectedColor.toARGB32() || _customBarFraction != fraction) {
      setState(() {
        _selectedColor = next;
        _customBarFraction = fraction;
      });
    }
  }

  final List<String> _weekDayNames = ['一', '二', '三', '四', '五', '六', '日'];

  @override
  void initState() {
    super.initState();
    _timeSlots = StorageService.getTimeSlots();
    _nameController = TextEditingController(text: widget.course?.name ?? '');
    _teacherController = TextEditingController(text: widget.course?.teacher ?? '');
    _locationController = TextEditingController(text: widget.course?.location ?? '');
    final dailyPeriods = StorageService.getDailyPeriods();
    _selectedDay = (widget.course?.day ?? widget.selectedDay).clamp(0, 6);
    _selectedStartTime = (widget.course?.time ?? widget.selectedPeriod ?? 0).clamp(0, dailyPeriods - 1);
    _selectedDuration = (widget.course?.duration ?? 2).clamp(1, 4);
    _selectedColor = widget.course != null
        ? _parseColor(widget.course!.color)
        : const Color(0xFF4A90E2);
    _originalColor = _selectedColor;
    _selectedWeeks = _parseWeeks(widget.course?.weeks ?? '');
    _removeConflictingWeeksFromSelection();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final section = widget.initialFocusSection;
      if (section != null) {
        // 等宿主的打开动画（morph 350ms / 弹性 400ms）完成后再滚动定位并
        // 高亮，避免与打开动画叠加造成对话框元素闪烁跳动
        Future.delayed(const Duration(milliseconds: 460), () {
          if (!mounted) return;
          _focusSection(section);
        });
      }
    });
  }

  Set<int> _parseWeeks(String weeks) {
    final semesterWeeks = StorageService.getSemesterWeeks();
    if (weeks.isEmpty) return Set.from(List.generate(semesterWeeks, (i) => i + 1));
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
    if (result.isEmpty) {
      return Set.from(List.generate(semesterWeeks, (i) => i + 1));
    }
    final filtered = result.where((w) => w <= semesterWeeks).toSet();
    return filtered.isEmpty ? Set.from(List.generate(semesterWeeks, (i) => i + 1)) : filtered;
  }

  String _weeksToString() {
    if (_selectedWeeks.isEmpty) return '';
    final sorted = _selectedWeeks.toList()..sort();
    final ranges = <String>[];
    var start = sorted[0];
    var end = sorted[0];

    for (var i = 1; i < sorted.length; i++) {
      if (sorted[i] == end + 1) {
        end = sorted[i];
      } else {
        ranges.add(start == end ? '$start' : '$start-$end');
        start = sorted[i];
        end = sorted[i];
      }
    }
    ranges.add(start == end ? '$start' : '$start-$end');
    return ranges.join(',');
  }

  String _getTimeSlotLabel(int index) {
    if (index < _timeSlots.length) {
      final slot = _timeSlots[index];
      return '第${index + 1}节 (${slot['start']}-${slot['end']})';
    }
    return '第${index + 1}节';
  }

  bool _isPeriodOverlap(int startA, int durationA, int startB, int durationB) {
    final endA = startA + durationA;
    final endB = startB + durationB;
    return startA < endB && startB < endA;
  }

  Set<int> _getOccupiedWeeksForSelectedSlot() {
    final occupiedWeeks = <int>{};
    final courses = StorageService.getCourses();
    for (final course in courses) {
      if (widget.course != null && course.id == widget.course!.id) continue;
      if (course.day != _selectedDay) continue;
      if (!_isPeriodOverlap(_selectedStartTime, _selectedDuration, course.time, course.duration)) {
        continue;
      }
      occupiedWeeks.addAll(_parseWeeks(course.weeks ?? ''));
    }
    return occupiedWeeks;
  }

  void _removeConflictingWeeksFromSelection() {
    final occupiedWeeks = _getOccupiedWeeksForSelectedSlot();
    _selectedWeeks.removeWhere((week) => occupiedWeeks.contains(week));
  }

  @override
  void dispose() {
    _highlightTimer?.cancel();
    _scrollController.dispose();
    _nameController.dispose();
    _teacherController.dispose();
    _locationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final screenHeight = mediaQuery.size.height;
    final keyboardHeight = mediaQuery.viewInsets.bottom;
    final topInset = mediaQuery.padding.top;
    final isSmallScreen = screenHeight < 700;
    double dialogMaxHeight = isSmallScreen ? screenHeight * 0.78 : screenHeight * 0.82;
    final availableHeight = screenHeight - topInset - keyboardHeight - 24;
    if (availableHeight < dialogMaxHeight) {
      dialogMaxHeight = availableHeight;
    }
    dialogMaxHeight = dialogMaxHeight.clamp(260.0, screenHeight).toDouble();
    
    final content = Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildHeader(isSmallScreen),
            Expanded(
              child: SingleChildScrollView(
                controller: _scrollController,
                physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
                padding: EdgeInsets.all(isSmallScreen ? 12 : 16),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildSectionBlock(
                        section: CourseEditFocusSection.basicInfo,
                        isSmallScreen: isSmallScreen,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _buildSectionTitle('基本信息', Icons.info_outline, isSmallScreen),
                            SizedBox(height: isSmallScreen ? 8 : 12),
                            _buildTextField(
                              controller: _nameController,
                              label: '课程名称',
                              icon: Icons.book_outlined,
                              isRequired: true,
                              isSmallScreen: isSmallScreen,
                            ),
                            SizedBox(height: isSmallScreen ? 10 : 14),
                            _buildTextField(
                              controller: _teacherController,
                              label: '教师',
                              icon: Icons.person_outline,
                              isSmallScreen: isSmallScreen,
                            ),
                            SizedBox(height: isSmallScreen ? 8 : 10),
                            _buildTextField(
                              controller: _locationController,
                              label: '地点',
                              icon: Icons.location_on_outlined,
                              isSmallScreen: isSmallScreen,
                            ),
                          ],
                        ),
                      ),
                      SizedBox(height: isSmallScreen ? 12 : 18),
                      _buildSectionBlock(
                        section: CourseEditFocusSection.time,
                        isSmallScreen: isSmallScreen,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _buildSectionTitle('上课时间', Icons.schedule, isSmallScreen),
                            SizedBox(height: isSmallScreen ? 6 : 10),
                            _buildTimeSelector(isSmallScreen),
                          ],
                        ),
                      ),
                      SizedBox(height: isSmallScreen ? 12 : 18),
                      _buildSectionBlock(
                        section: CourseEditFocusSection.weeks,
                        isSmallScreen: isSmallScreen,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _buildSectionTitle('上课周次', Icons.calendar_today, isSmallScreen),
                            SizedBox(height: isSmallScreen ? 6 : 10),
                            _buildWeekSelector(isSmallScreen),
                          ],
                        ),
                      ),
                      SizedBox(height: isSmallScreen ? 12 : 18),
                      _buildSectionBlock(
                        section: CourseEditFocusSection.color,
                        isSmallScreen: isSmallScreen,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _buildSectionTitle('课程颜色', Icons.palette_outlined, isSmallScreen),
                            SizedBox(height: isSmallScreen ? 6 : 10),
                            _buildColorSelector(isSmallScreen),
                          ],
                        ),
                      ),
                      SizedBox(height: isSmallScreen ? 8 : 12),
                    ],
                  ),
                ),
              ),
              ),
              Container(
                decoration: BoxDecoration(
                  border: Border(
                    top: BorderSide(color: AppColors.of(context).borderWeak),
                  ),
                ),
                child: _buildBottomButtons(isSmallScreen),
              ),
            ],
          );

    // hosted 模式：壳/边距/键盘避让由 BouncyDialogHost 提供；
    // 否则沿用自带壳（morph 版详情/添加课程对话框仍走该路径）
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      margin: widget.hosted
          ? EdgeInsets.zero
          : EdgeInsets.only(
              left: isSmallScreen ? 12 : 24,
              right: isSmallScreen ? 12 : 24,
              top: keyboardHeight > 0 ? topInset + 8 : 0,
              bottom: keyboardHeight > 0 ? keyboardHeight + 8 : 0,
            ),
      child: Container(
        constraints: BoxConstraints(
          maxHeight: dialogMaxHeight,
          maxWidth: isSmallScreen ? 340 : 380,
        ),
        child: widget.hosted
            ? content
            : GlassDialogShell(
                key: widget.shellKey,
                blurSigma: widget.backgroundBlurSigma,
                // 紧凑阴影（与 bouncy 入口一致）：阴影可见区域
                // 明显小于对话框本体
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.15),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
                child: _wrapUnifiedFadeBlur(content),
              ),
      ),
    );
  }

  /// 统一淡出的壳内内容模糊：sigma = 10 × closeU（与 BouncyDialogHost
  /// 关闭公式逐参数一致，壳保持锐利）。加号遮罩取消路径的路由已设
  /// reverseTransitionDuration=400ms（与正常对话框一致），closeU 直接
  /// 用 easeInCubic(1-t)（无需 ×1.5 压缩），逐帧与正常对话框关闭一致。
  /// 非淡出期（unifiedFadeMode=false）零开销直接返回 child
  Widget _wrapUnifiedFadeBlur(Widget content) {
    final anim = widget.routeAnimation;
    final mode = widget.unifiedFadeMode;
    if (anim == null || mode == null) return content;
    return AnimatedBuilder(
      animation: Listenable.merge([anim, mode]),
      builder: (context, child) {
        if (!mode.value) return child!;
        final closeU = Curves.easeInCubic.transform(1.0 - anim.value);
        final sigma = 10.0 * closeU;
        if (sigma <= 0.01) return child!;
        return ImageFiltered(
          imageFilter: ImageFilter.blur(
            sigmaX: sigma,
            sigmaY: sigma,
            tileMode: TileMode.clamp,
          ),
          child: child,
        );
      },
      child: content,
    );
  }

  Widget _buildHeader(bool isSmallScreen) {
    return Opacity(
      opacity: 0.82,
      child: Container(
        padding: EdgeInsets.all(isSmallScreen ? 12 : 20),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [_selectedColor, _selectedColor.withValues(alpha: 0.8)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(24),
            topRight: Radius.circular(24),
          ),
        ),
      child: Row(
        children: [
          Container(
            padding: EdgeInsets.all(isSmallScreen ? 6 : 10),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              widget.course == null ? Icons.add : Icons.edit,
              color: Colors.white,
              size: isSmallScreen ? 18 : 22,
            ),
          ),
          SizedBox(width: isSmallScreen ? 8 : 14),
          Expanded(
            child: Text(
              widget.course == null ? '添加新课程' : '编辑课程',
              style: TextStyle(
                fontSize: isSmallScreen ? 16 : 20,
                fontWeight: FontWeight.bold,
                color: Colors.white,
                letterSpacing: 0.5,
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
    );
  }

  Widget _buildSectionTitle(String title, IconData icon, bool isSmallScreen) {
    return Row(
      children: [
        Icon(icon, size: isSmallScreen ? 16 : 18, color: _selectedColor),
        SizedBox(width: isSmallScreen ? 6 : 8),
        Text(
          title,
          style: TextStyle(
            fontSize: isSmallScreen ? 13 : 15,
            fontWeight: FontWeight.w600,
            color: AppColors.of(context).textPrimary,
          ),
        ),
      ],
    );
  }
  Widget _buildSectionBlock({
    required CourseEditFocusSection section,
    required bool isSmallScreen,
    required Widget child,
  }) {
    final isHighlighted = _highlightedSection == section;
    return AnimatedContainer(
      key: _sectionKey(section),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      padding: EdgeInsets.all(isSmallScreen ? 8 : 10),
      decoration: BoxDecoration(
        color: isHighlighted ? _selectedColor.withValues(alpha: 0.08) : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isHighlighted ? _selectedColor.withValues(alpha: 0.7) : Colors.transparent,
          width: 1,
        ),
      ),
      child: child,
    );
  }

  GlobalKey _sectionKey(CourseEditFocusSection section) {
    switch (section) {
      case CourseEditFocusSection.basicInfo:
        return _basicInfoSectionKey;
      case CourseEditFocusSection.time:
        return _timeSectionKey;
      case CourseEditFocusSection.weeks:
        return _weeksSectionKey;
      case CourseEditFocusSection.color:
        return _colorSectionKey;
    }
  }

  Future<void> _focusSection(CourseEditFocusSection section, {bool animate = true}) async {
    final targetContext = _sectionKey(section).currentContext;
    if (targetContext != null) {
      await Scrollable.ensureVisible(
        targetContext,
        duration: animate ? const Duration(milliseconds: 320) : Duration.zero,
        curve: Curves.easeOutCubic,
        alignment: 0.04,
      );
    }

    if (!mounted) return;
    _highlightTimer?.cancel();
    setState(() {
      _highlightedSection = section;
    });
    _highlightTimer = Timer(const Duration(milliseconds: 1800), () {
      if (!mounted) return;
      setState(() {
        _highlightedSection = null;
      });
    });
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    bool isRequired = false,
    bool isSmallScreen = false,
  }) {
    return AppTextFormField(
      contextMenuBuilder: styledEditableContextMenu,
      controller: controller,
      style: TextStyle(fontSize: isSmallScreen ? 14 : 16),
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon, size: isSmallScreen ? 16 : 20, color: AppColors.of(context).textTertiary),
        filled: true,
        fillColor: AppColors.of(context).panel(0.4),
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: isSmallScreen ? 10 : 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: AppColors.of(context).borderWeak),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: AppColors.of(context).borderWeak),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: _selectedColor, width: 2),
        ),
      ),
      validator: isRequired
          ? (v) => v!.isEmpty ? '请输入$label' : null
          : null,
    );
  }

  Widget _buildTimeSelector(bool isSmallScreen) {
    final dailyPeriods = StorageService.getDailyPeriods();
    final validStartTime = _selectedStartTime.clamp(0, dailyPeriods - 1);
    if (validStartTime != _selectedStartTime) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        setState(() => _selectedStartTime = validStartTime);
      });
    }
    
    return Container(
      padding: EdgeInsets.all(isSmallScreen ? 12 : 16),
      decoration: BoxDecoration(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.of(context).borderWeak),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '星期',
                      style: TextStyle(
                        fontSize: isSmallScreen ? 12 : 13,
                        color: AppColors.of(context).textSecondary,
                      ),
                    ),
                    SizedBox(height: isSmallScreen ? 6 : 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      decoration: BoxDecoration(
                        color: AppColors.of(context).panel(0.4),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: AppColors.of(context).borderWeak),
                      ),
                      child: BlurredDropdown<int>(
                        value: _selectedDay,
                        isExpanded: true,
                        icon: Icon(Icons.expand_more, color: _selectedColor, size: isSmallScreen ? 18 : 20),
                        items: List.generate(7, (i) => DropdownMenuItem(
                          value: i,
                          child: Text(
                            '周${_weekDayNames[i]}',
                            style: TextStyle(fontSize: isSmallScreen ? 12 : 13),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        )),
                        onChanged: (v) {
                          if (v != null) {
                            setState(() {
                              _selectedDay = v;
                              _removeConflictingWeeksFromSelection();
                            });
                          }
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: isSmallScreen ? 10 : 12),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '开始节次',
                      style: TextStyle(
                        fontSize: isSmallScreen ? 12 : 13,
                        color: AppColors.of(context).textSecondary,
                      ),
                    ),
                    SizedBox(height: isSmallScreen ? 6 : 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      decoration: BoxDecoration(
                        color: AppColors.of(context).panel(0.4),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: AppColors.of(context).borderWeak),
                      ),
                      child: BlurredDropdown<int>(
                        value: _selectedStartTime,
                        isExpanded: true,
                        // 菜单与触发框同宽并居中对齐；大字号下菜单项由
                        // FittedBox 等比缩小，不会截断
                        centerMenu: true,
                        icon: Icon(Icons.expand_more, color: _selectedColor, size: isSmallScreen ? 18 : 20),
                        items: List.generate(
                          dailyPeriods,
                          (i) => DropdownMenuItem(
                            value: i,
                            child: Text(
                              '第${i + 1}节',
                              style: TextStyle(fontSize: isSmallScreen ? 12 : 13),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                        onChanged: (v) {
                          if (v != null) {
                            setState(() {
                              _selectedStartTime = v;
                              _removeConflictingWeeksFromSelection();
                            });
                          }
                        },
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(width: isSmallScreen ? 12 : 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '课程时长',
                      style: TextStyle(
                        fontSize: isSmallScreen ? 12 : 13,
                        color: AppColors.of(context).textSecondary,
                      ),
                    ),
                    SizedBox(height: isSmallScreen ? 6 : 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      decoration: BoxDecoration(
                        color: AppColors.of(context).panel(0.4),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: AppColors.of(context).borderWeak),
                      ),
                      child: BlurredDropdown<int>(
                        value: _selectedDuration,
                        isExpanded: true,
                        icon: Icon(Icons.expand_more, color: _selectedColor, size: isSmallScreen ? 18 : 20),
                        items: [1, 2, 3, 4].map((d) {
                          return DropdownMenuItem(
                            value: d,
                            child: Text(
                              '$d 节',
                              style: TextStyle(fontSize: isSmallScreen ? 12 : 13),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          );
                        }).toList(),
                        onChanged: (v) {
                          if (v != null) {
                            setState(() {
                              _selectedDuration = v;
                              _removeConflictingWeeksFromSelection();
                            });
                          }
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: isSmallScreen ? 10 : 12),
          Container(
            padding: EdgeInsets.all(isSmallScreen ? 10 : 12),
            decoration: BoxDecoration(
              color: _selectedColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(Icons.info_outline, size: isSmallScreen ? 14 : 16, color: _selectedColor),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '周${_weekDayNames[_selectedDay]} ${_selectedStartTime < _timeSlots.length
                        ? '${_timeSlots[_selectedStartTime]['start']} 起'
                        : '第${_selectedStartTime + 1}节起'}，共 $_selectedDuration 节',
                    style: TextStyle(
                      fontSize: isSmallScreen ? 12 : 13,
                      color: _selectedColor.withValues(alpha: 0.9),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWeekSelector(bool isSmallScreen) {
    final semesterWeeks = StorageService.getSemesterWeeks();
    final occupiedWeeks = _getOccupiedWeeksForSelectedSlot();
    final selectableWeeks = List.generate(semesterWeeks, (i) => i + 1)
        .where((week) => !occupiedWeeks.contains(week))
        .toSet();
    
    return Container(
      padding: EdgeInsets.all(isSmallScreen ? 12 : 16),
      decoration: BoxDecoration(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.of(context).borderWeak),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: isSmallScreen ? 4 : 6,
            runSpacing: isSmallScreen ? 4 : 6,
            children: [
              _buildQuickSelectButton('全选', () {
                setState(() {
                  _selectedWeeks = Set<int>.from(selectableWeeks);
                });
              }, isSmallScreen),
              _buildQuickSelectButton('清空', () {
                setState(() {
                  _selectedWeeks.clear();
                });
              }, isSmallScreen),
              _buildQuickSelectButton('单周', () {
                setState(() {
                  _selectedWeeks = selectableWeeks.where((w) => w.isOdd).toSet();
                });
              }, isSmallScreen),
              _buildQuickSelectButton('双周', () {
                setState(() {
                  _selectedWeeks = selectableWeeks.where((w) => w.isEven).toSet();
                });
              }, isSmallScreen),
            ],
          ),
          SizedBox(height: isSmallScreen ? 10 : 12),
          Wrap(
            spacing: isSmallScreen ? 4 : 6,
            runSpacing: isSmallScreen ? 4 : 6,
            children: List.generate(semesterWeeks, (index) {
              final week = index + 1;
              final isDisabled = occupiedWeeks.contains(week);
              final isSelected = _selectedWeeks.contains(week);
              return GestureDetector(
                onTap: () {
                  if (isDisabled) return;
                  setState(() {
                    if (isSelected) {
                      _selectedWeeks.remove(week);
                    } else {
                      _selectedWeeks.add(week);
                    }
                  });
                },
                child: Container(
                  width: isSmallScreen ? 32 : 36,
                  height: isSmallScreen ? 32 : 36,
                  decoration: BoxDecoration(
                    color: isDisabled
                        ? AppColors.of(context).panel(0.4)
                        : (isSelected ? _selectedColor : AppColors.of(context).panel(0.4)),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: isDisabled
                          ? AppColors.of(context).borderWeak
                          : (isSelected ? _selectedColor : AppColors.of(context).borderWeak),
                      width: isSelected ? 2 : 1,
                    ),
                    boxShadow: isDisabled
                        ? null
                        : isSelected
                        ? [
                            BoxShadow(
                              color: _selectedColor.withValues(alpha: 0.3),
                              blurRadius: 4,
                              offset: const Offset(0, 2),
                            ),
                          ]
                        : null,
                  ),
                  child: Center(
                    child: Text(
                      '$week',
                      style: TextStyle(
                        fontSize: isSmallScreen ? 11 : 13,
                        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                        color: isDisabled
                            ? AppColors.of(context).textTertiary
                            : (isSelected ? Colors.white : AppColors.of(context).textSecondary),
                      ),
                    ),
                  ),
                ),
              );
            }),
          ),
          SizedBox(height: isSmallScreen ? 10 : 12),
          if (occupiedWeeks.isNotEmpty)
            Container(
              margin: EdgeInsets.only(bottom: isSmallScreen ? 8 : 10),
              padding: EdgeInsets.all(isSmallScreen ? 8 : 10),
              decoration: BoxDecoration(
                color: AppColors.of(context).panel(0.4),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.of(context).borderWeak),
              ),
              child: Row(
                children: [
                  Icon(Icons.block, size: isSmallScreen ? 14 : 16, color: AppColors.of(context).textSecondary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '以下周次该时段已有课程，已禁选：${occupiedWeeks.toList()..sort()}',
                      style: TextStyle(
                        fontSize: isSmallScreen ? 11 : 12,
                        color: AppColors.of(context).textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          Container(
            padding: EdgeInsets.all(isSmallScreen ? 8 : 10),
            decoration: BoxDecoration(
              color: AppColors.of(context).panel(0.4),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.of(context).borderWeak),
            ),
            child: Row(
              children: [
                Icon(Icons.check_circle_outline, size: isSmallScreen ? 14 : 16, color: _selectedColor),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '已选: ${_selectedWeeks.isEmpty ? "未选择" : _weeksToString()} 周',
                    style: TextStyle(
                      fontSize: isSmallScreen ? 11 : 12,
                      color: AppColors.of(context).textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQuickSelectButton(String label, VoidCallback onTap, bool isSmallScreen) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: isSmallScreen ? 6 : 8, vertical: isSmallScreen ? 3 : 4),
        decoration: BoxDecoration(
          color: _selectedColor.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: isSmallScreen ? 10 : 11,
            color: _selectedColor,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _buildColorSelector(bool isSmallScreen) {
    return Container(
      padding: EdgeInsets.fromLTRB(
        isSmallScreen ? 10 : 12,
        isSmallScreen ? 12 : 16,
        isSmallScreen ? 10 : 12,
        isSmallScreen ? 10 : 12,
      ),
      decoration: BoxDecoration(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.of(context).borderWeak),
      ),
      child: Column(
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              const crossAxisCount = 5;
              final spacing = isSmallScreen ? 8.0 : 10.0;
              final itemExtent = ((constraints.maxWidth - spacing * (crossAxisCount - 1)) / crossAxisCount)
                  .clamp(isSmallScreen ? 32.0 : 36.0, isSmallScreen ? 40.0 : 44.0);
              // 选中色不在预设里 → 自定义模式，颜色轮呈选中态
              final isCustomActive =
                  !_colorOptions.any((c) => c.toARGB32() == _selectedColor.toARGB32());

              return GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                padding: EdgeInsets.zero,
                itemCount: _colorOptions.length + 1,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: crossAxisCount,
                  crossAxisSpacing: spacing,
                  mainAxisSpacing: spacing,
                  mainAxisExtent: itemExtent,
                ),
                itemBuilder: (context, index) {
                  // 末格：自定义颜色轮（原末位棕色位置）
                  if (index == _colorOptions.length) {
                    return _buildCustomColorWheel(isSmallScreen, itemExtent, isCustomActive);
                  }
                  final color = _colorOptions[index];
                  final isSelected = _selectedColor.toARGB32() == color.toARGB32();
                  return GestureDetector(
                    onTap: () => setState(() {
                      _selectedColor = color;
                      _customBarFraction = null;
                    }),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      width: itemExtent,
                      height: itemExtent,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                        // 未选中也有细白描边，选中态通过 AnimatedContainer
                        // 连贯过渡到粗白环（宽度与透明度同步渐变）
                        border: Border.all(
                          color: Colors.white.withValues(alpha: isSelected ? 1.0 : 0.4),
                          width: isSelected ? 3 : 1.5,
                        ),
                        boxShadow: isSelected
                            ? [
                                BoxShadow(
                                  color: color.withValues(alpha: 0.5),
                                  blurRadius: 8,
                                  offset: const Offset(0, 3),
                                ),
                              ]
                            : [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.1),
                                  blurRadius: 4,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                      ),
                      child: isSelected
                          ? const Icon(Icons.check, color: Colors.white, size: 18)
                          : null,
                    ),
                  );
                },
              );
            },
          ),
          SizedBox(height: isSmallScreen ? 10 : 12),
          _buildTrueColorBar(isSmallScreen),
          // 颜色被修改过才弹出：应用到同名课程（出现动画参考
          // 课表选择对话框的新增课表动画）
          _AppearSection(
            visible: _selectedColor.toARGB32() != _originalColor.toARGB32(),
            child: _buildApplySameNameOption(isSmallScreen),
          ),
        ],
      ),
    );
  }

  /// "应用到同名课程"选项：左侧文案，右侧小号圆形复选框
  /// （选中时填充当前目标颜色、白色对勾，无边框），整行可点按切换
  Widget _buildApplySameNameOption(bool isSmallScreen) {
    return Padding(
      padding: EdgeInsets.only(top: isSmallScreen ? 8 : 10),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () =>
            setState(() => _applyToSameNameCourses = !_applyToSameNameCourses),
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: isSmallScreen ? 10 : 12,
            vertical: isSmallScreen ? 6 : 7,
          ),
          decoration: BoxDecoration(
            color: _selectedColor.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '应用到同名课程',
                  style: TextStyle(
                    fontSize: isSmallScreen ? 11 : 12,
                    color: AppColors.of(context).textSecondary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              AnimatedContainer(
                key: ValueKey(Theme.of(context).brightness),
                duration: const Duration(milliseconds: 160),
                width: isSmallScreen ? 15 : 17,
                height: isSmallScreen ? 15 : 17,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  // 无边框：选中填充目标颜色，未选中为浅色底
                  color: _applyToSameNameCourses
                      ? _selectedColor
                      : AppColors.of(context).chipIdle,
                ),
                child: _applyToSameNameCourses
                    ? Icon(Icons.check,
                        size: isSmallScreen ? 10 : 12, color: Colors.white)
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 自定义颜色轮：真彩圆盘（每个半径扇区一个色相），中心留白色圆心。
  /// 选中时圆心放大为白色圆并显示对勾，外圈白环 + 当前颜色光晕。
  Widget _buildCustomColorWheel(bool isSmallScreen, double size, bool isSelected) {
    final wheelColors = List.generate(
      12,
      (i) => HSLColor.fromAHSL(1.0, i * 30.0, 0.72, 0.50).toColor(),
    );
    return GestureDetector(
      onTap: () {
        if (isSelected) return;
        setState(() {
          // 以当前颜色的色相落入优化色条，脱离预设进入自定义模式
          _selectedColor = _barColorAt(_colorBarFraction(_selectedColor));
        });
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: SweepGradient(colors: [...wheelColors, wheelColors.first]),
          // 与预设色块一致：未选中细白描边，选中连贯过渡到粗白环
          border: Border.all(
            color: Colors.white.withValues(alpha: isSelected ? 1.0 : 0.4),
            width: isSelected ? 3 : 1.5,
          ),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: _selectedColor.withValues(alpha: 0.5),
                    blurRadius: 8,
                    offset: const Offset(0, 3),
                  ),
                ]
              : [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.1),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ],
        ),
        child: isSelected
            ? Center(
                child: Container(
                  width: size * 0.44,
                  height: size * 0.44,
                  decoration: const BoxDecoration(shape: BoxShape.circle, color: Colors.white),
                  child: Icon(Icons.check, size: size * 0.28, color: _selectedColor),
                ),
              )
            : null,
      ),
    );
  }

  /// 长条形真彩颜色选择器：优化色谱 + 白色半透明镂空壳滑块。
  /// 整条区域可点按跳转/拖动，拖动时滑块轻微放大、跟手无吸附。
  Widget _buildTrueColorBar(bool isSmallScreen) {
    const gradientSamples = 25;
    final handleWidth = isSmallScreen ? 22.0 : 26.0;
    final handleHeight = isSmallScreen ? 30.0 : 34.0;
    return Padding(
      // 让滑块在最左/最右时仍不越过色条容器
      padding: EdgeInsets.symmetric(horizontal: handleWidth / 2 + 2),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final trackWidth = constraints.maxWidth;
          final fraction = _barHandleFraction;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) {
              setState(() => _isDraggingBar = true);
              _updateBarColor(d.localPosition.dx, trackWidth);
            },
            onTapUp: (_) => setState(() => _isDraggingBar = false),
            onTapCancel: () => setState(() => _isDraggingBar = false),
            onHorizontalDragStart: (d) {
              setState(() => _isDraggingBar = true);
              _updateBarColor(d.localPosition.dx, trackWidth);
            },
            onHorizontalDragUpdate: (d) =>
                _updateBarColor(d.localPosition.dx, trackWidth),
            onHorizontalDragEnd: (_) => setState(() => _isDraggingBar = false),
            onHorizontalDragCancel: () => setState(() => _isDraggingBar = false),
            child: SizedBox(
              height: isSmallScreen ? 36 : 40,
              width: double.infinity,
              child: Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.center,
                children: [
                  Container(
                    height: isSmallScreen ? 20 : 22,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(999),
                      gradient: LinearGradient(
                        colors: List.generate(
                          gradientSamples,
                          (i) => _barColorAt(i / (gradientSamples - 1)),
                        ),
                      ),
                    ),
                  ),
                  AnimatedAlign(
                    // 拖动时零时长贴手；点选预设色/色轮时平滑滑向新位置
                    duration: _isDraggingBar
                        ? Duration.zero
                        : const Duration(milliseconds: 260),
                    curve: Curves.easeOutCubic,
                    alignment: Alignment(fraction * 2 - 1, 0),
                    child: AnimatedScale(
                      scale: _isDraggingBar ? 1.12 : 1.0,
                      duration: const Duration(milliseconds: 120),
                      curve: Curves.easeOut,
                      child: Container(
                        width: handleWidth,
                        height: handleHeight,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(handleWidth * 0.38),
                          // 半透明白壳：仅淡淡一层白雾，中心镂空透出色条当前颜色
                          color: Colors.white.withValues(alpha: 0.16),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.92),
                            width: 3.5,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.18),
                              blurRadius: 6,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildBottomButtons(bool isSmallScreen) {
    return Container(
      padding: EdgeInsets.fromLTRB(isSmallScreen ? 16 : 20, isSmallScreen ? 12 : 16, isSmallScreen ? 16 : 20, isSmallScreen ? 16 : 20),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton(
              onPressed: () => Navigator.pop(context),
              style: OutlinedButton.styleFrom(
                padding: EdgeInsets.symmetric(vertical: isSmallScreen ? 12 : 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                side: BorderSide(color: AppColors.of(context).borderWeak),
              ),
              child: Text(
                '取消',
                style: TextStyle(color: AppColors.of(context).textSecondary, fontSize: isSmallScreen ? 13 : 14),
              ),
            ),
          ),
          SizedBox(width: isSmallScreen ? 10 : 12),
          Expanded(
            flex: 2,
            child: ElevatedButton(
              onPressed: _saveCourse,
              style: ElevatedButton.styleFrom(
                backgroundColor: _selectedColor,
                foregroundColor: Colors.white,
                padding: EdgeInsets.symmetric(vertical: isSmallScreen ? 12 : 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                elevation: 0,
                shadowColor: Colors.transparent,
              ),
              child: Text(
                '保存课程',
                style: TextStyle(
                  fontSize: isSmallScreen ? 13 : 15,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ],
      ),
    );
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

  void _saveCourse() {
    if (_formKey.currentState!.validate()) {
      final occupiedWeeks = _getOccupiedWeeksForSelectedSlot();
      final conflictWeeks = _selectedWeeks.where((w) => occupiedWeeks.contains(w)).toList()..sort();
      if (conflictWeeks.isNotEmpty) {
        toastNotification.show(context, '该时段在第 ${conflictWeeks.join(',')} 周已有课程', type: ToastType.error);
        return;
      }

      if (_selectedWeeks.isEmpty) {
        toastNotification.show(context, '请至少选择一个上课周次', type: ToastType.error);
        return;
      }

      final course = Course(
        id: widget.course?.id ?? DateTime.now().millisecondsSinceEpoch.toString(),
        name: _nameController.text,
        teacher: _teacherController.text,
        location: _locationController.text,
        day: _selectedDay,
        time: _selectedStartTime,
        duration: _selectedDuration,
        weeks: _weeksToString(),
        color: '#${_selectedColor.toARGB32().toRadixString(16).substring(2)}',
      );

      if (widget.saveOnConfirm) {
        if (widget.course == null) {
          StorageService.addCourse(course);
        } else {
          StorageService.updateCourse(course);
        }
        // 颜色被修改且勾选"应用到同名课程"：把新颜色同步到当前
        // 课表中所有同名课程（排除正在保存的这条）
        if (_applyToSameNameCourses &&
            _selectedColor.toARGB32() != _originalColor.toARGB32()) {
          for (final other in StorageService.getCourses()) {
            if (other.name == course.name && other.id != course.id) {
              StorageService.updateCourse(Course(
                id: other.id,
                name: other.name,
                teacher: other.teacher,
                location: other.location,
                day: other.day,
                time: other.time,
                duration: other.duration,
                weeks: other.weeks,
                color: course.color,
              ));
            }
          }
        }
      }

      Navigator.pop(context, course);

      if (widget.saveOnConfirm) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          toastNotification.show(
            context,
            widget.course == null ? '添加课程成功' : '课程已更新',
            type: ToastType.success,
          );
        });
      }
    }
  }
}

/// 参考课表选择对话框"新增课表"的出现动画（220ms easeOutCubic：
/// 模糊 14→0 + 缩放 0.55→1 + 淡入），叠加 SizeTransition 高度展开；
/// visible 切换时正向/反向播放，隐藏时不占高度也不接收点击
class _AppearSection extends StatefulWidget {
  final bool visible;
  final Widget child;

  const _AppearSection({required this.visible, required this.child});

  @override
  State<_AppearSection> createState() => _AppearSectionState();
}

class _AppearSectionState extends State<_AppearSection>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );

  @override
  void initState() {
    super.initState();
    if (widget.visible) _controller.value = 1.0;
  }

  @override
  void didUpdateWidget(covariant _AppearSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible != oldWidget.visible) {
      if (widget.visible) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
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
        final t = Curves.easeOutCubic.transform(_controller.value);
        return ClipRect(
          child: SizeTransition(
            sizeFactor: AlwaysStoppedAnimation(t),
            axisAlignment: -1.0,
            child: Opacity(
              opacity: t,
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
          ),
        );
      },
      child: widget.child,
    );
  }
}
