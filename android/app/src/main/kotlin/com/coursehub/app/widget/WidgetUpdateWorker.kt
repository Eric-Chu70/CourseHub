package com.coursehub.app.widget

import android.content.Context
import androidx.glance.appwidget.updateAll
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import java.util.concurrent.TimeUnit

/**
 * WorkManager 周期性小组件更新 Worker
 *
 * 作为 AlarmManager 的兜底方案：即使 app 被系统杀死、闹钟被 ROM 限制，
 * WorkManager 由系统调度（基于 JobScheduler），更抗国产 ROM 杀后台。
 *
 * 周期：15 分钟（WorkManager 周期性任务的最小值）
 * 任务：更新所有今日课程类小组件 + 链式调度下一次 AlarmManager
 */
class WidgetUpdateWorker(
    context: Context,
    params: WorkerParameters
) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        return try {
            val context = applicationContext
            // 更新所有小组件（provideGlance 会调用 loadTodayDataAuto 自治计算）
            TodaySmallWidget().updateAll(context)
            TodayMediumWidget().updateAll(context)
            TodayLargeWidget().updateAll(context)
            // 同步重新调度 AlarmManager（精确触发）
            WidgetUpdateScheduler.scheduleNextUpdate(context)
            Result.success()
        } catch (e: Exception) {
            Result.retry()
        }
    }

    companion object {
        private const val WORK_NAME = "widget_update_work"

        /**
         * 启动/刷新周期性任务
         *
         * 使用 KEEP 策略：如果已有同名任务，保留原任务（避免重复创建）。
         * 在以下时机调用：
         * - APPWIDGET_UPDATE（widget 被添加或系统刷新时）
         * - APP 启动
         * - BOOT_COMPLETED
         */
        fun enqueuePeriodic(context: Context) {
            val constraints = Constraints.Builder()
                .build()

            val request = PeriodicWorkRequestBuilder<WidgetUpdateWorker>(
                15, TimeUnit.MINUTES
            )
                .setConstraints(constraints)
                .build()

            WorkManager.getInstance(context).enqueueUniquePeriodicWork(
                WORK_NAME,
                ExistingPeriodicWorkPolicy.KEEP,
                request
            )
        }

        /** 取消周期性任务（卸载 widget 时可选调用） */
        fun cancelPeriodic(context: Context) {
            WorkManager.getInstance(context).cancelUniqueWork(WORK_NAME)
        }
    }
}
