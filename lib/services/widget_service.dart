import 'dart:convert';
import 'package:coursehub/models/course.dart';
import 'package:coursehub/utils/storage.dart';
import 'package:home_widget/home_widget.dart';
import 'package:flutter/foundation.dart';

/// 安卓桌面小组件数据同步服务
///
/// 将 Flutter 侧的课程数据序列化为 JSON，通过 home_widget 推送到原生小组件。
/// 需要在课程数据变更、课表切换、应用启动时调用 [updateAllWidgets]。
class WidgetService {
  static const _androidPackage = 'com.coursehub.app.widget';

  /// 更新所有小组件（2x2 / 4x2 / 4x4今日）
  static Future<void> updateAllWidgets() async {
    try {
      final todayData = _buildTodayData();
      final weekData = _buildWeekData();

      await HomeWidget.saveWidgetData<String>(
        'widget_today_data',
        jsonEncode(todayData),
      );
      await HomeWidget.saveWidgetData<String>(
        'widget_week_data',
        jsonEncode(weekData),
      );

      // 通过 home_widget 官方 API 触发 widget 更新
      // 使用 qualifiedAndroidName 传完整类名，避免 packageName 前缀拼接错误
      // 它会发送 APPWIDGET_UPDATE 广播给各 receiver，
      // receiver 用自己持有的 glanceAppWidget 实例处理更新
      for (final receiver in [
        '$_androidPackage.TodaySmallWidgetReceiver',
        '$_androidPackage.TodayMediumWidgetReceiver',
        '$_androidPackage.TodayLargeWidgetReceiver',
      ]) {
        await HomeWidget.updateWidget(qualifiedAndroidName: receiver);
      }
    } catch (e) {
      debugPrint('WidgetService updateAllWidgets error: $e');
    }
  }

  // =================== 今日课程数据 ===================

  static Map<String, dynamic> _buildTodayData() {
    final courses = StorageService.getCourses();
    final currentWeek = StorageService.getCurrentWeek();
    final semesterWeeks = StorageService.getSemesterWeeks();
    final timeSlots = StorageService.getTimeSlots();
    final isHoliday = currentWeek > semesterWeeks;

    final now = DateTime.now();
    final dayIndex = now.weekday - 1; // 0=周一 ... 6=周日
    final weekDays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    final label = '${weekDays[dayIndex]} · 第$currentWeek周';

    // 过滤今日课程
    final todayCourses = courses.where((c) {
      if (c.day != dayIndex) return false;
      if (c.weeks != null && c.weeks!.isNotEmpty) {
        return _isCourseInWeek(c.weeks!, currentWeek);
      }
      return true;
    }).toList()
      ..sort((a, b) => a.time.compareTo(b.time));

    // 序列化全部今日课程（原生侧根据当前时间自行过滤，实现自动递推）
    final coursesJson = todayCourses
        .map((c) => _courseToJson(c, timeSlots, includeDay: false))
        .toList();

    // 下一节课 / 当前课程（初始值，原生侧会根据实时时间重新计算）
    Map<String, dynamic>? nextCourse;
    Map<String, dynamic>? followingCourse;
    if (!isHoliday && todayCourses.isNotEmpty) {
      final result = _findNextAndFollowing(todayCourses, timeSlots);
      nextCourse = result.$1;
      followingCourse = result.$2;
    }

    // 是否今日所有课程已上完（初始值，原生侧会根据实时时间重新计算）
    final nowMinutes = now.hour * 60 + now.minute;
    final hasFinished = !isHoliday && todayCourses.isNotEmpty &&
        todayCourses.every((c) {
          if (c.time < 0 || c.time >= timeSlots.length) return false;
          final endIdx = c.time + c.duration - 1;
          if (endIdx < 0 || endIdx >= timeSlots.length) return false;
          final endStr = timeSlots[endIdx]['end'] ?? '';
          if (endStr.isEmpty || endStr == '00:00') return false;
          return nowMinutes > _timeToMinutes(endStr);
        });

    // 明日课程（今日已上完时用于 4x4）
    List<Map<String, dynamic>> tomorrowCoursesJson = [];
    String tomorrowLabel = '';
    if (hasFinished) {
      final tomorrow = now.add(const Duration(days: 1));
      final tomorrowDayIndex = tomorrow.weekday - 1;
      final tomorrowWeekDays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
      tomorrowLabel = '${tomorrowWeekDays[tomorrowDayIndex]} · 第$currentWeek周';
      final tomorrowCourses = courses.where((c) {
        if (c.day != tomorrowDayIndex) return false;
        if (c.weeks != null && c.weeks!.isNotEmpty) {
          return _isCourseInWeek(c.weeks!, currentWeek);
        }
        return true;
      }).toList()
        ..sort((a, b) => a.time.compareTo(b.time));
      tomorrowCoursesJson = tomorrowCourses
          .map((c) => _courseToJson(c, timeSlots, includeDay: false))
          .toList();
    }

    return {
      'label': label,
      'isHoliday': isHoliday,
      'courses': coursesJson,
      'nextCourse': nextCourse,
      'followingCourse': followingCourse,
      'hasFinished': hasFinished,
      'tomorrowLabel': tomorrowLabel,
      'tomorrowCourses': tomorrowCoursesJson,
    };
  }

  /// 找到下一节课/当前课程，以及之后的课程
  static (Map<String, dynamic>?, Map<String, dynamic>?) _findNextAndFollowing(
    List<Course> courses,
    List<Map<String, String>> timeSlots,
  ) {
    final now = DateTime.now();
    final nowMinutes = now.hour * 60 + now.minute;

    Map<String, dynamic>? next;
    Map<String, dynamic>? following;
    bool foundNext = false;

    for (final course in courses) {
      if (course.time < 0) continue;
      // time 超出 timeSlots 范围时，视为未设置时间，作为候选
      if (course.time >= timeSlots.length) {
        if (!foundNext) {
          next = _courseToJson(course, timeSlots,
              includeDay: false, isCurrent: false);
          foundNext = true;
        } else {
          following = _courseToJson(course, timeSlots, includeDay: false);
          break;
        }
        continue;
      }
      final startStr = timeSlots[course.time]['start'] ?? '';
      final endIdx = course.time + course.duration - 1;
      if (endIdx < 0) continue;
      if (endIdx >= timeSlots.length) {
        // endIdx 超出范围，视为未设置时间
        if (!foundNext) {
          final isCurrent = startStr.isEmpty || startStr == '00:00' ||
              nowMinutes >= _timeToMinutes(startStr);
          next = _courseToJson(course, timeSlots,
              includeDay: false, isCurrent: isCurrent);
          foundNext = true;
        } else {
          following = _courseToJson(course, timeSlots, includeDay: false);
          break;
        }
        continue;
      }
      final endStr = timeSlots[endIdx]['end'] ?? '';
      // 时间段为 00:00 或空时，视为未设置，直接作为候选
      if (endStr.isEmpty || endStr == '00:00') {
        if (!foundNext) {
          final isCurrent = startStr.isEmpty || startStr == '00:00' ||
              nowMinutes >= _timeToMinutes(startStr);
          next = _courseToJson(course, timeSlots,
              includeDay: false, isCurrent: isCurrent);
          foundNext = true;
        } else {
          following = _courseToJson(course, timeSlots, includeDay: false);
          break;
        }
        continue;
      }

      final startMin = _timeToMinutes(startStr);
      final endMin = _timeToMinutes(endStr);

      if (nowMinutes <= endMin) {
        if (!foundNext) {
          final isCurrent = nowMinutes >= startMin;
          next = _courseToJson(course, timeSlots,
              includeDay: false, isCurrent: isCurrent);
          foundNext = true;
        } else {
          following = _courseToJson(course, timeSlots, includeDay: false);
          break;
        }
      }
    }
    return (next, following);
  }

  // =================== 本周课表数据 ===================

  static Map<String, dynamic> _buildWeekData() {
    final courses = StorageService.getCourses();
    final currentWeek = StorageService.getCurrentWeek();
    final semesterWeeks = StorageService.getSemesterWeeks();
    final dailyPeriods = StorageService.getDailyPeriods();
    final timeSlots = StorageService.getTimeSlots();
    final isHoliday = currentWeek > semesterWeeks;

    final label = '第$currentWeek周';

    // 过滤本周课程
    final weekCourses = courses.where((c) {
      if (c.weeks != null && c.weeks!.isNotEmpty) {
        return _isCourseInWeek(c.weeks!, currentWeek);
      }
      return true;
    }).toList();

    final coursesJson = weekCourses
        .map((c) => _courseToJson(c, timeSlots, includeDay: true))
        .toList();

    // 序列化时间表
    final timeSlotsJson = timeSlots.map((slot) => {
      'start': slot['start'] ?? '',
      'end': slot['end'] ?? '',
    }).toList();

    return {
      'label': label,
      'isHoliday': isHoliday,
      'dailyPeriods': dailyPeriods,
      'currentWeek': currentWeek,
      'semesterWeeks': semesterWeeks,
      'courses': coursesJson,
      'timeSlots': timeSlotsJson,
    };
  }

  // =================== 工具方法 ===================

  /// 将 Course 序列化为小组件 JSON
  static Map<String, dynamic> _courseToJson(
    Course course,
    List<Map<String, String>>? timeSlots, {
    bool includeDay = false,
    bool isCurrent = false,
  }) {
    String startTime = '';
    String endTime = '';
    final periodStart = course.time + 1; // 1-based
    final periodEnd = course.time + course.duration; // 1-based

    if (timeSlots != null &&
        course.time >= 0 &&
        course.time < timeSlots.length) {
      startTime = timeSlots[course.time]['start'] ?? '';
      final endIdx = course.time + course.duration - 1;
      if (endIdx >= 0 && endIdx < timeSlots.length) {
        endTime = timeSlots[endIdx]['end'] ?? '';
      }
    }

    final json = <String, dynamic>{
      'name': course.name,
      'teacher': course.teacher ?? '',
      'location': course.location ?? '',
      'color': course.color,
      'startTime': startTime,
      'endTime': endTime,
      'periodStart': periodStart,
      'periodEnd': periodEnd,
      'isCurrent': isCurrent,
    };
    if (includeDay) {
      json['day'] = course.day;
    }
    return json;
  }

  /// "HH:mm" 转为分钟数
  static int _timeToMinutes(String time) {
    final parts = time.split(':');
    if (parts.length == 2) {
      final h = int.tryParse(parts[0]) ?? 0;
      final m = int.tryParse(parts[1]) ?? 0;
      return h * 60 + m;
    }
    return 0;
  }

  /// 判断课程是否在指定周次
  /// 支持 "1-16"、"1,3,5,7"、"1-16连" 等格式
  static bool _isCourseInWeek(String weeks, int currentWeek) {
    final cleaned = weeks.replaceAll('连', '').replaceAll('周', '').replaceAll(' ', '');
    final parts = cleaned.split(',');
    for (var part in parts) {
      part = part.trim();
      if (part.contains('-')) {
        final range = part.split('-');
        if (range.length == 2) {
          final start = int.tryParse(range[0].trim());
          final end = int.tryParse(range[1].trim());
          if (start != null && end != null &&
              currentWeek >= start && currentWeek <= end) {
            return true;
          }
        }
      } else {
        final week = int.tryParse(part);
        if (week != null && week == currentWeek) return true;
      }
    }
    return false;
  }
}
