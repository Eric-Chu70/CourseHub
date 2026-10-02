import 'package:flutter_test/flutter_test.dart';
import 'package:coursehub/utils/course_summary.dart';
import 'package:coursehub/models/course.dart';

Course _cell({
  required String name,
  required int day,
  required int time,
  int duration = 2,
  String? teacher,
  String? location,
  String? weeks,
}) {
  return Course(
    id: '$name-$day-$time',
    name: name,
    day: day,
    time: time,
    duration: duration,
    teacher: teacher,
    location: location,
    weeks: weeks,
  );
}

void main() {
  group('parseCourseWeeks', () {
    test('区间+单周混合', () {
      expect(parseCourseWeeks('1-8,10', 16), {1, 2, 3, 4, 5, 6, 7, 8, 10});
    });
    test('清理「周/连」与空格', () {
      expect(parseCourseWeeks('1-8周,连周9-16', 16).last, 16);
    });
    test('null/空/全周 = 整学期', () {
      expect(parseCourseWeeks(null, 16).length, 16);
      expect(parseCourseWeeks('', 16).length, 16);
      expect(parseCourseWeeks('全周', 16).length, 16);
      expect(parseCourseWeeks('乱七八糟', 16).length, 16);
    });
  });

  group('aggregateCoursesByName', () {
    test('用户实例：同名两节，周一 1-8 周先结束，周二 1-16 周继续 → 结课周取 16', () {
      final courses = [
        _cell(name: '中国近现代史纲要', day: 0, time: 0, teacher: '张三', location: 'A101', weeks: '1-8周'),
        _cell(name: '中国近现代史纲要', day: 1, time: 2, teacher: '张三', location: 'A101', weeks: '1-16周'),
      ];
      final summaries = aggregateCoursesByName(courses, 16);
      expect(summaries.length, 1);
      expect(summaries.first.endWeek, 16);
      expect(summaries.first.summaryLine(16), contains('第16周结课'));
      // 教师一致时不逐节标注
      expect(summaries.first.summaryLine(16), isNot(contains('张三(')));
    });

    test('教师不同：逐节标注 + 教师列表去重，不产生「结课」歧义', () {
      final courses = [
        _cell(name: '高等数学', day: 0, time: 0, teacher: '张三', location: 'B202', weeks: '1-16周'),
        _cell(name: '高等数学', day: 2, time: 0, teacher: '李四', location: 'B202', weeks: '1-16周'),
      ];
      final line = aggregateCoursesByName(courses, 16).first.summaryLine(16);
      expect(line, contains('周一1-2节(张三)'));
      expect(line, contains('周三1-2节(李四)'));
      expect(line, contains('教师：张三/李四'));
      expect(line, contains('第16周结课'));
    });

    test('缺口周次并集压缩回区间', () {
      final courses = [
        _cell(name: '体育', day: 4, time: 5, weeks: '1-8周'),
        _cell(name: '体育', day: 4, time: 6, weeks: '10-16周'),
      ];
      final line = aggregateCoursesByName(courses, 16).first.summaryLine(16);
      expect(line, contains('上课周：1-8,10-16周'));
      expect(line, contains('第16周结课'));
    });

    test('名字带首尾空格归并；无周次按全周', () {
      final courses = [
        _cell(name: '大学英语 ', day: 0, time: 0),
        _cell(name: '大学英语', day: 1, time: 0),
      ];
      final summaries = aggregateCoursesByName(courses, 16);
      expect(summaries.length, 1);
      expect(summaries.first.summaryLine(16), contains('全周'));
      expect(summaries.first.endWeek, 16);
    });
  });
}
