import 'package:hive/hive.dart';
import 'package:flutter/foundation.dart';
import '../models/course.dart';
import '../models/task.dart';
import '../services/notification_service.dart';

class TimetableInfo {
  final String id;
  final String name;
  final DateTime createdAt;
  
  TimetableInfo({
    required this.id,
    required this.name,
    required this.createdAt,
  });
  
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'createdAt': createdAt.toIso8601String(),
  };
  
  factory TimetableInfo.fromJson(Map<String, dynamic> json) => TimetableInfo(
    id: json['id'],
    name: json['name'],
    createdAt: DateTime.parse(json['createdAt']),
  );
}

class StorageService {
  static late Box<Course> _coursesBox;
  static late Box<Task> _tasksBox;
  static late Box<dynamic> _settingsBox;
  
  static String _currentTimetableId = 'default';
  static final ValueNotifier<int> _dataChangeNotifier = ValueNotifier<int>(0);

  static ValueListenable<int> get dataChangeListenable => _dataChangeNotifier;

  static void _notifyDataChanged() {
    _dataChangeNotifier.value++;
  }

  static Future<void> init() async {
    _coursesBox = await Hive.openBox<Course>('courses');
    _tasksBox = await Hive.openBox<Task>('tasks');
    _settingsBox = await Hive.openBox('settings');
    
    _currentTimetableId = _settingsBox.get('currentTimetableId', defaultValue: 'default');
    
    if (!_settingsBox.containsKey('timetables')) {
      await _settingsBox.put('timetables', [
        {'id': 'default', 'name': '默认课表', 'createdAt': DateTime.now().toIso8601String()}
      ]);
    }
  }
  
  static String get currentTimetableId => _currentTimetableId;
  
  static List<TimetableInfo> getTimetables() {
    final saved = _settingsBox.get('timetables', defaultValue: []);
    return (saved as List).map((item) => TimetableInfo.fromJson(Map<String, dynamic>.from(item))).toList();
  }
  
  static TimetableInfo? getCurrentTimetable() {
    final timetables = getTimetables();
    return timetables.firstWhere(
      (t) => t.id == _currentTimetableId,
      orElse: () => timetables.first,
    );
  }
  
  static Future<void> createTimetable(String name) async {
    final id = 'tt_${DateTime.now().millisecondsSinceEpoch}';
    final timetables = getTimetables();
    timetables.add(TimetableInfo(
      id: id,
      name: name,
      createdAt: DateTime.now(),
    ));
    await _settingsBox.put('timetables', timetables.map((t) => t.toJson()).toList());
    await switchTimetable(id);
    _notifyDataChanged();
  }
  
  static Future<void> switchTimetable(String id) async {
    _currentTimetableId = id;
    await _settingsBox.put('currentTimetableId', id);
    await _refreshTaskNotifications();
    _notifyDataChanged();
  }
  
  static Future<void> deleteTimetable(String id) async {
    if (id == 'default') return;
    
    final timetables = getTimetables();
    timetables.removeWhere((t) => t.id == id);
    await _settingsBox.put('timetables', timetables.map((t) => t.toJson()).toList());
    
    final courseKeys = _coursesBox.keys.where((k) => k.toString().startsWith('${id}_')).toList();
    for (final key in courseKeys) {
      await _coursesBox.delete(key);
    }
    
    final taskKeys = _tasksBox.keys.where((k) => k.toString().startsWith('${id}_')).toList();
    for (final key in taskKeys) {
      await _tasksBox.delete(key);
    }
    
    final settingKeys = [
      '${id}_timeSlots', '${id}_semesterStartDate', '${id}_semesterWeeks',
      '${id}_dailyPeriods', '${id}_manualCurrentWeek',
    ];
    for (final key in settingKeys) {
      await _settingsBox.delete(key);
    }
    
    if (_currentTimetableId == id) {
      await switchTimetable('default');
    } else {
      await _refreshTaskNotifications();
      _notifyDataChanged();
    }
  }
  
  static Future<void> renameTimetable(String id, String newName) async {
    final timetables = getTimetables();
    final index = timetables.indexWhere((t) => t.id == id);
    if (index != -1) {
      timetables[index] = TimetableInfo(
        id: id,
        name: newName,
        createdAt: timetables[index].createdAt,
      );
      await _settingsBox.put('timetables', timetables.map((t) => t.toJson()).toList());
      _notifyDataChanged();
    }
  }

  // ========== 课程相关 ==========
  static String _courseKey(String id) => '${_currentTimetableId}_$id';
  
  static List<Course> getCourses() {
    return _coursesBox.values
        .where((c) => c.id.startsWith('${_currentTimetableId}_'))
        .toList();
  }

  static Future<void> addCourse(Course course) async {
    final prefixedCourse = Course(
      id: _courseKey(course.id),
      name: course.name,
      teacher: course.teacher,
      location: course.location,
      day: course.day,
      time: course.time,
      duration: course.duration,
      weeks: course.weeks,
      color: course.color,
    );
    await _coursesBox.put(prefixedCourse.id, prefixedCourse);
    _notifyDataChanged();
  }

  static Future<void> updateCourse(Course course) async {
    await _coursesBox.put(course.id, course);
    _notifyDataChanged();
  }

  static Future<void> deleteCourse(String id) async {
    await _coursesBox.delete(id);
    _notifyDataChanged();
  }

  static List<Course> getCoursesByDay(int day) {
    return getCourses().where((c) => c.day == day).toList();
  }

  // ========== 任务相关 ==========
  static String _taskKey(String id) => '${_currentTimetableId}_$id';
  
  static List<Task> getTasks() {
    return _tasksBox.values
        .where((t) => t.id.startsWith('${_currentTimetableId}_'))
        .toList();
  }

  static Future<void> addTask(Task task) async {
    final prefixedTask = Task(
      id: _taskKey(task.id),
      courseId: task.courseId,
      name: task.name,
      type: task.type,
      dueDate: task.dueDate,
      priority: task.priority,
      note: task.note,
    );
    await _tasksBox.put(prefixedTask.id, prefixedTask);
    await _refreshTaskNotifications();
    _notifyDataChanged();
  }

  static Future<void> updateTask(Task task) async {
    await _tasksBox.put(task.id, task);
    await _refreshTaskNotifications();
    _notifyDataChanged();
  }

  static Future<void> deleteTask(String id) async {
    await _tasksBox.delete(id);
    await _refreshTaskNotifications();
    _notifyDataChanged();
  }

  static Future<void> _refreshTaskNotifications() async {
    try {
      await NotificationService.instance.rescheduleTaskNotifications(getTasks());
    } catch (e) {
      debugPrint('_refreshTaskNotifications failed: $e');
    }
  }

  static List<Task> getTasksByDate(DateTime date) {
    return getTasks().where((t) {
      final taskDate = DateTime(t.dueDate.year, t.dueDate.month, t.dueDate.day);
      final targetDate = DateTime(date.year, date.month, date.day);
      return taskDate == targetDate;
    }).toList();
  }

  // ========== 时间段设置 ==========
  static List<Map<String, String>> getDefaultTimeSlots() {
    return [
      {'start': '08:00', 'end': '08:45'},
      {'start': '08:55', 'end': '09:40'},
      {'start': '10:00', 'end': '10:45'},
      {'start': '10:55', 'end': '11:40'},
      {'start': '14:00', 'end': '14:45'},
      {'start': '14:55', 'end': '15:40'},
      {'start': '16:00', 'end': '16:45'},
      {'start': '16:55', 'end': '17:40'},
      {'start': '19:00', 'end': '19:45'},
      {'start': '19:55', 'end': '20:40'},
    ];
  }

  static List<Map<String, String>> getTimeSlots() {
    final saved = _settingsBox.get('${_currentTimetableId}_timeSlots');
    if (saved == null) {
      return getDefaultTimeSlots();
    }
    return List<Map<String, String>>.from(
      (saved as List).map((item) => Map<String, String>.from(item)),
    );
  }

  static Future<void> setTimeSlots(List<Map<String, String>> slots) async {
    await _settingsBox.put('${_currentTimetableId}_timeSlots', slots);
    _notifyDataChanged();
  }

  // ========== 学期设置 ==========
  static DateTime getSemesterStartDate() {
    final saved = _settingsBox.get('${_currentTimetableId}_semesterStartDate');
    if (saved == null) {
      final now = DateTime.now();
      return DateTime(now.year, now.month >= 9 ? 9 : 2, 1);
    }
    return DateTime.parse(saved);
  }

  static Future<void> setSemesterStartDate(DateTime date) async {
    await _settingsBox.put('${_currentTimetableId}_semesterStartDate', date.toIso8601String());
    _notifyDataChanged();
  }

  static int getSemesterWeeks() {
    return _settingsBox.get('${_currentTimetableId}_semesterWeeks', defaultValue: 18);
  }

  static Future<void> setSemesterWeeks(int weeks) async {
    await _settingsBox.put('${_currentTimetableId}_semesterWeeks', weeks);
    _notifyDataChanged();
  }

  static int getCurrentWeek() {
    final manualWeek = _settingsBox.get('${_currentTimetableId}_manualCurrentWeek', defaultValue: -1);
    if (manualWeek != -1) return manualWeek;
    
    final startDate = getSemesterStartDate();
    final now = DateTime.now();
    final diff = now.difference(startDate).inDays;
    final week = (diff ~/ 7) + 1;
    if (week < 1) return 1;
    if (week > getSemesterWeeks()) return getSemesterWeeks();
    return week;
  }
  
  static Future<void> setCurrentWeek(int week) async {
    await _settingsBox.put('${_currentTimetableId}_manualCurrentWeek', week);
    _notifyDataChanged();
  }

  static Future<void> resetCurrentWeek() async {
    await _settingsBox.delete('${_currentTimetableId}_manualCurrentWeek');
    _notifyDataChanged();
  }

  // ========== 每日课程节数 ==========
  static int getDailyPeriods() {
    return _settingsBox.get('${_currentTimetableId}_dailyPeriods', defaultValue: 10);
  }

  static Future<void> setDailyPeriods(int periods) async {
    await _settingsBox.put('${_currentTimetableId}_dailyPeriods', periods);
    _notifyDataChanged();
  }

  // ========== 设置相关 ==========
  static T? getSetting<T>(String key, T? defaultValue) {
    return _settingsBox.get(key, defaultValue: defaultValue) as T?;
  }

  static Future<void> setSetting<T>(String key, T value) async {
    await _settingsBox.put(key, value);
    _notifyDataChanged();
  }

  // ========== 数据导出 ==========
  static Map<String, dynamic> exportData() {
    return {
      'version': '1.0',
      'timetables': getTimetables().map((t) => t.toJson()).toList(),
      'currentTimetableId': _currentTimetableId,
      'courses': getCourses().map((c) => {
        'id': c.id,
        'name': c.name,
        'teacher': c.teacher,
        'location': c.location,
        'day': c.day,
        'time': c.time,
        'duration': c.duration,
        'weeks': c.weeks,
        'color': c.color,
      }).toList(),
      'tasks': getTasks().map((t) => {
        'id': t.id,
        'courseId': t.courseId,
        'name': t.name,
        'type': t.type,
        'dueDate': t.dueDate.toIso8601String(),
        'priority': t.priority,
        'note': t.note,
      }).toList(),
      'settings': {
        'timeSlots': getTimeSlots(),
        'semesterStartDate': getSemesterStartDate().toIso8601String(),
        'semesterWeeks': getSemesterWeeks(),
        'dailyPeriods': getDailyPeriods(),
      },
    };
  }

  static Map<String, dynamic> exportAllDataByTimetableName() {
    final namedTimetables = <String, dynamic>{};
    final usedNames = <String>{};

    for (final timetable in getTimetables()) {
      final backupName = _buildUniqueTimetableBackupName(timetable.name, usedNames);
      namedTimetables[backupName] = _exportSingleTimetableData(timetable);
    }

    return {
      'version': '2.0',
      'backupType': 'full_named_timetables',
      'currentTimetableId': _currentTimetableId,
      'namedTimetables': namedTimetables,
    };
  }

  static Map<String, dynamic> exportSelectedDataByTimetableIds(List<String> timetableIds) {
    final selectedSet = timetableIds.toSet();
    final selectedTimetables = getTimetables().where((t) => selectedSet.contains(t.id)).toList();
    final namedTimetables = <String, dynamic>{};
    final usedNames = <String>{};

    for (final timetable in selectedTimetables) {
      final backupName = _buildUniqueTimetableBackupName(timetable.name, usedNames);
      namedTimetables[backupName] = _exportSingleTimetableData(timetable);
    }

    final currentId = selectedSet.contains(_currentTimetableId)
        ? _currentTimetableId
        : (selectedTimetables.isNotEmpty ? selectedTimetables.first.id : null);

    return {
      'version': '2.0',
      'backupType': 'full_named_timetables',
      'currentTimetableId': currentId,
      'namedTimetables': namedTimetables,
    };
  }

  static List<String> getCloudBackupTimetableNames(Map<String, dynamic> payload) {
    final names = <String>[];

    final namedTimetables = payload['namedTimetables'];
    if (namedTimetables is Map) {
      for (final entry in namedTimetables.entries) {
        if (entry.key is String && entry.value is Map) {
          names.add(entry.key as String);
        }
      }
      if (names.isNotEmpty) {
        return names;
      }
    }

    // Backward compatibility for old single-timetable payload.
    if ((payload['courses'] is List) || (payload['tasks'] is List) || (payload['settings'] is Map)) {
      return ['当前课表'];
    }

    return names;
  }

  static Map<String, dynamic>? getCloudBackupTimetableData(
    Map<String, dynamic> payload,
    String timetableName,
  ) {
    final namedTimetables = payload['namedTimetables'];
    if (namedTimetables is Map && namedTimetables[timetableName] is Map) {
      return Map<String, dynamic>.from(namedTimetables[timetableName] as Map);
    }

    if (timetableName == '当前课表') {
      return {
        'courses': payload['courses'] is List ? payload['courses'] : <dynamic>[],
        'tasks': payload['tasks'] is List ? payload['tasks'] : <dynamic>[],
        'settings': payload['settings'] is Map ? payload['settings'] : <String, dynamic>{},
      };
    }

    return null;
  }

  static String _buildUniqueTimetableBackupName(String rawName, Set<String> usedNames) {
    final baseName = rawName.trim().isEmpty ? '未命名课表' : rawName.trim();
    if (!usedNames.contains(baseName)) {
      usedNames.add(baseName);
      return baseName;
    }

    int suffix = 2;
    while (usedNames.contains('$baseName($suffix)')) {
      suffix++;
    }
    final uniqueName = '$baseName($suffix)';
    usedNames.add(uniqueName);
    return uniqueName;
  }

  static Map<String, dynamic> _exportSingleTimetableData(TimetableInfo timetable) {
    final timetableId = timetable.id;
    final courses = _coursesBox.values
        .where((c) => c.id.startsWith('${timetableId}_'))
        .map((c) => {
              'id': _stripTimetablePrefix(c.id, timetableId),
              'name': c.name,
              'teacher': c.teacher,
              'location': c.location,
              'day': c.day,
              'time': c.time,
              'duration': c.duration,
              'weeks': c.weeks,
              'color': c.color,
            })
        .toList();

    final tasks = _tasksBox.values
        .where((t) => t.id.startsWith('${timetableId}_'))
        .map((t) => {
              'id': _stripTimetablePrefix(t.id, timetableId),
              'courseId': _stripTimetablePrefix(t.courseId, timetableId),
              'name': t.name,
              'type': t.type,
              'dueDate': t.dueDate.toIso8601String(),
              'priority': t.priority,
              'note': t.note,
              'completed': t.completed,
            })
        .toList();

    return {
      'timetableId': timetableId,
      'timetableName': timetable.name,
      'createdAt': timetable.createdAt.toIso8601String(),
      'courses': courses,
      'tasks': tasks,
      'settings': {
        'timeSlots': _getTimeSlotsForTimetable(timetableId),
        'semesterStartDate': _getSemesterStartDateForTimetable(timetableId).toIso8601String(),
        'semesterWeeks': _getSemesterWeeksForTimetable(timetableId),
        'dailyPeriods': _getDailyPeriodsForTimetable(timetableId),
      },
    };
  }

  static String _stripTimetablePrefix(String value, String timetableId) {
    final prefix = '${timetableId}_';
    if (value.startsWith(prefix)) {
      return value.substring(prefix.length);
    }
    return value;
  }

  static List<Map<String, String>> _getTimeSlotsForTimetable(String timetableId) {
    final saved = _settingsBox.get('${timetableId}_timeSlots');
    if (saved == null) {
      return getDefaultTimeSlots();
    }
    return List<Map<String, String>>.from(
      (saved as List).map((item) => Map<String, String>.from(item)),
    );
  }

  static DateTime _getSemesterStartDateForTimetable(String timetableId) {
    final saved = _settingsBox.get('${timetableId}_semesterStartDate');
    if (saved == null) {
      final now = DateTime.now();
      return DateTime(now.year, now.month >= 9 ? 9 : 2, 1);
    }
    return DateTime.parse(saved);
  }

  static int _getSemesterWeeksForTimetable(String timetableId) {
    return _settingsBox.get('${timetableId}_semesterWeeks', defaultValue: 18);
  }

  static int _getDailyPeriodsForTimetable(String timetableId) {
    return _settingsBox.get('${timetableId}_dailyPeriods', defaultValue: 10);
  }

  static String _normalizeImportedEntityId(String rawId) {
    if (rawId.isEmpty) return rawId;

    if (rawId.startsWith('default_')) {
      return rawId.substring('default_'.length);
    }

    if (rawId.startsWith('tt_')) {
      final secondUnderscore = rawId.indexOf('_', 3);
      if (secondUnderscore > 3 && secondUnderscore + 1 < rawId.length) {
        return rawId.substring(secondUnderscore + 1);
      }
    }

    return rawId;
  }

  static Future<ImportResult> importData(Map<String, dynamic> data, {ImportMode mode = ImportMode.merge}) async {
    final result = ImportResult();
    
    try {
      final hasCourses = data.containsKey('courses') && data['courses'] is List;
      final hasTasks = data.containsKey('tasks') && data['tasks'] is List;
      final hasSettings = data.containsKey('settings') && data['settings'] is Map;
      if (!hasCourses && !hasTasks && !hasSettings) {
        result.success = false;
        result.errorMessage = '无效的数据格式：缺少可导入的课程、任务或设置数据';
        return result;
      }

      if (mode == ImportMode.replace) {
        await clearCurrentTimetableData();
      }

      if (data.containsKey('timetables') && data['timetables'] is List) {
        final existingTimetables = getTimetables();
        final existingIds = existingTimetables.map((t) => t.id).toSet();
        
        for (final item in data['timetables'] as List) {
          try {
            final timetable = TimetableInfo.fromJson(Map<String, dynamic>.from(item));
            if (!existingIds.contains(timetable.id)) {
              existingTimetables.add(timetable);
              result.timetablesImported++;
            }
          } catch (e) {
            result.timetableErrors++;
          }
        }
        
        await _settingsBox.put('timetables', existingTimetables.map((t) => t.toJson()).toList());
      }

      if (data.containsKey('courses') && data['courses'] is List) {
        for (final item in data['courses'] as List) {
          try {
            final courseData = Map<String, dynamic>.from(item);
            String courseId = courseData['id']?.toString() ?? '';
            
            if (mode == ImportMode.merge) {
              courseId = _normalizeImportedEntityId(courseId);
            }
            
            final newId = _courseKey(courseId.isEmpty 
                ? 'course_${DateTime.now().millisecondsSinceEpoch}_${result.coursesImported}' 
                : courseId);
            
            final existingCourse = _coursesBox.get(newId);
            if (mode == ImportMode.merge && existingCourse != null) {
              result.coursesSkipped++;
              continue;
            }
            
            final course = Course(
              id: newId,
              name: courseData['name']?.toString() ?? '未命名课程',
              teacher: courseData['teacher']?.toString(),
              location: courseData['location']?.toString(),
              day: courseData['day'] is int ? courseData['day'] : int.tryParse(courseData['day'].toString()) ?? 0,
              time: courseData['time'] is int ? courseData['time'] : int.tryParse(courseData['time'].toString()) ?? 0,
              duration: courseData['duration'] is int ? courseData['duration'] : int.tryParse(courseData['duration'].toString()) ?? 1,
              weeks: courseData['weeks']?.toString(),
              color: courseData['color']?.toString() ?? '#4A90E2',
            );
            
            await _coursesBox.put(course.id, course);
            result.coursesImported++;
          } catch (e) {
            result.courseErrors++;
          }
        }
      }

      if (data.containsKey('tasks') && data['tasks'] is List) {
        for (final item in data['tasks'] as List) {
          try {
            final taskData = Map<String, dynamic>.from(item);
            String taskId = taskData['id']?.toString() ?? '';
            String courseId = taskData['courseId']?.toString() ?? '';
            
            if (mode == ImportMode.merge) {
              taskId = _normalizeImportedEntityId(taskId);
              courseId = _normalizeImportedEntityId(courseId);
            }
            
            final newTaskId = _taskKey(taskId.isEmpty 
                ? 'task_${DateTime.now().millisecondsSinceEpoch}_${result.tasksImported}' 
                : taskId);
            
            final existingTask = _tasksBox.get(newTaskId);
            if (mode == ImportMode.merge && existingTask != null) {
              result.tasksSkipped++;
              continue;
            }
            
            DateTime dueDate;
            try {
              dueDate = taskData['dueDate'] != null 
                  ? DateTime.parse(taskData['dueDate'].toString())
                  : DateTime.now().add(const Duration(days: 1));
            } catch (e) {
              dueDate = DateTime.now().add(const Duration(days: 1));
            }
            
            final task = Task(
              id: newTaskId,
              courseId: courseId.isEmpty ? newTaskId : (courseId.startsWith(_currentTimetableId) ? courseId : _courseKey(courseId)),
              name: taskData['name']?.toString() ?? '未命名任务',
              type: taskData['type']?.toString() ?? '作业',
              dueDate: dueDate,
              priority: taskData['priority']?.toString() ?? '中',
              note: taskData['note']?.toString(),
            );
            
            await _tasksBox.put(task.id, task);
            result.tasksImported++;
          } catch (e) {
            result.taskErrors++;
          }
        }
      }

      if (data.containsKey('settings') && data['settings'] is Map) {
        final settings = Map<String, dynamic>.from(data['settings']);
        
        if (settings.containsKey('timeSlots')) {
          try {
            final slots = List<Map<String, String>>.from(
              (settings['timeSlots'] as List).map((item) => Map<String, String>.from(item)),
            );
            await setTimeSlots(slots);
            result.settingsImported++;
          } catch (e) {}
        }
        
        if (settings.containsKey('semesterStartDate')) {
          try {
            await setSemesterStartDate(DateTime.parse(settings['semesterStartDate'].toString()));
            result.settingsImported++;
          } catch (e) {}
        }
        
        if (settings.containsKey('semesterWeeks')) {
          try {
            await setSemesterWeeks(int.parse(settings['semesterWeeks'].toString()));
            result.settingsImported++;
          } catch (e) {}
        }
        
        if (settings.containsKey('dailyPeriods')) {
          try {
            await setDailyPeriods(int.parse(settings['dailyPeriods'].toString()));
            result.settingsImported++;
          } catch (e) {}
        }
      }

      result.success = true;
      await _refreshTaskNotifications();
      _notifyDataChanged();
    } catch (e) {
      result.success = false;
      result.errorMessage = '导入失败：${e.toString()}';
    }
    
    return result;
  }

  static Future<void> clearCurrentTimetableData() async {
    final courseKeys = _coursesBox.keys.where((k) => k.toString().startsWith('$_currentTimetableId\_')).toList();
    for (final key in courseKeys) {
      await _coursesBox.delete(key);
    }
    
    final taskKeys = _tasksBox.keys.where((k) => k.toString().startsWith('$_currentTimetableId\_')).toList();
    for (final key in taskKeys) {
      await _tasksBox.delete(key);
    }
    
    final settingKeys = [
      '$_currentTimetableId\_timeSlots', '$_currentTimetableId\_semesterStartDate', 
      '$_currentTimetableId\_semesterWeeks', '$_currentTimetableId\_dailyPeriods',
      '$_currentTimetableId\_manualCurrentWeek',
    ];
    for (final key in settingKeys) {
      await _settingsBox.delete(key);
    }

    await _refreshTaskNotifications();
    _notifyDataChanged();
  }

  static Future<void> clearAllData() async {
    await _coursesBox.clear();
    await _tasksBox.clear();
    await _settingsBox.clear();
    await NotificationService.instance.cancelAllTaskNotifications();
    _notifyDataChanged();
  }
}

enum ImportMode {
  merge,
  replace,
}

class ImportResult {
  bool success = false;
  String? errorMessage;
  
  int timetablesImported = 0;
  int timetableErrors = 0;
  
  int coursesImported = 0;
  int coursesSkipped = 0;
  int courseErrors = 0;
  
  int tasksImported = 0;
  int tasksSkipped = 0;
  int taskErrors = 0;
  
  int settingsImported = 0;

  int get totalErrors => courseErrors + taskErrors + timetableErrors;
  int get totalImported => timetablesImported + coursesImported + tasksImported + settingsImported;
  
  String get summary {
    final parts = <String>[];
    if (timetablesImported > 0) parts.add('课表: $timetablesImported');
    if (coursesImported > 0) parts.add('课程: $coursesImported');
    if (tasksImported > 0) parts.add('任务: $tasksImported');
    if (settingsImported > 0) parts.add('设置: $settingsImported');
    if (coursesSkipped > 0 || tasksSkipped > 0) {
      parts.add('跳过: ${coursesSkipped + tasksSkipped}');
    }
    if (totalErrors > 0) {
      parts.add(totalImported > 0 ? '异常条目: $totalErrors' : '错误: $totalErrors');
    }
    return parts.isEmpty ? '无数据导入' : parts.join(', ');
  }
}
