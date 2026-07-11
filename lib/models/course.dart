import 'package:hive/hive.dart';

part 'course.g.dart';

@HiveType(typeId: 0)
class Course extends HiveObject {
  @HiveField(0)
  String id;

  @HiveField(1)
  String name;

  @HiveField(2)
  String? teacher;

  @HiveField(3)
  String? location;

  @HiveField(4)
  int day; // 0-6 (周一到周日)

  @HiveField(5)
  int time; // 第几节课

  @HiveField(6)
  int duration; // 持续几节课

  @HiveField(7)
  String? weeks; // 上课周次

  @HiveField(8)
  String color; // 课程颜色

  Course({
    required this.id,
    required this.name,
    this.teacher,
    this.location,
    required this.day,
    required this.time,
    this.duration = 1,
    this.weeks,
    this.color = '#4A90E2',
  });
}
