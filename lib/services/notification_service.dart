import 'dart:async';

import 'package:awesome_notifications/awesome_notifications.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/task.dart';

enum NotificationCopyStyle {
  casual,
  serious,
  motivational,
}

NotificationCopyStyle notificationCopyStyleFromValue(String? value) {
  switch (value) {
    case 'serious':
      return NotificationCopyStyle.serious;
    case 'motivational':
      return NotificationCopyStyle.motivational;
    case 'casual':
    default:
      return NotificationCopyStyle.casual;
  }
}

String notificationCopyStyleValue(NotificationCopyStyle style) {
  switch (style) {
    case NotificationCopyStyle.serious:
      return 'serious';
    case NotificationCopyStyle.motivational:
      return 'motivational';
    case NotificationCopyStyle.casual:
      return 'casual';
  }
}

class NotificationTemplate {
  final String title;
  final String body;

  const NotificationTemplate({required this.title, required this.body});
}

class TaskNotificationSettings {
  final bool enabled;
  final int days;
  final int hours;
  final int minutes;
  final NotificationCopyStyle style;

  const TaskNotificationSettings({
    required this.enabled,
    required this.days,
    required this.hours,
    required this.minutes,
    required this.style,
  });

  Duration get leadTime => Duration(days: days, hours: hours, minutes: minutes);
}

class NotificationService {
  NotificationService._();

  static final NotificationService instance = NotificationService._();

  static const String _enabledKey = 'task_notification_enabled';
  static const String _daysKey = 'task_notification_days';
  static const String _hoursKey = 'task_notification_hours';
  static const String _minutesKey = 'task_notification_minutes';
  static const String _styleKey = 'task_notification_copy_style';

  static const String _channelKey = 'task_deadline_channel';
  static const String _channelName = '任务临期提醒';
  static const String _channelDesc = '任务截止前提醒通知';

  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;

    debugPrint('[Notify] init start');

    await AwesomeNotifications().initialize(
      null,
      [
        NotificationChannel(
          channelKey: _channelKey,
          channelName: _channelName,
          channelDescription: _channelDesc,
          importance: NotificationImportance.High,
          defaultColor: const Color(0xFF4A90E2),
          ledColor: const Color(0xFF4A90E2),
        ),
      ],
    );

    _initialized = true;
    debugPrint('[Notify] init done');
  }

  Future<TaskNotificationSettings> getTaskNotificationSettings() async {
    final prefs = await SharedPreferences.getInstance();
    return TaskNotificationSettings(
      enabled: prefs.getBool(_enabledKey) ?? false,
      days: prefs.getInt(_daysKey) ?? 0,
      hours: prefs.getInt(_hoursKey) ?? 2,
      minutes: prefs.getInt(_minutesKey) ?? 0,
      style: notificationCopyStyleFromValue(prefs.getString(_styleKey)),
    );
  }

  Future<void> saveTaskNotificationSettings({
    required bool enabled,
    required int days,
    required int hours,
    required int minutes,
    required NotificationCopyStyle style,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, enabled);
    await prefs.setInt(_daysKey, days.clamp(0, 30));
    await prefs.setInt(_hoursKey, hours.clamp(0, 23));
    await prefs.setInt(_minutesKey, minutes.clamp(0, 59));
    await prefs.setString(_styleKey, notificationCopyStyleValue(style));
  }

  Future<bool> requestNotificationPermission() async {
    await init();
    final granted = await AwesomeNotifications().requestPermissionToSendNotifications();
    debugPrint('[Notify] permission granted: $granted');
    return granted;
  }

  Future<void> cancelAllTaskNotifications() async {
    await AwesomeNotifications().cancelAll();
    debugPrint('[Notify] cancelAll done');
  }

  Future<void> rescheduleTaskNotifications(List<Task> tasks) async {
    await init();
    final settings = await getTaskNotificationSettings();

    debugPrint('[Notify] rescheduling ${tasks.length} tasks');

    var scheduledCount = 0;
    var skippedCount = 0;
    var errorCount = 0;

    await AwesomeNotifications().cancelAll();

    if (!settings.enabled) {
      debugPrint('[Notify] notifications disabled');
      return;
    }

    final now = DateTime.now();
    final leadTime = settings.leadTime;
    final soonFallbackAt = now.add(const Duration(minutes: 1));

    for (final task in tasks) {
      if (task.completed) {
        skippedCount++;
        continue;
      }
      if (!task.dueDate.isAfter(now)) {
        skippedCount++;
        continue;
      }

      var notifyAt = task.dueDate.subtract(leadTime);
      if (!notifyAt.isAfter(now)) {
        if (task.dueDate.isAfter(soonFallbackAt)) {
          notifyAt = soonFallbackAt;
        } else {
          skippedCount++;
          continue;
        }
      }

      final templates = _buildTemplates(
        task: task,
        dueDate: task.dueDate,
        remaining: task.dueDate.difference(notifyAt),
        style: settings.style,
      );
      final index = (task.id.hashCode ^ task.dueDate.millisecondsSinceEpoch).abs() % templates.length;
      final selectedTemplate = templates[index];
      final notifyId = _notificationIdForTask(task);

      try {
        await AwesomeNotifications().createNotification(
          content: NotificationContent(
            id: notifyId,
            channelKey: _channelKey,
            title: selectedTemplate.title,
            body: selectedTemplate.body,
            payload: {'taskId': task.id},
          ),
          schedule: NotificationCalendar.fromDate(date: notifyAt),
        );
        scheduledCount++;
        debugPrint('[Notify] ✅ scheduled id=$notifyId at=$notifyAt');
      } catch (e) {
        debugPrint('[Notify] ❌ schedule failed id=$notifyId: $e');
        errorCount++;
      }
    }

    debugPrint('[Notify] summary: scheduled=$scheduledCount, skipped=$skippedCount, errors=$errorCount');
  }

  String formatLeadTimeText(int days, int hours, int minutes) {
    final parts = <String>[];
    if (days > 0) parts.add('$days 天');
    if (hours > 0) parts.add('$hours 小时');
    if (minutes > 0) parts.add('$minutes 分钟');
    return parts.isEmpty ? '截止时提醒' : parts.join('');
  }

  String copyStyleLabel(NotificationCopyStyle style) {
    switch (style) {
      case NotificationCopyStyle.casual:
        return '轻松';
      case NotificationCopyStyle.serious:
        return '严肃';
      case NotificationCopyStyle.motivational:
        return '鸡血';
    }
  }

  String copyStyleDescription(NotificationCopyStyle style) {
    switch (style) {
      case NotificationCopyStyle.casual:
        return '像同学提醒，语气轻松接地气';
      case NotificationCopyStyle.serious:
        return '正式稳重，适合计划导向';
      case NotificationCopyStyle.motivational:
        return '鼓励冲刺，适合临近DDL';
    }
  }

  int _notificationIdForTask(Task task) {
    final hash = task.id.hashCode ^ task.dueDate.millisecondsSinceEpoch.hashCode;
    final id = hash & 0x7fffffff;
    return id == 0 ? 1 : id;
  }

  List<NotificationTemplate> _buildTemplates({
    required Task task,
    required DateTime dueDate,
    required Duration remaining,
    required NotificationCopyStyle style,
  }) {
    final dueText = DateFormat('M月d日 HH:mm').format(dueDate);
    final remainingText = _formatRemaining(remaining);

    switch (style) {
      case NotificationCopyStyle.casual:
        return [
          NotificationTemplate(
            title: 'Hi！你是否还记得 ${task.name} 仍未完成呢',
            body: '${task.name} 还有 $remainingText 就截止啦！请注意合理安排时间（截止：$dueText）。',
          ),
          NotificationTemplate(
            title: '别拖啦，${task.name} 快到点啦',
            body: '你还有 $remainingText 可以搞定 ${task.name}，截止时间是 $dueText，别等最后一分钟。',
          ),
          NotificationTemplate(
            title: '学习搭子提醒：${task.name}',
            body: '温馨提醒：${task.name} 还没完成，距离截止只剩 $remainingText（$dueText）。',
          ),
          NotificationTemplate(
            title: '滴滴！${task.name} 要交啦',
            body: '${task.name} 的 DDL 还有 $remainingText，截止在 $dueText，冲一波就完事。',
          ),
          NotificationTemplate(
            title: '再提醒你一下：${task.name}',
            body: '${task.name} 将在 $dueText 截止，现在到截止只剩 $remainingText。',
          ),
        ];
      case NotificationCopyStyle.serious:
        return [
          NotificationTemplate(
            title: '任务截止提醒：${task.name}',
            body: '任务 ${task.name} 距离截止还剩 $remainingText，截止时间 $dueText，请尽快安排处理。',
          ),
          NotificationTemplate(
            title: '请关注任务进度：${task.name}',
            body: '当前距 ${task.name} 截止还有 $remainingText（$dueText），建议优先完成。',
          ),
          NotificationTemplate(
            title: '时间节点提醒：${task.name}',
            body: '${task.name} 将于 $dueText 截止，剩余时间 $remainingText，请及时提交。',
          ),
          NotificationTemplate(
            title: '临期通知：${task.name}',
            body: '请注意：${task.name} 进入临期阶段，距离截止仅 $remainingText（$dueText）。',
          ),
          NotificationTemplate(
            title: '任务管理提醒：${task.name}',
            body: '${task.name} 截止时间为 $dueText，目前剩余 $remainingText，建议立即处理。',
          ),
        ];
      case NotificationCopyStyle.motivational:
        return [
          NotificationTemplate(
            title: '冲刺时间到！${task.name}',
            body: '${task.name} 还有 $remainingText 截止（$dueText），现在开干，稳稳拿下。',
          ),
          NotificationTemplate(
            title: '别怂，${task.name} 一把过',
            body: '距离 ${task.name} 截止还剩 $remainingText，截止 $dueText，先做完再放松。',
          ),
          NotificationTemplate(
            title: '今天也要赢：${task.name}',
            body: '${task.name} 的截止时间是 $dueText，倒计时 $remainingText，冲刺就现在。',
          ),
          NotificationTemplate(
            title: '就差这一步：${task.name}',
            body: '${task.name} 还剩 $remainingText 截止（$dueText），现在推进一段，进度就起来了。',
          ),
          NotificationTemplate(
            title: 'DDL 在前，行动在先',
            body: '${task.name} 距离截止仅 $remainingText，时间点 $dueText，马上行动，别给拖延留机会。',
          ),
        ];
    }
  }

  String _formatRemaining(Duration duration) {
    var minutes = duration.inMinutes;
    if (minutes <= 0) return '不到1分钟';

    final days = minutes ~/ (24 * 60);
    minutes -= days * 24 * 60;
    final hours = minutes ~/ 60;
    minutes -= hours * 60;

    final parts = <String>[];
    if (days > 0) parts.add('$days 天');
    if (hours > 0) parts.add('$hours 小时');
    if (minutes > 0) parts.add('$minutes 分钟');
    return parts.join('');
  }
}
