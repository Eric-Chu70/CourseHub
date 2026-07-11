package com.coursehub.app.widget

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.updateAll
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/**
 * 接收 AlarmManager 闹钟广播，触发所有小组件更新
 *
 * 更新流程：
 * 1. 接收 WIDGET_AUTO_UPDATE 广播
 * 2. 调用所有 widget 的 updateAll()（会重新读取 SharedPreferences 并根据当前时间过滤课程）
 * 3. 重新调度下一次更新（链式调度）
 */
class WidgetUpdateReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != WidgetUpdateScheduler.ACTION_AUTO_UPDATE &&
            intent.action != Intent.ACTION_BOOT_COMPLETED &&
            intent.action != "android.intent.action.QUICKBOOT_POWERON"
        ) return

        val pendingResult = goAsync()
        CoroutineScope(Dispatchers.Default).launch {
            try {
                // 更新所有今日课程类小组件
                // updateAll 会触发 provideGlance，其中会调用 loadTodayDataFiltered
                // 根据当前时间重新过滤课程
                TodaySmallWidget().updateAll(context.applicationContext)
                TodayMediumWidget().updateAll(context.applicationContext)
                TodayLargeWidget().updateAll(context.applicationContext)
            } catch (e: Exception) {
                // 忽略更新失败
            } finally {
                // 链式调度下一次更新
                try {
                    WidgetUpdateScheduler.scheduleNextUpdate(context.applicationContext)
                    // 同时刷新 WorkManager 周期任务
                    WidgetUpdateWorker.enqueuePeriodic(context.applicationContext)
                } catch (e: Exception) {
                    // 忽略调度失败
                }
                pendingResult.finish()
            }
        }
    }
}
