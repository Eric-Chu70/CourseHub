import '../models/course.dart';

/// AI 上下文用的课程聚合视图。
///
/// 背景：课表数据按「节次单元格」存储（同一门课在周一/周二各是一条
/// Course 记录，周次、教师、地点可以不同）。直接把单元格逐行喂给模型，
/// 会被解读成「孤立课程」：某节周次更短 → 误报整门课即将结课；某节
/// 换了老师 → 误报换课/结课。这里按课程名聚合后再输出，结课周取全部
/// 节次周次并集的最大值，模型只需引用、无需自行推算。

const List<String> _kDayNames = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

String _dayName(int day) =>
    (day >= 0 && day <= 6) ? _kDayNames[day] : _kDayNames[0];

/// 解析周次串（兼容 "1-8"、"1-8,10-16"、"1-8周"、"1-8(连周)" 等写法）。
/// null / 空 / "全周" / 解析后为空 → 返回整学期 1..semesterWeeks。
Set<int> parseCourseWeeks(String? weeks, int semesterWeeks) {
  final result = <int>{};
  final cleaned = (weeks ?? '').replaceAll('连', '').replaceAll('周', '').replaceAll(' ', '');
  if (cleaned.isEmpty || cleaned == '全' || cleaned == '整学期') {
    return {for (var i = 1; i <= semesterWeeks; i++) i};
  }
  for (var part in cleaned.split(',')) {
    part = part.trim();
    if (part.isEmpty) continue;
    if (part.contains('-')) {
      final range = part.split('-');
      if (range.length == 2) {
        final start = int.tryParse(range[0].trim());
        final end = int.tryParse(range[1].trim());
        if (start != null && end != null && start <= end) {
          for (var i = start; i <= end; i++) {
            result.add(i);
          }
          continue;
        }
      }
    } else {
      final single = int.tryParse(part);
      if (single != null) result.add(single);
    }
  }
  if (result.isEmpty) {
    return {for (var i = 1; i <= semesterWeeks; i++) i};
  }
  return result;
}

/// 周次集合压缩为紧凑文本："1-16" → "1-16周"，"1-8,10-16"；
/// 覆盖 1..semesterWeeks 全部周时输出 "全周"
String formatWeekRanges(Set<int> weeks, int semesterWeeks) {
  if (weeks.length >= semesterWeeks) return '全周';
  final sorted = weeks.toList()..sort();
  final parts = <String>[];
  var start = sorted.first;
  var prev = start;
  for (final w in sorted.skip(1)) {
    if (w == prev + 1) {
      prev = w;
      continue;
    }
    parts.add(start == prev ? '$start' : '$start-$prev');
    start = w;
    prev = w;
  }
  parts.add(start == prev ? '$start' : '$start-$prev');
  return '${parts.join(',')}周';
}

/// 按课程名聚合后的摘要
class CourseSummary {
  final String name;
  final List<Course> cells; // 同一课程名的全部节次，按 星期+节次 排序
  final Set<int> weeks; // 各节周次的并集
  final int endWeek; // 聚合结课周 = 并集最大值

  CourseSummary({
    required this.name,
    required this.cells,
    required this.weeks,
    required this.endWeek,
  });

  factory CourseSummary.of(List<Course> sameNameCells, int semesterWeeks) {
    final cells = [...sameNameCells]..sort((a, b) {
        final byDay = a.day.compareTo(b.day);
        return byDay != 0 ? byDay : a.time.compareTo(b.time);
      });
    final weeks = <int>{};
    for (final c in cells) {
      weeks.addAll(parseCourseWeeks(c.weeks, semesterWeeks));
    }
    return CourseSummary(
      name: (cells.first.name).trim(),
      cells: cells,
      weeks: weeks,
      endWeek: weeks.reduce((a, b) => a > b ? a : b),
    );
  }

  bool _teacherVaries(List<String> teachers) =>
      teachers.map((t) => t.trim()).toSet().length > 1;

  /// 节次文本。教师/地点存在差异时按节次内联标注：
  /// "周一1-2节(张三)、周二3-4节(李四)"
  String get cellsText {
    final teachers = cells.map((c) => (c.teacher ?? '').trim()).toList();
    final locations = cells.map((c) => (c.location ?? '').trim()).toList();
    return cells.asMap().entries.map((entry) {
      final c = entry.value;
      final start = c.time + 1;
      final end = start + c.duration - 1;
      var text = '${_dayName(c.day)}$start-$end节';
      if (_teacherVaries(teachers)) {
        final t = (c.teacher ?? '').trim();
        if (t.isNotEmpty) text += '($t)';
      }
      if (_teacherVaries(locations)) {
        final l = (c.location ?? '').trim();
        if (l.isNotEmpty) text += '@$l';
      }
      return text;
    }).join('、');
  }

  /// 去重后的教师列表："张三" 或 "张三/李四"
  String get teacherText {
    final set = cells
        .map((c) => (c.teacher ?? '').trim())
        .where((t) => t.isNotEmpty)
        .toSet();
    return set.isEmpty ? '未知' : set.join('/');
  }

  /// 去重后的地点列表："A101" 或 "A101/B202"
  String get locationText {
    final set = cells
        .map((c) => (c.location ?? '').trim())
        .where((l) => l.isNotEmpty)
        .toSet();
    return set.isEmpty ? '未知' : set.join('/');
  }

  /// 周次并集文本："1-16周" / "1-8,10-16周" / "全周"
  String weekText(int semesterWeeks) => formatWeekRanges(weeks, semesterWeeks);

  /// 喂给 AI 的单行文本（每门课一行，结课周为聚合结论）
  String summaryLine(int semesterWeeks) =>
      '• $name｜$cellsText｜教师：$teacherText｜地点：$locationText'
      '｜上课周：${weekText(semesterWeeks)}｜第$endWeek周结课';
}

/// 按课程名聚合（去除首尾空白后同名归并），保持首次出现顺序
List<CourseSummary> aggregateCoursesByName(List<Course> courses, int semesterWeeks) {
  final byName = <String, List<Course>>{};
  for (final c in courses) {
    byName.putIfAbsent(c.name.trim(), () => []).add(c);
  }
  return byName.values.map((cells) => CourseSummary.of(cells, semesterWeeks)).toList();
}

/// 直接生成喂给 AI 的多行文本（无课程时返回 "暂无课程"）
String buildCourseSummaryLines(List<Course> courses, int semesterWeeks) {
  final summaries = aggregateCoursesByName(courses, semesterWeeks);
  if (summaries.isEmpty) return '暂无课程';
  return summaries.map((s) => s.summaryLine(semesterWeeks)).join('\n');
}

/// 提示词中的课程解读规则：防模型把单节周次/教师差异误读为结课或换课。
/// 是否主动提醒结课由模型结合语境自行决定，这里不做强制。
const String kCourseInterpretationRules = '''
⚠️ 课程解读规则：
- 同名课程是同一门课的不同节次：各节的教师、地点、周次可以不同，这不代表换课、停课或结课；
- 每门课的「第X周结课」已按其全部节次的周次并集计算完成，判断结课只看该字段，不要用任何单个节次的周次推算；
- 「即将结课」最多提前一周告知：仅当结课周与当前周相同或只差 1 周时才可提及，更早一律不提；
- 是否主动向用户提及课程临近结课，由你结合语境自行决定。''';
