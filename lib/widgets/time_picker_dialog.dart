import 'dart:ui';
import 'package:flutter/material.dart';

class TimePickerResult {
  final int hour;
  final int minute;

  TimePickerResult({required this.hour, required this.minute});

  String get formatted => '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
}

class LeadTimePickerResult {
  final int days;
  final int hours;
  final int minutes;

  LeadTimePickerResult({
    required this.days,
    required this.hours,
    required this.minutes,
  });
}

Future<TimePickerResult?> show3DTimePicker({
  required BuildContext context,
  required int initialHour,
  required int initialMinute,
  String title = '选择时间',
}) async {
  int selectedHour = initialHour;
  int selectedMinute = initialMinute;

  final FixedExtentScrollController hourController = FixedExtentScrollController(initialItem: initialHour);
  final FixedExtentScrollController minuteController = FixedExtentScrollController(initialItem: initialMinute);

  final result = await showGeneralDialog<TimePickerResult>(
    context: context,
    barrierDismissible: true,
    barrierLabel: title,
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
                      width: 300,
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
                          Text(
                            title,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF1A1A2E),
                            ),
                          ),
                          const SizedBox(height: 20),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              SizedBox(
                                width: 80,
                                height: 150,
                                child: ListWheelScrollView.useDelegate(
                                  controller: hourController,
                                  itemExtent: 40,
                                  perspective: 0.005,
                                  diameterRatio: 1.5,
                                  physics: const FixedExtentScrollPhysics(
                                    parent: BouncingScrollPhysics(),
                                  ),
                                  onSelectedItemChanged: (index) {
                                    setDialogState(() {
                                      selectedHour = index;
                                    });
                                  },
                                  childDelegate: ListWheelChildBuilderDelegate(
                                    childCount: 24,
                                    builder: (context, index) {
                                      final isSelected = index == selectedHour;
                                      return Container(
                                        alignment: Alignment.center,
                                        child: Text(
                                          index.toString().padLeft(2, '0'),
                                          style: TextStyle(
                                            fontSize: isSelected ? 24 : 18,
                                            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                            color: isSelected ? const Color(0xFF4A90E2) : Colors.grey.shade600,
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              ),
                              Container(
                                width: 30,
                                alignment: Alignment.center,
                                child: Text(
                                  ':',
                                  style: TextStyle(
                                    fontSize: 24,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.grey.shade700,
                                  ),
                                ),
                              ),
                              SizedBox(
                                width: 80,
                                height: 150,
                                child: ListWheelScrollView.useDelegate(
                                  controller: minuteController,
                                  itemExtent: 40,
                                  perspective: 0.005,
                                  diameterRatio: 1.5,
                                  physics: const FixedExtentScrollPhysics(
                                    parent: BouncingScrollPhysics(),
                                  ),
                                  onSelectedItemChanged: (index) {
                                    setDialogState(() {
                                      selectedMinute = index;
                                    });
                                  },
                                  childDelegate: ListWheelChildBuilderDelegate(
                                    childCount: 60,
                                    builder: (context, index) {
                                      final isSelected = index == selectedMinute;
                                      return Container(
                                        alignment: Alignment.center,
                                        child: Text(
                                          index.toString().padLeft(2, '0'),
                                          style: TextStyle(
                                            fontSize: isSelected ? 24 : 18,
                                            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                            color: isSelected ? const Color(0xFF4A90E2) : Colors.grey.shade600,
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              ),
                            ],
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
                                    Navigator.pop(
                                      context,
                                      TimePickerResult(hour: selectedHour, minute: selectedMinute),
                                    );
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

  return result;
}

Future<LeadTimePickerResult?> show3DLeadTimePicker({
  required BuildContext context,
  required int initialDays,
  required int initialHours,
  required int initialMinutes,
  int maxDays = 30,
  String title = '选择提醒时间',
}) async {
  int selectedDays = initialDays;
  int selectedHours = initialHours;
  int selectedMinutes = initialMinutes;

  final FixedExtentScrollController dayController =
      FixedExtentScrollController(initialItem: initialDays);
  final FixedExtentScrollController hourController =
      FixedExtentScrollController(initialItem: initialHours);
  final FixedExtentScrollController minuteController =
      FixedExtentScrollController(initialItem: initialMinutes);

  final result = await showGeneralDialog<LeadTimePickerResult>(
    context: context,
    barrierDismissible: true,
    barrierLabel: title,
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
                    Widget buildWheel({
                      required FixedExtentScrollController controller,
                      required int count,
                      required int selected,
                      required ValueChanged<int> onChanged,
                    }) {
                      return SizedBox(
                        width: 72,
                        height: 150,
                        child: ListWheelScrollView.useDelegate(
                          controller: controller,
                          itemExtent: 40,
                          perspective: 0.005,
                          diameterRatio: 1.5,
                          physics: const FixedExtentScrollPhysics(
                            parent: BouncingScrollPhysics(),
                          ),
                          onSelectedItemChanged: onChanged,
                          childDelegate: ListWheelChildBuilderDelegate(
                            childCount: count,
                            builder: (context, index) {
                              final isSelected = index == selected;
                              return Container(
                                alignment: Alignment.center,
                                child: Text(
                                  index.toString().padLeft(2, '0'),
                                  style: TextStyle(
                                    fontSize: isSelected ? 24 : 18,
                                    fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                    color: isSelected ? const Color(0xFF4A90E2) : Colors.grey.shade600,
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      );
                    }

                    return Container(
                      width: 340,
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
                          Text(
                            title,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF1A1A2E),
                            ),
                          ),
                          const SizedBox(height: 20),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              buildWheel(
                                controller: dayController,
                                count: maxDays + 1,
                                selected: selectedDays,
                                onChanged: (index) {
                                  setDialogState(() {
                                    selectedDays = index;
                                  });
                                },
                              ),
                              SizedBox(
                                width: 28,
                                child: Text(
                                  '天',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.grey.shade700,
                                  ),
                                ),
                              ),
                              buildWheel(
                                controller: hourController,
                                count: 24,
                                selected: selectedHours,
                                onChanged: (index) {
                                  setDialogState(() {
                                    selectedHours = index;
                                  });
                                },
                              ),
                              SizedBox(
                                width: 28,
                                child: Text(
                                  '时',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.grey.shade700,
                                  ),
                                ),
                              ),
                              buildWheel(
                                controller: minuteController,
                                count: 60,
                                selected: selectedMinutes,
                                onChanged: (index) {
                                  setDialogState(() {
                                    selectedMinutes = index;
                                  });
                                },
                              ),
                              SizedBox(
                                width: 28,
                                child: Text(
                                  '分',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.grey.shade700,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 14),
                          Text(
                            '已选：${selectedDays}天${selectedHours}小时${selectedMinutes}分钟',
                            style: TextStyle(
                              fontSize: 13,
                              color: Colors.grey.shade600,
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
                                    Navigator.pop(
                                      context,
                                      LeadTimePickerResult(
                                        days: selectedDays,
                                        hours: selectedHours,
                                        minutes: selectedMinutes,
                                      ),
                                    );
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

  return result;
}
