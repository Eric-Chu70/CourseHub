import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import '../models/course.dart';
import '../utils/course_color_palette.dart';
import '../utils/storage.dart';
import '../widgets/toast_notification.dart';

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

  const CourseDialog({
    super.key,
    this.course,
    required this.selectedDay,
    this.selectedPeriod,
    this.saveOnConfirm = true,
    this.initialFocusSection,
  });

  static Future<Course?> show({
    required BuildContext context,
    Course? course,
    required int selectedDay,
    int? selectedPeriod,
    bool saveOnConfirm = true,
    CourseEditFocusSection? initialFocusSection,
  }) {
    return showGeneralDialog<Course>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '课程编辑',
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
                selectedDay: selectedDay,
                selectedPeriod: selectedPeriod,
                saveOnConfirm: saveOnConfirm,
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
  late Set<int> _selectedWeeks;
  CourseEditFocusSection? _highlightedSection;
  Timer? _highlightTimer;

  List<Map<String, String>> _timeSlots = [];

  final List<Color> _colorOptions = CourseColorPalette.primaryColors;

  final List<String> _weekDayNames = ['一', '二', '三', '四', '五', '六', '日'];

  @override
  void initState() {
    super.initState();
    _timeSlots = StorageService.getTimeSlots();
    _nameController = TextEditingController(text: widget.course?.name ?? '');
    _teacherController = TextEditingController(text: widget.course?.teacher ?? '');
    _locationController = TextEditingController(text: widget.course?.location ?? '');
    _selectedDay = (widget.course?.day ?? widget.selectedDay).clamp(0, 6);
    _selectedStartTime = (widget.course?.time ?? widget.selectedPeriod ?? 0).clamp(0, 11);
    _selectedDuration = (widget.course?.duration ?? 2).clamp(1, 4);
    _selectedColor = widget.course != null
        ? _parseColor(widget.course!.color)
        : const Color(0xFF4A90E2);
    _selectedWeeks = _parseWeeks(widget.course?.weeks ?? '');
    _removeConflictingWeeksFromSelection();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final section = widget.initialFocusSection;
      if (section != null) {
        _focusSection(section, animate: false);
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
    
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      margin: EdgeInsets.only(
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
                    top: BorderSide(color: Colors.grey.shade200),
                  ),
                ),
                child: _buildBottomButtons(isSmallScreen),
              ),
            ],
          ),
        ),
      );
  }

  Widget _buildHeader(bool isSmallScreen) {
    return Container(
      padding: EdgeInsets.all(isSmallScreen ? 12 : 20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [_selectedColor, _selectedColor.withValues(alpha: 0.8)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(20),
          topRight: Radius.circular(20),
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
            color: Colors.grey.shade800,
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
          width: isHighlighted ? 1.6 : 1,
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
    return TextFormField(
      controller: controller,
      style: TextStyle(fontSize: isSmallScreen ? 14 : 16),
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon, size: isSmallScreen ? 16 : 20, color: Colors.grey.shade500),
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
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
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
                        color: Colors.grey.shade600,
                      ),
                    ),
                    SizedBox(height: isSmallScreen ? 6 : 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.grey.shade300),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<int>(
                          value: _selectedDay,
                          isExpanded: true,
                          icon: Icon(Icons.expand_more, color: _selectedColor, size: isSmallScreen ? 18 : 20),
                          dropdownColor: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          items: List.generate(7, (i) => DropdownMenuItem(
                            value: i,
                            child: Text(
                              '周${_weekDayNames[i]}',
                              style: TextStyle(fontSize: isSmallScreen ? 12 : 13),
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
                        color: Colors.grey.shade600,
                      ),
                    ),
                    SizedBox(height: isSmallScreen ? 6 : 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.grey.shade300),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<int>(
                          value: _selectedStartTime,
                          isExpanded: true,
                          icon: Icon(Icons.expand_more, color: _selectedColor, size: isSmallScreen ? 18 : 20),
                          dropdownColor: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          items: List.generate(
                            dailyPeriods,
                            (i) => DropdownMenuItem(
                              value: i,
                              child: Text(
                                isSmallScreen ? '第${i + 1}节' : _getTimeSlotLabel(i),
                                style: TextStyle(fontSize: isSmallScreen ? 12 : 13),
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
                        color: Colors.grey.shade600,
                      ),
                    ),
                    SizedBox(height: isSmallScreen ? 6 : 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.grey.shade300),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<int>(
                          value: _selectedDuration,
                          isExpanded: true,
                          icon: Icon(Icons.expand_more, color: _selectedColor, size: isSmallScreen ? 18 : 20),
                          dropdownColor: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          items: [1, 2, 3, 4].map((d) {
                            return DropdownMenuItem(
                              value: d,
                              child: Text('$d 节', style: TextStyle(fontSize: isSmallScreen ? 12 : 13)),
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
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
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
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  width: isSmallScreen ? 32 : 36,
                  height: isSmallScreen ? 32 : 36,
                  decoration: BoxDecoration(
                    color: isDisabled
                        ? Colors.grey.shade200
                        : (isSelected ? _selectedColor : Colors.white),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: isDisabled
                          ? Colors.grey.shade300
                          : (isSelected ? _selectedColor : Colors.grey.shade300),
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
                            ? Colors.grey.shade400
                            : (isSelected ? Colors.white : Colors.grey.shade700),
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
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey.shade300),
              ),
              child: Row(
                children: [
                  Icon(Icons.block, size: isSmallScreen ? 14 : 16, color: Colors.grey.shade600),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '以下周次该时段已有课程，已禁选：${occupiedWeeks.toList()..sort()}',
                      style: TextStyle(
                        fontSize: isSmallScreen ? 11 : 12,
                        color: Colors.grey.shade700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          Container(
            padding: EdgeInsets.all(isSmallScreen ? 8 : 10),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.grey.shade200),
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
                      color: Colors.grey.shade600,
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
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              const crossAxisCount = 5;
              final spacing = isSmallScreen ? 8.0 : 10.0;
              final itemExtent = ((constraints.maxWidth - spacing * (crossAxisCount - 1)) / crossAxisCount)
                  .clamp(isSmallScreen ? 32.0 : 36.0, isSmallScreen ? 40.0 : 44.0);

              return GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                padding: EdgeInsets.zero,
                itemCount: _colorOptions.length,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: crossAxisCount,
                  crossAxisSpacing: spacing,
                  mainAxisSpacing: spacing,
                  mainAxisExtent: itemExtent,
                ),
                itemBuilder: (context, index) {
                  final color = _colorOptions[index];
                  final isSelected = _selectedColor.toARGB32() == color.toARGB32();
                  return GestureDetector(
                    onTap: () => setState(() => _selectedColor = color),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      width: itemExtent,
                      height: itemExtent,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: isSelected ? Colors.white : Colors.transparent,
                          width: isSelected ? 3 : 0,
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
          Container(
            padding: EdgeInsets.all(isSmallScreen ? 8 : 10),
            decoration: BoxDecoration(
              color: _selectedColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: isSmallScreen ? 16 : 20,
                  height: isSmallScreen ? 16 : 20,
                  decoration: BoxDecoration(
                    color: _selectedColor,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  '当前颜色: #${_selectedColor.toARGB32().toRadixString(16).substring(2).toUpperCase()}',
                  style: TextStyle(
                    fontSize: isSmallScreen ? 11 : 12,
                    color: _selectedColor.withValues(alpha: 0.9),
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ],
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
                side: BorderSide(color: Colors.grey.shade300),
              ),
              child: Text(
                '取消',
                style: TextStyle(color: Colors.grey.shade700, fontSize: isSmallScreen ? 13 : 14),
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
