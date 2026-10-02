package com.coursehub.app.liveupdate

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * 课程实时活动的广播入口
 *
 * 四类触发：
 * 1. ACTION_TICK：闹钟到点，重算并续链
 * 2. ACTION_SKIP_ONCE：用户点「取消本次提醒」或滑掉胶囊，本次课不再展示
 * 3. BOOT_COMPLETED / QUICKBOOT_POWERON：开机后续上闹钟链
 * 4. MY_PACKAGE_REPLACED：覆盖安装后系统会清掉旧闹钟，需重排
 *
 * 全部同步执行：只做一次 JSON 解析 + 一次 notify，远低于广播 10s 预算，
 * 不引入协程与 goAsync，避免与小组件接收器的续链时序相互干扰。
 */
class ClassLiveUpdateReceiver : BroadcastReceiver() {

    companion object {
        const val ACTION_TICK = "com.coursehub.app.LIVE_UPDATE_TICK"
        const val ACTION_SKIP_ONCE = "com.coursehub.app.LIVE_UPDATE_SKIP_ONCE"
        const val ACTION_STOP_TEST = "com.coursehub.app.LIVE_UPDATE_STOP_TEST"
        const val EXTRA_COURSE_KEY = "course_key"
        const val EXTRA_END_MINUTES = "end_minutes"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val appContext = context.applicationContext
        try {
            when (intent.action) {
                ACTION_TICK -> {
                    ClassLiveUpdateManager.refresh(appContext)
                    ClassLiveUpdateScheduler.scheduleNext(appContext)
                }

                ACTION_SKIP_ONCE -> {
                    val key = intent.getStringExtra(EXTRA_COURSE_KEY) ?: return
                    val endMinutes = intent.getIntExtra(EXTRA_END_MINUTES, -1)
                    if (endMinutes < 0) return
                    ClassLiveUpdateManager.skipOnce(appContext, key, endMinutes)
                }

                ACTION_STOP_TEST ->
                    ClassLiveUpdateManager.stopTest(appContext)

                Intent.ACTION_BOOT_COMPLETED,
                "android.intent.action.QUICKBOOT_POWERON",
                Intent.ACTION_MY_PACKAGE_REPLACED -> {
                    ClassLiveUpdateManager.refresh(appContext)
                    ClassLiveUpdateScheduler.scheduleNext(appContext)
                }
            }
        } catch (e: Exception) {
            // 广播内不允许抛异常：失败仅损失本次刷新
        }
    }
}
