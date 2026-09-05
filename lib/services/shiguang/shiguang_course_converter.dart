import '../../models/course.dart';
import '../../utils/course_color_palette.dart';

/// 适配脚本课程 JSON → Course 模型的转换结果。
class ShiguangConvertResult {
  final List<Course> courses;
  final int skippedCount;
  final List<String> errors;

  const ShiguangConvertResult({
    required this.courses,
    this.skippedCount = 0,
    this.errors = const [],
  });
}

/// 拾光适配脚本输出的课程 JSON 转换为 CrouseHub 的 Course 模型。
///
/// 适配脚本字段（以正方通用脚本为准）：
/// - name: 课程名
/// - day: 星期（1-7）
/// - weeks: 周次数组（[1,2,3,...]）
/// - teacher: 教师
/// - position: 上课地点
/// - startSection / endSection: 起止节次（1 基）
///
/// CrouseHub 语义：day 为 0-6，time 为 0 基节次（与 AI 图片导入的
/// `period - 1` 一致），weeks 为压缩字符串（如 "1-3,5-6,8"）。
class ShiguangCourseConverter {
  /// 解析适配脚本回传的 JSON（兼容裸数组与 {"courses": [...]} 两种形态）。
  static ShiguangConvertResult convert(dynamic parsed,
      {required String idPrefix}) {
    final List rawList;
    if (parsed is List) {
      rawList = parsed;
    } else if (parsed is Map && parsed['courses'] is List) {
      rawList = parsed['courses'] as List;
    } else {
      return const ShiguangConvertResult(
        courses: [],
        errors: ['数据格式不符：既不是数组也不含 courses 字段'],
      );
    }

    final courses = <Course>[];
    final errors = <String>[];
    int skipped = 0;
    final colorByName = <String, String>{};
    final timestamp = DateTime.now().millisecondsSinceEpoch;

    for (final item in rawList) {
      if (item is! Map) {
        skipped++;
        continue;
      }

      final name = item['name']?.toString().trim() ?? '';
      if (name.isEmpty) {
        skipped++;
        continue;
      }

      final dayRaw = _toInt(item['day']);
      // 适配脚本 day 为 1-7，Course.day 为 0-6。
      if (dayRaw == null || dayRaw < 1 || dayRaw > 7) {
        skipped++;
        errors.add('「$name」星期无效：$dayRaw');
        continue;
      }

      final startSection = _toInt(item['startSection']);
      final endSection = _toInt(item['endSection']);
      if (startSection == null || startSection < 1) {
        skipped++;
        errors.add('「$name」节次无效');
        continue;
      }
      final duration =
          (endSection != null && endSection >= startSection && endSection < 64)
              ? endSection - startSection + 1
              : 1;

      final weeks = _parseWeeks(item['weeks']);
      final teacher = item['teacher']?.toString().trim();
      final location = item['position']?.toString().trim();

      // 同课同名同色：按课程名首现顺序轮转分配调色板颜色。
      final color = colorByName.putIfAbsent(
        name,
        () => CourseColorPalette.extendedHexColors[
            colorByName.length % CourseColorPalette.extendedHexColors.length],
      );

      courses.add(Course(
        id: '${idPrefix}_${timestamp}_${courses.length}',
        name: name,
        teacher: (teacher == null || teacher.isEmpty) ? null : teacher,
        location: (location == null || location.isEmpty) ? null : location,
        day: dayRaw - 1,
        time: startSection - 1,
        duration: duration,
        weeks: weeks,
        color: color,
      ));
    }

    return ShiguangConvertResult(
      courses: courses,
      skippedCount: skipped,
      errors: errors,
    );
  }

  /// 周次数组压缩为字符串：[1,2,3,5,6,8] → "1-3,5-6,8"；空数组返回 null。
  static String? compressWeeks(List<int>? weeks) {
    if (weeks == null || weeks.isEmpty) return null;
    final sorted = weeks.where((w) => w > 0).toSet().toList()..sort();
    if (sorted.isEmpty) return null;

    final segments = <String>[];
    int segStart = sorted.first;
    int prev = sorted.first;
    for (final w in sorted.skip(1)) {
      if (w == prev + 1) {
        prev = w;
        continue;
      }
      segments.add(prev == segStart ? '$segStart' : '$segStart-$prev');
      segStart = w;
      prev = w;
    }
    segments.add(prev == segStart ? '$segStart' : '$segStart-$prev');
    return segments.join(',');
  }

  static String? _parseWeeks(dynamic raw) {
    if (raw is List) {
      final weeks = raw
          .map((w) => _toInt(w))
          .whereType<int>()
          .where((w) => w > 0 && w <= 60)
          .toList();
      return compressWeeks(weeks);
    }
    if (raw is String && raw.trim().isNotEmpty) {
      // 个别适配器可能直接回传字符串（如 "1-16"），原样透传。
      return raw.trim();
    }
    return null;
  }

  static int? _toInt(dynamic raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) {
      return int.tryParse(raw.trim().replaceAll(RegExp(r'[^0-9]'), ''));
    }
    return null;
  }
}
