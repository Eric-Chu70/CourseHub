package com.coursehub.app.widget

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import java.util.Calendar

/**
 * 小组件自动更新调度器
 *
 * 使用 AlarmManager.setExactAndAllowWhileIdle 在每节课结束时精确触发更新。
 * 链式调度：每次闹钟触发后，自动计算并设置下一次闹钟。
 *
 * 调度时机：
 * 1. APPWIDGET_UPDATE（系统或 app 触发更新时）
 * 2. 闹钟触发（WidgetUpdateReceiver.onReceive）
 * 3. BOOT_COMPLETED（设备重启后）
 * 4. MY_PACKAGE_REPLACED（app 更新后）
 */
object WidgetUpdateScheduler {

    private const val REQUEST_CODE = 10001
    const val ACTION_AUTO_UPDATE = "com.coursehub.app.WIDGET_AUTO_UPDATE"

    /**
     * 调度下一次小组件更新
     *
     * 调度策略：
     * 1. 当前有课进行中：1分钟后触发更新（刷新"xx分钟后下课"倒计时，近似实时）
     *    - 用户看 widget 时屏幕亮着，设备不在 Doze，闹钟能正常每分钟触发
     *    - 同时调度课程结束时间点 + 结束前5分钟的触发
     * 2. 当前无课：下一个课程结束时间 + 结束前5分钟触发
     * 3. 没有更多课程：次日0点更新
     */
    fun scheduleNextUpdate(context: Context) {
        try {
            val data = WidgetData.loadTodayData(context)
            val now = Calendar.getInstance()
            val nowMinutes = now.get(Calendar.HOUR_OF_DAY) * 60 + now.get(Calendar.MINUTE)

            // 找到当前时间之后最近的课程结束时间
            var nextEndMinutes: Int? = null
            // 检查当前是否有课正在进行中
            var currentCourseEndMinutes: Int? = null
            for (course in data.courses) {
                if (course.endTime.isEmpty() || course.endTime == "00:00") continue
                val endMin = WidgetData.timeToMinutes(course.endTime)
                val startMin = if (course.startTime.isEmpty() || course.startTime == "00:00") -1
                               else WidgetData.timeToMinutes(course.startTime)
                if (endMin > nowMinutes) {
                    if (nextEndMinutes == null || endMin < nextEndMinutes) {
                        nextEndMinutes = endMin
                    }
                }
                // 当前上课中
                if (startMin >= 0 && nowMinutes >= startMin && nowMinutes <= endMin) {
                    currentCourseEndMinutes = endMin
                }
            }

            val triggers = mutableListOf<Long>()

            // 当前上课中：1分钟后触发（刷新倒计时），近似实时
            if (currentCourseEndMinutes != null) {
                triggers.add(System.currentTimeMillis() + 60_000)
            }

            if (nextEndMinutes != null) {
                val cal = Calendar.getInstance().apply {
                    set(Calendar.HOUR_OF_DAY, nextEndMinutes / 60)
                    set(Calendar.MINUTE, nextEndMinutes % 60)
                    set(Calendar.SECOND, 0)
                    set(Calendar.MILLISECOND, 0)
                    add(Calendar.MINUTE, 1)
                }
                triggers.add(cal.timeInMillis)
            }
            // 当前上课中：在课程结束前5分钟触发一次，让倒计时更准确
            if (currentCourseEndMinutes != null && currentCourseEndMinutes - nowMinutes > 5) {
                val cal = Calendar.getInstance().apply {
                    set(Calendar.HOUR_OF_DAY, (currentCourseEndMinutes - 5) / 60)
                    set(Calendar.MINUTE, (currentCourseEndMinutes - 5) % 60)
                    set(Calendar.SECOND, 0)
                    set(Calendar.MILLISECOND, 0)
                }
                val triggerTime = cal.timeInMillis
                if (triggerTime > System.currentTimeMillis()) {
                    triggers.add(triggerTime)
                }
            }
            if (triggers.isEmpty()) {
                // 没有更多课程，次日0点更新
                val cal = Calendar.getInstance().apply {
                    add(Calendar.DAY_OF_MONTH, 1)
                    set(Calendar.HOUR_OF_DAY, 0)
                    set(Calendar.MINUTE, 1)
                    set(Calendar.SECOND, 0)
                    set(Calendar.MILLISECOND, 0)
                }
                triggers.add(cal.timeInMillis)
            }

            // 设置最近的闹钟
            val triggerAtMillis = triggers.minOrNull() ?: return
            setAlarm(context, triggerAtMillis)
        } catch (e: Exception) {
            // 忽略调度失败
        }
    }

    /** 设置精确闹钟 */
    private fun setAlarm(context: Context, triggerAtMillis: Long) {
        val intent = Intent(context, WidgetUpdateReceiver::class.java).apply {
            action = ACTION_AUTO_UPDATE
        }
        val pendingIntent = PendingIntent.getBroadcast(
            context, REQUEST_CODE, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager

        // Android 12+ (API 31+) 需要检查是否允许设置精确闹钟
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            if (alarmManager.canScheduleExactAlarms()) {
                alarmManager.setExactAndAllowWhileIdle(
                    AlarmManager.RTC_WAKEUP, triggerAtMillis, pendingIntent
                )
            } else {
                // 不允许精确闹钟时，退退用 setAndAllowWhileIdle（非精确，但至少能触发）
                alarmManager.setAndAllowWhileIdle(
                    AlarmManager.RTC_WAKEUP, triggerAtMillis, pendingIntent
                )
            }
        } else {
            alarmManager.setExactAndAllowWhileIdle(
                AlarmManager.RTC_WAKEUP, triggerAtMillis, pendingIntent
            )
        }
    }

    /** 取消已调度的更新 */
    fun cancelNextUpdate(context: Context) {
        val intent = Intent(context, WidgetUpdateReceiver::class.java).apply {
            action = ACTION_AUTO_UPDATE
        }
        val pendingIntent = PendingIntent.getBroadcast(
            context, REQUEST_CODE, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        alarmManager.cancel(pendingIntent)
    }
}
