import 'package:hive/hive.dart';

part 'task.g.dart';

@HiveType(typeId: 1)
class Task extends HiveObject {
  @HiveField(0)
  String id;

  @HiveField(1)
  String courseId;

  @HiveField(2)
  String name;

  @HiveField(3)
  String type;

  @HiveField(4)
  DateTime dueDate;

  @HiveField(5)
  String priority;

  @HiveField(6)
  String? note;

  @HiveField(7)
  bool completed;

  Task({
    required this.id,
    required this.courseId,
    required this.name,
    this.type = '作业',
    required this.dueDate,
    this.priority = '中',
    this.note,
    this.completed = false,
  });
}
