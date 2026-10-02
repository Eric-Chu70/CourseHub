package com.coursehub.app.liveupdate

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import com.coursehub.app.widget.WidgetData
import java.util.Calendar

/**
 * 课程实时活动的闹钟调度
 *
 * 与 WidgetUpdateScheduler 同构（链式：每次触发后重排下一次），但使用独立的
 * requestCode 与广播 action，互不影响——小组件的既有行为不做任何改动。
 *
 * 触发点取以下候选里最近的一个：
 * 1. 上课前 leadMinutes 分钟：胶囊出现
 * 2. 上课时刻：BigText 切成 ProgressStyle
 * 3. 上课中：每分钟一次，推进倒计时与进度条
 * 4. 下课时刻：取消胶囊，并顺延到下一节
 * 今日无课时排到次日 00:05。
 */
object ClassLiveUpdateScheduler {

    private const val REQUEST_CODE = 10002

    fun scheduleNext(context: Context) {
        try {
            // 测试窗口优先：到点醒一次，把展示交还给真实课表
            if (ClassLiveUpdateManager.isTestActive(context)) {
                ClassLiveUpdateManager.setExactAlarm(
                    context,
                    ClassLiveUpdateManager.testUntilMillis(context),
                    tickPendingIntent(context)
                )
                return
            }

            if (!ClassLiveUpdateManager.isEnabled(context)) {
                cancelNext(context)
                ClassLiveUpdateManager.cancel(context)
                return
            }

            val triggerAt = nextTriggerMillis(context) ?: return
            ClassLiveUpdateManager.setExactAlarm(context, triggerAt, tickPendingIntent(context))
        } catch (e: Exception) {
            // 调度失败只损失本次刷新，下次 app 启动或闹钟触发后自愈
        }
    }

    fun cancelNext(context: Context) {
        val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        alarmManager.cancel(tickPendingIntent(context))
    }

    /** 计算下一个需要刷新实时活动的时刻 */
    private fun nextTriggerMillis(context: Context): Long? {
        val data = WidgetData.loadTodayDataAuto(context)
        val nowMillis = System.currentTimeMillis()
        val nowMinutes = WidgetData.getCurrentMinutes()
        val lead = ClassLiveUpdateManager.leadMinutes(context)

        val course = if (data.isHoliday) null else data.nextCourse
        if (course == null ||
            course.startTime.isEmpty() || course.startTime == "00:00" ||
            course.endTime.isEmpty() || course.endTime == "00:00"
        ) {
            return nextDayMillis()
        }

        val startMin = WidgetData.timeToMinutes(course.startTime)
        val endMin = WidgetData.timeToMinutes(course.endTime)
        if (endMin <= startMin) return nextDayMillis()

        val startMillis = ClassLiveUpdateManager.millisOfTodayMinutes(startMin)
        val endMillis = ClassLiveUpdateManager.millisOfTodayMinutes(endMin)
        val candidates = mutableListOf<Long>()

        when {
            // 还没进课前窗口：只在「上课前 lead 分钟」醒一次
            nowMinutes < startMin - lead ->
                candidates.add(startMillis - lead * 60_000L)

            // 已在课前窗口内但未上课：上课时刻切形态（lead=0 时立即补一次）
            nowMinutes < startMin ->
                candidates.add(if (startMillis <= nowMillis) nowMillis + 1_000L else startMillis)

            // 上课中：每分钟推进倒计时
            nowMinutes <= endMin ->
                candidates.add(nowMillis + 60_000L)
        }

        // 兜底：只要这节课还没结束，下课点必须排进去，避免胶囊赖在状态栏
        if (nowMinutes <= endMin) candidates.add(endMillis)

        return candidates.filter { it > nowMillis }.minOrNull() ?: nextDayMillis()
    }

    /** 今日无课/已下课：次日 00:05 重算（跨天后今日课程集合会变） */
    private fun nextDayMillis(): Long = Calendar.getInstance().apply {
        add(Calendar.DAY_OF_MONTH, 1)
        set(Calendar.HOUR_OF_DAY, 0)
        set(Calendar.MINUTE, 5)
        set(Calendar.SECOND, 0)
        set(Calendar.MILLISECOND, 0)
    }.timeInMillis

    private fun tickPendingIntent(context: Context): PendingIntent {
        val intent = Intent(context, ClassLiveUpdateReceiver::class.java).apply {
            action = ClassLiveUpdateReceiver.ACTION_TICK
        }
        return PendingIntent.getBroadcast(
            context, REQUEST_CODE, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }
}
