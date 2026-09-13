import 'package:flutter/material.dart';
import 'glass_dialog.dart';

class AnimatedCalendarDatePicker extends StatefulWidget {
  final DateTime initialDate;
  final DateTime firstDate;
  final DateTime lastDate;
  final Function(DateTime) onDateChanged;

  const AnimatedCalendarDatePicker({
    super.key,
    required this.initialDate,
    required this.firstDate,
    required this.lastDate,
    required this.onDateChanged,
  });

  @override
  State<AnimatedCalendarDatePicker> createState() => _AnimatedCalendarDatePickerState();
}

class _AnimatedCalendarDatePickerState extends State<AnimatedCalendarDatePicker> {
  late DateTime _selectedDate;
  late PageController _pageController;
  static const int _initialPage = 1200;
  
  final monthNames = ['1月', '2月', '3月', '4月', '5月', '6月', '7月', '8月', '9月', '10月', '11月', '12月'];
  static const double _cellSize = 40.0;
  static const double _cellSpacing = 4.0;
  /// 周标题行固定高（文字垂直居中），供网格总高精确计算
  static const double _weekHeaderHeight = 20.0;
  /// 最后一行日期与下方操作按钮之间的呼吸间距
  static const double _gridBottomGap = 6.0;

  @override
  void initState() {
    super.initState();
    _selectedDate = widget.initialDate;
    _pageController = PageController(initialPage: _initialPage);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  DateTime _getMonthFromPageIndex(int index) {
    final now = DateTime.now();
    final monthOffset = index - _initialPage;
    return DateTime(now.year, now.month + monthOffset, 1);
  }

  int _getWeeksInMonth(DateTime month) {
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    final firstDayOfMonth = DateTime(month.year, month.month, 1);
    final startWeekday = firstDayOfMonth.weekday % 7;
    return ((startWeekday + daysInMonth) / 7).ceil();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildHeader(),
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          alignment: Alignment.topCenter,
          child: _buildCurrentMonthGrid(),
        ),
        _buildActionButtons(context),
      ],
    );
  }

  Widget _buildCurrentMonthGrid() {
    final pageIndex = _pageController.hasClients
        ? (_pageController.page?.round() ?? _initialPage)
        : _initialPage;
    final month = _getMonthFromPageIndex(pageIndex);
    final weeksInMonth = _getWeeksInMonth(month);
    return LayoutBuilder(builder: (context, constraints) {
      // 格子是 childAspectRatio 1.0 的正方形，高度 = 宽度 =
      // (可用宽 − 左右 padding 32 − 6×列间距)/7，随对话框宽度变化。
      // 原实现按写死的 40px 估算行高，行数少、格子小的月份在最后一行
      // 下方留出成片空白（对话框越窄越严重）——改为按实际格宽推导
      final gridWidth = constraints.maxWidth;
      final cellSize = gridWidth.isFinite
          ? (gridWidth - 32 - 6 * _cellSpacing) / 7
          : _cellSize;
      final gridHeight = _weekHeaderHeight +
          8 +
          weeksInMonth * cellSize +
          (weeksInMonth - 1) * _cellSpacing +
          _gridBottomGap;
      return SizedBox(
        height: gridHeight,
        child: PageView.builder(
          controller: _pageController,
          onPageChanged: (index) {
            setState(() {});
          },
          itemBuilder: (context, index) {
            final m = _getMonthFromPageIndex(index);
            return _buildMonthGrid(m, cellSize);
          },
        ),
      );
    });
  }

  Widget _buildHeader() {
    final pageIndex = _pageController.hasClients 
        ? (_pageController.page?.round() ?? _initialPage) 
        : _initialPage;
    final currentMonth = _getMonthFromPageIndex(pageIndex);
    final year = currentMonth.year;
    final month = currentMonth.month;
    
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          IconButton(
            onPressed: () {
              _pageController.previousPage(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeInOut,
              );
            },
            icon: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: const Color(0xFF4A90E2).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.chevron_left, color: Color(0xFF4A90E2), size: 20),
            ),
          ),
          Text(
            '$year年 ${monthNames[month - 1]}',
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: Color(0xFF1A1A2E),
            ),
          ),
          IconButton(
            onPressed: () {
              _pageController.nextPage(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeInOut,
              );
            },
            icon: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: const Color(0xFF4A90E2).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.chevron_right, color: Color(0xFF4A90E2), size: 20),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMonthGrid(DateTime month, double cellSize) {
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    final firstDayOfMonth = DateTime(month.year, month.month, 1);
    final startWeekday = firstDayOfMonth.weekday % 7;
    final weeksInMonth = _getWeeksInMonth(month);

    final weekDays = ['日', '一', '二', '三', '四', '五', '六'];

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          SizedBox(
            height: _weekHeaderHeight,
            child: _buildWeekDaysHeader(weekDays),
          ),
          const SizedBox(height: 8),
          // 日期网格精确到实际行高：当前页恰好铺满无留白；滑动经过
          // 行数更多的相邻页时由 Flexible 兜底（网格临时内部滚动），
          // 不产生布局溢出
          Flexible(
            child: SizedBox(
              height:
                  weeksInMonth * cellSize + (weeksInMonth - 1) * _cellSpacing,
              child: _buildDaysGrid(month, daysInMonth, startWeekday),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWeekDaysHeader(List<String> weekDays) {
    return Row(
      children: weekDays.map((day) {
        return Expanded(
          child: Center(
            child: Text(
              day,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: Colors.grey.shade600,
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildDaysGrid(DateTime month, int daysInMonth, int startWeekday) {
    final List<Widget> dayWidgets = [];
    
    for (int i = 0; i < startWeekday; i++) {
      dayWidgets.add(const SizedBox());
    }
    
    for (int day = 1; day <= daysInMonth; day++) {
      final date = DateTime(month.year, month.month, day);
      final isSelected = date.year == _selectedDate.year &&
          date.month == _selectedDate.month &&
          date.day == _selectedDate.day;
      final isToday = date.year == DateTime.now().year &&
          date.month == DateTime.now().month &&
          date.day == DateTime.now().day;
      final isDisabled = date.isBefore(widget.firstDate) || date.isAfter(widget.lastDate);
      
      dayWidgets.add(
        _buildDayCell(
          day: day,
          isSelected: isSelected,
          isToday: isToday,
          isDisabled: isDisabled,
          onTap: isDisabled
              ? null
              : () {
                  setState(() {
                    _selectedDate = date;
                  });
                },
        ),
      );
    }
    
    return GridView.count(
      crossAxisCount: 7,
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      mainAxisSpacing: _cellSpacing,
      crossAxisSpacing: _cellSpacing,
      childAspectRatio: 1.0,
      children: dayWidgets,
    );
  }

  Widget _buildDayCell({
    required int day,
    required bool isSelected,
    required bool isToday,
    required bool isDisabled,
    VoidCallback? onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: isSelected
              ? const Color(0xFF4A90E2)
              : isToday
                  ? const Color(0xFF4A90E2).withValues(alpha: 0.15)
                  : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: isToday && !isSelected
              ? Border.all(color: const Color(0xFF4A90E2), width: 1.5)
              : null,
        ),
        child: Center(
          child: Text(
            '$day',
            style: TextStyle(
              fontSize: 14,
              fontWeight: isSelected || isToday ? FontWeight.bold : FontWeight.normal,
              color: isDisabled
                  ? Colors.grey.shade400
                  : isSelected
                      ? Colors.white
                      : const Color(0xFF1A1A2E),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildActionButtons(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton(
              onPressed: () => Navigator.pop(context),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                side: BorderSide(color: Colors.grey.shade300),
              ),
              child: const Text('取消'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: ElevatedButton(
              onPressed: () {
                widget.onDateChanged(_selectedDate);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF4A90E2),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: Text('确定 (${_selectedDate.month}/${_selectedDate.day})'),
            ),
          ),
        ],
      ),
    );
  }
}

Future<DateTime?> showAnimatedDatePicker({
  required BuildContext context,
  required DateTime initialDate,
  DateTime? firstDate,
  DateTime? lastDate,
  String title = '选择日期',
}) async {
  DateTime? selectedDate;
  
  await showBouncyDialog(
    context: context,
    barrierLabel: title,
    shellPadding: EdgeInsets.zero,
    shellBoxShadow: [
      BoxShadow(
        color: Colors.black.withValues(alpha: 0.2),
        blurRadius: 20,
        offset: const Offset(0, 10),
      ),
    ],
    builder: (context) {
      final screenWidth = MediaQuery.of(context).size.width;
      final dialogWidth = screenWidth > 400 ? 360.0 : screenWidth * 0.9;
      
      return SizedBox(
        width: dialogWidth,
        child: AnimatedCalendarDatePicker(
                      initialDate: initialDate,
                      // 归一化到当天 00:00：调用方常传 DateTime.now()（含时分），
                      // 而日历格子日期是当天零点，未归一化时今天会被
                      // isBefore 误判为禁用，导致当天无法选择
                      firstDate: firstDate != null
                          ? DateTime(firstDate.year, firstDate.month, firstDate.day)
                          : DateTime(2020),
                      lastDate: lastDate != null
                          ? DateTime(lastDate.year, lastDate.month, lastDate.day)
                          : DateTime(2030),
                      onDateChanged: (date) {
                        selectedDate = date;
                        Navigator.pop(context);
                      },
                    ),
      );
    },
  );

  return selectedDate;
}
