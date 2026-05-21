import 'dart:convert';
import 'glm_service.dart';

class RegexParserService {
  static final RegexParserService _instance = RegexParserService._internal();
  factory RegexParserService() => _instance;
  RegexParserService._internal();

  static RegexParserService get instance => _instance;

  List<CourseData> parseScheduleText(String text) {
    final courses = <CourseData>[];
    final lines = text.split('\n');

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;

      final course = _parseLine(line, lines, i);
      if (course != null) {
        courses.add(course);
      }
    }

    return _mergeCourses(courses);
  }

  CourseData? _parseLine(String line, List<String> allLines, int currentIndex) {
    final dayPatterns = [
      RegExp(r'周[一二三四五六日天]'),
      RegExp(r'[一二三四五六日天]'),
      RegExp(r'Mon|Tue|Wed|Thu|Fri|Sat|Sun', caseSensitive: false),
    ];

    int? dayOfWeek;
    for (final pattern in dayPatterns) {
      final match = pattern.firstMatch(line);
      if (match != null) {
        dayOfWeek = _parseDayOfWeek(match.group(0)!);
        break;
      }
    }

    if (dayOfWeek == null) return null;

    final timePattern = RegExp(r'(\d{1,2})[:：](\d{2})\s*[-~至]\s*(\d{1,2})[:：](\d{2})');
    final timeMatch = timePattern.firstMatch(line);
    
    String? startTime;
    String? endTime;
    
    if (timeMatch != null) {
      startTime = '${timeMatch.group(1)}:${timeMatch.group(2)}';
      endTime = '${timeMatch.group(3)}:${timeMatch.group(4)}';
    }

    final sectionPattern = RegExp(r'第?\s*(\d+)\s*节');
    final sectionMatch = sectionPattern.firstMatch(line);
    
    if (sectionMatch != null && (startTime == null || endTime == null)) {
      final sectionStr = sectionMatch.group(1);
      if (sectionStr != null) {
        final section = int.tryParse(sectionStr);
        if (section != null) {
          final timeRange = _getSectionTime(section);
          startTime = timeRange['start'];
          endTime = timeRange['end'];
        }
      }
    }

    if (startTime == null || endTime == null) return null;

    String? courseName;
    String? teacher;
    String? location;

    final namePatterns = [
      RegExp(r'[\u4e00-\u9fa5]{2,}(?:课|课程|基础|原理|导论|概论|方法|技术|系统|设计|实验|实践)'),
      RegExp(r'[\u4e00-\u9fa5]{4,}(?=\s|$)'),
    ];

    for (final pattern in namePatterns) {
      final match = pattern.firstMatch(line);
      if (match != null) {
        courseName = match.group(0);
        break;
      }
    }

    if (courseName == null) {
      final words = line.replaceAll(RegExp(r'[一二三四五六日天周]'), '')
          .replaceAll(RegExp(r'\d{1,2}[:：]\d{2}'), '')
          .replaceAll(RegExp(r'[-~至]'), '')
          .trim();
      
      final wordList = words.split(RegExp(r'\s+'));
      for (final word in wordList) {
        if (word.length >= 2 && RegExp(r'[\u4e00-\u9fa5]').hasMatch(word)) {
          courseName = word;
          break;
        }
      }
    }

    if (courseName == null) return null;

    final locationPattern = RegExp(r'(?:教室|地点|教室[：:]\s*)([\u4e00-\u9fa5A-Za-z0-9]+)');
    final locationMatch = locationPattern.firstMatch(line);
    if (locationMatch != null) {
      location = locationMatch.group(1);
    } else {
      final roomPattern = RegExp(r'[A-Za-z]?\d{3,}[A-Za-z0-9]*');
      final roomMatch = roomPattern.firstMatch(line);
      if (roomMatch != null) {
        location = roomMatch.group(0);
      }
    }

    final teacherPattern = RegExp(r'(?:教师|老师|授课教师[：:]\s*)([\u4e00-\u9fa5]{2,3})');
    final teacherMatch = teacherPattern.firstMatch(line);
    if (teacherMatch != null) {
      teacher = teacherMatch.group(1);
    } else {
      final namePattern = RegExp(r'[\u4e00-\u9fa5]{2,3}(?=\s|$)');
      final names = namePattern.allMatches(line).toList();
      if (names.isNotEmpty && courseName != null) {
        for (final name in names) {
          final matchedName = name.group(0);
          if (matchedName != null && !courseName.contains(matchedName) && matchedName.length <= 3) {
            teacher = matchedName;
            break;
          }
        }
      }
    }

    final weekPattern = RegExp(r'(\d+)\s*[-~至]\s*(\d+)\s*周');
    final weekMatch = weekPattern.firstMatch(line);
    
    int? startWeek;
    int? endWeek;
    
    if (weekMatch != null) {
      startWeek = int.tryParse(weekMatch.group(1) ?? '');
      endWeek = int.tryParse(weekMatch.group(2) ?? '');
    }

    return CourseData(
      name: courseName,
      teacher: teacher,
      location: location,
      dayOfWeek: dayOfWeek,
      startTime: startTime,
      endTime: endTime,
      startWeek: startWeek,
      endWeek: endWeek,
    );
  }

  int _parseDayOfWeek(String dayStr) {
    final dayMap = {
      '周一': 1, '星期一': 1, '一': 1, 'Mon': 1,
      '周二': 2, '星期二': 2, '二': 2, 'Tue': 2,
      '周三': 3, '星期三': 3, '三': 3, 'Wed': 3,
      '周四': 4, '星期四': 4, '四': 4, 'Thu': 4,
      '周五': 5, '星期五': 5, '五': 5, 'Fri': 5,
      '周六': 6, '星期六': 6, '六': 6, 'Sat': 6,
      '周日': 7, '星期日': 7, '星期天': 7, '日': 7, '天': 7, 'Sun': 7,
    };

    for (final entry in dayMap.entries) {
      if (dayStr.contains(entry.key)) {
        return entry.value;
      }
    }
    return 1;
  }

  Map<String, String> _getSectionTime(int section) {
    final sections = {
      1: {'start': '08:00', 'end': '09:40'},
      2: {'start': '08:55', 'end': '09:40'},
      3: {'start': '10:00', 'end': '11:40'},
      4: {'start': '10:55', 'end': '11:40'},
      5: {'start': '14:00', 'end': '15:40'},
      6: {'start': '14:55', 'end': '15:40'},
      7: {'start': '16:00', 'end': '17:40'},
      8: {'start': '16:55', 'end': '17:40'},
      9: {'start': '19:00', 'end': '20:40'},
      10: {'start': '19:55', 'end': '20:40'},
    };
    return sections[section] ?? {'start': '08:00', 'end': '09:40'};
  }

  List<CourseData> _mergeCourses(List<CourseData> courses) {
    final merged = <CourseData>[];
    final seen = <String>{};

    for (final course in courses) {
      final weeksKey = (course.weeks ?? '').trim().isNotEmpty
          ? course.weeks!.trim()
          : '${course.startWeek ?? ''}-${course.endWeek ?? ''}';
      final key = '${course.name}_${course.dayOfWeek}_${course.startTime}_${course.endTime}_${course.location ?? ''}_${course.teacher ?? ''}_$weeksKey';
      if (!seen.contains(key)) {
        seen.add(key);
        merged.add(course);
      }
    }

    return merged;
  }
}
