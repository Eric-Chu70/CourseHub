import 'package:flutter_test/flutter_test.dart';

import 'package:coursehub/services/shiguang/shiguang_course_converter.dart';

void main() {
  group('compressWeeks', () {
    test('连续周次折叠为区间', () {
      expect(ShiguangCourseConverter.compressWeeks([1, 2, 3, 4, 5]),
          '1-5');
    });

    test('不连续周次用逗号分隔', () {
      expect(ShiguangCourseConverter.compressWeeks([1, 2, 3, 5, 6, 8]),
          '1-3,5-6,8');
    });

    test('单个周次', () {
      expect(ShiguangCourseConverter.compressWeeks([3]), '3');
    });

    test('乱序输入自动排序去重', () {
      expect(ShiguangCourseConverter.compressWeeks([5, 1, 3, 2, 1]), '1-3,5');
    });

    test('空数组返回 null', () {
      expect(ShiguangCourseConverter.compressWeeks([]), isNull);
      expect(ShiguangCourseConverter.compressWeeks(null), isNull);
    });

    test('过滤非正数', () {
      expect(ShiguangCourseConverter.compressWeeks([0, 1, 2, -3]), '1-2');
    });
  });

  group('convert', () {
    test('标准字段映射', () {
      final result = ShiguangCourseConverter.convert([
        {
          'name': '高等数学',
          'day': 1,
          'weeks': [1, 2, 3, 4, 5, 6, 7, 8],
          'teacher': '张三',
          'position': '教1-101',
          'startSection': 3,
          'endSection': 4,
        }
      ], idPrefix: 'sg_test');

      expect(result.courses, hasLength(1));
      final c = result.courses.first;
      expect(c.name, '高等数学');
      expect(c.teacher, '张三');
      expect(c.location, '教1-101');
      expect(c.day, 0); // 1-7 → 0-6
      expect(c.time, 2); // startSection 3 → 0 基节次 2
      expect(c.duration, 2); // endSection 4 - startSection 3 + 1
      expect(c.weeks, '1-8');
      expect(result.skippedCount, 0);
    });

    test('兼容 {"courses": [...]} 包装形态', () {
      final result = ShiguangCourseConverter.convert({
        'courses': [
          {'name': '大学英语', 'day': 5, 'startSection': 1, 'endSection': 2}
        ]
      }, idPrefix: 'sg_test');

      expect(result.courses, hasLength(1));
      expect(result.courses.first.name, '大学英语');
      expect(result.courses.first.day, 4);
    });

    test('同课同名同色', () {
      final result = ShiguangCourseConverter.convert([
        {'name': '体育', 'day': 1, 'startSection': 1, 'endSection': 2},
        {'name': '体育', 'day': 3, 'startSection': 1, 'endSection': 2},
        {'name': '线性代数', 'day': 2, 'startSection': 1, 'endSection': 2},
      ], idPrefix: 'sg_test');

      expect(result.courses[0].color, result.courses[1].color);
      expect(result.courses[0].color, isNot(result.courses[2].color));
    });

    test('无效数据跳过并计数', () {
      final result = ShiguangCourseConverter.convert([
        {'name': '', 'day': 1, 'startSection': 1, 'endSection': 2}, // 无名
        {'name': '坏数据', 'day': 8, 'startSection': 1, 'endSection': 2}, // day 越界
        {'name': '坏数据2', 'day': 0, 'startSection': 1, 'endSection': 2}, // day 越界
        'not-a-map', // 非 Map
        {'name': '好课', 'day': 2, 'startSection': 1, 'endSection': 2}, // 有效
      ], idPrefix: 'sg_test');

      expect(result.courses, hasLength(1));
      expect(result.skippedCount, 4);
      expect(result.courses.first.name, '好课');
    });

    test('空节次容错：缺 endSection 时 duration 为 1', () {
      final result = ShiguangCourseConverter.convert([
        {'name': '选修', 'day': 4, 'startSection': 6}
      ], idPrefix: 'sg_test');

      expect(result.courses.first.duration, 1);
      expect(result.courses.first.time, 5);
    });

    test('字段为字符串数字时兼容', () {
      final result = ShiguangCourseConverter.convert([
        {
          'name': '计算机组成原理',
          'day': '3',
          'startSection': '5',
          'endSection': '8',
          'weeks': [1, 2, 3],
        }
      ], idPrefix: 'sg_test');

      expect(result.courses, hasLength(1));
      expect(result.courses.first.day, 2);
      expect(result.courses.first.time, 4);
      expect(result.courses.first.duration, 4);
    });

    test('weeks 为空数组时为 null', () {
      final result = ShiguangCourseConverter.convert([
        {'name': '实验课', 'day': 5, 'startSection': 1, 'endSection': 4, 'weeks': []}
      ], idPrefix: 'sg_test');

      expect(result.courses.first.weeks, isNull);
    });

    test('非数组非 Map 输入返回错误', () {
      final result = ShiguangCourseConverter.convert('bad input',
          idPrefix: 'sg_test');
      expect(result.courses, isEmpty);
      expect(result.errors, isNotEmpty);
    });
  });
}
