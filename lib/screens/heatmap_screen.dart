import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import '../utils/storage.dart';
import '../models/task.dart';
import '../models/course.dart';
import '../widgets/add_options_sheet.dart';
import '../dialogs/course_dialog.dart';
import '../widgets/toast_notification.dart';
import '../widgets/time_picker_dialog.dart';
import '../widgets/animated_calendar.dart';
import '../widgets/ddl_ai_insight_card.dart';
import '../config/ai_feature_flags.dart';
import '../widgets/glass_dialog.dart';
import '../widgets/blur_selection_menu.dart';
import '../widgets/gradient_blur_header.dart';
import '../widgets/app_text_field.dart';

class HeatmapScreen extends StatefulWidget {
  const HeatmapScreen({super.key});

  @override
  State<HeatmapScreen> createState() => HeatmapScreenState();
}

class HeatmapScreenState extends State<HeatmapScreen>
    with TickerProviderStateMixin {
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

  // AI 建议框页高度（根据内容动态变化）
  double _ddlInsightHeight = 200.0;

  /// 「设置 → AI设置 → 自动任务分析」子开关（从属于 AI 功能总开关）。
  /// 读 [AIAutoAnalysisFlags] 的同步缓存而不是自己 await：本页间距和
  /// 卡片定相必须在同一帧得出同一个结论，异步读会错开一帧，表现为
  /// 「关闭时每次进入都播一遍折叠动画」「重新打开时顶间距等分析跑完才复原」。
  /// AI 总开关关闭仍是原来的引导提示态，不受此开关影响。
  bool get _autoTaskAnalysis => AIAutoAnalysisFlags.taskEnabled;

  /// 建议框是否收起（决定其与上下元素的间距）：用户点过叉，
  /// 或子开关关闭且没有可保留的分析结果。纯同步求值，不依赖卡片回调
  bool get _aiInsightCollapsed =>
      DDLAIInsightCard.isDismissedThisRun ||
      (!_autoTaskAnalysis && !DDLAIInsightCard.hasResult);

  // 任务列表筛选：all=全部 / threeDays=三天内 / sevenDays=七天内 / overdue=已逾期
  // 与顶部统计框口径对齐：「即将到期」按 3 天算（diff 0~3），故点它筛「三天内」
  String _taskFilter = 'all';

  // 「任务列表」标题锚点：点顶部统计框后滑动定位；筛选按钮锚点：下拉菜单定位
  final GlobalKey _taskListTitleKey = GlobalKey();
  final GlobalKey _filterButtonKey = GlobalKey();

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
    _tasks = allTasks.where((t) {
      if (!t.completed) return true;
      return _retainedCompletedTaskIds.contains(t.id);
    }).toList();
    _sortTasks();
  }

  void _sortTasks() {
    _tasks.sort((a, b) {
      return a.dueDate.compareTo(b.dueDate);
    });
  }

  /// 当前筛选条件下的任务列表（只影响任务列表展示，日历热力与统计框不受影响）。
  /// 口径与顶部统计框一致：「三天内/七天内」只含未到期任务（diff 0~3 / 0~6），
  /// 「已逾期」只列未完成的逾期任务（已完成任务由列表本身的保留机制管理）。
  List<Task> get _filteredTasks {
    final now = DateTime.now();
    switch (_taskFilter) {
      case 'threeDays':
        return _tasks.where((t) {
          final diff = t.dueDate.difference(now).inDays;
          return diff >= 0 && diff <= 3;
        }).toList();
      case 'sevenDays':
        return _tasks.where((t) {
          final diff = t.dueDate.difference(now).inDays;
          return diff >= 0 && diff <= 6;
        }).toList();
      case 'overdue':
        return _tasks
            .where((t) => !t.completed && t.dueDate.isBefore(now))
            .toList();
      default:
        return _tasks;
    }
  }

  /// 统计框点击入口：数量为 0 时弹绿色 toast 提示（不筛选不滑动），
  /// 否则应用对应筛选并滑到任务列表
  void _onStatCardTap(String filter, int count) {
    if (count == 0) {
      HapticFeedback.selectionClick();
      toastNotification.show(context, '没有符合条件的任务',
          type: ToastType.success);
      return;
    }
    _applyFilterAndScroll(filter);
  }

  /// 应用筛选并滑动到任务列表（顶部统计框点击入口）。
  /// 滑动放在帧末：筛选后列表高度变化，先等当帧布局完成再定位。
  void _applyFilterAndScroll(String filter) {
    if (_taskFilter != filter) {
      setState(() => _taskFilter = filter);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final titleContext = _taskListTitleKey.currentContext;
      if (titleContext != null) {
        Scrollable.ensureVisible(
          titleContext,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  /// 筛选下拉菜单：复用全局毛玻璃菜单（glass_dialog.dart 的 showBlurredMenu），
  /// 锚定筛选按钮向下弹出，返回选中的筛选值
  Future<void> _showFilterMenu() async {
    final anchorContext = _filterButtonKey.currentContext ?? context;
    const items = [
      DropdownMenuItem<String>(value: 'all', child: Text('全部')),
      DropdownMenuItem<String>(value: 'threeDays', child: Text('三天内')),
      DropdownMenuItem<String>(value: 'sevenDays', child: Text('七天内')),
      DropdownMenuItem<String>(value: 'overdue', child: Text('已逾期')),
    ];
    // 菜单整体左移使右缘与按钮右缘对齐（同对话页徽章的做法）：
    // 偏移量按锚点实际宽度动态算，菜单比锚点宽多少就左移多少
    double horizontalShift = 0;
    final anchorBox = _filterButtonKey.currentContext?.findRenderObject();
    if (anchorBox is RenderBox) {
      horizontalShift = anchorBox.size.width - 132;
    }
    final result = await showBlurredMenu<String>(
      context: anchorContext,
      value: _taskFilter,
      menuWidth: 132,
      menuHorizontalShift: horizontalShift,
      items: items,
    );
    if (result != null && mounted) {
      setState(() => _taskFilter = result);
    }
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
    final overdueTasks =
        activeTasks.where((t) => t.dueDate.isBefore(today)).length;
    final upcomingTasks = activeTasks.where((t) {
      final diff = t.dueDate.difference(today).inDays;
      return diff >= 0 && diff <= 3;
    }).length;

    return Scaffold(
      backgroundColor: Theme.of(context).brightness == Brightness.dark
          ? AppPalette.dark.scaffold
          : const Color(0xFFF8F9FC),
      body: Stack(
        children: [
          CustomScrollView(
            physics: const BouncingScrollPhysics(
                parent: AlwaysScrollableScrollPhysics()),
            slivers: [
              SliverPadding(
                padding: EdgeInsets.only(
                    top: MediaQuery.of(context).padding.top + 62),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 140),
                sliver: SliverList(
                  delegate: SliverChildListDelegate([
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 三个统计方块（独立卡片，固定高度）
                        // 点方块 = 应用对应筛选并滑动到任务列表（口径与统计一致）；
                        // 数量为 0 时只弹绿色 toast 提示，不筛选不滑动
                        Row(
                          children: [
                            Expanded(
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () =>
                                    _onStatCardTap('all', totalTasks),
                                child: _buildStatCard(
                                    '总任务', '$totalTasks', Colors.blue),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () => _onStatCardTap(
                                    'threeDays', upcomingTasks),
                                child: _buildStatCard(
                                    '即将到期', '$upcomingTasks', Colors.orange),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () => _onStatCardTap(
                                    'overdue', overdueTasks),
                                child: _buildStatCard(
                                    '已逾期', '$overdueTasks', Colors.red),
                              ),
                            ),
                          ],
                        ),
                        // 中间间距：任务提示被用户关闭、或「自动任务分析」
                        // 子开关关闭后收窄（动画与卡片收起同步，避免下方内容
                        // 先跳变再滑动），使日历与数量统计的间距等于数量统计与
                        // 标题栏的间距（16）
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 250),
                          curve: Curves.easeInOutCubic,
                          height: _aiInsightCollapsed ? 0 : 16,
                        ),
                        // AI 任务建议框（独立卡片，高度根据内容自适应，用 AnimatedSize 平滑延展）
                        // 是否展示、是否保留已有结果由卡片自己按子开关定相
                        AnimatedSize(
                          duration: const Duration(milliseconds: 250),
                          curve: Curves.easeInOutCubic,
                          alignment: Alignment.topCenter,
                          child: DDLAIInsightCard(
                            tasks: _tasks,
                            autoAnalysis: _autoTaskAnalysis,
                            onHeightChanged: (h) {
                              final newHeight = h + 4;
                              if ((newHeight - _ddlInsightHeight).abs() > 1) {
                                setState(() {
                                  _ddlInsightHeight = newHeight;
                                });
                              }
                            },
                          ),
                        ),
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 250),
                          curve: Curves.easeInOutCubic,
                          height: _aiInsightCollapsed ? 16 : 24,
                        ),

                        _buildCalendarHeatmap(),
                        const SizedBox(height: 24),

                        if (_selectedDate != null) ...[
                          _buildSelectedDateTasks(),
                          const SizedBox(height: 24),
                        ],

                        // 标题行：左标题 + 右侧筛选按钮（点击弹出筛选下拉菜单）
                        Row(
                          key: _taskListTitleKey,
                          children: [
                            const Text(
                              '任务列表',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const Spacer(),
                            GestureDetector(
                              key: _filterButtonKey,
                              behavior: HitTestBehavior.opaque,
                              onTap: _showFilterMenu,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 2, vertical: 4),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.filter_alt_outlined,
                                      size: 18,
                                      // 筛选生效时高亮主题蓝，提示当前非「全部」
                                      color: _taskFilter == 'all'
                                          ? AppColors.of(context).textSecondary
                                          : const Color(0xFF4A90E2),
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      '筛选',
                                      style: TextStyle(
                                        fontSize: 13,
                                        color:
                                            AppColors.of(context).textSecondary,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 5),

                        _buildFilteredTaskList(),
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
    // 无界渐变标题栏（同设置页）：模糊/雾化自顶部向底缘衰减归零
    return Positioned(
      left: 0,
      right: 0,
      top: 0,
      child: GradientBlurHeader(
        topPadding: topPadding,
        title: '待办',
        // 雾面曲线整体下移 6px（绘制区不越出标题栏，减弱模式同样
        // 生效）：同高度浓度=原上移 6px 处，标题下方一行可读性↑
        blurCurveShift: 6,
        // 标题栏本体增高 6px：内容区起始位置随之下移（列表顶部偏移
        // 已同步 +6），底部坡面多出 6px 渐变空间
        layoutBottomExtend: 6,
      ),
    );
  }

  /// 加号 FAB「添加」底部弹出框：壳与内容统一走共享组件
  /// （add_options_sheet.dart，课表页同款），本页只传各自的按钮回调；
  /// [onGoToChat] 由 home_screen 传入，用于「前往对话页」按钮跳转 Tab。
  /// 课程入口与课表页一致——直接开课程对话框，不再只提示"请前往课表页"
  void showAddOptions({VoidCallback? onGoToChat}) {
    showAddOptionsSheet(
      context,
      onCourse: _showAddCourseDialog,
      onTask: _showAddTaskWithOptions,
      onGoToChat: onGoToChat ?? () {},
    );
  }

  /// 待办页直接添加课程：与课表页「无锚点」入口同一套（CourseDialog.show，
  /// hosted 模式的关于式弹性对话框）。保存成功后刷新本页数据——课表页经
  /// StorageService 的数据变更通知自行刷新，无需这里处理
  Future<void> _showAddCourseDialog() async {
    final saved = await CourseDialog.show(
      context: context,
      // 默认选中今天（与课表页添加一致：DateTime.now().weekday 为 1~7）
      selectedDay: DateTime.now().weekday - 1,
    );
    if (!mounted || saved == null) return;
    _loadData();
    setState(() {});
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
        constraints:
            BoxConstraints(maxWidth: 360, maxHeight: screenHeight * 0.6),
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
                      child:
                          const Icon(Icons.book, color: Colors.white, size: 22),
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
                        child: const Icon(Icons.close,
                            color: Colors.white, size: 18),
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
                    Icon(Icons.book_outlined,
                        size: 48, color: AppColors.of(context).textTertiary),
                    const SizedBox(height: 12),
                    Text(
                      '暂无课程',
                      style:
                          TextStyle(color: AppColors.of(context).textTertiary),
                    ),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: () {
                        // 关闭「选择课程」框后直接开课程对话框（与加号菜单
                        // 的「添加课程」同款），不再只提示跳转课表页。
                        // 注意用页面 State 的方法：这里的 context 是
                        // 本对话框内部的，pop 后即失效
                        Navigator.pop(context);
                        _showAddCourseDialog();
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
                  physics: const BouncingScrollPhysics(
                      parent: AlwaysScrollableScrollPhysics()),
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
                        color: AppColors.of(context).panel(0.4),
                        borderRadius: BorderRadius.circular(12),
                        border:
                            Border.all(color: AppColors.of(context).borderWeak),
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
                        subtitle: courses.first.teacher != null &&
                                courses.first.teacher!.isNotEmpty
                            ? Text(courses.first.teacher!,
                                style: TextStyle(
                                    fontSize: 12,
                                    color: AppColors.of(context).textSecondary))
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

    showBouncyDialog(
      context: context,
      barrierLabel: '添加任务',
      avoidKeyboard: true,
      margin: EdgeInsets.symmetric(
          horizontal: MediaQuery.of(context).size.height < 700 ? 16 : 24),
      shellPadding: EdgeInsets.zero,
      shellBoxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.2),
          blurRadius: 20,
          offset: const Offset(0, 10),
        ),
      ],
      builder: (context) => StatefulBuilder(
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
          dialogMaxHeight =
              dialogMaxHeight.clamp(260.0, baseMaxHeight).toDouble();

          return ConstrainedBox(
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
                        colors: [
                          courseColor,
                          courseColor.withValues(alpha: 0.8)
                        ],
                      ),
                      borderRadius:
                          const BorderRadius.vertical(top: Radius.circular(24)),
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: EdgeInsets.all(isSmallScreen ? 8 : 10),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(Icons.add_task,
                              color: Colors.white,
                              size: isSmallScreen ? 20 : 22),
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
                            child: Icon(Icons.close,
                                color: Colors.white,
                                size: isSmallScreen ? 16 : 18),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    physics: const BouncingScrollPhysics(
                        parent: AlwaysScrollableScrollPhysics()),
                    padding: EdgeInsets.all(isSmallScreen ? 16 : 20),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AppTextField(
                          contextMenuBuilder: styledEditableContextMenu,
                          decoration: InputDecoration(
                            labelText: '任务名称',
                            prefixIcon: Icon(Icons.task,
                                color: courseColor.withValues(alpha: 0.7),
                                size: isSmallScreen ? 18 : 20),
                            filled: true,
                            fillColor: AppColors.of(context).panel(0.4),
                            contentPadding: EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: isSmallScreen ? 12 : 14),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(
                                  color: AppColors.of(context).borderWeak),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(
                                  color: AppColors.of(context).borderWeak),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide:
                                  BorderSide(color: courseColor, width: 2),
                            ),
                          ),
                          style: TextStyle(fontSize: isSmallScreen ? 14 : 16),
                          onChanged: (v) => taskTitle = v,
                        ),
                        SizedBox(height: isSmallScreen ? 12 : 16),
                        Row(
                          children: [
                            Icon(Icons.category_outlined,
                                color: courseColor.withValues(alpha: 0.7),
                                size: isSmallScreen ? 18 : 20),
                            SizedBox(width: isSmallScreen ? 6 : 8),
                            Text(
                              '任务类型',
                              style: TextStyle(
                                fontSize: isSmallScreen ? 11 : 12,
                                color: AppColors.of(context).textSecondary,
                              ),
                            ),
                          ],
                        ),
                        SizedBox(height: isSmallScreen ? 6 : 8),
                        Container(
                          padding: EdgeInsets.symmetric(
                              horizontal: isSmallScreen ? 10 : 12),
                          decoration: BoxDecoration(
                            color: AppColors.of(context).panel(0.4),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                                color: AppColors.of(context).borderWeak),
                          ),
                          child: BlurredDropdown<String>(
                            value: type,
                            isExpanded: true,
                            icon: Icon(Icons.expand_more,
                                color: courseColor,
                                size: isSmallScreen ? 18 : 20),
                            items: ['作业', '考试', '报告', '其他']
                                .map((e) => DropdownMenuItem(
                                    value: e,
                                    child: Text(e,
                                        style: TextStyle(
                                            fontSize:
                                                isSmallScreen ? 14 : 16))))
                                .toList(),
                            onChanged: (v) => setDialogState(() => type = v!),
                          ),
                        ),
                        SizedBox(height: isSmallScreen ? 12 : 16),
                        InkWell(
                          onTap: () async {
                            final date = await showAnimatedDatePicker(
                              context: context,
                              initialDate: dueDate,
                              firstDate: DateTime.now(),
                              lastDate:
                                  DateTime.now().add(const Duration(days: 365)),
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
                                setDialogState(() {
                                  dueDate = DateTime(date.year, date.month,
                                      date.day, time.hour, time.minute);
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
                              color: AppColors.of(context).panel(0.4),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                  color: AppColors.of(context).borderWeak),
                            ),
                            child: Row(
                              children: [
                                Icon(Icons.calendar_today,
                                    color: courseColor.withValues(alpha: 0.7),
                                    size: isSmallScreen ? 18 : 20),
                                SizedBox(width: isSmallScreen ? 10 : 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text('截止时间',
                                          style: TextStyle(
                                              fontSize: isSmallScreen ? 11 : 12,
                                              color: AppColors.of(context)
                                                  .textSecondary)),
                                      Text(
                                          '${dueDate.year}/${dueDate.month}/${dueDate.day} ${dueDate.hour.toString().padLeft(2, '0')}:${dueDate.minute.toString().padLeft(2, '0')}',
                                          style: TextStyle(
                                              fontWeight: FontWeight.w500,
                                              fontSize:
                                                  isSmallScreen ? 14 : 16)),
                                    ],
                                  ),
                                ),
                                Icon(Icons.chevron_right,
                                    color: AppColors.of(context).textTertiary,
                                    size: isSmallScreen ? 18 : 20),
                              ],
                            ),
                          ),
                        ),
                        SizedBox(height: isSmallScreen ? 12 : 16),
                        Row(
                          children: [
                            Icon(Icons.flag_outlined,
                                color: courseColor.withValues(alpha: 0.7),
                                size: isSmallScreen ? 18 : 20),
                            SizedBox(width: isSmallScreen ? 6 : 8),
                            Text(
                              '优先级',
                              style: TextStyle(
                                fontSize: isSmallScreen ? 11 : 12,
                                color: AppColors.of(context).textSecondary,
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
                            } else if (p == '中')
                              priorityColor = Colors.orange;
                            else
                              priorityColor = Colors.green;

                            return Expanded(
                              child: GestureDetector(
                                onTap: () => setDialogState(() => priority = p),
                                child: Container(
                                  margin: EdgeInsets.symmetric(
                                      horizontal: isSmallScreen ? 3 : 4),
                                  padding: EdgeInsets.symmetric(
                                      vertical: isSmallScreen ? 8 : 10),
                                  decoration: BoxDecoration(
                                    color: isSelected
                                        ? priorityColor.withValues(alpha: 0.15)
                                        : AppColors.of(context).panel(0.4),
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(
                                      color: isSelected
                                          ? priorityColor
                                          : Colors.grey.shade200,
                                      width: isSelected ? 2 : 1,
                                    ),
                                  ),
                                  child: Text(
                                    p,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontSize: isSmallScreen ? 13 : 14,
                                      color: isSelected
                                          ? priorityColor
                                          : Colors.grey.shade600,
                                      fontWeight: isSelected
                                          ? FontWeight.bold
                                          : FontWeight.normal,
                                    ),
                                  ),
                                ),
                              ),
                            );
                          }).toList(),
                        ),
                        SizedBox(height: isSmallScreen ? 12 : 16),
                        AppTextField(
                          contextMenuBuilder: styledEditableContextMenu,
                          maxLines: 1,
                          decoration: InputDecoration(
                            labelText: '备注',
                            prefixIcon: Icon(Icons.note_outlined,
                                color: courseColor.withValues(alpha: 0.7),
                                size: isSmallScreen ? 18 : 20),
                            filled: true,
                            fillColor: AppColors.of(context).panel(0.4),
                            contentPadding: EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: isSmallScreen ? 12 : 14),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(
                                  color: AppColors.of(context).borderWeak),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(
                                  color: AppColors.of(context).borderWeak),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide:
                                  BorderSide(color: courseColor, width: 2),
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
                  padding: EdgeInsets.fromLTRB(isSmallScreen ? 16 : 20, 0,
                      isSmallScreen ? 16 : 20, isSmallScreen ? 16 : 20),
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.pop(context),
                          style: OutlinedButton.styleFrom(
                            padding: EdgeInsets.symmetric(
                                vertical: isSmallScreen ? 12 : 14),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                            side: BorderSide(
                                color: AppColors.of(context).borderWeak),
                          ),
                          child: Text('取消',
                              style:
                                  TextStyle(fontSize: isSmallScreen ? 13 : 14)),
                        ),
                      ),
                      SizedBox(width: isSmallScreen ? 10 : 12),
                      Expanded(
                        flex: 2,
                        child: ElevatedButton(
                          onPressed: () async {
                            if (taskTitle.isEmpty) {
                              toastNotification.show(context, '请输入任务名称',
                                  type: ToastType.error);
                              return;
                            }
                            final isMergedCourse = StorageService.getCourses()
                                    .where((c) => c.name == course.name)
                                    .length >
                                1;
                            final taskCourseId = isMergedCourse
                                ? 'course_name:${course.name}'
                                : course.id;
                            final task = Task(
                              id: DateTime.now()
                                  .millisecondsSinceEpoch
                                  .toString(),
                              courseId: taskCourseId,
                              name: taskTitle,
                              type: type,
                              dueDate: dueDate,
                              priority: priority,
                              note: description,
                            );
                            await StorageService.addTask(task);
                            if (context.mounted) {
                              Navigator.pop(context);
                            }
                            _loadData();
                            setState(() {});
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              toastNotification.show(context, '添加任务成功',
                                  type: ToastType.success);
                            });
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: courseColor,
                            foregroundColor: Colors.white,
                            padding: EdgeInsets.symmetric(
                                vertical: isSmallScreen ? 12 : 14),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                          ),
                          child: Text('保存',
                              style:
                                  TextStyle(fontSize: isSmallScreen ? 13 : 15)),
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

  Widget _buildCalendarHeatmap() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.of(context).surface,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: AppColors.of(context).overlaySoft,
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
                  (_targetCalendarHeight - _currentCalendarHeight) *
                      _calendarHeightAnimation.value;
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
                final newMonth = DateTime(
                    DateTime.now().year, DateTime.now().month + monthOffset, 1);
                final newHeight = _calculateMonthGridHeight(newMonth);

                setState(() {
                  _currentCalendarHeight =
                      _calculateMonthGridHeight(_selectedMonth);
                  _targetCalendarHeight = newHeight;
                  _selectedMonth = newMonth;
                  _selectedDate = null;
                });

                // 触发动画
                _calendarHeightController.forward(from: 0);
              },
              itemBuilder: (context, index) {
                final monthOffset = index - _calendarInitialPage;
                final month = DateTime(
                    DateTime.now().year, DateTime.now().month + monthOffset, 1);
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
    // 标题走 Stack 绝对居中：Row+spaceBetween 下右侧「今 + >」两组按钮
    // （96dp）比左侧单箭头（48dp）宽，会把标题中心左挤约 24dp（实测量到 27dp）
    return Stack(
      alignment: Alignment.center,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: IconButton(
            icon: const Icon(Icons.chevron_left),
            onPressed: () {
              _calendarPageController.previousPage(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeInOut,
              );
            },
          ),
        ),
        Text(
          '${_selectedMonth.year}年${_selectedMonth.month}月',
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),
        // 「今」与右箭头同侧成组：槽位常驻只淡入淡出，箭头不随显隐位移
        Align(
          alignment: Alignment.centerRight,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildMonthTodayButton(),
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
          ),
        ),
      ],
    );
  }

  /// 头部「今」按钮：浏览月不是本月时出现，点击回到本月。
  ///
  /// 外观刻意对齐右侧 chevron：同为 IconButton 的 48×48 命中区，字色取
  /// IconTheme 继承色（与未指定 color 的 Icon 同源的解析结果）。
  /// 出现/消失为淡入淡出 + 缩放（0.8 → 1.0），与课表页那颗同参数。
  Widget _buildMonthTodayButton() {
    final bool atCurrentMonth = _isViewingCurrentMonth;
    return AnimatedScale(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
      scale: atCurrentMonth ? 0.8 : 1.0,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
        opacity: atCurrentMonth ? 0.0 : 1.0,
        child: IgnorePointer(
          ignoring: atCurrentMonth,
          child: IconButton(
            onPressed: _goToCurrentMonth,
            icon: Text(
              '今',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: IconTheme.of(context).color ??
                    AppColors.of(context).textPrimary,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 日历浏览月是否就是本月（「今」按钮的显隐依据）
  bool get _isViewingCurrentMonth {
    final now = DateTime.now();
    return _selectedMonth.year == now.year && _selectedMonth.month == now.month;
  }

  /// 回到本月：动画时长与曲线同左右箭头。_selectedMonth 由 onPageChanged 回写，
  /// 按钮随之淡出，故手动滑回本月与点击「今」共用同一条收敛路径
  void _goToCurrentMonth() {
    if (_isViewingCurrentMonth || !_calendarPageController.hasClients) return;
    _calendarPageController.animateToPage(
      _calendarInitialPage,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  Widget _buildWeekDaysHeader() {
    final weekDays = ['日', '一', '二', '三', '四', '五', '六'];
    return Row(
      children: weekDays
          .map((day) => Expanded(
                child: Center(
                  child: Text(
                    day,
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.of(context).textTertiary,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ))
          .toList(),
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
                    color: taskCount > 0
                        ? _getHeatColor(taskCount)
                        : AppColors.of(context).surfaceAlt,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: isToday
                          ? const Color(0xFF4A90E2)
                          : isSelected
                              ? const Color(0xFF4A90E2).withValues(alpha: 0.5)
                              : AppColors.of(context).borderWeak,
                      width: isToday || isSelected ? 2 : 1,
                    ),
                  ),
                  child: Center(
                    child: Text(
                      '$dayNumber',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight:
                            isToday ? FontWeight.bold : FontWeight.normal,
                        color: taskCount > 0
                            ? taskCount >= 3
                                ? Colors.white
                                : const Color(0xFFE60000)
                            : AppColors.of(context).textPrimary,
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
            border: Border.all(color: AppColors.of(context).borderWeak),
          ),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            color: AppColors.of(context).textSecondary,
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
        color: AppColors.of(context).surface,
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
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: tasks.isEmpty
                      ? AppColors.of(context).surfaceAlt
                      : const Color(0xFFFF4D4D).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '${tasks.length} 个任务',
                  style: TextStyle(
                    fontSize: 12,
                    color: tasks.isEmpty
                        ? AppColors.of(context).textSecondary
                        : const Color(0xFFE60000),
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
                    color: AppColors.of(context).textTertiary,
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
    final priorityColor = task.priority == '高'
        ? Colors.red
        : task.priority == '中'
            ? Colors.orange
            : Colors.green;
    final isCompleted = task.completed;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isCompleted
            ? AppColors.of(context).surfaceAlt
            : AppColors.of(context).surfaceAlt,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
            color: isCompleted
                ? AppColors.of(context).borderWeak
                : AppColors.of(context).borderWeak),
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
                  color: isCompleted
                      ? priorityColor
                      : AppColors.of(context).textTertiary,
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
              color: isCompleted
                  ? AppColors.of(context).textTertiary
                  : (isOverdue ? Colors.red : priorityColor),
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
                    color:
                        isCompleted ? AppColors.of(context).textTertiary : null,
                    decoration: isCompleted ? TextDecoration.lineThrough : null,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${task.type} · ${DateFormat('HH:mm').format(task.dueDate)}',
                  style: TextStyle(
                    fontSize: 11,
                    color: isCompleted
                        ? AppColors.of(context).textTertiary
                        : AppColors.of(context).textSecondary,
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
                  ? AppColors.of(context).borderWeak
                  : priorityColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              task.priority,
              style: TextStyle(
                fontSize: 10,
                color: isCompleted
                    ? AppColors.of(context).textTertiary
                    : priorityColor,
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
    return date.year == now.year &&
        date.month == now.month &&
        date.day == now.day;
  }

  Widget _buildStatCard(String label, String value, Color color) {
    // 不自带 Expanded：调用方决定弹性布局（统计行现在是
    // Expanded > GestureDetector(点击筛选) > 本卡片 的嵌套结构）
    return Card(
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: AppColors.of(context).borderWeak),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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
              const SizedBox(height: 2),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  color: AppColors.of(context).textSecondary,
                ),
              ),
            ],
          ),
        ),
    );
  }

  /// 任务列表（含筛选切换动画）。
  /// 列表数据在此处取快照：AnimatedSwitcher 保留的旧列表在退场动画期间必须
  /// 继续显示「旧数据」——若闭包直接读 _filteredTasks getter，动画期间它已
  /// 返回筛选后的新列表，旧列表内容会提前变成新内容（动画看着像没播），
  /// 且旧 itemCount 大于新列表长度时会索引越界
  Widget _buildFilteredTaskList() {
    final filtered = _filteredTasks;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) {
        final isIncoming =
            (child.key as ValueKey<String>).value == _taskFilter;
        if (isIncoming) {
          // 新列表：只淡入，不做任何缩放——稳态尺寸恒为 1.0，
          // 彻底排除「动画结束后列表停在缩小状态」的可能
          return FadeTransition(opacity: animation, child: child);
        }
        // 旧列表：向内收缩 + 淡出。出场动画由 AnimatedSwitcher 反向播放
        // （1→0），故 0.55 + 0.45 * value 即 1.0→0.55 收缩；幅度对齐切换课表
        // 对话框删除动画（仅去掉模糊）。顶部锚定缩放，避免长列表以中心
        // 缩放时可见内容被抽到中间一小块
        return FadeTransition(
          opacity: animation,
          child: Transform.scale(
            scale: 0.55 + 0.45 * animation.value,
            alignment: Alignment.topCenter,
            child: child,
          ),
        );
      },
      // 旧列表放 Stack 最上层：淡出必须发生在新内容之上才看得见
      layoutBuilder: (currentChild, previousChildren) => Stack(
        alignment: Alignment.topCenter,
        clipBehavior: Clip.none,
        children: [
          if (currentChild != null) currentChild,
          for (final child in previousChildren)
            Positioned(left: 0, right: 0, child: child),
        ],
      ),
      child: filtered.isEmpty
          ? KeyedSubtree(
              key: ValueKey<String>(_taskFilter),
              child: _buildEmptyState(),
            )
          : ListView.builder(
              key: ValueKey<String>(_taskFilter),
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.only(top: 5, bottom: 48),
              itemCount: filtered.length,
              itemBuilder: (context, index) {
                final task = filtered[index];
                return _buildTaskCard(task, context);
              },
            ),
    );
  }

  Widget _buildEmptyState() {
    // 筛选生效时区分「真的没有任务」与「没有符合筛选条件的任务」
    final hasFilter = _taskFilter != 'all';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          children: [
            Icon(
              Icons.task_alt,
              size: 80,
              color: AppColors.of(context).borderWeak,
            ),
            const SizedBox(height: 16),
            Text(
              hasFilter ? '该筛选条件下暂无任务' : '暂无任务',
              style: TextStyle(
                fontSize: 16,
                color: AppColors.of(context).textTertiary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTaskCard(Task task, BuildContext context) {
    final isOverdue = task.dueDate.isBefore(DateTime.now());
    final priorityColor = task.priority == '高'
        ? Colors.red
        : task.priority == '中'
            ? Colors.orange
            : Colors.green;
    final isCompleted = task.completed;

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
            color: isCompleted
                ? AppColors.of(context).borderWeak
                : AppColors.of(context).borderWeak),
      ),
      color: isCompleted ? AppColors.of(context).surfaceAlt : null,
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
                    color: isCompleted
                        ? priorityColor
                        : AppColors.of(context).textTertiary,
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
                color: isCompleted
                    ? AppColors.of(context).textTertiary
                    : (isOverdue ? Colors.red : priorityColor),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ],
        ),
        title: Text(
          task.name,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: isCompleted ? AppColors.of(context).textTertiary : null,
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
                    ? AppColors.of(context).textTertiary
                    : (isOverdue
                        ? Colors.red
                        : AppColors.of(context).textSecondary),
                decoration: isCompleted ? TextDecoration.lineThrough : null,
              ),
            ),
          ],
        ),
        trailing: isCompleted
            ? null
            : Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: (_) => HapticFeedback.selectionClick(),
                child: BlurredPopupMenuButton<String>(
                  icon: Icon(Icons.more_vert,
                      color: AppColors.of(context).textTertiary, size: 20),
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
                      _showEditTaskDialog(task);
                    } else if (value == 'delete') {
                      StorageService.deleteTask(task.id);
                      _loadData();
                      setState(() {});
                      toastNotification.show(context, '任务已删除',
                          type: ToastType.error);
                    }
                  },
                ),
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
      final matchedCourse = StorageService.getCourses()
          .where((c) => c.name == courseName)
          .firstOrNull;
      if (matchedCourse != null) {
        courseColor = _parseColor(matchedCourse.color);
      }
    } else if (task.courseId != 'ai_created') {
      final matchedCourse = StorageService.getCourses()
          .where((c) => c.id == task.courseId)
          .firstOrNull;
      if (matchedCourse != null) {
        courseColor = _parseColor(matchedCourse.color);
      }
    }

    showBouncyDialog(
      context: context,
      barrierLabel: '编辑任务',
      avoidKeyboard: true,
      margin: EdgeInsets.symmetric(
          horizontal: MediaQuery.of(context).size.height < 700 ? 16 : 24),
      shellPadding: EdgeInsets.zero,
      shellBoxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.2),
          blurRadius: 20,
          offset: const Offset(0, 10),
        ),
      ],
      builder: (context) => StatefulBuilder(
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
          dialogMaxHeight =
              dialogMaxHeight.clamp(260.0, baseMaxHeight).toDouble();

          return ConstrainedBox(
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
                        colors: [
                          courseColor,
                          courseColor.withValues(alpha: 0.8)
                        ],
                      ),
                      borderRadius:
                          const BorderRadius.vertical(top: Radius.circular(24)),
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: EdgeInsets.all(isSmallScreen ? 8 : 10),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(Icons.edit_note,
                              color: Colors.white,
                              size: isSmallScreen ? 20 : 22),
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
                            child: Icon(Icons.close,
                                color: Colors.white,
                                size: isSmallScreen ? 16 : 18),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    physics: const BouncingScrollPhysics(
                        parent: AlwaysScrollableScrollPhysics()),
                    padding: EdgeInsets.all(isSmallScreen ? 16 : 20),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AppTextField(
                          contextMenuBuilder: styledEditableContextMenu,
                          controller: nameController,
                          decoration: InputDecoration(
                            labelText: '任务名称',
                            prefixIcon: Icon(Icons.task,
                                color: courseColor.withValues(alpha: 0.7),
                                size: isSmallScreen ? 18 : 20),
                            filled: true,
                            fillColor: AppColors.of(context).panel(0.4),
                            contentPadding: EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: isSmallScreen ? 12 : 14),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(
                                  color: AppColors.of(context).borderWeak),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(
                                  color: AppColors.of(context).borderWeak),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide:
                                  BorderSide(color: courseColor, width: 2),
                            ),
                          ),
                          style: TextStyle(fontSize: isSmallScreen ? 14 : 16),
                        ),
                        SizedBox(height: isSmallScreen ? 12 : 16),
                        Row(
                          children: [
                            Icon(Icons.category_outlined,
                                color: courseColor.withValues(alpha: 0.7),
                                size: isSmallScreen ? 18 : 20),
                            SizedBox(width: isSmallScreen ? 6 : 8),
                            Text(
                              '任务类型',
                              style: TextStyle(
                                fontSize: isSmallScreen ? 11 : 12,
                                color: AppColors.of(context).textSecondary,
                              ),
                            ),
                          ],
                        ),
                        SizedBox(height: isSmallScreen ? 6 : 8),
                        Container(
                          padding: EdgeInsets.symmetric(
                              horizontal: isSmallScreen ? 10 : 12),
                          decoration: BoxDecoration(
                            color: AppColors.of(context).panel(0.4),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                                color: AppColors.of(context).borderWeak),
                          ),
                          child: BlurredDropdown<String>(
                            value: type,
                            isExpanded: true,
                            icon: Icon(Icons.expand_more,
                                color: courseColor,
                                size: isSmallScreen ? 18 : 20),
                            items: ['作业', '考试', '报告', '其他']
                                .map((e) => DropdownMenuItem(
                                    value: e,
                                    child: Text(e,
                                        style: TextStyle(
                                            fontSize:
                                                isSmallScreen ? 14 : 16))))
                                .toList(),
                            onChanged: (v) => setDialogState(() => type = v!),
                          ),
                        ),
                        SizedBox(height: isSmallScreen ? 12 : 16),
                        InkWell(
                          onTap: () async {
                            final date = await showAnimatedDatePicker(
                              context: context,
                              initialDate: dueDate,
                              firstDate: DateTime(2020),
                              lastDate: DateTime.now()
                                  .add(const Duration(days: 365 * 2)),
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
                                setDialogState(() {
                                  dueDate = DateTime(date.year, date.month,
                                      date.day, time.hour, time.minute);
                                });
                              }
                            }
                          },
                          borderRadius: BorderRadius.circular(12),
                          child: Container(
                            padding: EdgeInsets.all(isSmallScreen ? 12 : 16),
                            decoration: BoxDecoration(
                              color: AppColors.of(context).panel(0.4),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                  color: AppColors.of(context).borderWeak),
                            ),
                            child: Row(
                              children: [
                                Icon(Icons.calendar_today,
                                    color: courseColor.withValues(alpha: 0.7),
                                    size: isSmallScreen ? 18 : 20),
                                SizedBox(width: isSmallScreen ? 10 : 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text('截止日期',
                                          style: TextStyle(
                                              fontSize: isSmallScreen ? 11 : 12,
                                              color: AppColors.of(context)
                                                  .textSecondary)),
                                      Text(
                                          DateFormat('yyyy/MM/dd HH:mm')
                                              .format(dueDate),
                                          style: TextStyle(
                                              fontWeight: FontWeight.w500,
                                              fontSize:
                                                  isSmallScreen ? 14 : 16)),
                                    ],
                                  ),
                                ),
                                Icon(Icons.chevron_right,
                                    color: AppColors.of(context).textTertiary,
                                    size: isSmallScreen ? 18 : 20),
                              ],
                            ),
                          ),
                        ),
                        SizedBox(height: isSmallScreen ? 12 : 16),
                        Row(
                          children: [
                            Icon(Icons.flag_outlined,
                                color: courseColor.withValues(alpha: 0.7),
                                size: isSmallScreen ? 18 : 20),
                            SizedBox(width: isSmallScreen ? 6 : 8),
                            Text(
                              '优先级',
                              style: TextStyle(
                                fontSize: isSmallScreen ? 11 : 12,
                                color: AppColors.of(context).textSecondary,
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
                            } else if (p == '中')
                              priorityColor = Colors.orange;
                            else
                              priorityColor = Colors.green;

                            return Expanded(
                              child: GestureDetector(
                                onTap: () => setDialogState(() => priority = p),
                                child: Container(
                                  margin: EdgeInsets.symmetric(
                                      horizontal: isSmallScreen ? 3 : 4),
                                  padding: EdgeInsets.symmetric(
                                      vertical: isSmallScreen ? 8 : 10),
                                  decoration: BoxDecoration(
                                    color: isSelected
                                        ? priorityColor.withValues(alpha: 0.15)
                                        : AppColors.of(context).panel(0.4),
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(
                                      color: isSelected
                                          ? priorityColor
                                          : Colors.grey.shade200,
                                      width: isSelected ? 2 : 1,
                                    ),
                                  ),
                                  child: Text(
                                    p,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontSize: isSmallScreen ? 13 : 14,
                                      color: isSelected
                                          ? priorityColor
                                          : Colors.grey.shade600,
                                      fontWeight: isSelected
                                          ? FontWeight.bold
                                          : FontWeight.normal,
                                    ),
                                  ),
                                ),
                              ),
                            );
                          }).toList(),
                        ),
                        SizedBox(height: isSmallScreen ? 12 : 16),
                        AppTextField(
                          contextMenuBuilder: styledEditableContextMenu,
                          controller: noteController,
                          maxLines: 1,
                          decoration: InputDecoration(
                            labelText: '备注（可选）',
                            prefixIcon: Icon(Icons.note_outlined,
                                color: courseColor.withValues(alpha: 0.7),
                                size: isSmallScreen ? 18 : 20),
                            filled: true,
                            fillColor: AppColors.of(context).panel(0.4),
                            contentPadding: EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: isSmallScreen ? 12 : 14),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(
                                  color: AppColors.of(context).borderWeak),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(
                                  color: AppColors.of(context).borderWeak),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide:
                                  BorderSide(color: courseColor, width: 2),
                            ),
                          ),
                          style: TextStyle(fontSize: isSmallScreen ? 14 : 16),
                        ),
                      ],
                    ),
                  ),
                ),
                Container(
                  padding: EdgeInsets.fromLTRB(isSmallScreen ? 16 : 20, 0,
                      isSmallScreen ? 16 : 20, isSmallScreen ? 16 : 20),
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.pop(context),
                          style: OutlinedButton.styleFrom(
                            padding: EdgeInsets.symmetric(
                                vertical: isSmallScreen ? 12 : 14),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                            side: BorderSide(
                                color: AppColors.of(context).borderWeak),
                          ),
                          child: Text('取消',
                              style:
                                  TextStyle(fontSize: isSmallScreen ? 13 : 14)),
                        ),
                      ),
                      SizedBox(width: isSmallScreen ? 10 : 12),
                      Expanded(
                        flex: 2,
                        child: ElevatedButton(
                          onPressed: () async {
                            if (nameController.text.isEmpty) {
                              return;
                            }
                            final updatedTask = Task(
                              id: task.id,
                              courseId: task.courseId,
                              name: nameController.text,
                              type: type,
                              dueDate: dueDate,
                              priority: priority,
                              note: noteController.text.isEmpty
                                  ? null
                                  : noteController.text,
                              completed: task.completed,
                            );
                            await StorageService.updateTask(updatedTask);
                            if (context.mounted) {
                              Navigator.pop(context);
                            }
                            _loadData();
                            if (mounted) setState(() {});
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              toastNotification.show(context, '任务已更新',
                                  type: ToastType.success);
                            });
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: courseColor,
                            foregroundColor: Colors.white,
                            padding: EdgeInsets.symmetric(
                                vertical: isSmallScreen ? 12 : 14),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                          ),
                          child: Text('保存',
                              style:
                                  TextStyle(fontSize: isSmallScreen ? 13 : 15)),
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
}
