import 'package:flutter/material.dart';

import '../models/course.dart';
import '../utils/storage.dart';
import 'glass_dialog.dart';

/// 教务系统导入 - 课程预览与导入模式选择弹窗。
///
/// 展示适配脚本解析出的课程列表，选择合并/替换模式后返回；
/// 返回 null 表示用户取消导入。
class ShiguangImportPreviewDialog {
  ShiguangImportPreviewDialog._();

  static Future<ImportMode?> show(
    BuildContext context, {
    required List<Course> courses,
    required int skippedCount,
    required String schoolName,
  }) {
    return showBouncyDialog<ImportMode>(
      context: context,
      barrierLabel: '预览导入课程',
      shellPadding: const EdgeInsets.all(24),
      shellBoxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.2),
          blurRadius: 20,
          offset: const Offset(0, 10),
        ),
      ],
      shellConstraintsBuilder: (context) {
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
        return BoxConstraints(
            maxWidth: 420, maxHeight: dialogMaxHeight.clamp(320.0, baseMaxHeight));
      },
      builder: (context) => _PreviewBody(
        courses: courses,
        skippedCount: skippedCount,
        schoolName: schoolName,
      ),
    );
  }
}

class _PreviewBody extends StatefulWidget {
  final List<Course> courses;
  final int skippedCount;
  final String schoolName;

  const _PreviewBody({
    required this.courses,
    required this.skippedCount,
    required this.schoolName,
  });

  @override
  State<_PreviewBody> createState() => _PreviewBodyState();
}

class _PreviewBodyState extends State<_PreviewBody> {
  ImportMode selectedMode = ImportMode.merge;

  static const List<String> _dayNames = [
    '周一',
    '周二',
    '周三',
    '周四',
    '周五',
    '周六',
    '周日',
  ];

  @override
  Widget build(BuildContext context) {
    final courseCount = widget.courses.length;

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
                colors: [Color(0xFF9B59B6), Color(0xFFAF7AC5)],
              ),
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Icon(
              Icons.school,
              size: 32,
              color: Colors.white,
            ),
          ),
        ),
        const SizedBox(height: 16),
        const Text(
          '确认导入课程',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Text(
          '从 ${widget.schoolName} 解析到 $courseCount 门课程'
          '${widget.skippedCount > 0 ? '，跳过 ${widget.skippedCount} 条无效数据' : ''}',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
        ),
        const SizedBox(height: 16),
        Flexible(child: _buildCourseList()),
        const SizedBox(height: 16),
        _buildModeOption(
          title: '合并导入',
          subtitle: '保留现有课程，添加新课程',
          icon: Icons.merge_type,
          color: Colors.green,
          isSelected: selectedMode == ImportMode.merge,
          onTap: () => setState(() => selectedMode = ImportMode.merge),
        ),
        const SizedBox(height: 12),
        _buildModeOption(
          title: '替换导入',
          subtitle: '清空当前课表后导入',
          icon: Icons.refresh,
          color: Colors.orange,
          isSelected: selectedMode == ImportMode.replace,
          onTap: () => setState(() => selectedMode = ImportMode.replace),
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
                onPressed: () => Navigator.pop(context, selectedMode),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF9B59B6),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text('开始导入'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildCourseList() {
    return Container(
      constraints: const BoxConstraints(maxHeight: 260),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: ListView.builder(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: widget.courses.length,
        itemBuilder: (context, index) {
          final course = widget.courses[index];
          return _buildCourseTile(course);
        },
      ),
    );
  }

  Widget _buildCourseTile(Course course) {
    final dayText = course.day >= 0 && course.day < 7
        ? _dayNames[course.day]
        : '未知';
    final sectionText = course.duration > 1
        ? '${course.time + 1}-${course.time + course.duration}节'
        : '第${course.time + 1}节';
    final weeksText =
        course.weeks != null && course.weeks!.isNotEmpty ? '${course.weeks}周' : '';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: _parseColor(course.color),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  course.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  [
                    '$dayText $sectionText',
                    if (weeksText.isNotEmpty) weeksText,
                    if (course.teacher?.isNotEmpty == true) course.teacher!,
                    if (course.location?.isNotEmpty == true) course.location!,
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Color _parseColor(String hex) {
    try {
      final normalized = hex.startsWith('#') ? hex.substring(1) : hex;
      return Color(int.parse('FF$normalized', radix: 16));
    } catch (_) {
      return const Color(0xFF4A90E2);
    }
  }

  Widget _buildModeOption({
    required String title,
    required String subtitle,
    required IconData icon,
    required Color color,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: isSelected
              ? color.withValues(alpha: 0.1)
              : Colors.white.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? color : Colors.grey.shade200,
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.15),
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
                      color: isSelected ? color : Colors.black87,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey.shade600,
                    ),
                  ),
                ],
              ),
            ),
            if (isSelected) Icon(Icons.check_circle, color: color, size: 22),
          ],
        ),
      ),
    );
  }
}
