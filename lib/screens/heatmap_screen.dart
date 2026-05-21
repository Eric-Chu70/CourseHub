import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import '../utils/storage.dart';
import '../models/task.dart';
import '../models/course.dart';
import '../widgets/toast_notification.dart';
import '../widgets/time_picker_dialog.dart';
import '../widgets/animated_calendar.dart';

class HeatmapScreen extends StatefulWidget {
  const HeatmapScreen({super.key});

  @override
  State<HeatmapScreen> createState() => HeatmapScreenState();
}

class HeatmapScreenState extends State<HeatmapScreen> with TickerProviderStateMixin {
  List<Task> _tasks = [];
  final Set<String> _retainedCompletedTaskIds = <String>{};
  DateTime _selectedMonth = DateTime.now();
  DateTime? _selectedDate;
  
  late PageController _pageController;
  static const int _initialPage = 1200;
  
  late PageController _calendarPageController;
  static const int _calendarInitialPage = 1200;
  
  // 日历高度动画
  late AnimationController _calendarHeightController;
  late Animation<double> _calendarHeightAnimation;
  double _currentCalendarHeight = 0;
  double _targetCalendarHeight = 0;

  @override
  void initState() {
    super.initState();
    _loadData();
    
    _pageController = PageController(initialPage: _initialPage);
    
    _calendarPageController = PageController(initialPage: _calendarInitialPage);
    
    // 初始化日历高度动画
    _calendarHeightController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _calendarHeightAnimation = CurvedAnimation(
      parent: _calendarHeightController,
      curve: Curves.easeInOutCubic,
    );
    // 设置初始高度
    _currentCalendarHeight = _calculateMonthGridHeight(_selectedMonth);
    _targetCalendarHeight = _currentCalendarHeight;
  }
  
  @override
  void dispose() {
    _pageController.dispose();
    _calendarPageController.dispose();
    _calendarHeightController.dispose();
    super.dispose();
  }

  void _loadData() {
    final allTasks = StorageService.getTasks();
    _tasks = allTasks.where((t){
      if(!t.completed)  return true;
      return _retainedCompletedTaskIds.contains(t.id);
    }).toList();
    _sortTasks();
  }

  void _sortTasks() {
    _tasks.sort((a, b) {
      return a.dueDate.compareTo(b.dueDate);
    });
  }

  Future<void> _toggleTaskCompletion(Task task) async {
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

    final index = _tasks.indexWhere((t) => t.id == task.id);
    if (index == -1) return;

    setState(() {
      _tasks[index] = updatedTask;
      if (updatedTask.completed) {
        _retainedCompletedTaskIds.add(updatedTask.id);
      } else {
        _retainedCompletedTaskIds.remove(updatedTask.id);
      }
    });

    await StorageService.updateTask(updatedTask);
  }

  Future<void> clearRetainedCompletedTasks() async {
    if (_retainedCompletedTaskIds.isEmpty) return;

    final idsToDelete = _retainedCompletedTaskIds.toList();
    _retainedCompletedTaskIds.clear();
    for (final taskId in idsToDelete) {
      await StorageService.deleteTask(taskId);
    }
    _loadData();
    if (mounted) {
      setState(() {});
    }
  }

  void refreshData() {
    _loadData();
    if (mounted) {
      setState(() {});
    }
  }

  int _getTaskCountForDate(DateTime date) {
    return _tasks.where((t) {
      final taskDate = DateTime(t.dueDate.year, t.dueDate.month, t.dueDate.day);
      final targetDate = DateTime(date.year, date.month, date.day);
      return taskDate == targetDate && !t.completed;
    }).length;
  }

  List<Task> _getTasksForDate(DateTime date) {
    return _tasks.where((t) {
      final taskDate = DateTime(t.dueDate.year, t.dueDate.month, t.dueDate.day);
      final targetDate = DateTime(date.year, date.month, date.day);
      return taskDate == targetDate;
    }).toList();
  }

  Color _getHeatColor(int count) {
    if (count == 0) return Colors.transparent;
    final alpha = 0.15 + (count * 0.17).clamp(0.0, 0.85);
    return Colors.red.withValues(alpha: alpha);
  }

  @override
  Widget build(BuildContext context) {
    final today = DateTime.now();
    final activeTasks = _tasks.where((t) => !t.completed).toList();
    
    final totalTasks = activeTasks.length;
    final overdueTasks = activeTasks.where((t) => t.dueDate.isBefore(today)).length;
    final upcomingTasks = activeTasks.where((t) {
      final diff = t.dueDate.difference(today).inDays;
      return diff >= 0 && diff <= 3;
    }).length;

    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FC),
      body: Stack(
        children: [
          CustomScrollView(
            physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
            slivers: [
              SliverPadding(
                padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top + 56),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 140),
                sliver: SliverList(
                  delegate: SliverChildListDelegate([
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            _buildStatCard('总任务', '$totalTasks', Colors.blue),
                            const SizedBox(width: 12),
                            _buildStatCard('即将到期', '$upcomingTasks', Colors.orange),
                            const SizedBox(width: 12),
                            _buildStatCard('已逾期', '$overdueTasks', Colors.red),
                          ],
                        ),
                        const SizedBox(height: 24),
                        
                        _buildCalendarHeatmap(),
                        const SizedBox(height: 24),
                        
                        if (_selectedDate != null) ...[
                          _buildSelectedDateTasks(),
                          const SizedBox(height: 24),
                        ],
                        
                        const Text(
                          '任务列表',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 5),
                        
                        _tasks.isEmpty
                            ? _buildEmptyState()
                            : ListView.builder(
                                shrinkWrap: true,
                                physics: const NeverScrollableScrollPhysics(),
                                padding: const EdgeInsets.only(top: 5, bottom: 48),
                                itemCount: _tasks.length,
                                itemBuilder: (context, index) {
                                  final task = _tasks[index];
                                  return _buildTaskCard(task, context);
                                },
                              ),
                      ],
                    ),
                  ]),
                ),
              ),
            ],
          ),
          _buildPinnedHeader(context),
        ],
      ),
    );
  }

  Widget _buildPinnedHeader(BuildContext context) {
    final topPadding = MediaQuery.of(context).padding.top;
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
                      'DDL 热度',
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
                                WidgetsBinding.instance.addPostFrameCallback((_) {
                                  toastNotification.show(context, '请前往课表页添加课程', type: ToastType.error);
                                });
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
                                    WidgetsBinding.instance.addPostFrameCallback((_) {
                                      toastNotification.show(context, '请前往课表页添加课程', type: ToastType.error);
                                    });
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

  Color _parseColor(String colorString) {
    try {
      final value = int.parse(colorString);
      return Color(value);
    } catch (e) {
      return const Color(0xFF4A90E2);
    }
  }

  void _showTaskDialog(Course course) {
    final courseColor = _parseColor(course.color);
    String taskTitle = '';
    DateTime dueDate = DateTime.now().add(const Duration(days: 1));
    String type = '作业';
    String priority = '中';
    String description = '';
    
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: '添加任务',
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (context, animation, secondaryAnimation) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
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
                                      onChanged: (v) => taskTitle = v,
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
                                          onChanged: (v) => setDialogState(() => type = v!),
                                        ),
                                      ),
                                    ),
                                    SizedBox(height: isSmallScreen ? 12 : 16),
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
                                            setDialogState(() {
                                              dueDate = DateTime(date.year, date.month, date.day, time.hour, time.minute);
                                            });
                                          } else {
                                            setDialogState(() => dueDate = date);
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
                                                  Text('截止时间', style: TextStyle(fontSize: isSmallScreen ? 11 : 12, color: Colors.grey.shade600)),
                                                  Text('${dueDate.year}/${dueDate.month}/${dueDate.day} ${dueDate.hour.toString().padLeft(2, '0')}:${dueDate.minute.toString().padLeft(2, '0')}', style: TextStyle(fontWeight: FontWeight.w500, fontSize: isSmallScreen ? 14 : 16)),
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
                                            onTap: () => setDialogState(() => priority = p),
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
                                      maxLines: 1,
                                      decoration: InputDecoration(
                                        labelText: '备注',
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
                                      onChanged: (v) => description = v,
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
                                        if (taskTitle.isEmpty) {
                                          toastNotification.show(context, '请输入任务名称', type: ToastType.error);
                                          return;
                                        }
                                        final isMergedCourse = StorageService.getCourses()
                                              .where((c) => c.name == course.name)
                                              .length > 1;
                                        final taskCourseId = isMergedCourse
                                            ? 'course_name:${course.name}'
                                            : course.id;
                                        final task = Task(
                                          id: DateTime.now().millisecondsSinceEpoch.toString(),
                                          courseId: taskCourseId,
                                          name: taskTitle,
                                          type: type,
                                          dueDate: dueDate,
                                          priority: priority,
                                          note: description,
                                        );
                                        await StorageService.addTask(task);
                                        Navigator.pop(context);
                                        _loadData();
                                        setState(() {});
                                        WidgetsBinding.instance.addPostFrameCallback((_) {
                                          toastNotification.show(context, '添加任务成功', type: ToastType.success);
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

  Widget _buildCalendarHeatmap() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          _buildMonthHeader(),
          const SizedBox(height: 12),
          _buildWeekDaysHeader(),
          const SizedBox(height: 8),
          AnimatedBuilder(
            animation: _calendarHeightAnimation,
            builder: (context, child) {
              final animatedHeight = _currentCalendarHeight + 
                  (_targetCalendarHeight - _currentCalendarHeight) * _calendarHeightAnimation.value;
              return SizedBox(
                height: animatedHeight,
                child: child,
              );
            },
            child: PageView.builder(
              controller: _calendarPageController,
              itemCount: 2400,
              onPageChanged: (index) {
                final monthOffset = index - _calendarInitialPage;
                final newMonth = DateTime(DateTime.now().year, DateTime.now().month + monthOffset, 1);
                final newHeight = _calculateMonthGridHeight(newMonth);
                
                setState(() {
                  _currentCalendarHeight = _calculateMonthGridHeight(_selectedMonth);
                  _targetCalendarHeight = newHeight;
                  _selectedMonth = newMonth;
                  _selectedDate = null;
                });
                
                // 触发动画
                _calendarHeightController.forward(from: 0);
              },
              itemBuilder: (context, index) {
                final monthOffset = index - _calendarInitialPage;
                final month = DateTime(DateTime.now().year, DateTime.now().month + monthOffset, 1);
                return _buildMonthGrid(month);
              },
            ),
          ),
        ],
      ),
    );
  }
  
  double _calculateMonthGridHeight(DateTime month) {
    final firstDayOfMonth = DateTime(month.year, month.month, 1);
    final lastDayOfMonth = DateTime(month.year, month.month + 1, 0);
    final firstWeekday = firstDayOfMonth.weekday % 7;
    final daysInMonth = lastDayOfMonth.day;
    final weeks = ((firstWeekday + daysInMonth) / 7).ceil();
    return weeks * 44.0;
  }
  
  Widget _buildMonthHeader() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        IconButton(
          icon: const Icon(Icons.chevron_left),
          onPressed: () {
            _calendarPageController.previousPage(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeInOut,
            );
          },
        ),
        Text(
          '${_selectedMonth.year}年${_selectedMonth.month}月',
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),
        IconButton(
          icon: const Icon(Icons.chevron_right),
          onPressed: () {
            _calendarPageController.nextPage(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeInOut,
            );
          },
        ),
      ],
    );
  }
  
  Widget _buildWeekDaysHeader() {
    final weekDays = ['日', '一', '二', '三', '四', '五', '六'];
    return Row(
      children: weekDays.map((day) => Expanded(
        child: Center(
          child: Text(
            day,
            style: TextStyle(
              fontSize: 12,
              color: Colors.grey.shade500,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      )).toList(),
    );
  }
  
  Widget _buildMonthGrid(DateTime month) {
    final firstDayOfMonth = DateTime(month.year, month.month, 1);
    final lastDayOfMonth = DateTime(month.year, month.month + 1, 0);
    final firstWeekday = firstDayOfMonth.weekday % 7;
    final daysInMonth = lastDayOfMonth.day;
    final weeks = ((firstWeekday + daysInMonth) / 7).ceil();
    
    return Column(
      children: List.generate(weeks, (weekIndex) {
        return Row(
          children: List.generate(7, (dayIndex) {
            final dayNumber = weekIndex * 7 + dayIndex - firstWeekday + 1;
            
            if (dayNumber < 1 || dayNumber > daysInMonth) {
              return Expanded(child: Container(height: 40));
            }
            
            final date = DateTime(month.year, month.month, dayNumber);
            final taskCount = _getTaskCountForDate(date);
            final isToday = _isToday(date);
            final isSelected = _selectedDate != null &&
                date.year == _selectedDate!.year &&
                date.month == _selectedDate!.month &&
                date.day == _selectedDate!.day;
            
            return Expanded(
              child: GestureDetector(
                onTap: () {
                  setState(() {
                    _selectedDate = date;
                  });
                },
                child: Container(
                  height: 40,
                  margin: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    color: taskCount > 0 ? _getHeatColor(taskCount) : Colors.grey.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: isToday
                          ? const Color(0xFF4A90E2)
                          : isSelected
                              ? const Color(0xFF4A90E2).withValues(alpha: 0.5)
                              : Colors.grey.shade200,
                      width: isToday || isSelected ? 2 : 1,
                    ),
                  ),
                  child: Center(
                    child: Text(
                      '$dayNumber',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: isToday ? FontWeight.bold : FontWeight.normal,
                        color: taskCount > 0
                            ? taskCount >= 3
                                ? Colors.white
                                : const Color(0xFFE60000)
                            : Colors.black87,
                      ),
                    ),
                  ),
                ),
              ),
            );
          }),
        );
      }),
    );
  }

  Widget _buildHeatLegend(String label, Color color) {
    return Row(
      children: [
        Container(
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: Colors.grey.shade300),
          ),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            color: Colors.grey.shade600,
          ),
        ),
      ],
    );
  }

  Widget _buildSelectedDateTasks() {
    final tasks = _getTasksForDate(_selectedDate!);
    final dateStr = DateFormat('yyyy年MM月dd日').format(_selectedDate!);
    
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                dateStr,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: tasks.isEmpty ? Colors.grey.shade100 : const Color(0xFFFF4D4D).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '${tasks.length} 个任务',
                  style: TextStyle(
                    fontSize: 12,
                    color: tasks.isEmpty ? Colors.grey.shade600 : const Color(0xFFE60000),
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (tasks.isEmpty)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  '当天无任务',
                  style: TextStyle(
                    color: Colors.grey.shade400,
                  ),
                ),
              ),
            )
          else
            ...tasks.map((task) => _buildTaskItem(task)),
        ],
      ),
    );
  }

  Widget _buildTaskItem(Task task) {
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
              await _toggleTaskCompletion(task);
            },
            child: Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: isCompleted ? priorityColor : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: isCompleted ? priorityColor : Colors.grey.shade400,
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
            height: 30,
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
                Text(
                  task.name,
                  style: TextStyle(
                    fontWeight: FontWeight.w500,
                    fontSize: 13,
                    color: isCompleted ? Colors.grey.shade500 : null,
                    decoration: isCompleted ? TextDecoration.lineThrough : null,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${task.type} · ${DateFormat('HH:mm').format(task.dueDate)}',
                  style: TextStyle(
                    fontSize: 11,
                    color: isCompleted ? Colors.grey.shade400 : Colors.grey.shade600,
                    decoration: isCompleted ? TextDecoration.lineThrough : null,
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: isCompleted 
                  ? Colors.grey.shade200 
                  : priorityColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              task.priority,
              style: TextStyle(
                fontSize: 10,
                color: isCompleted ? Colors.grey.shade500 : priorityColor,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  bool _isToday(DateTime date) {
    final now = DateTime.now();
    return date.year == now.year && date.month == now.month && date.day == now.day;
  }

  Widget _buildStatCard(String label, String value, Color color) {
    return Expanded(
      child: Card(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: Colors.grey.shade200),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            children: [
              Text(
                value,
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.grey.shade600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          children: [
            Icon(
              Icons.task_alt,
              size: 80,
              color: Colors.grey.shade300,
            ),
            const SizedBox(height: 16),
            Text(
              '暂无任务',
              style: TextStyle(
                fontSize: 16,
                color: Colors.grey.shade400,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTaskCard(Task task, BuildContext context) {
    final isOverdue = task.dueDate.isBefore(DateTime.now());
    final priorityColor = task.priority == '高' ? Colors.red : 
                          task.priority == '中' ? Colors.orange : Colors.green;
    final isCompleted = task.completed;
    
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: isCompleted ? Colors.grey.shade300 : Colors.grey.shade200),
      ),
      color: isCompleted ? Colors.grey.shade50 : null,
      child: ListTile(
        contentPadding: const EdgeInsets.all(16),
        leading: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            GestureDetector(
              onTap: () async {
                HapticFeedback.selectionClick();
                await _toggleTaskCompletion(task);
              },
              child: Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: isCompleted ? priorityColor : Colors.transparent,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: isCompleted ? priorityColor : Colors.grey.shade400,
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
          ],
        ),
        title: Text(
          task.name,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: isCompleted ? Colors.grey.shade500 : null,
            decoration: isCompleted ? TextDecoration.lineThrough : null,
          ),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 4),
            Text(
              '${task.type} · 截止：${DateFormat('MM/dd HH:mm').format(task.dueDate)}',
              style: TextStyle(
                fontSize: 12,
                color: isCompleted 
                    ? Colors.grey.shade400 
                    : (isOverdue ? Colors.red : Colors.grey.shade600),
                decoration: isCompleted ? TextDecoration.lineThrough : null,
              ),
            ),
          ],
        ),
        trailing: isCompleted 
            ? null 
            : PopupMenuButton<String>(
          icon: Icon(Icons.more_vert, color: Colors.grey.shade400, size: 20),
          onOpened: () {
            HapticFeedback.selectionClick();
          },
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          color: Colors.white,
          elevation: 8,
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
          onSelected: (value) async {
            if (value == 'edit') {
              await Future.delayed(const Duration(milliseconds: 200));
              _showEditTaskDialog(task);
            } else if (value == 'delete') {
              StorageService.deleteTask(task.id);
              _loadData();
              setState(() {});
              toastNotification.show(context, '任务已删除', type: ToastType.error);
            }
          },
        ),
      ),
    );
  }

  void _showEditTaskDialog(Task task) {
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
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (context, animation, secondaryAnimation) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
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
                                          onChanged: (v) => setDialogState(() => type = v!),
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
                                            setDialogState(() {
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
                                                  Text(DateFormat('yyyy/MM/dd HH:mm').format(dueDate), style: TextStyle(fontWeight: FontWeight.w500, fontSize: isSmallScreen ? 14 : 16)),
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
                                            onTap: () => setDialogState(() => priority = p),
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
                                        _loadData();
                                        if (mounted) setState(() {});
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
}
